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
    /// 0.2.59 jitter buffer (see OnDeviceConversationSession twin).
    private var ttsPrebufferedSec: Double = 0
    private var ttsPrebufferDeadline: CFAbsoluteTime = 0
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    /// True after stop() invalidated urlSession (A1: URLSession retains its
    /// delegate — self — so every un-invalidated session leaked this whole
    /// object, engine + observers included, on stopCapture()/selectAgent()).
    /// start() rebuilds the session if a restart ever follows a stop.
    private var urlSessionInvalidated = false
    private var isRunning = false
    private var isMuted = false
    /// True when the last unmuteMic() actually re-acquired the mic. The view
    /// model checks this after an unmute so a FAILED unmute can never show
    /// "listening" over a dead mic (2026-08-07 roundtable A2).
    private(set) var micReacquired = true
    private let targetFormat: AVAudioFormat    // 16kHz mono float32 — mic upload
    private let ttsFormat: AVAudioFormat       // 24kHz mono float32 — Kokoro PCM playback
    // P0 (0.2.50): the mic converter is no longer a shared stored property —
    // it is captured per-tap in the installTap closure so the render thread
    // never reads a converter a concurrent rebuild could swap mid-convert
    // (AVAudioConverter is not thread-safe → use-after-free crash on route change).
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
        // Never relight the mic while muted — a route/config/interruption event
        // must not undo mute-mic-only by re-adding the input tap.
        guard isRunning, !isMuted else { return }
        let targetFormat = self.targetFormat
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let hwFormat = input.outputFormat(forBus: 0)
        accumulatorLock.lock()
        pcmAccumulator.removeAll(keepingCapacity: true)
        accumulatorLock.unlock()
        if let conv = AVAudioConverter(from: hwFormat, to: targetFormat) {
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer, converter: conv)
            }
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
            // ROOT-CAUSE FIX (2026-08-18 P0): do NOT tear down + rebuild the
            // socket on every foreground. The old unconditional reconnectNow()
            // cancelled even a perfectly healthy socket with .goingAway (1001) —
            // and when it fired mid-reply the reply's transcript_gemma / tts_end
            // never landed, so the card froze on "Working" forever (the
            // confirmed production bug). Now: keep a live socket; only rebuild
            // when it's genuinely dead, and NEVER while TTS is still streaming
            // back. A kept socket is verified with a ping instead of a
            // destructive rebuild — the pong refreshes lastPongAt, and a ping
            // failure routes through handleDisconnect → backoff reconnect.
            if !isMidReply() && !socketAppearsAlive() {
                NSLog("[GemmaVoice] foreground — socket dead/stale, reconnecting")
                reconnectNow()
            } else {
                NSLog("[GemmaVoice] foreground — keeping socket (midReply=\(isMidReply())), pinging to verify")
                sendPing()
            }
        }
    }

    /// True while Gemma's reply is still streaming/playing back — TTS is marked
    /// playing OR scheduled buffers are still draining. A foreground during this
    /// window must NEVER rebuild the socket: that self-inflicted close is what
    /// stranded the turn on "Working".
    private func isMidReply() -> Bool {
        if isTTSPlaying { return true }
        // Pre-TTS window: the reply text has arrived but no audio buffer has
        // scheduled yet. Without this, a foreground here rebuilds the socket and
        // strands the turn on "Working" (0.2.49 hardening).
        if hasServerReply { return true }
        ttsBufferLock.lock(); let inFlight = ttsBuffersInFlight; ttsBufferLock.unlock()
        return inFlight > 0
    }

    /// Liveness check for the current socket: a live task, no reconnect already
    /// pending, and a pong/message seen within the timeout window. Decides
    /// whether a foreground can KEEP the socket rather than rebuild it.
    private func socketAppearsAlive() -> Bool {
        guard webSocket != nil, !isReconnecting else { return false }
        return CFAbsoluteTimeGetCurrent() - lastPongAt <= pongTimeout
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
    // 0.2.47: 0.8 → 0.3 so the mic reopens faster after Gemma's last chunk —
    // part of the mid-speech-cutoff fix (task #16); barge-in ON covers speech
    // that lands while she's still talking.
    private let ttsDrainTailGrace: TimeInterval = 0.3
    // P0 (0.2.50): bounded drain-release watchdog. A scheduleBuffer completion
    // handler can fail to fire — e.g. a chunk scheduled while the engine was
    // stopped (call/Siri/background mid-reply) — leaving ttsBuffersInFlight
    // latched >0 and isTTSPlaying=true forever, so the mic-upload gate stays
    // shut and the mic goes deaf until an app restart. This deadline-bounded
    // release clears the gate regardless of completion bookkeeping (mirrors the
    // on-device playerNode.isPlaying poll with a hard cap).
    private var ttsDrainTask: Task<Void, Never>?
    private let ttsDrainHardCap: TimeInterval = 6.0

    // Barge-in: track whether TTS is currently playing so the mic path can
    // detect user speech-over-TTS and signal an interrupt to the server.
    private var isTTSPlaying = false
    /// 0.2.49: true from when the server's reply TEXT (transcript_gemma) lands
    /// until the turn terminates (tts_end/interrupted/dropped) or a new turn /
    /// reconnect resets it. Closes the pre-TTS window Kai flagged: between the
    /// reply arriving and the first TTS buffer scheduling, isTTSPlaying and
    /// ttsBuffersInFlight are both still 0, so isMidReply() would wrongly say
    /// "not mid-reply" and a foreground could rebuild the socket and strand the
    /// turn. Main-thread only (set/cleared inside DispatchQueue.main handlers and
    /// connectSocket), so no lock — same posture as isTTSPlaying's writers.
    private var hasServerReply = false
    /// 0.2.46 single audio owner: true while the view model's HTTP reply player
    /// (photo/typed turns) is speaking. Gates mic upload just like isTTSPlaying
    /// so this session's live mic can't re-capture the HTTP audio as a user
    /// turn. Written on main, read on the render thread — same lock-free posture
    /// as isTTSPlaying.
    private var externalPlaybackActive = false
    private var bargeInEnabled = true   // refreshed at TTS-start; default ON since 0.2.47 (mid-speech cutoff fix)
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
        // Connect at the engine's actual output format (driven by hardware /
        // session mode), not the Kokoro 24kHz source format. scheduleTTSChunk
        // resamples each chunk before scheduling.
        // Zero-channel guard ported from the on-device path (A1, 2026-08-07):
        // mainMixerNode.outputFormat(forBus:0) can return a 0-channel format on
        // a freshly-activated audio session before the output graph exists, and
        // engine.connect then throws an uncatchable NSInvalidArgumentException
        // ("required condition is false: format.channelCount > 0").
        // outputNode.inputFormat is what the engine actually sends to hardware;
        // fall back to a known-good 48kHz stereo if even that is zero-channel.
        engine.attach(playerNode)
        let candidateFormat = engine.outputNode.inputFormat(forBus: 0)
        let connFormat: AVAudioFormat = (candidateFormat.channelCount > 0)
            ? candidateFormat
            : AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.connect(playerNode, to: engine.mainMixerNode, format: connFormat)
        self.playerConnectionFormat = connFormat
        self.ttsResampler = AVAudioConverter(from: ttsFormat, to: connFormat)

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        if let conv = AVAudioConverter(from: hwFormat, to: targetFormat) {
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer, converter: conv)
            }
        }
        engine.prepare()
        try engine.start()

        // WebSocket + send loop + ping keepalive.
        micArmedAt = CFAbsoluteTimeGetCurrent() + micWarmupGrace
        isRunning = true
        // stop() invalidates urlSession to break the delegate retain (A1);
        // rebuild it if this instance is ever restarted after a stop.
        if urlSessionInvalidated {
            urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
            urlSessionInvalidated = false
        }
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
        // A1 (2026-08-07 roundtable): URLSession(configuration:delegate:)
        // RETAINS its delegate (self). Without invalidation, every
        // stopCapture()/selectAgent() leaked this entire session object —
        // AVAudioEngine + the 4 notification observers included (the view
        // model nils its reference, but the URLSession kept us alive).
        // invalidateAndCancel breaks the retain so deinit can run.
        urlSession.invalidateAndCancel()
        urlSessionInvalidated = true
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

    // MARK: - Mute = MIC ONLY (feedback_mute_cuts_mic_only_hard_rule)
    //
    // The mute button releases ONLY the mic input. The WebSocket, engine, and
    // any in-flight TTS all stay ALIVE. Full teardown (stop()) is correct ONLY
    // for background/terminate — never for mute.

    /// Mute: (1) tell the server to finalize the in-flight utterance so the
    /// user's mid-sentence still commits + gets a reply (the server's `mute`
    /// only pauses its VAD — it does NOT cancel the in-flight process_utterance,
    /// so the flushed turn's TTS still streams back over the OPEN socket), then
    /// (2) drop the mic tap + go playback-only so the orange mic dot goes dark,
    /// WITHOUT stopping the engine, halting playback, or closing the socket.
    /// Main-actor isolated (called only from the view model) to satisfy the
    /// @MainActor MicMuteControllable contract.
    @MainActor
    func muteMicOnly() {
        guard isRunning else { return }
        sendControl(["type": "force_cut"])
        isMuted = true
        sendControl(["type": "mute"])
        engine.inputNode.removeTap(onBus: 0)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true, options: [])
        } catch {
            NSLog("[GemmaVoice] muteMicOnly playback-only switch failed: \(error)")
        }
    }

    /// Unmute: re-acquire the mic on the still-open session — restore the
    /// record+playback category, tell the server to resume its VAD, and
    /// rebuild the mic tap. No socket/engine rebuild.
    /// A2 (2026-08-07): a FAILED re-acquire keeps isMuted asserted and reports
    /// micReacquired=false so the UI never shows "listening" over a dead mic.
    @MainActor
    func unmuteMic() {
        guard isRunning else { return }
        var ok = true
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                    options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true, options: [])
            if !hasExternalOutputRoute(session) {
                try? session.overrideOutputAudioPort(.speaker)
            }
        } catch {
            NSLog("[GemmaVoice] unmuteMic category restore failed: \(error)")
            ok = false
        }
        if ok {
            isMuted = false
            sendControl(["type": "unmute"])
            rebuildMicTap()   // reinstall tap, fresh converter, re-arm warmup gate
            if !engine.isRunning {
                // rebuildMicTap couldn't restart the engine — the mic is NOT hot.
                NSLog("[GemmaVoice] unmuteMic: engine failed to restart — staying muted")
                engine.inputNode.removeTap(onBus: 0)
                ok = false
            }
        }
        if !ok { isMuted = true }   // failed unmute stays honestly muted
        micReacquired = ok
    }

    func forceCut() {
        sendControl(["type": "force_cut"])
    }

    // MARK: - Speaker = OUTPUT ONLY (feedback_implement_the_literal_control_behavior)
    //
    // The speaker toggle changes ONLY the live playback volume of Gemma's TTS.
    // Setting playerNode.volume takes effect IMMEDIATELY on the audio the mixer
    // is rendering right now — so audio already playing is cut/restored
    // mid-buffer, at the moment of press, NOT at the next turn boundary. The
    // node keeps playing (buffers keep draining, completion handlers still fire,
    // the turn/card still complete), it's just inaudible. Independent of mute.

    /// Set Gemma's audio output audible (on) or silent (off) IMMEDIATELY.
    /// `playerNode.volume` is a real-time mixing parameter — changing it affects
    /// the buffer currently rendering, so an OFF cuts her voice live, even
    /// mid-sentence, without stopping the node or the turn. See SpeakerSelfTest.
    @MainActor
    func setSpeakerOutput(on: Bool) {
        playerNode.volume = on ? 1.0 : 0.0
    }

    // MARK: - Single audio owner (0.2.46)

    /// Another player (the view model's HTTP reply player, for photo/typed
    /// turns) is taking over as the sole audio owner. Silence THIS session's
    /// node so two TTS streams never overlap, and gate mic upload for the
    /// duration so the external audio can't be re-captured and transcribed as a
    /// user turn. Releasing (on:false) simply re-opens the upload gate; the mic
    /// tap was never touched, so mute state is unaffected.
    @MainActor
    func suppressForExternalPlayback(_ on: Bool) {
        externalPlaybackActive = on
        if on {
            playerNode.stop()
            playerNode.reset()
            ttsBufferLock.lock(); ttsBuffersInFlight = 0; ttsBufferLock.unlock()
            isTTSPlaying = false
        }
    }

    /// User swiped away the in-flight turn (a mis-captured cough/"mm-hmm"):
    /// stop its TTS locally and tell the server to flush the rest of the reply.
    /// Reuses the barge-in interrupt path — the mic/socket stay up, only this
    /// turn's playback/stream is killed.
    func cancelInFlightTurn() {
        triggerBargeIn()
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

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
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
            if !isTTSPlaying && !externalPlaybackActive {
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
                // shutdown, or if a reconnect is already in flight.
                // 0.2.46: `wasBackgrounded` was dropped here — a socket death
                // while backgrounded used to bail out and never reconnect, so a
                // reply couldn't arrive until foreground. Now the backoff
                // reconnect runs in the background too (UIBackgroundModes=audio
                // keeps us alive), and handleForeground still rebuilds on return.
                if self.isReconnecting || !self.isRunning {
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
    /// A2 (2026-08-07 roundtable): the handshake now carries the same
    /// HMAC-SHA256 shared secret as /text_turn (TextTurnClient scheme) — the
    /// :9201 socket carries LIVE MIC AUDIO and can inject turns into
    /// desk-Gemma, yet was the one transport with no auth. Signed material is
    /// "ws-connect:<unix-ts>"; the timestamp rides in X-Voice-TS so the server
    /// can verify and replay-window it. NOTE: stream_server.py does NOT yet
    /// validate these headers on the audio WS (handle_client has no auth
    /// check) — server-side enforcement is a TODO; sending now means deployed
    /// clients are already compliant the day it flips on.
    private func connectSocket() {
        guard isRunning else { return }
        webSocket?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: url)
        if let secret = VoiceAuthSecret.read() {
            let ts = String(Int(Date().timeIntervalSince1970))
            let mac = TextTurnClient.hmacSHA256Hex(secret: secret,
                                                   bodyBytes: Data("ws-connect:\(ts)".utf8))
            request.setValue(ts, forHTTPHeaderField: "X-Voice-TS")
            request.setValue(mac, forHTTPHeaderField: "X-Voice-Auth")
        }
        let task = urlSession.webSocketTask(with: request)
        webSocket = task
        task.resume()
        lastPongAt = CFAbsoluteTimeGetCurrent()
        isReconnecting = false
        hasServerReply = false   // fresh socket — no reply in flight; prevents a stuck-true flag (0.2.49)
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

    /// Exponential backoff: 1s, 2s, 4s, … capped at 30s, with ±25% jitter so a
    /// fleet of clients (or repeated attempts after a server restart) don't
    /// reconnect in lockstep and hammer the server in a thundering herd.
    private func scheduleReconnect() {
        let base = min(maxReconnectDelay, pow(2.0, Double(reconnectAttempt)))
        let delay = max(0, base + base * 0.25 * Double.random(in: -1...1))
        reconnectAttempt += 1
        NSLog("[GemmaVoice] reconnecting in \(String(format: "%.1f", delay))s (attempt \(reconnectAttempt))")
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
        // Server-initiated close. Ignore our own teardown / an in-flight
        // reconnect. 0.2.46: `!wasBackgrounded` dropped so a peer close while
        // backgrounded reconnects instead of stranding the socket dead.
        guard isRunning, !isReconnecting, webSocketTask === webSocket else { return }
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
                    self.hasServerReply = false   // new user turn — clear any prior reply-in-flight (0.2.49)
                    self.onEvent?(.speechStart)
                case "speech_end":
                    self.onEvent?(.speechEnd)
                case "transcript_you":
                    self.onEvent?(.transcriptYou(json["text"] as? String ?? "",
                                                  speaker: json["speaker"] as? String))
                case "transcript_gemma":
                    // Reply text landed — mark the turn in-flight so a foreground
                    // in the pre-TTS window won't rebuild the socket (0.2.49).
                    self.hasServerReply = true
                    self.onEvent?(.transcriptGemma(json["text"] as? String ?? "",
                                                    source: json["source"] as? String))
                case "tts_end":
                    // tts_end means the server is done SENDING, not that audio
                    // has finished PLAYING — don't clear the mic gate here or the
                    // mic reopens while the speaker is still draining and re-
                    // transcribes Gemma's tail. P0 (0.2.50): arm the bounded
                    // drain-release, which waits for real playout (isPlaying) up
                    // to a hard cap and then force-clears the gate — so a lost
                    // completion handler can never wedge the mic deaf.
                    self.releaseGateAfterDrain()
                    self.hasServerReply = false   // reply text lifecycle done (0.2.49)
                    self.onEvent?(.ttsEnd)
                case "tts_interrupted":
                    // Barge-in / interrupt: flush immediately and reopen the mic.
                    self.ttsDrainTask?.cancel()   // a pending drain-release must not fire into the interrupt
                    self.isTTSPlaying = false
                    self.hasServerReply = false
                    self.bargeInFrames = 0
                    self.ttsBufferLock.lock(); self.ttsBuffersInFlight = 0; self.ttsBufferLock.unlock()
                    self.playerNode.stop()
                    self.playerNode.reset()
                    self.onEvent?(.ttsEnd)
                case "dropped":
                    self.hasServerReply = false
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
        // P0 (0.2.50): never schedule a buffer the engine can't render. A no-op
        // play() on a stopped engine means the completion handler never fires and
        // the mic gate latches shut. Recover the engine, or drop this chunk —
        // dropping a little audio is far better than a deaf mic.
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
        guard engine.isRunning else {
            NSLog("[GemmaVoice] dropping TTS chunk — engine down, not latching gate")
            return
        }
        // 0.2.59 jitter buffer: queue ~220ms before starting the render clock
        // (350ms failsafe). Underruns read as a sibilant "S" on word endings.
        if !playerNode.isPlaying {
            let dur = Double(bufferToSchedule.frameLength) / bufferToSchedule.format.sampleRate
            let now = CFAbsoluteTimeGetCurrent()
            if ttsPrebufferDeadline == 0 {
                ttsPrebufferDeadline = now + 0.35
                ttsPrebufferedSec = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                    guard let self = self else { return }
                    if !self.playerNode.isPlaying, self.ttsPrebufferDeadline != 0 {
                        self.playerNode.play()
                        self.ttsPrebufferDeadline = 0
                    }
                }
            }
            ttsPrebufferedSec += dur
            if ttsPrebufferedSec >= 0.22 || now >= ttsPrebufferDeadline {
                playerNode.play()
                ttsPrebufferDeadline = 0
            }
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
            ttsDrainTask?.cancel()   // new turn — cancel any pending drain-release from the last turn
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

    /// P0 (0.2.50): bounded, self-releasing drain gate armed at tts_end. Waits
    /// for playback to actually finish (playerNode.isPlaying) but NEVER longer
    /// than ttsDrainHardCap, then force-clears the mic-upload gate regardless of
    /// completion-handler bookkeeping — so a lost TTS completion handler can no
    /// longer latch the mic deaf. Cancelled when a new turn starts or an
    /// interrupt fires. Runs on the main actor (all gate state is main-thread).
    private func releaseGateAfterDrain() {
        ttsDrainTask?.cancel()
        ttsDrainTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let deadline = Date().addingTimeInterval(self.ttsDrainHardCap)
            while Date() < deadline && self.playerNode.isPlaying {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: UInt64(self.ttsDrainTailGrace * 1_000_000_000))
            if Task.isCancelled { return }
            self.ttsBufferLock.lock(); self.ttsBuffersInFlight = 0; self.ttsBufferLock.unlock()
            self.isTTSPlaying = false
            self.bargeInFrames = 0
        }
    }

    // MARK: - Control

    private func sendControl(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { _ in }
    }
}

// Mute = MIC ONLY contract (see MuteSelfTest.swift). Methods live in the class
// body above; this declares the conformance.
extension StreamingSession: MicMuteControllable {}
extension StreamingSession: SpeakerControllable {}
