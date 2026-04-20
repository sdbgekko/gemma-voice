import AVFoundation
import Foundation
import UIKit

/// Bidirectional voice session over a single WebSocket.
/// Mic frames flow up as raw 16kHz mono float32. Control messages + TTS
/// chunks flow down. Replaces the HTTP POST + local VAD + full-WAV playback
/// path with full-duplex streaming.
final class StreamingSession: NSObject, URLSessionWebSocketDelegate {
    enum Event {
        case speechStart
        case speechEnd
        case transcriptYou(String, speaker: String?)
        case transcriptGemma(String, source: String?)
        case ttsEnd
        case dropped(String)
        case connectionClosed(Error?)
        case level(Float)    // 0..1 RMS of current mic frame
    }

    /// Fire-and-forget callback; always invoked on main.
    var onEvent: ((Event) -> Void)?

    private let url: URL
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var isRunning = false
    private var isMuted = false
    private let targetFormat: AVAudioFormat    // 16kHz mono float32 — mic upload
    private let ttsFormat: AVAudioFormat       // 24kHz mono float32 — Kokoro PCM playback
    private var converter: AVAudioConverter?
    private let frameSize: AVAudioFrameCount = 512
    private var pcmAccumulator: [Float] = []
    private let accumulatorLock = NSLock()

    init?(url: URL) {
        self.url = url
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let tts = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else { return nil }
        self.targetFormat = target
        self.ttsFormat = tts
        super.init()
        self.urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        // iOS suspends backgrounded apps and silently kills the WebSocket.
        // Reconnect when the user returns.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func handleBackground() {
        // With UIBackgroundModes=audio, AVAudioEngine keeps capturing and
        // URLSession keeps the WebSocket alive. Don't tear anything down —
        // the mic should stay live so Sherman can keep talking while
        // checking other apps.
        NSLog("[GemmaVoice] backgrounded — keeping session alive (audio bg mode)")
    }

    @objc private func handleForeground() {
        // Nothing to do unless the socket died for some other reason,
        // which the receiveLoop error handler already catches.
        NSLog("[GemmaVoice] foregrounded")
    }

    private var wasBackgrounded = false
    private var isReconnecting = false

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: [])
        try? session.overrideOutputAudioPort(.speaker)

        // Output graph: player node -> main mixer -> output.
        // PlayerNode uses 24kHz (Kokoro's PCM format) — the mainMixer resamples
        // to the engine's output rate automatically.
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: ttsFormat)

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        self.converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }
        engine.prepare()
        try engine.start()

        // WebSocket + send loop.
        let task = urlSession.webSocketTask(with: url)
        webSocket = task
        task.resume()
        receiveLoop()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        playerNode.stop()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isRunning = false
    }

    func mute() {
        // Tell server to finish the in-flight utterance before going mute,
        // so the user's mid-sentence isn't discarded.
        sendControl(["type": "force_cut"])
        isMuted = true
        sendControl(["type": "mute"])
    }

    func unmute() {
        isMuted = false
        sendControl(["type": "unmute"])
    }

    func forceCut() {
        sendControl(["type": "force_cut"])
    }

    // MARK: - Mic path

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        if isMuted {
            // Keep the waveform rolling toward flat instead of freezing.
            DispatchQueue.main.async { [weak self] in self?.onEvent?(.level(0)) }
            return
        }
        guard let converter = converter else { return }
        let sourceRate = buffer.format.sampleRate
        let ratio = targetFormat.sampleRate / sourceRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return }
        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0, let ch = outBuffer.floatChannelData?[0] else { return }
        var samples = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount { samples[i] = ch[i] }
        accumulatorLock.lock()
        pcmAccumulator.append(contentsOf: samples)
        // Emit full 512-sample frames.
        let chunkSize = Int(frameSize)
        while pcmAccumulator.count >= chunkSize {
            let frame: [Float] = Array(pcmAccumulator.prefix(chunkSize))
            pcmAccumulator.removeFirst(chunkSize)
            accumulatorLock.unlock()
            // RMS -> 0..1 for waveform display.
            var sumSq: Float = 0
            for v in frame { sumSq += v * v }
            let rms = sqrt(sumSq / Float(frame.count))
            let level = min(1.0, rms * 4.0)
            DispatchQueue.main.async { [weak self] in self?.onEvent?(.level(level)) }

            let data: Data = frame.withUnsafeBufferPointer { Data(buffer: $0) }
            webSocket?.send(.data(data)) { _ in }
            accumulatorLock.lock()
        }
        accumulatorLock.unlock()
    }

    // MARK: - Receive

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                // Don't fire error alert for our own cancel during
                // backgrounding or shutdown.
                if self.isReconnecting || self.wasBackgrounded || !self.isRunning {
                    return
                }
                // Auto-reconnect once on unexpected socket close (server
                // restart, network blip). Silent — no alert unless the
                // reconnect itself fails.
                NSLog("[GemmaVoice] WS receive failed, attempting reconnect: \(error)")
                self.isReconnecting = true
                self.webSocket?.cancel(with: .goingAway, reason: nil)
                let task = self.urlSession.webSocketTask(with: self.url)
                self.webSocket = task
                task.resume()
                self.isReconnecting = false
                self.receiveLoop()
                return
            case .success(let message):
                self.handleIncoming(message)
                self.receiveLoop()
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let d):
            // TTS PCM16 chunk — schedule on player node as a buffer.
            self.scheduleTTSChunk(d)
        case .string(let s):
            guard let data = s.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return }
            DispatchQueue.main.async {
                switch type {
                case "speech_start":
                    self.onEvent?(.speechStart)
                case "speech_end":
                    self.onEvent?(.speechEnd)
                case "transcript_you":
                    self.onEvent?(.transcriptYou(json["text"] as? String ?? "",
                                                  speaker: json["speaker"] as? String))
                case "transcript_gemma":
                    self.onEvent?(.transcriptGemma(json["text"] as? String ?? "",
                                                    source: json["source"] as? String))
                case "tts_end":
                    self.onEvent?(.ttsEnd)
                case "dropped":
                    self.onEvent?(.dropped(json["reason"] as? String ?? ""))
                default: break
                }
            }
        @unknown default: break
        }
    }

    private func scheduleTTSChunk(_ data: Data) {
        // Incoming: 24kHz mono int16 PCM from Kokoro.
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: ttsFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return }
        data.withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                channel[i] = Float(int16[i]) / 32768.0
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Control

    private func sendControl(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { _ in }
    }
}
