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
        case connectionOpened
        case level(Float)    // 0..1 RMS of current mic frame
        case agent(String)   // server-side active agent display name
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
    /// Resamples 24kHz Kokoro PCM to whatever format playerNode is wired
    /// at (which mirrors the engine's output rate — 16kHz under voiceChat,
    /// 24/48kHz under spokenAudio). Built once at start; rebuilt on engine
    /// configuration change.
    private var ttsResampler: AVAudioConverter?
    /// Format playerNode is currently connected to mainMixer at. Captured
    /// from mainMixerNode.outputFormat(forBus:0) so playback adapts to
    /// whatever sample rate voiceChat / hardware route forces.
    private var playerConnectionFormat: AVAudioFormat?
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
        micArmedAt = CFAbsoluteTimeGetCurrent() + micWarmupGrace
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
            // P0-1: the WebSocket and its receive loop don't reliably survive a
            // background stint — the receive-failure path bails out while
            // backgrounded (wasBackgrounded guard) and never reconnects. Rebuild
            // the socket from scratch on foreground so we're never falsely
            // "listening" on a dead socket. reconnectNow forces an immediate
            // fresh connection (no backoff wait).
            reconnectNow()
        }
    }

    private var wasBackgrounded = false
    private var isReconnecting = false

    // P0-1: honest connection state + exponential-backoff reconnect.
    /// Number of consecutive reconnect attempts; drives the backoff delay
    /// (1s → cap 30s). Reset to 0 on a successful handshake / message.
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    /// 10s WebSocket ping keepalive. A missing pong or a stale receive
    /// (no message/pong for `pongTimeout`) is treated as a disconnect so
    /// the UI can't sit on a false "listening" over a dead socket.
    private var pingTimer: Timer?
    private var lastPongAt: CFAbsoluteTime = 0
    private let pingInterval: TimeInterval = 10
    private let pongTimeout: TimeInterval = 22   // ~2 missed intervals

    // P0-2: true half-duplex — keep isTTSPlaying true until playback actually
    // DRAINS (outstanding scheduleBuffer completion handlers hit zero), plus a
    // tail grace, not on the server's tts_end. Mirrors the on-device path.
    private var ttsBuffersInFlight = 0
    private let ttsBufferLock = NSLock()
    private let ttsDrainTailGrace: TimeInterval = 0.8

    // Barge-in: track whether TTS is currently playing so the mic path can
    // detect user speech-over-TTS and signal an interrupt to the server.
    private var isTTSPlaying = false
    private var bargeInEnabled = false  // refreshed at TTS-start; v0.2.13
    private var bargeInFrames = 0
    private let bargeInThreshold: Float = 0.04      // 0.05 was too high (missed normal speech), 0.02 was too low (background noise + TTS bleed self-triggered cuts)
    private let bargeInFramesToTrigger = 4          // ~128ms at 32ms — longer window prevents transient noise spikes from triggering
    /// Earliest time at which barge-in detection is allowed for the current
    /// TTS turn. We ignore detection for the first 600ms of playback so the
    /// player can warm up and Sherman's own TTS bleeding back through the
    /// mic doesn't self-interrupt. Reset on every new TTS turn.
    private var bargeInArmedAt: CFAbsoluteTime = 0
    private let bargeInGracePeriod: CFAbsoluteTime = 0.6

    /// Earliest time at which mic frames are forwarded to the server.
    /// On `start()` and after route/config rebuilds, the AVAudioSession
    /// HAL takes 100-300ms to fully activate (especially under iOS 17+
    /// .spokenAudio / BT routes). During that window the mic tap fires
    /// but buffers are silent/garbage, so Silero never trips and the
    /// user's first word(s) are dropped. Gate uploads until the HAL
    /// is warm. Local level meter still updates so the UI feels live.
    private var micArmedAt: CFAbsoluteTime = 0
    private let micWarmupGrace: CFAbsoluteTime = 0.25

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
        // v0.2.18: rolled back to .spokenAudio after v0.2.17 silent-playback
        // regression in the field — same failure shape as the v0.2.8 rollback.
        // Resampler infrastructure (ttsResampler / playerConnectionFormat) kept;
        // it makes the playback graph more robust regardless of session mode.
        // AEC will return once voiceChat + resampler can be tested on-device.
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true, options: [])
        if !hasExternalOutputRoute(session) {
            try? session.overrideOutputAudioPort(.speaker)
        }

        // Output graph: player node -> main mixer -> output.
        // Connect at the mixer's actual output format (driven by hardware /
        // session mode), not the Kokoro 24kHz source format. scheduleTTSChunk
        // resamples each chunk before scheduling.
        engine.attach(playerNode)
        let connFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: connFormat)
        self.playerConnectionFormat = connFormat
        self.ttsResampler = AVAudioConverter(from: ttsFormat, to: connFormat)

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        self.converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }
        engine.prepare()
        try engine.start()

        // WebSocket + send loop + ping keepalive.
        micArmedAt = CFAbsoluteTimeGetCurrent() + micWarmupGrace
        isRunning = true
        connectSocket()
    }

    func stop() {
        guard isRunning else { return }
        // Set first so the receive-failure / ping paths bail out instead of
        // scheduling a reconnect during teardown.
        isRunning = false
        reconnectAttempt = 0
        stopPingTimer()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        playerNode.stop()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// v0.2.21 — re-assert audio session on foreground. iOS may have deactivated
    /// it during background. If the engine isn't running, this is a no-op (next
    /// `start()` rebuilds cleanly). If it IS running, ensure the session stays hot.
    func handleAppDidBecomeActive() {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            try? engine.start()
        }
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
        ttsBufferLock.lock(); ttsBuffersInFlight = 0; ttsBufferLock.unlock()
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
        // Warm-up gate: the first ~250ms of frames after engine start
        // are silent/garbage while the AVAudioSession HAL activates.
        // Drop them client-side so they never reach Silero — which
        // otherwise stays below threshold long enough that the user's
        // first word lands before pre-roll catches up.
        if CFAbsoluteTimeGetCurrent() < micArmedAt {
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
            // for ~128ms continuous AFTER the grace period, interrupt the
            // in-flight TTS. The grace period prevents the player-warmup
            // tail and self-feedback (TTS bleeding through mic) from
            // self-triggering an interrupt.
            if bargeInEnabled && isTTSPlaying && CFAbsoluteTimeGetCurrent() >= bargeInArmedAt {
                if rms >= bargeInThreshold {
                    bargeInFrames += 1
                    if bargeInFrames >= bargeInFramesToTrigger {
                        triggerBargeIn()
                    }
                } else {
                    bargeInFrames = 0
                }
            }

            // v0.2.19: don't ship mic frames to the server while our own
            // TTS is playing back. With voiceChat / hardware AEC off (post
            // v0.2.18 rollback) the speaker bleeds into the mic and the
            // server transcribes our own voice as the user. RMS above is
            // still computed every frame so barge-in still works locally;
            // we just skip the upload.
            if !isTTSPlaying {
                let data: Data = frame.withUnsafeBufferPointer { Data(buffer: $0) }
                webSocket?.send(.data(data)) { _ in }
            }
            accumulatorLock.lock()
        }
        accumulatorLock.unlock()
    }

    // MARK: - Receive

    private func receiveLoop() {
        let task = webSocket
        task?.receive { [weak self] result in
            guard let self = self else { return }
            // Ignore callbacks from a socket we've already replaced (a
            // reconnect swapped `webSocket` out from under this closure).
            guard task === self.webSocket else { return }
            switch result {
            case .failure(let error):
                // Don't fire the disconnect path for our own cancel during
                // backgrounding or shutdown, or if a reconnect is already in
                // flight. handleForeground() rebuilds the socket on return.
                if self.isReconnecting || self.wasBackgrounded || !self.isRunning {
                    return
                }
                // P0-1: unexpected socket close (server restart, network blip).
                // Emit the honest connectionClosed event and reconnect with
                // exponential backoff instead of a silent one-shot retry.
                NSLog("[GemmaVoice] WS receive failed: \(error)")
                self.handleDisconnect(error)
                return
            case .success(let message):
                // Any inbound traffic proves the socket is live — refresh the
                // liveness clock and clear the backoff counter.
                self.lastPongAt = CFAbsoluteTimeGetCurrent()
                self.reconnectAttempt = 0
                self.handleIncoming(message)
                self.receiveLoop()
            }
        }
    }

    // MARK: - Connection lifecycle (P0-1)

    /// Open a fresh WebSocket, start the receive loop + ping keepalive.
    private func connectSocket() {
        guard isRunning else { return }
        webSocket?.cancel(with: .goingAway, reason: nil)
        let task = urlSession.webSocketTask(with: url)
        webSocket = task
        task.resume()
        lastPongAt = CFAbsoluteTimeGetCurrent()
        isReconnecting = false
        startPingTimer()
        receiveLoop()
    }

    /// Tear the socket down, tell the UI honestly, and schedule a backoff
    /// reconnect. Idempotent while a reconnect is already pending.
    private func handleDisconnect(_ error: Error?) {
        guard isRunning, !isReconnecting else { return }
        isReconnecting = true
        stopPingTimer()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        DispatchQueue.main.async { [weak self] in self?.onEvent?(.connectionClosed(error)) }
        scheduleReconnect()
    }

    /// Exponential backoff: 1s, 2s, 4s, … capped at 30s.
    private func scheduleReconnect() {
        let delay = min(maxReconnectDelay, pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        NSLog("[GemmaVoice] reconnecting in \(delay)s (attempt \(reconnectAttempt))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.isRunning, self.isReconnecting else { return }
            self.connectSocket()
        }
    }

    /// User-initiated (tap-to-reconnect) or foreground reconnect — immediate,
    /// no backoff wait.
    func reconnectNow() {
        guard isRunning else { return }
        stopPingTimer()
        isReconnecting = true
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        reconnectAttempt = 0
        connectSocket()
    }

    // MARK: - Ping keepalive (P0-1)

    private func startPingTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pingTimer?.invalidate()
            let t = Timer.scheduledTimer(withTimeInterval: self.pingInterval, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
            RunLoop.main.add(t, forMode: .common)
            self.pingTimer = t
        }
    }

    private func stopPingTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
        }
    }

    private func sendPing() {
        guard isRunning, !isReconnecting, let ws = webSocket else { return }
        // Stale receive: no message or pong within the timeout window → dead.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPongAt > pongTimeout {
            NSLog("[GemmaVoice] no pong/message in \(Int(now - lastPongAt))s — treating as disconnect")
            handleDisconnect(nil)
            return
        }
        ws.sendPing { [weak self] error in
            guard let self = self else { return }
            // Ignore a pong/error from a socket we've already replaced.
            guard ws === self.webSocket else { return }
            if let error = error {
                NSLog("[GemmaVoice] ping failed: \(error)")
                self.handleDisconnect(error)
            } else {
                self.lastPongAt = CFAbsoluteTimeGetCurrent()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate (P0-1)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        // Handshake completed — the socket is genuinely live. Reset backoff and
        // tell the UI it's honest to show a listening state again.
        lastPongAt = CFAbsoluteTimeGetCurrent()
        reconnectAttempt = 0
        DispatchQueue.main.async { [weak self] in self?.onEvent?(.connectionOpened) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        // Server-initiated close. Ignore our own teardown / backgrounding.
        guard isRunning, !isReconnecting, !wasBackgrounded, webSocketTask === webSocket else { return }
        NSLog("[GemmaVoice] WS closed by peer (code \(closeCode.rawValue))")
        handleDisconnect(nil)
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
                    // P0-2: tts_end means the server is done SENDING, not that
                    // audio has finished PLAYING. Don't clear isTTSPlaying (the
                    // mic-upload gate) here — that reopens the mic while our own
                    // speaker is still draining and the server transcribes our
                    // voice as the user. If all scheduled buffers have already
                    // drained, start the tail-grace timer; otherwise the last
                    // buffer's completion handler starts it.
                    self.ttsBufferLock.lock()
                    let alreadyDrained = self.ttsBuffersInFlight <= 0
                    self.ttsBufferLock.unlock()
                    if alreadyDrained { self.scheduleTTSDrainCheck() }
                    self.onEvent?(.ttsEnd)
                case "tts_interrupted":
                    // Barge-in / interrupt: flush immediately and reopen the mic.
                    self.isTTSPlaying = false
                    self.bargeInFrames = 0
                    self.ttsBufferLock.lock(); self.ttsBuffersInFlight = 0; self.ttsBufferLock.unlock()
                    self.playerNode.stop()
                    self.playerNode.reset()
                    self.onEvent?(.ttsEnd)
                case "dropped":
                    self.onEvent?(.dropped(json["reason"] as? String ?? ""))
                case "agent":
                    if let name = json["name"] as? String, !name.isEmpty {
                        self.onEvent?(.agent(name))
                    }
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
              let inBuffer = AVAudioPCMBuffer(pcmFormat: ttsFormat, frameCapacity: frameCount) else { return }
        inBuffer.frameLength = frameCount
        guard let channel = inBuffer.floatChannelData?[0] else { return }
        data.withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                channel[i] = Float(int16[i]) / 32768.0
            }
        }
        // Resample 24kHz Kokoro audio to the playerNode's connection format
        // (engine output rate — varies with session mode and route). Without
        // this, voiceChat's 16kHz hw lock results in silent / garbled
        // playback (the v0.2.8 rollback).
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
        if !playerNode.isPlaying {
            playerNode.play()
        }
        // P0-2: count outstanding buffers so isTTSPlaying stays true until
        // playback actually DRAINS (mirrors OnDeviceConversationSession's
        // playerNode.isPlaying poll). Increment on schedule, decrement in the
        // completion block; when the count hits zero, kick the tail-grace timer.
        ttsBufferLock.lock()
        ttsBuffersInFlight += 1
        ttsBufferLock.unlock()
        playerNode.scheduleBuffer(bufferToSchedule) { [weak self] in
            guard let self = self else { return }
            self.ttsBufferLock.lock()
            self.ttsBuffersInFlight -= 1
            let drained = self.ttsBuffersInFlight <= 0
            if drained { self.ttsBuffersInFlight = 0 }
            self.ttsBufferLock.unlock()
            if drained {
                DispatchQueue.main.async { [weak self] in self?.scheduleTTSDrainCheck() }
            }
        }
        // Mark TTS as actively playing so the mic loop can detect barge-in.
        // First chunk of a turn arms the grace-period window so the
        // player-warmup tail and TTS-bleed-through-mic can't self-interrupt.
        if !isTTSPlaying {
            bargeInArmedAt = CFAbsoluteTimeGetCurrent() + bargeInGracePeriod
            bargeInEnabled = UserDefaults.standard.bool(forKey: "bargeInEnabled")
        }
        isTTSPlaying = true
        bargeInFrames = 0
    }

    /// P0-2: once the scheduled TTS buffers have drained, wait a short tail
    /// grace before reopening the mic upload gate (isTTSPlaying=false). If a
    /// new chunk arrives during the grace window the count goes positive again
    /// and we leave the gate closed — a transient inter-chunk gap must not
    /// reopen the mic mid-utterance and let the speaker bleed re-transcribe.
    private func scheduleTTSDrainCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + ttsDrainTailGrace) { [weak self] in
            guard let self = self else { return }
            self.ttsBufferLock.lock()
            let stillDrained = self.ttsBuffersInFlight <= 0
            self.ttsBufferLock.unlock()
            if stillDrained {
                self.isTTSPlaying = false
                self.bargeInFrames = 0
            }
        }
    }

    // MARK: - Control

    private func sendControl(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { _ in }
    }
}
