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
}
