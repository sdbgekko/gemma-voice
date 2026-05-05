//
//  OnDeviceConversationSession.swift
//  GemmaVoice
//
//  B2 on-device STT path (v0.2.16). Runs the full conversation loop with
//  transcription happening locally on the phone — no audio leaves the
//  device for STT. After end-of-utterance, the transcribed text is posted
//  to the server's /text_turn endpoint (see TextTurnClient.swift) and the
//  Kokoro PCM reply streams back for playback through this same engine.
//
//  This is a sibling of StreamingSession (the WebSocket audio path). When
//  the @AppStorage("useOnDeviceSTT") toggle is ON, StreamingViewModel
//  drives this class instead of StreamingSession. WebSocket path is
//  untouched and continues to work when toggle is OFF.
//
//  End-of-utterance detection: heuristic — 800ms continuous below an RMS
//  floor (matched to the server's silero/RMS_FLOOR rough range). The
//  dispatch noted that mirroring server VAD timing is preferred but a
//  heuristic is acceptable for v1. Tuning notes in code below.
//

import AVFoundation
import Foundation
import UIKit

@MainActor
final class OnDeviceConversationSession: NSObject {
    enum Event {
        case speechStart
        case speechEnd
        case transcriptYou(String)
        case transcriptGemma(String)
        case ttsEnd
        case dropped(String)
        case sessionError(Error)
        case level(Float)
    }

    var onEvent: ((Event) -> Void)?

    // Audio I/O
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let captureFormat: AVAudioFormat   // 16kHz mono float32 — for OnDeviceSTT
    private let ttsFormat: AVAudioFormat       // 24kHz mono float32 — Kokoro PCM playback
    private var converter: AVAudioConverter?
    /// Resamples 24kHz Kokoro PCM to playerNode's connection format. Same
    /// mechanism as StreamingSession — required to keep TTS audible under
    /// .voiceChat session mode (which forces hw to 16kHz).
    private var ttsResampler: AVAudioConverter?
    private var playerConnectionFormat: AVAudioFormat?

    // VAD / utterance buffering
    private var pcmAccumulator: [Float] = []   // current utterance (16kHz f32)
    private let accumulatorLock = NSLock()
    /// RMS floor matched to the server's RMS_FLOOR (0.005). Below this is
    /// treated as silence for VAD purposes.
    private let speechRmsThreshold: Float = 0.012   // a bit higher than server floor — local mic gain runs hotter
    /// Frames of continuous silence required to end an utterance. 32ms per
    /// frame at 16kHz/512-sample chunks → 25 frames = 800ms. Matches the
    /// "shorter heuristic" called out in the dispatch.
    private let silenceFramesToCut = 25
    /// Minimum utterance length, also in 32ms frames. 15 = 480ms (matches
    /// server MIN_UTTERANCE_FRAMES).
    private let minUtteranceFrames = 15
    /// Hard cap so a runaway buffer doesn't grow unbounded. ~30s.
    private let maxUtteranceFrames = 30_000 / 32
    private let frameSize: AVAudioFrameCount = 512
    private var silenceFrameCount = 0
    private var speechFrameCount = 0
    private var inSpeech = false

    // State machine
    private var isRunning = false
    private var isMuted = false
    /// While the LLM is thinking or TTS is playing, we suspend new
    /// utterance detection so the user doesn't talk over Gemma's reply
    /// (and vice versa). Re-enabled on tts_end / error.
    private var isProcessing = false

    // Networking — injected so tests can swap a mock.
    private let textTurnClient: TextTurnClientProtocol
    /// Stable session id sent to the server with each turn for log
    /// correlation. Re-rolled on every full session start.
    private var sessionId: String = UUID().uuidString

    init?(client: TextTurnClientProtocol) {
        guard let cap = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16_000,
                                      channels: 1,
                                      interleaved: true),
              let tts = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 24_000,
                                      channels: 1,
                                      interleaved: true) else { return nil }
        self.captureFormat = cap
        self.ttsFormat = tts
        self.textTurnClient = client
        super.init()
    }

    func start() throws {
        guard !isRunning else { return }
        sessionId = UUID().uuidString

        let session = AVAudioSession.sharedInstance()
        // Same category/mode as StreamingSession so the audio routes line
        // up with the rest of the app's UX (Bluetooth, speaker fallback).
        // v0.2.18: rolled back to .spokenAudio matching StreamingSession.
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true, options: [])
        if !hasExternalOutputRoute(session) {
            try? session.overrideOutputAudioPort(.speaker)
        }

        engine.attach(playerNode)
        let connFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: connFormat)
        self.playerConnectionFormat = connFormat
        self.ttsResampler = AVAudioConverter(from: ttsFormat, to: connFormat)

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        self.converter = AVAudioConverter(from: hwFormat, to: captureFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        playerNode.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isRunning = false
        accumulatorLock.lock()
        pcmAccumulator.removeAll(keepingCapacity: false)
        silenceFrameCount = 0
        speechFrameCount = 0
        inSpeech = false
        accumulatorLock.unlock()
    }

    func mute() { isMuted = true }
    func unmute() { isMuted = false }

    /// Force-cut the current utterance immediately (Sherman tapping send).
    func forceCut() {
        accumulatorLock.lock()
        guard inSpeech, speechFrameCount >= minUtteranceFrames else {
            accumulatorLock.unlock()
            return
        }
        let pcm = pcmAccumulator
        pcmAccumulator.removeAll(keepingCapacity: true)
        silenceFrameCount = 0
        speechFrameCount = 0
        inSpeech = false
        accumulatorLock.unlock()
        Task { await processUtterance(pcm: pcm) }
    }

    // MARK: - Mic loop

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        if isMuted || isProcessing {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(.level(0)) }
            return
        }
        guard let converter = converter else { return }
        let sourceRate = buffer.format.sampleRate
        let ratio = captureFormat.sampleRate / sourceRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: outCapacity) else { return }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return }
        let frameCount = Int(out.frameLength)
        guard frameCount > 0, let ch = out.floatChannelData?[0] else { return }
        var samples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount { samples[i] = ch[i] }

        accumulatorLock.lock()
        pcmAccumulator.append(contentsOf: samples)
        // Process in fixed-size 512-sample chunks so VAD timing matches
        // the server's silero (which also runs at 32ms/frame at 16kHz).
        let chunk = Int(frameSize)
        while pcmAccumulator.count - frameOffset() >= chunk {
            let start = frameOffset()
            let frame = Array(pcmAccumulator[start..<(start + chunk)])
            advanceFrameOffset(by: chunk)

            // RMS for both UI and VAD.
            var sumSq: Float = 0
            for v in frame { sumSq += v * v }
            let rms = sqrt(sumSq / Float(frame.count))
            let level = min(1.0, rms * 4.0)
            DispatchQueue.main.async { [weak self] in self?.onEvent?(.level(level)) }

            let isSpeech = rms >= speechRmsThreshold
            if isSpeech {
                if !inSpeech {
                    inSpeech = true
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(.speechStart) }
                }
                speechFrameCount += 1
                silenceFrameCount = 0
            } else if inSpeech {
                silenceFrameCount += 1
            }

            let total = speechFrameCount + silenceFrameCount
            if inSpeech && (silenceFrameCount >= silenceFramesToCut || total >= maxUtteranceFrames) {
                if speechFrameCount >= minUtteranceFrames {
                    let pcm = trimToProcessed()
                    accumulatorLock.unlock()
                    DispatchQueue.main.async { [weak self] in self?.onEvent?(.speechEnd) }
                    Task { [weak self] in await self?.processUtterance(pcm: pcm) }
                    accumulatorLock.lock()
                } else {
                    // Drop tiny utterance, reset.
                    pcmAccumulator.removeAll(keepingCapacity: true)
                    resetUtteranceState()
                }
            }
        }
        accumulatorLock.unlock()
    }

    /// We accumulate full utterance audio in pcmAccumulator. `frameOffset`
    /// tracks how many samples of the *current utterance* we've already
    /// VAD-classified, so we don't re-classify the same frame twice.
    private var processedSampleCount: Int = 0
    private func frameOffset() -> Int { processedSampleCount }
    private func advanceFrameOffset(by n: Int) { processedSampleCount += n }
    private func resetUtteranceState() {
        speechFrameCount = 0
        silenceFrameCount = 0
        inSpeech = false
        processedSampleCount = 0
    }
    private func trimToProcessed() -> [Float] {
        let pcm = pcmAccumulator
        pcmAccumulator.removeAll(keepingCapacity: true)
        resetUtteranceState()
        return pcm
    }

    // MARK: - Utterance processing

    private func processUtterance(pcm: [Float]) async {
        await MainActor.run { self.isProcessing = true }
        // v0.2.19: previously the defer fired the moment /text_turn finished
        // streaming, but TTS chunks queued in playerNode are still playing
        // back for 1-3s after that. Mic re-opening during playback was the
        // echo-loop trigger. Hold isProcessing for an extra grace period
        // sized to typical buffered playback.
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.isProcessing = false
            }
        }

        // Wrap the float array as Data for OnDeviceSTT.
        let pcmData = pcm.withUnsafeBufferPointer { buf -> Data in
            return Data(buffer: buf)
        }

        let transcript: String
        do {
            transcript = try await transcribeOnDevice(pcm: pcmData)
        } catch {
            await MainActor.run { self.onEvent?(.dropped("stt: \(error)")) }
            return
        }
        let polished = postProcess(transcript)
        if polished.isEmpty {
            await MainActor.run { self.onEvent?(.dropped("empty transcript")) }
            return
        }
        await MainActor.run { self.onEvent?(.transcriptYou(polished)) }

        // POST to /text_turn and play the streamed PCM back as it arrives.
        do {
            let result = try await textTurnClient.postText(
                polished,
                speakerHint: "sherman",
                sessionId: sessionId,
                onAudioChunk: { [weak self] chunk in
                    self?.scheduleTTSChunk(chunk)
                }
            )
            await MainActor.run { self.onEvent?(.transcriptGemma(result.replyText)) }
            await MainActor.run { self.onEvent?(.ttsEnd) }
        } catch {
            // Distinguish 2FA vs generic via NSError userInfo if present
            // (TextTurnClient sets it in commit 3). Either way we surface a
            // user-visible "dropped" so the conversation flow doesn't hang.
            let ns = error as NSError
            if let kw = ns.userInfo["matchedKeyword"] as? String {
                await MainActor.run {
                    self.onEvent?(.dropped("passphrase required for '\(kw)'"))
                }
            } else {
                await MainActor.run { self.onEvent?(.sessionError(error)) }
            }
        }
    }

    private func transcribeOnDevice(pcm: Data) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            OnDeviceSTT.shared.transcribe(pcm: pcm) { result in
                switch result {
                case .success(let text): cont.resume(returning: text)
                case .failure(let err):  cont.resume(throwing: err)
                }
            }
        }
    }

    /// Light post-processing — sentence-case + terminal "." or "?" if
    /// missing. No LLM call; rules live in TranscriptPostProcessor for
    /// testability and so the rule list is in one obvious place.
    private func postProcess(_ text: String) -> String {
        return TranscriptPostProcessor.polish(text)
    }

    // MARK: - TTS playback

    private func scheduleTTSChunk(_ data: Data) {
        // Same shape as StreamingSession.scheduleTTSChunk — Kokoro emits
        // 24kHz mono int16 PCM via /text_turn just like the WS path.
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: ttsFormat, frameCapacity: frameCount) else { return }
        inBuffer.frameLength = frameCount
        guard let channel = inBuffer.floatChannelData?[0] else { return }
        data.withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                channel[i] = Float(int16[i]) / 32768.0
            }
        }
        let bufferToSchedule: AVAudioPCMBuffer
        if let resampler = ttsResampler,
           let connFormat = playerConnectionFormat,
           connFormat.sampleRate != ttsFormat.sampleRate {
            let ratio = connFormat.sampleRate / ttsFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: connFormat, frameCapacity: outCapacity) else { return }
            var error: NSError?
            var consumed = false
            let status = resampler.convert(to: outBuffer, error: &error) { _, inputStatus in
                if consumed { inputStatus.pointee = .noDataNow; return nil }
                consumed = true
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error || error != nil {
                NSLog("[GemmaVoice] TTS resample failed: \(String(describing: error))")
                return
            }
            bufferToSchedule = outBuffer
        } else {
            bufferToSchedule = inBuffer
        }
        if !playerNode.isPlaying { playerNode.play() }
        playerNode.scheduleBuffer(bufferToSchedule, completionHandler: nil)
    }

    // MARK: - Helpers

    private func hasExternalOutputRoute(_ session: AVAudioSession) -> Bool {
        let externalTypes: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio, .headphones, .airPlay, .usbAudio
        ]
        return session.currentRoute.outputs.contains { externalTypes.contains($0.portType) }
    }
}

// MARK: - TextTurnClient stub protocol
// Real implementation lands in commit 3 (TextTurnClient.swift). Defined
// here as a protocol so this commit compiles standalone.

protocol TextTurnClientProtocol {
    /// POST text to /text_turn and stream the PCM reply via onAudioChunk
    /// as it arrives. Returns the reply text (from the X-Reply-Text header).
    func postText(
        _ text: String,
        speakerHint: String,
        sessionId: String,
        onAudioChunk: @escaping (Data) -> Void
    ) async throws -> TextTurnResult
}

struct TextTurnResult {
    let replyText: String
}

/// Inert default client used if nothing else is wired. Returns a friendly
/// error so misconfiguration surfaces obviously rather than hanging.
struct StubTextTurnClient: TextTurnClientProtocol {
    func postText(_ text: String,
                  speakerHint: String,
                  sessionId: String,
                  onAudioChunk: @escaping (Data) -> Void) async throws -> TextTurnResult {
        throw NSError(
            domain: "OnDeviceConversation",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "TextTurnClient not wired (see commit 3)"]
        )
    }
}
