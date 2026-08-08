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

    /// Domain vocabulary fed to every recognition request (2026-08-07
    /// roundtable A3 — "zero contextualStrings" was the highest-leverage STT
    /// fix). Apple's on-device model has never heard "Sekushi" or "Kavika";
    /// contextualStrings biases recognition toward these exact spellings.
    static let contextualStrings: [String] = [
        "Sekushi", "Kokoro", "Merlin", "Kai", "Jarvis", "AlohaVoice",
        "Sophie", "SCG", "Gemma", "Malia", "Bellavino", "Oahu", "ohana",
    ]

    // Live recording state — used by the Settings test button (B1 verification ship).
    private var liveEngine: AVAudioEngine?
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?

    // Push-based streaming state (conversation flow) — see startStreaming. Owns
    // NO engine/session; the conversation session feeds it from its own mic tap.
    // streamLock guards streamRequest/streamTask: appendStreaming/endStreaming
    // are invoked from the conversation session's AUDIO render thread while
    // start/cancel run on the main actor — unguarded, that's a real data race
    // (2026-08-07 roundtable A1, render-thread races).
    private let streamLock = NSLock()
    private var streamRequest: SFSpeechAudioBufferRecognitionRequest?
    private var streamTask: SFSpeechRecognitionTask?
    // Pre-test session snapshot — restored on cleanup so the conversation flow's
    // .playAndRecord/.spokenAudio session isn't stranded by our .record/.measurement.
    private var savedCategory: AVAudioSession.Category?
    private var savedMode: AVAudioSession.Mode?
    private var savedOptions: AVAudioSession.CategoryOptions = []

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
        request.contextualStrings = Self.contextualStrings
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
            // Snapshot the conversation flow's session config so we can restore it on cleanup.
            self.savedCategory = session.category
            self.savedMode = session.mode
            self.savedOptions = session.categoryOptions
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
        request.contextualStrings = Self.contextualStrings

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
        // Restore the conversation flow's session config (.playAndRecord/.spokenAudio)
        // so the user can resume talking without force-quitting. Don't deactivate —
        // leave the session live so the conversation surface's tap can engage.
        let session = AVAudioSession.sharedInstance()
        if let cat = savedCategory, let mode = savedMode {
            try? session.setCategory(cat, mode: mode, options: savedOptions)
            try? session.setActive(true, options: [])
        }
        savedCategory = nil
        savedMode = nil
        savedOptions = []
    }

    // MARK: - Push-based streaming (conversation flow)
    //
    // Unlike startLive (the Settings test button), this owns NO AVAudioEngine and
    // NO audio session — the conversation session (OnDeviceConversationSession)
    // already holds the mic tap and session. It feeds converted 16 kHz frames via
    // appendStreaming as the user speaks, so recognition runs DURING speech and
    // the final is ready within the recognizer's short drain (~100-300 ms) after
    // endStreaming(), instead of a cold full-utterance batch (~300-1200 ms) at
    // end-of-speech. onPartial streams the incremental transcript; onFinal fires
    // exactly once, shortly after endStreaming() (or immediately on error).

    /// Begin a live streaming recognition. Returns false (and fires onFinal with
    /// the reason) if the recognizer is unauthorized/unavailable.
    func startStreaming(onPartial: @escaping (String) -> Void,
                        onFinal: @escaping (Result<String, STTError>) -> Void) -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            onFinal(.failure(.notAuthorized)); return false
        }
        guard let recognizer, recognizer.isAvailable, supportsOnDevice else {
            onFinal(.failure(.onDeviceUnavailable)); return false
        }
        // Abandon any prior stream (e.g. a dropped tiny utterance) first.
        cancelStreaming()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true   // no Apple-server round trip
        request.shouldReportPartialResults = true    // stream partials as we feed
        request.contextualStrings = Self.contextualStrings
        streamLock.lock()
        self.streamRequest = request
        streamLock.unlock()

        var settled = false
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    if settled { return }
                    settled = true
                    onFinal(text.isEmpty ? .failure(.emptyResult) : .success(text))
                } else {
                    onPartial(text)
                }
            }
            if let error {
                if settled { return }
                settled = true
                onFinal(.failure(.recognitionFailed(error.localizedDescription)))
            }
        }
        streamLock.lock()
        self.streamTask = task
        streamLock.unlock()
        return true
    }

    /// Feed converted mic audio (16 kHz mono float32) to the live recognizer.
    /// Called from the conversation session's mic tap; SFSpeechAudioBufferRecognitionRequest
    /// is designed to be appended off the main thread (startLive does the same).
    func appendStreaming(_ buffer: AVAudioPCMBuffer) {
        streamLock.lock()
        let request = streamRequest
        streamLock.unlock()
        request?.append(buffer)
    }

    /// Close the audio stream. The recognizer drains its buffered audio and fires
    /// the final through onFinal (passed to startStreaming) shortly after.
    func endStreaming() {
        streamLock.lock()
        let request = streamRequest
        streamLock.unlock()
        request?.endAudio()
    }

    /// Abandon the current stream without waiting for a final (teardown / dropped
    /// short utterance). Safe to call when no stream is active.
    func cancelStreaming() {
        streamLock.lock()
        let task = streamTask
        let request = streamRequest
        streamTask = nil
        streamRequest = nil
        streamLock.unlock()
        task?.cancel()
        request?.endAudio()
    }
}
