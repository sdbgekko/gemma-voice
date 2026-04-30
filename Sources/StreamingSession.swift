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
        // Route changes (Bluetooth connect/disconnect, headphones plug/unplug,
        // carplay) break the installed mic tap silently — rebuild it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
        // Configuration changes (e.g., buffer size change after a BT device
        // renegotiates) also invalidate the mic tap.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange, object: nil)
        // Phone calls / Siri / other apps grabbing the audio session pause
        // our engine; resume on .ended so we keep recording in background.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc private func handleAudioInterruption(_ note: Notification) {
        guard isRunning else { return }
        guard let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        switch type {
        case .began:
            NSLog("[GemmaVoice] audio interruption began (call/Siri/other app)")
        case .ended:
            NSLog("[GemmaVoice] audio interruption ended — re-priming session")
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                if !engine.isRunning {
                    engine.prepare()
                    try engine.start()
                }
                rebuildMicTap()
            } catch {
                NSLog("[GemmaVoice] interruption recovery failed: \(error)")
            }
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard isRunning else { return }
        guard let reasonVal = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }
        // Rebuild the mic on any meaningful route change. Skip categoryChange
        // (that's our own setCategory at start) and unknown.
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
            NSLog("[GemmaVoice] route change \(reasonVal) — rebuilding mic tap")
            rebuildMicTap()
        default:
            break
        }
    }

    @objc private func handleEngineConfigurationChange(_ note: Notification) {
        guard isRunning else { return }
        NSLog("[GemmaVoice] engine config change — rebuilding mic tap")
        rebuildMicTap()
    }

    private func rebuildMicTap() {
        guard isRunning, let targetFormat = Optional(self.targetFormat) else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let hwFormat = input.outputFormat(forBus: 0)
        self.converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        accumulatorLock.lock()
        pcmAccumulator.removeAll(keepingCapacity: true)
        accumulatorLock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func handleBackground() {
        // UIBackgroundModes=audio is necessary but not sufficient — iOS
        // sometimes deactivates the audio session on transition. Re-assert
        // active state and verify the engine is still running so the mic
        // indicator stays lit and PCM frames keep flowing to the WebSocket.
        guard isRunning else { return }
        NSLog("[GemmaVoice] backgrounded — re-priming audio session")
        wasBackgrounded = true
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            NSLog("[GemmaVoice] background setActive failed: \(error)")
        }
        if !engine.isRunning {
            NSLog("[GemmaVoice] engine stopped on background — restarting")
            engine.prepare()
            try? engine.start()
        }
    }

    @objc private func handleForeground() {
        guard isRunning else { return }
        NSLog("[GemmaVoice] foregrounded")
        // Route may have changed silently while backgrounded (BT reconnect,
        // headphones plugged/unplugged). Rebuild the tap to be safe and
        // re-prime the session so playback works immediately.
        if wasBackgrounded {
            wasBackgrounded = false
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
            } catch {
                NSLog("[GemmaVoice] foreground setActive failed: \(error)")
            }
            if !engine.isRunning {
                engine.prepare()
                try? engine.start()
            }
            rebuildMicTap()
        }
    }

    private var wasBackgrounded = false
    private var isReconnecting = false

    // Barge-in: track whether TTS is currently playing so the mic path can
    // detect user speech-over-TTS and signal an interrupt to the server.
    private var isTTSPlaying = false
    private var bargeInFrames = 0
    private let bargeInThreshold: Float = 0.02      // lowered from 0.05 — was too high for normal speech in car / quiet rooms
    private let bargeInFramesToTrigger = 2          // ~64ms at 32ms per frame (was 3 frames / 96ms)

    private func hasExternalOutputRoute(_ session: AVAudioSession) -> Bool {
        let externalTypes: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio, .headphones, .airPlay, .usbAudio
        ]
        return session.currentRoute.outputs.contains { externalTypes.contains($0.portType) }
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // Accept whatever output route the user has connected (car BT, AirPods,
        // etc.). Only fall back to the phone speaker if nothing's connected.
        // Rolled back from .voiceChat → .spokenAudio in v0.2.8: voiceChat mode
        // forced a hardware sample rate (typically 16kHz) that broke the
        // playerNode→mainMixer connection (configured at 24kHz Kokoro format),
        // resulting in silent TTS playback. Re-introducing .defaultToSpeaker
        // so output still routes to loudspeaker without headphones. Echo
        // cancellation (the original reason for voiceChat) is on hold until
        // we can match the playback graph to voiceChat's preferred rate.
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true, options: [])
        if !hasExternalOutputRoute(session) {
            try? session.overrideOutputAudioPort(.speaker)
        }

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

    /// Barge-in: user spoke over Gemma's TTS. Stop local playback immediately
    /// and tell the server to flush the rest of the in-flight TTS stream.
    /// Must hop to main before touching playerNode — AVAudioEngine nodes are
    /// not thread-safe, calling them from the audio thread (where this is
    /// invoked from handleMicBuffer) crashes the app intermittently.
    private func triggerBargeIn() {
        NSLog("[GemmaVoice] barge-in detected — interrupting TTS")
        isTTSPlaying = false
        bargeInFrames = 0
        // Send interrupt over WS immediately (URLSessionWebSocketTask is
        // thread-safe). Player teardown jumps to main.
        sendControl(["type": "interrupt"])
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.playerNode.stop()
            self.playerNode.reset()
        }
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

            // Barge-in detector: if TTS is playing and the user speaks over it
            // for ~96ms continuous, interrupt the in-flight TTS and let the
            // user take the floor.
            if isTTSPlaying {
                if rms >= bargeInThreshold {
                    bargeInFrames += 1
                    if bargeInFrames >= bargeInFramesToTrigger {
                        triggerBargeIn()
                    }
                } else {
                    bargeInFrames = 0
                }
            }

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
                    self.isTTSPlaying = false
                    self.bargeInFrames = 0
                    self.onEvent?(.ttsEnd)
                case "tts_interrupted":
                    self.isTTSPlaying = false
                    self.bargeInFrames = 0
                    self.playerNode.stop()
                    self.playerNode.reset()
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
        // Mark TTS as actively playing so the mic loop can detect barge-in.
        isTTSPlaying = true
        bargeInFrames = 0
    }

    // MARK: - Control

    private func sendControl(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { _ in }
    }
}
