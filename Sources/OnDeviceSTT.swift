//
//  OnDeviceSTT.swift
//  GemmaVoice
//
//  Apple Speech framework wrapper forcing on-device recognition. Used as
//  a fallback when the server-side Whisper/Parakeet endpoint is unreachable
//  (e.g. KPC offline, plane wifi, hotel captive portal). Trades away server
//  speaker verification for offline capability.
//
//  Caller pattern:
//    OnDeviceSTT.shared.requestAuthorizationIfNeeded()
//    OnDeviceSTT.shared.transcribe(pcm: wav16kMonoFloat32) { result in ... }
//

import Foundation
import Speech
import AVFoundation

@MainActor
final class OnDeviceSTT {
    static let shared = OnDeviceSTT()

    enum STTError: Error {
        case notAuthorized
        case onDeviceUnavailable
        case recognitionFailed(String)
        case emptyResult
    }

    private let recognizer: SFSpeechRecognizer?

    // Live recording state — used by the Settings test button (B1 verification ship).
    private var liveEngine: AVAudioEngine?
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?

    private init() {
        // en-US covers Sherman's usage. A locale picker can come later.
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    var supportsOnDevice: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    var isAvailable: Bool {
        (recognizer?.isAvailable ?? false) && supportsOnDevice
    }

    func requestAuthorizationIfNeeded(_ completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    completion(status == .authorized)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    /// Transcribe a PCM buffer (16 kHz mono float32) on-device. Returns the
    /// final transcript string via the completion closure. No streaming —
    /// the caller hands us a complete utterance.
    func transcribe(pcm: Data,
                    sampleRate: Double = 16_000,
                    completion: @escaping (Result<String, STTError>) -> Void) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            completion(.failure(.notAuthorized))
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            completion(.failure(.onDeviceUnavailable))
            return
        }
        guard supportsOnDevice else {
            completion(.failure(.onDeviceUnavailable))
            return
        }

        // Wrap raw PCM bytes in an AVAudioPCMBuffer.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            completion(.failure(.recognitionFailed("bad format")))
            return
        }

        let frameCount = UInt32(pcm.count / MemoryLayout<Float>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: frameCount) else {
            completion(.failure(.recognitionFailed("buffer alloc failed")))
            return
        }
        buffer.frameLength = frameCount
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let dst = buffer.floatChannelData![0]
            memcpy(dst, base, Int(frameCount) * MemoryLayout<Float>.size)
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // no Apple-server round trip
        request.shouldReportPartialResults = false
        request.append(buffer)
        request.endAudio()

        var finished = false
        recognizer.recognitionTask(with: request) { result, error in
            if finished { return }
            if let error {
                finished = true
                completion(.failure(.recognitionFailed(error.localizedDescription)))
                return
            }
            guard let result else { return }
            if result.isFinal {
                finished = true
                let text = result.bestTranscription.formattedString
                if text.isEmpty {
                    completion(.failure(.emptyResult))
                } else {
                    completion(.success(text))
                }
            }
        }
    }

    /// Live mic capture + on-device transcription for the Settings test button.
    /// Caller drives start/stop; partial results stream during the session, the
    /// final transcript fires once after stopLive() is called and the recognizer
    /// drains. Configures its own AVAudioSession; restores .ambient on stop so
    /// it doesn't strand the conversation flow's session state.
    func startLive(onPartial: @escaping (String) -> Void,
                   onFinal: @escaping (Result<String, STTError>) -> Void) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            onFinal(.failure(.notAuthorized))
            return
        }
        guard let recognizer, recognizer.isAvailable, supportsOnDevice else {
            onFinal(.failure(.onDeviceUnavailable))
            return
        }
        // Don't double-start.
        if liveEngine != nil { stopLive() }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            onFinal(.failure(.recognitionFailed("audio session: \(error.localizedDescription)")))
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            request.append(buf)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            onFinal(.failure(.recognitionFailed("engine start: \(error.localizedDescription)")))
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            return
        }

        self.liveEngine = engine
        self.liveRequest = request

        var settled = false
        self.liveTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                onPartial(text)
                if result.isFinal {
                    if settled { return }
                    settled = true
                    if text.isEmpty {
                        onFinal(.failure(.emptyResult))
                    } else {
                        onFinal(.success(text))
                    }
                    self.cleanupLive()
                }
            }
            if let error {
                if settled { return }
                settled = true
                onFinal(.failure(.recognitionFailed(error.localizedDescription)))
                self.cleanupLive()
            }
        }
    }

    /// Stop capture; the recognizer still has a few hundred ms of audio to drain
    /// before it fires .isFinal back through the closure passed to startLive.
    func stopLive() {
        liveEngine?.stop()
        liveEngine?.inputNode.removeTap(onBus: 0)
        liveRequest?.endAudio()
    }

    private func cleanupLive() {
        liveEngine = nil
        liveRequest = nil
        liveTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
