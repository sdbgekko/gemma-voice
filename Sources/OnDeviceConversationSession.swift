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
        /// A resume that lands inside the continuation grace window. The UI must
        /// NOT open a new turn card for this — the just-said fragment is being
        /// merged into the still-open turn (see transcriptContinued). Fires the
        /// "got it" ack like speechEnd but suppresses the new-card append.
        case continuationHeard
        case transcriptYou(String)
        /// Combined transcript of a merged turn ("…first part …continued part").
        /// The ledger card grows in place rather than a second card appearing.
        case transcriptContinued(String)
        /// Reply text plus the brain that ACTUALLY answered (server X-Brain
        /// header: "gemma" | "jarvis" | "kai"; nil on older servers). A
        /// busy-fallback turn arrives with brain == "jarvis" so the UI can
        /// badge it honestly instead of hardcoding "gemma".
        case transcriptGemma(String, brain: String?)
        /// Streaming path only (0.2.32): the reply text arrived AFTER the audio
        /// (fetched via /reply_text once ttsEnd already closed the turn). The
        /// UI backfills the already-answered card's Gemma text with this.
        case replyTextLate(String)
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
    /// Written on main (start/unmute/route-rebuild), read on the render
    /// thread — stateLock-guarded, see the cross-thread block above.
    private var converter: AVAudioConverter? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _converter }
        set { stateLock.lock(); _converter = newValue; stateLock.unlock() }
    }
    /// Resamples 24kHz Kokoro PCM to playerNode's connection format. Same
    /// mechanism as StreamingSession — required to keep TTS audible under
    /// .voiceChat session mode (which forces hw to 16kHz).
    private var ttsResampler: AVAudioConverter?
    private var playerConnectionFormat: AVAudioFormat?

    // VAD / utterance buffering
    private var pcmAccumulator: [Float] = []   // current utterance (16kHz f32)
    private let accumulatorLock = NSLock()
    /// Jetsam bounds (2026-08-07 roundtable A1). Before these, pcmAccumulator
    /// appended every mic frame (64 KB/s) and cleared ONLY at an utterance cut
    /// — ambient silence accumulated ~230 MB/hr, including while backgrounded
    /// (UIBackgroundModes=audio), which is exactly the 0.2.31/0.2.32 jetsam
    /// kill pattern. Outside speech we keep only a short pre-roll tail (the
    /// utterance lead-in); a 60s hard cap with drop-oldest is the last-resort
    /// guard so NO path can grow the buffer unbounded.
    private let preRollKeepSamples = 10 * 512      // ~320ms lead-in kept while idle
    private let hardCapSamples = 60 * 16_000       // 60s of 16kHz audio, absolute

    // Cross-thread mic-path state (2026-08-07 roundtable A1, render-thread
    // races). These are written on the main actor but read (and in one case
    // written) on the AVAudioEngine render thread inside handleMicBuffer.
    // Unguarded, those are real data races on @MainActor storage. All access
    // goes through stateLock via the computed properties below — call sites
    // are unchanged. Lock order where nesting occurs: accumulatorLock is
    // always taken FIRST, stateLock only ever held alone inside it.
    private let stateLock = NSLock()
    private var _isMuted = false
    private var _isProcessing = false
    /// 0.2.46 single audio owner: true while the view model's HTTP reply player
    /// (photo/typed turns) is speaking. Gates mic capture like isProcessing so
    /// this session's live mic can't re-capture the HTTP audio as a user turn.
    private var _externalPlaybackActive = false
    private var _micHotAfter = Date.distantPast
    private var _converter: AVAudioConverter?
    private var _latestPartial = ""
    /// RMS floor matched to the server's RMS_FLOOR (0.005). Below this is
    /// treated as silence for VAD purposes.
    private let speechRmsThreshold: Float = 0.012   // a bit higher than server floor — local mic gain runs hotter
    /// Frames of continuous silence required to end an utterance. 32ms per
    /// frame at 16kHz/512-sample chunks. History: 25 (800ms) → 16 (512ms) in
    /// 0.2.28 for latency → 20 (640ms) in 0.2.29. Nudged back up because
    /// 512ms chopped Sherman's mid-thought pauses into two turns; 640ms is
    /// more pause-forgiving while keeping most of the 0.2.28 speed win, and the
    /// continuation grace window (below) now catches the longer pauses that
    /// still slip past the gate by merging the resumed speech into the same
    /// turn instead of starting a disconnected new one.
    private let silenceFramesToCut = 20
    /// Minimum utterance length, also in 32ms frames. 15 = 480ms (matches
    /// server MIN_UTTERANCE_FRAMES).
    private let minUtteranceFrames = 15
    /// Hard cap so a runaway buffer doesn't grow unbounded. ~30s.
    private let maxUtteranceFrames = 30_000 / 32
    private let frameSize: AVAudioFrameCount = 512
    private var silenceFrameCount = 0
    private var speechFrameCount = 0
    private var inSpeech = false

    // Live streaming STT (v0.2.28). The recognizer runs DURING speech instead of
    // a cold batch at speech-end. `streamingActive` gates mic-frame feeding;
    // `latestPartial` is the most recent incremental transcript (used as a
    // fallback if the streamed final drains empty). The final arrives async via
    // deliverStreamingFinal → either resumes `streamFinalCont` or is stashed in
    // `pendingStreamResult` when the awaiter hasn't installed a continuation yet.
    private var streamingActive = false
    /// Written from the recognizer's onPartial hop (main) AND reset on the
    /// render thread at speech onset — stateLock-guarded.
    private var latestPartial: String {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _latestPartial }
        set { stateLock.lock(); _latestPartial = newValue; stateLock.unlock() }
    }
    private var streamFinalCont: CheckedContinuation<String, Error>?
    private var pendingStreamResult: Result<String, Error>?
    /// Guards the drained-final await: if the recognizer never delivers (rare
    /// SFSpeech hang), the waiting continuation is resumed with an error after
    /// this long instead of a suspended Task leaking forever (A1, was the
    /// "leaked continuation" at the old :816/:844).
    private let streamFinalTimeout: TimeInterval = 10
    private var streamFinalTimeoutTask: Task<Void, Never>?

    // State machine
    private var isRunning = false
    /// Read on the render thread at the top of handleMicBuffer — stateLock-guarded.
    private var isMuted: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isMuted }
        set { stateLock.lock(); _isMuted = newValue; stateLock.unlock() }
    }
    /// While TTS is playing we suspend new utterance detection so the user
    /// doesn't talk over Gemma's reply (and vice versa). 0.2.29: this is NO
    /// longer set the instant the utterance is cut — the continuation grace
    /// window (below) keeps the mic hot after the send so a resumed thought can
    /// merge. It's asserted when the reply's first audio arrives (half-duplex)
    /// or when the grace window expires. Re-enabled on tts_end / error via
    /// releaseProcessingAfterDrain(). Read on the render thread — stateLock-guarded.
    private var isProcessing: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isProcessing }
        set { stateLock.lock(); _isProcessing = newValue; stateLock.unlock() }
    }
    /// 0.2.46 single audio owner: gates mic capture while an external (HTTP
    /// reply) player is speaking. Read on the render thread — stateLock-guarded.
    private var externalPlaybackActive: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _externalPlaybackActive }
        set { stateLock.lock(); _externalPlaybackActive = newValue; stateLock.unlock() }
    }

    // MARK: Utterance continuation (0.2.29)
    //
    // Sherman pauses mid-thought; the silence gate cuts and sends, so his
    // continued speech used to become a NEW, disconnected turn. Fix: after a
    // turn is sent, hold a short GRACE window during which the mic stays hot.
    // If he resumes within it, cancel the in-flight /text_turn, append the new
    // transcript to the prior text, and re-send as the SAME turn (the ledger
    // card grows in place). If the reply's audio has already started, the mic
    // is already half-duplex-deaf, so a later utterance is naturally a new turn
    // (barge-in-merge is a future enhancement). If the window expires with no
    // resume, we fall back to normal half-duplex and the turn stands as-is.

    /// How long after a send we keep listening for a continuation. Tunable.
    /// 2.5s covers a natural mid-thought breath without holding the mic open
    /// through a long think; note that when the brain is slow (>2.5s to first
    /// audio) this expires FIRST and the mic goes half-duplex before the reply
    /// plays — the common path — while a fast reply closes it on first audio.
    private let continuationGraceWindow: TimeInterval = 2.5
    /// Right after a cut we play a 160ms earback "got it" tone; with the mic now
    /// hot during grace it would otherwise feed back into VAD. Swallow input for
    /// this long after a send so the local tone can't self-trigger a resume.
    private let earbackGuardWindow: TimeInterval = 0.25

    /// True while a sent turn's grace window is open (mic hot, resume merges).
    /// Flipped only via setGraceActive() so the mic thread can read it under the
    /// accumulator lock when classifying a cut as fresh vs. continuation.
    private var graceActive = false
    /// Text of the turn currently in its grace window — the base a continuation
    /// is appended to. Empty when no turn is open.
    private var pendingTurnText = ""
    /// The in-flight /text_turn request for the open turn. Cancelled and
    /// superseded when a continuation merges new speech into the same turn.
    private var inFlightTurnTask: Task<Void, Never>?
    /// 0.2.44 redelivery: the view model's recovery poll must not race a
    /// request that is still alive and may deliver normally — it waits while
    /// this is true (the request's own completion clears PendingTurnStore).
    var hasInFlightTurn: Bool { inFlightTurnTask != nil }
    /// Fires continuationGraceWindow after a send; closes the window if no
    /// resume and no reply-audio arrived (falls back to half-duplex).
    private var graceTimerTask: Task<Void, Never>?
    /// Streaming path (0.2.32): after a turn's audio finishes with no reply
    /// text in the header, this task polls GET /reply_text to backfill the
    /// Gemma text card. Cancelled on stop() so a teardown can't fire a late
    /// event into a dead session.
    private var lateReplyTask: Task<Void, Never>?
    /// Set once the open turn's reply audio has begun — guards the grace/expiry
    /// paths from reopening the mic after playback has started.
    private var ttsStartedThisTurn = false
    /// Mic input before this instant is ignored (earback-tone guard). Set on the
    /// main actor at send time, read on the audio thread — stateLock-guarded,
    /// same posture as isProcessing.
    private var micHotAfter: Date {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _micHotAfter }
        set { stateLock.lock(); _micHotAfter = newValue; stateLock.unlock() }
    }

    // MARK: Per-turn speaker verification (0.2.31)
    //
    // The on-device STT path posts TEXT only, so the server's enrolled-
    // voiceprint engine never hears the audio. Attach the utterance's 16kHz
    // mono PCM16 as a base64 WAV to each /text_turn so the server can verify
    // who's speaking (SPEAKER_ID_MODE shadow/tag on the voice-turn server).

    /// Speaker-ID clip cap: 15s at 16kHz. Keeps the WAV ≈480KB (≈640KB as
    /// base64) — well under the ~2MB request budget.
    private let maxSpeakerClipSamples = 15 * 16_000
    /// Utterance PCM snapshotted at the VAD/force cut, before pcmAccumulator
    /// is cleared. Guarded by accumulatorLock; claimed by handleUtteranceCut.
    private var lastCutPCM: [Float] = []
    /// Audio backing pendingTurnText — the open turn's fragment(s). A
    /// continuation APPENDS its fragment so a merged re-send carries the
    /// CONCATENATED audio of both fragments (capped at maxSpeakerClipSamples).
    private var pendingTurnAudio: [Float] = []

    // Networking — injected so tests can swap a mock.
    private let textTurnClient: TextTurnClientProtocol
    /// Stable session id sent to the server with each turn for log
    /// correlation. Re-rolled on every full session start.
    private var sessionId: String = UUID().uuidString

    /// True when the last unmuteMic() actually re-acquired the mic (category
    /// restored + tap installed + engine running). The view model checks this
    /// after an unmute so a FAILED unmute can never show "listening" over a
    /// dead mic (2026-08-07 roundtable A2).
    private(set) var micReacquired = true

    /// Audio-session defense observers (2026-08-07 roundtable A1). The WS path
    /// (StreamingSession) has had interruption/route-change/config-change
    /// recovery since v0.2.x; this DEFAULT on-device path had none — a phone
    /// call, Siri grab, or BT connect/disconnect silently killed the mic tap.
    /// Token-based observers on the main queue; removed in deinit.
    private var lifecycleObservers: [NSObjectProtocol] = []

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
        installAudioSessionObservers()
    }

    deinit {
        for token in lifecycleObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func installAudioSessionObservers() {
        let nc = NotificationCenter.default
        // Phone calls / Siri / other apps grabbing the audio session pause our
        // engine; re-prime on .ended so the conversation keeps working.
        lifecycleObservers.append(nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleAudioInterruption(note) }
        })
        // Route changes (BT connect/disconnect, headphones, CarPlay) break the
        // installed mic tap silently — rebuild it.
        lifecycleObservers.append(nc.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })
        // Configuration changes (e.g. buffer size renegotiation) also
        // invalidate the mic tap.
        lifecycleObservers.append(nc.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleEngineConfigurationChange(note) }
        })
        // 0.2.46 background audio: this DEFAULT on-device path had NO
        // didEnterBackground observer (the WS path has had one since v0.2.x) —
        // iOS could deactivate the audio session on backgrounding and the reply
        // stopped speaking / the mic went dead until foreground. Mirror
        // StreamingSession.handleBackground: re-assert setActive(true) and
        // restart the engine, WITHOUT re-installing the mic tap (a muted
        // session must stay mic-dark in the background).
        lifecycleObservers.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidEnterBackground() }
        })
    }

    /// 0.2.46: re-prime the audio session/engine on backgrounding so a reply
    /// keeps playing and the mic keeps capturing (UIBackgroundModes=audio is
    /// necessary but not sufficient — iOS sometimes deactivates the session on
    /// the transition). Does NOT rebuild the mic tap: mute-mic-only must survive
    /// backgrounding, and an unmuted tap is still installed and valid.
    private func handleDidEnterBackground() {
        guard isRunning else { return }
        NSLog("[GemmaVoice] on-device: backgrounded — re-priming audio session")
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            NSLog("[GemmaVoice] on-device: background setActive failed: \(error)")
        }
        if !engine.isRunning {
            NSLog("[GemmaVoice] on-device: engine stopped on background — restarting")
            engine.prepare()
            try? engine.start()
        }
    }

    private func handleAudioInterruption(_ note: Notification) {
        guard isRunning else { return }
        guard let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        switch type {
        case .began:
            NSLog("[GemmaVoice] on-device: audio interruption began (call/Siri/other app)")
        case .ended:
            NSLog("[GemmaVoice] on-device: audio interruption ended — re-priming session")
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                if !engine.isRunning {
                    engine.prepare()
                    try engine.start()
                }
                rebuildMicTap()
            } catch {
                NSLog("[GemmaVoice] on-device: interruption recovery failed: \(error)")
            }
        @unknown default: break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard isRunning else { return }
        guard let reasonVal = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal) else { return }
        // Rebuild the mic on any meaningful route change. Skip categoryChange
        // (that's our own setCategory) and unknown — same policy as the WS path.
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
            NSLog("[GemmaVoice] on-device: route change \(reasonVal) — rebuilding mic tap")
            rebuildMicTap()
        default:
            break
        }
    }

    private func handleEngineConfigurationChange(_ note: Notification) {
        guard isRunning else { return }
        NSLog("[GemmaVoice] on-device: engine config change — rebuilding mic tap")
        rebuildMicTap()
    }

    /// Reinstall the mic tap after a route/config/interruption event. Never
    /// relights the mic while muted (mute-mic-only hard rule). Abandons any
    /// half-captured utterance — the route change invalidated its audio.
    private func rebuildMicTap() {
        guard isRunning, !isMuted else { return }
        accumulatorLock.lock()
        if inSpeech || streamingActive {
            streamingActive = false
            OnDeviceSTT.shared.cancelStreaming()
        }
        pcmAccumulator.removeAll(keepingCapacity: true)
        resetUtteranceState()
        accumulatorLock.unlock()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let hwFormat = input.outputFormat(forBus: 0)
        self.converter = AVAudioConverter(from: hwFormat, to: captureFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
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
        // Echo cancellation (beta, flag-gated behind aecEnabled). Enable Apple's
        // voice-processing I/O unit BEFORE the format reads + graph connect below:
        // VPIO changes the I/O unit's sample format, so enabling it after the
        // connect would leave playerNode wired at a stale format = the silent-
        // playback regression that caused the .voiceChat rollback. The ttsResampler
        // built from the post-VPIO connFormat (line ~445) is exactly what makes
        // playback survive the format change. AGC is disabled so voice-processing's
        // auto-gain can't pump the mic level and break the fixed barge-in threshold.
        // Any failure logs and falls back to the plain .spokenAudio path (no AEC).
        // Must be called with the engine stopped and the input node not yet in use
        // (both true here — start() hasn't reached engine.start()).
        if UserDefaults.standard.bool(forKey: "aecEnabled") {
            let vp = engine.inputNode
            do {
                try vp.setVoiceProcessingEnabled(true)
                vp.isVoiceProcessingAGCEnabled = false
                NSLog("[GemmaVoice] AEC: voice processing enabled (beta)")
            } catch {
                NSLog("[GemmaVoice] AEC: setVoiceProcessingEnabled failed — falling back to no-AEC: \(error)")
            }
        }
        // v0.2.21 fix: mainMixerNode.outputFormat(forBus:0) returns a 0-channel format
        // on a freshly-activated audio session before the output graph has been built,
        // causing engine.connect to throw an uncatchable NSInvalidArgumentException
        // ("required condition is false: format.channelCount > 0"). outputNode.inputFormat
        // is the format the engine will actually send to hardware — same trick Apple uses
        // in their AVAudioEngine playback samples. Fall back to a known-good 48kHz stereo
        // if even that comes back zero-channel (paranoia).
        let candidateFormat = engine.outputNode.inputFormat(forBus: 0)
        let connFormat: AVAudioFormat = (candidateFormat.channelCount > 0)
            ? candidateFormat
            : AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
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
        // Tear the continuation grace window down FIRST: cancel the timer and
        // any in-flight/pending turn so mute, backgrounding, or teardown can
        // never leave the mic hot or a request running past the conversation.
        graceTimerTask?.cancel(); graceTimerTask = nil
        inFlightTurnTask?.cancel(); inFlightTurnTask = nil
        lateReplyTask?.cancel(); lateReplyTask = nil
        setGraceActive(false)
        pendingTurnText = ""
        pendingTurnAudio = []
        ttsStartedThisTurn = false
        isProcessing = false
        micHotAfter = .distantPast
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        playerNode.stop()
        // Abandon any in-flight live recognizer so a teardown/mute leaves no
        // recognition task running.
        OnDeviceSTT.shared.cancelStreaming()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isRunning = false
        accumulatorLock.lock()
        pcmAccumulator.removeAll(keepingCapacity: false)
        lastCutPCM.removeAll(keepingCapacity: false)
        silenceFrameCount = 0
        speechFrameCount = 0
        inSpeech = false
        streamingActive = false
        accumulatorLock.unlock()
        // Release any awaiter that was blocked on a streamed final so its Task
        // doesn't hang after the session is torn down.
        streamFinalTimeoutTask?.cancel(); streamFinalTimeoutTask = nil
        if let cont = streamFinalCont {
            streamFinalCont = nil
            cont.resume(throwing: OnDeviceSTT.STTError.recognitionFailed("session stopped"))
        }
        pendingStreamResult = nil
    }

    /// User swiped away the in-flight turn: kill just this turn's work — the
    /// request task (0.2.29) and any late-reply fetch (0.2.32) — and stop the
    /// TTS still playing for it, WITHOUT tearing down the mic/engine. The
    /// session keeps listening; only the one turn the session is working on is
    /// cancelled. A cancelled inFlightTurnTask makes performRequest bail before
    /// emitting transcriptGemma/ttsEnd, so no late events touch the ledger.
    func cancelInFlightTurn() {
        // User explicitly killed this turn — it must never come back via
        // redelivery either.
        PendingTurnStore.clear()
        inFlightTurnTask?.cancel(); inFlightTurnTask = nil
        lateReplyTask?.cancel(); lateReplyTask = nil
        graceTimerTask?.cancel(); graceTimerTask = nil
        setGraceActive(false)
        pendingTurnText = ""
        pendingTurnAudio = []
        ttsStartedThisTurn = false
        // Stop this turn's TTS and release the half-duplex gate so the mic
        // reopens immediately (a no-op if nothing was playing).
        playerNode.stop()
        playerNode.reset()
        isProcessing = false
    }

    /// v0.2.21 — re-assert session + engine on foreground. iOS may have deactivated
    /// during background; without this the playerNode has nothing to push frames into.
    func handleAppDidBecomeActive() {
        guard isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            try? engine.start()
        }
    }

    func mute() { isMuted = true }
    func unmute() { isMuted = false }

    // MARK: - Mute = MIC ONLY (feedback_mute_cuts_mic_only_hard_rule)
    //
    // The mute button must release ONLY the mic input. It must NEVER stop the
    // session, cancel an in-flight utterance, or kill in-progress TTS. This is
    // the counterpart to stop() (full teardown), which is correct ONLY for
    // background/terminate — never for mute. Do NOT route mute through stop().

    /// Mute: (1) finalize any committable in-flight utterance so it still
    /// commits → fires the turn → gets its TTS reply, (2) drop the mic input
    /// tap, (3) reconfigure the audio session to playback-only so the orange
    /// mic indicator goes dark — WHILE the engine keeps running (any playing
    /// reply drains), the session object stays alive, and the turn machinery
    /// is untouched. Never engine.stop() / setActive(false) / nil the session.
    func muteMicOnly() {
        guard isRunning else { return }
        // (1) Finalize an in-flight utterance through the normal cut path. Check
        //     committability under the lock; forceCut() drains the live
        //     recognizer (endStreaming) and awaits its final → a reply streams.
        accumulatorLock.lock()
        let hasCommittable = inSpeech && speechFrameCount >= minUtteranceFrames
        accumulatorLock.unlock()
        if hasCommittable {
            forceCut()
        } else {
            // Nothing worth committing — abandon any half-captured fragment so a
            // live recognizer isn't left running once the tap is gone.
            accumulatorLock.lock()
            streamingActive = false
            pcmAccumulator.removeAll(keepingCapacity: true)
            resetUtteranceState()
            accumulatorLock.unlock()
            OnDeviceSTT.shared.cancelStreaming()
        }
        // (2) Release ONLY the mic input.
        isMuted = true
        engine.inputNode.removeTap(onBus: 0)
        // (3) Go playback-only so the mic indicator goes dark WITHOUT stopping
        //     the engine — the playerNode keeps draining in-flight TTS and the
        //     session stays alive. Restored by unmuteMic().
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true, options: [])
        } catch {
            NSLog("[GemmaVoice] muteMicOnly playback-only switch failed: \(error)")
        }
    }

    /// Unmute: re-acquire the mic on the STILL-ALIVE session — restore the
    /// record+playback category and re-install the input tap on the still-
    /// running engine. Counterpart to muteMicOnly(); no session rebuild.
    /// A2 (2026-08-07): a FAILED re-acquire keeps isMuted asserted and reports
    /// micReacquired=false so the UI never shows "listening" over a dead mic.
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
            // Re-install the mic tap on the running engine (fresh converter in
            // case the hw format changed while playback-only).
            let input = engine.inputNode
            let hwFormat = input.outputFormat(forBus: 0)
            self.converter = AVAudioConverter(from: hwFormat, to: captureFormat)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer)
            }
            if !engine.isRunning {
                engine.prepare()
                do {
                    try engine.start()
                } catch {
                    NSLog("[GemmaVoice] unmuteMic engine restart failed: \(error)")
                    engine.inputNode.removeTap(onBus: 0)
                    ok = false
                }
            }
        }
        // Failed unmute stays honestly muted; the next tap retries.
        isMuted = !ok
        micReacquired = ok
    }

    /// Force-cut the current utterance immediately (Sherman tapping send).
    func forceCut() {
        accumulatorLock.lock()
        guard inSpeech, speechFrameCount >= minUtteranceFrames else {
            accumulatorLock.unlock()
            return
        }
        // Snapshot the utterance audio for per-turn speaker verification
        // before the accumulator is cleared (same as the VAD-cut path).
        lastCutPCM = pcmAccumulator
        pcmAccumulator.removeAll(keepingCapacity: true)
        silenceFrameCount = 0
        speechFrameCount = 0
        inSpeech = false
        streamingActive = false
        accumulatorLock.unlock()
        // Close the live stream; handleUtteranceCut awaits the drained final.
        // A force-cut inside an open grace window still merges (graceActive is
        // read there), so tapping send on a continued thought keeps one turn.
        OnDeviceSTT.shared.endStreaming()
        Task { await handleUtteranceCut() }
    }

    // MARK: - Speaker = OUTPUT ONLY (feedback_implement_the_literal_control_behavior)
    //
    // The speaker toggle changes ONLY the live playback volume of Gemma's TTS.
    // Setting playerNode.volume takes effect IMMEDIATELY on the audio the mixer
    // is rendering right now — so audio already playing is cut/restored
    // mid-buffer, at the moment of press, NOT at the next turn boundary. The
    // node keeps playing (buffers keep draining, the turn/card still complete),
    // it's just inaudible. Independent of mute.

    /// Set Gemma's audio output audible (on) or silent (off) IMMEDIATELY.
    /// `playerNode.volume` is a real-time mixing parameter — changing it affects
    /// the buffer currently rendering, so an OFF cuts her voice live, even
    /// mid-sentence, without stopping the node or the turn. See SpeakerSelfTest.
    @MainActor
    func setSpeakerOutput(on: Bool) {
        playerNode.volume = on ? 1.0 : 0.0
    }

    // MARK: - Single audio owner (0.2.46)

    /// The view model's HTTP reply player (photo/typed turns) is taking over as
    /// the sole audio owner. Silence THIS session's node so two TTS streams
    /// never overlap, and gate mic capture for the duration so the external
    /// audio can't be re-captured and transcribed as a user turn. Releasing
    /// (on:false) re-opens the capture gate; the mic tap is never touched, so
    /// mute state is unaffected.
    @MainActor
    func suppressForExternalPlayback(_ on: Bool) {
        externalPlaybackActive = on
        if on {
            playerNode.stop()
            playerNode.reset()
        }
    }

    // MARK: - Mic loop

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        if isMuted || isProcessing || externalPlaybackActive {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(.level(0)) }
            return
        }
        // Earback-tone guard: right after a send the mic is kept hot for the
        // continuation window, but the local "got it" tone plays in that same
        // instant — swallow input briefly so it can't self-trigger a resume.
        if Date() < micHotAfter {
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
                    // Spin up the live recognizer at speech onset so THIS
                    // utterance is transcribed as it arrives. The current `out`
                    // buffer (fed below) carries the onset, so no lead-in drop.
                    latestPartial = ""
                    beginStreaming()
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
                    // A cut that lands while a turn's grace window is still open
                    // is a CONTINUATION of that turn, not a new one. graceActive
                    // is flipped under this same lock (setGraceActive), so the
                    // read here is race-free.
                    let continuing = graceActive
                    // Stop feeding + close the audio stream; the recognizer
                    // drains to its final while handleUtteranceCut awaits it.
                    streamingActive = false
                    OnDeviceSTT.shared.endStreaming()
                    // Snapshot the utterance audio for per-turn speaker
                    // verification before the accumulator is cleared.
                    lastCutPCM = pcmAccumulator
                    pcmAccumulator.removeAll(keepingCapacity: true)
                    resetUtteranceState()
                    accumulatorLock.unlock()
                    DispatchQueue.main.async { [weak self] in
                        self?.onEvent?(continuing ? .continuationHeard : .speechEnd)
                    }
                    Task { [weak self] in await self?.handleUtteranceCut() }
                    accumulatorLock.lock()
                } else {
                    // Drop tiny utterance, reset — abandon its live stream too.
                    streamingActive = false
                    OnDeviceSTT.shared.cancelStreaming()
                    pcmAccumulator.removeAll(keepingCapacity: true)
                    resetUtteranceState()
                }
            }
        }
        // Feed this callback's converted audio to the live recognizer while
        // we're mid-utterance (started at speech onset, closed at the cut above).
        if streamingActive {
            OnDeviceSTT.shared.appendStreaming(out)
        }
        // A1 (jetsam): bound the accumulator. Outside speech only a short
        // pre-roll tail is worth keeping (utterance lead-in) — everything
        // older is ambient silence that used to accumulate at 64 KB/s for the
        // life of the session. In speech the VAD force-cut bounds the
        // utterance (~30s via maxUtteranceFrames), but the hard cap
        // drop-oldest below guards every remaining path. processedSampleCount
        // tracks positions in accumulator coordinates, so it shifts with any
        // front-drop.
        if !inSpeech && pcmAccumulator.count > preRollKeepSamples {
            let drop = pcmAccumulator.count - preRollKeepSamples
            pcmAccumulator.removeFirst(drop)
            processedSampleCount = max(0, processedSampleCount - drop)
        }
        if pcmAccumulator.count > hardCapSamples {
            let drop = pcmAccumulator.count - hardCapSamples
            pcmAccumulator.removeFirst(drop)
            processedSampleCount = max(0, processedSampleCount - drop)
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

    // MARK: - Utterance processing / continuation state machine

    /// An utterance just ended (VAD cut or force-cut). Transcribe it, then
    /// either open a FRESH turn or, if a turn's grace window is still open,
    /// MERGE this fragment into it — cancelling the in-flight request and
    /// re-sending the combined text as the same turn.
    private func handleUtteranceCut() async {
        // Claim the just-cut utterance audio (snapshotted under the lock at
        // the cut) as this turn's speaker-verification fragment. Claimed up
        // front so an empty/errored transcript discards it rather than letting
        // it leak into a later turn.
        let fragmentPCM = claimCutPCM()
        // The recognizer has been fed live during speech and endStreaming() was
        // called at the cut; await its drained final (~100-300ms) rather than
        // transcribing a cold full-utterance batch here.
        let transcript: String
        do {
            transcript = try await awaitStreamingFinal()
        } catch {
            // Final drained empty or errored — fall back to the last partial if
            // we captured one, so a drain hiccup doesn't drop a whole utterance.
            let fallback = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            if fallback.isEmpty {
                self.onEvent?(.dropped("stt: \(error)"))
                return
            }
            transcript = fallback
        }
        let polished = postProcess(transcript)
        if polished.isEmpty {
            // An empty continuation leaves the open turn untouched; an empty
            // fresh utterance is a plain drop.
            if !graceActive { self.onEvent?(.dropped("empty transcript")) }
            return
        }

        if graceActive {
            // CONTINUATION: supersede the in-flight turn. Cancel its request,
            // grow the text, and re-send the combined thought as the same turn.
            inFlightTurnTask?.cancel()
            let combined = pendingTurnText.isEmpty ? polished : pendingTurnText + " " + polished
            pendingTurnText = combined
            // Merged re-send carries the CONCATENATED audio of both fragments.
            pendingTurnAudio = Array((pendingTurnAudio + fragmentPCM).prefix(maxSpeakerClipSamples))
            self.onEvent?(.transcriptContinued(combined))
            sendTurn(text: combined)
        } else {
            // FRESH turn.
            pendingTurnText = polished
            pendingTurnAudio = Array(fragmentPCM.prefix(maxSpeakerClipSamples))
            self.onEvent?(.transcriptYou(polished))
            sendTurn(text: polished)
        }
    }

    /// Dispatch (or re-dispatch, on a merge) the open turn to /text_turn and
    /// open its continuation grace window: the mic stays hot (isProcessing
    /// stays false) so a resumed thought can merge, until either the reply's
    /// first audio arrives (→ half-duplex) or the window expires.
    private func sendTurn(text: String) {
        setGraceActive(true)
        ttsStartedThisTurn = false
        isProcessing = false
        // Keep the mic hot from here, but swallow the earback tone that plays in
        // this same instant so it can't self-trigger a continuation.
        micHotAfter = Date().addingTimeInterval(earbackGuardWindow)
        startGraceTimer()
        let turnText = text
        inFlightTurnTask = Task { [weak self] in
            await self?.performRequest(turnText)
        }
    }

    /// POST the (possibly merged) turn text and stream the reply audio. Bails
    /// silently if a continuation cancelled it mid-flight — the merged re-send
    /// now owns the turn.
    private func performRequest(_ text: String) async {
        // Build the speaker-verification WAV from the open turn's audio at
        // send time — a merged re-send therefore carries both fragments.
        let wavBase64 = Self.speakerClipBase64(fromPCM: pendingTurnAudio)
        // 0.2.44 redelivery: durable record of the in-flight turn. Overwritten
        // by a continuation merge (same logical turn), upgraded with the
        // server's X-Turn-Id when headers arrive, cleared on resolution below.
        PendingTurnStore.begin(text: text)
        do {
            let result = try await textTurnClient.postText(
                text,
                speakerHint: "sherman",
                sessionId: sessionId,
                wavBase64: wavBase64,
                imageBase64: nil,   // voice turns carry no photo (0.2.45)
                onTurnId: { rid in
                    // URLSession delivers this off-main; the store is
                    // UserDefaults-backed and thread-safe.
                    PendingTurnStore.assignRid(rid)
                },
                onAudioChunk: { [weak self] chunk in
                    guard let self = self else { return }
                    // First reply audio = she's answering. Go half-duplex
                    // SYNCHRONOUSLY (Bool read on the audio thread) to close the
                    // echo window tightly, then do the bookkeeping on the main
                    // actor. Idempotent: only the first chunk of the turn acts.
                    if self.graceActive {
                        self.isProcessing = true
                        Task { @MainActor [weak self] in self?.closeGraceForPlayback() }
                    }
                    self.scheduleTTSChunk(chunk)
                }
            )
            if Task.isCancelled { return }
            // Turn completed over its own transport — nothing to redeliver.
            // (Streaming path: fetchLateReply below still backfills the text.)
            PendingTurnStore.clear()
            if !result.replyText.isEmpty {
                // Classic path: the reply came back in the X-Reply-Text header.
                // Show it immediately, exactly as before. `brain` carries the
                // server's X-Brain (who ACTUALLY answered) for the UI badge.
                self.onEvent?(.transcriptGemma(result.replyText, brain: result.brain))
                self.onEvent?(.ttsEnd)
                finishTurn()
            } else if let rid = result.rid, !rid.isEmpty {
                // Streaming path: the header carried no reply text (it's sent
                // before the reply exists). Complete the turn's audio FIRST so
                // the mic reopens without waiting on the text, then fetch the
                // reply and backfill the card. Don't block audio on the fetch.
                self.onEvent?(.ttsEnd)
                finishTurn()
                fetchLateReply(rid: rid)
            } else {
                // No reply text and no rid to fetch one — still end the turn
                // cleanly (parity with the old empty-header no-op).
                self.onEvent?(.ttsEnd)
                finishTurn()
            }
        } catch is CancellationError {
            // Cancelled by a merge (re-send owns the record) or a teardown
            // (the reply may still land server-side — KEEP the record so the
            // foreground redelivery check can fetch it). Swipe-delete clears
            // explicitly in cancelInFlightTurn.
            return
        } catch {
            let ns = error as NSError
            if Task.isCancelled || ns.code == NSURLErrorCancelled { return }
            // 0.2.44 redelivery: a transport-class death (connection lost,
            // timeout, app suspended mid-request) is exactly the case the
            // server-side reply store covers — KEEP the pending record; the
            // view model's recovery path fetches GET /reply_text with it.
            // Anything else (auth, 4xx/5xx, passphrase) is a real turn
            // failure: clear so stale records can't ghost-redeliver later.
            if ns.domain != NSURLErrorDomain {
                PendingTurnStore.clear()
            }
            // A real failure ends the turn: release the gate, surface it.
            finishTurn()
            if let kw = ns.userInfo["matchedKeyword"] as? String {
                self.onEvent?(.dropped("passphrase required for '\(kw)'"))
            } else {
                self.onEvent?(.sessionError(error))
            }
        }
    }

    /// Streaming path (0.2.32): the turn's audio has finished but the reply
    /// text wasn't in the response header. Poll GET /reply_text?rid a few times
    /// (the text lands within a sentence or two of audio end) and, once it's
    /// non-null, emit .replyTextLate so the UI backfills the answered card.
    /// Runs detached from the turn's request task — audio already played, so
    /// nothing here blocks playback or the mic. Cancelled on stop().
    private func fetchLateReply(rid: String) {
        lateReplyTask?.cancel()
        lateReplyTask = Task { [weak self] in
            // Up to 3 attempts at ~400ms spacing. First try fires immediately;
            // if the reply is still null we wait, then retry.
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                guard let self = self else { return }
                if let reply = try? await self.textTurnClient.fetchReplyText(rid: rid),
                   !reply.isEmpty {
                    if Task.isCancelled { return }
                    self.onEvent?(.replyTextLate(reply))
                    return
                }
                // reply null / not ready — back off before the next try (skip
                // the wait after the final attempt).
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
    }

    // MARK: - Grace-window lifecycle

    /// Flip graceActive under the accumulator lock so the mic thread (which
    /// reads it when classifying a cut) never sees a torn value.
    private func setGraceActive(_ value: Bool) {
        accumulatorLock.lock()
        graceActive = value
        accumulatorLock.unlock()
    }

    private func startGraceTimer() {
        graceTimerTask?.cancel()
        let window = continuationGraceWindow
        graceTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.expireGrace()
        }
    }

    /// Window elapsed with no resume and no reply audio yet (brain still
    /// thinking). Fall back to normal half-duplex — mic deaf until the reply is
    /// done; a later utterance becomes a fresh turn. If the user is actively
    /// mid-continuation right now, DON'T slam the mic shut — extend the window
    /// so the in-progress thought finishes and merges.
    private func expireGrace() {
        guard graceActive, !ttsStartedThisTurn else { return }
        accumulatorLock.lock()
        let speaking = inSpeech
        accumulatorLock.unlock()
        if speaking { startGraceTimer(); return }
        setGraceActive(false)
        isProcessing = true
    }

    /// Reply audio has started — close the window and go half-duplex for the
    /// duration of playback. Idempotent. Abandons any half-captured resume
    /// (rare: reply beat a mid-continuation utterance to the finish line).
    private func closeGraceForPlayback() {
        guard graceActive else { return }
        setGraceActive(false)
        graceTimerTask?.cancel(); graceTimerTask = nil
        ttsStartedThisTurn = true
        isProcessing = true
        abandonInProgressCapture()
    }

    /// Turn is fully done (reply played, or errored). Clear turn state and
    /// release the half-duplex gate once playback drains.
    private func finishTurn() {
        setGraceActive(false)
        graceTimerTask?.cancel(); graceTimerTask = nil
        inFlightTurnTask = nil
        pendingTurnText = ""
        pendingTurnAudio = []
        ttsStartedThisTurn = false
        releaseProcessingAfterDrain()
    }

    /// v0.2.20 drain behaviour, factored out of the old processUtterance defer:
    /// hold isProcessing only until playerNode actually drains, polling every
    /// 100ms, hard-capped at 2s so a stuck node can't latch the mic shut.
    private func releaseProcessingAfterDrain() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline && self.playerNode.isPlaying {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self.isProcessing = false
        }
    }

    /// Abandon a live recognizer / half-captured utterance (used when playback
    /// forces the window shut mid-continuation).
    private func abandonInProgressCapture() {
        accumulatorLock.lock()
        if inSpeech || streamingActive {
            streamingActive = false
            OnDeviceSTT.shared.cancelStreaming()
            pcmAccumulator.removeAll(keepingCapacity: true)
            resetUtteranceState()
        }
        accumulatorLock.unlock()
    }

    // MARK: - Streaming STT lifecycle

    /// Start the live recognizer for the current utterance. onPartial keeps
    /// `latestPartial` current (fallback + future on-screen display); onFinal
    /// routes the drained final to deliverStreamingFinal.
    private func beginStreaming() {
        guard !streamingActive else { return }
        // Reset the final-handoff state ON THE MAIN ACTOR — beginStreaming is
        // called from the render thread (speech onset), and streamFinalCont /
        // pendingStreamResult are main-actor state (A1, render-thread races).
        // A lingering continuation from an abandoned turn is RESUMED with an
        // error, never nil'd unresumed — dropping it leaked the awaiting Task
        // (~2MB) forever (the old :816 bug).
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingStreamResult = nil
            self.streamFinalTimeoutTask?.cancel(); self.streamFinalTimeoutTask = nil
            if let cont = self.streamFinalCont {
                self.streamFinalCont = nil
                cont.resume(throwing: OnDeviceSTT.STTError.recognitionFailed("superseded by new utterance"))
            }
        }
        let ok = OnDeviceSTT.shared.startStreaming(
            onPartial: { [weak self] text in
                Task { @MainActor in self?.latestPartial = text }
            },
            onFinal: { [weak self] result in
                Task { @MainActor in self?.deliverStreamingFinal(result) }
            }
        )
        streamingActive = ok
    }

    /// Receives the streamed final (async, on the main actor). Resumes a waiting
    /// awaiter if one is installed, otherwise stashes the result so a
    /// slightly-later awaitStreamingFinal() picks it up. MainActor serialization
    /// makes this handoff race-free.
    private func deliverStreamingFinal(_ result: Result<String, OnDeviceSTT.STTError>) {
        streamFinalTimeoutTask?.cancel(); streamFinalTimeoutTask = nil
        let mapped: Result<String, Error> = result.mapError { $0 as Error }
        if let cont = streamFinalCont {
            streamFinalCont = nil
            cont.resume(with: mapped)
        } else {
            pendingStreamResult = mapped
        }
    }

    /// Await the drained final for the just-cut utterance. Returns immediately if
    /// the final already arrived (stashed), else suspends until deliverStreamingFinal
    /// — bounded by streamFinalTimeout so a hung recognizer can't strand the
    /// awaiting Task forever (A1, the old :844 had no timeout).
    private func awaitStreamingFinal() async throws -> String {
        if let pending = pendingStreamResult {
            pendingStreamResult = nil
            return try pending.get()
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            streamFinalCont = cont
            streamFinalTimeoutTask?.cancel()
            let timeout = streamFinalTimeout
            streamFinalTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if let cont = self.streamFinalCont {
                    self.streamFinalCont = nil
                    cont.resume(throwing: OnDeviceSTT.STTError.recognitionFailed(
                        "streamed final timed out after \(Int(timeout))s"))
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

    /// Take-and-clear the utterance PCM snapshotted at the cut. Synchronous so
    /// the NSLock stays out of async contexts (a Swift 6 error otherwise);
    /// called from handleUtteranceCut on the main actor.
    private func claimCutPCM() -> [Float] {
        accumulatorLock.lock()
        defer { accumulatorLock.unlock() }
        let pcm = lastCutPCM
        lastCutPCM = []
        return pcm
    }

    /// Pack float32 [-1,1] samples into a base64 16kHz mono PCM16 WAV for the
    /// /text_turn `wav_base64` field — same WAV builder the enrollment flow
    /// uses (AudioRecorder.wavData). Returns nil when there is no audio.
    private static func speakerClipBase64(fromPCM pcm: [Float]) -> String? {
        guard !pcm.isEmpty else { return nil }
        var samples = [Int16](repeating: 0, count: pcm.count)
        for i in 0..<pcm.count {
            let clamped = max(-1.0, min(1.0, pcm[i]))
            samples[i] = Int16(clamped * 32767)
        }
        let pcmData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let wav = AudioRecorder.wavData(pcm16: pcmData, sampleRate: 16_000, channels: 1)
        return wav.base64EncodedString()
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

// Mute = MIC ONLY contract (see MuteSelfTest.swift). Methods live in the class
// body above; this declares the conformance.
extension OnDeviceConversationSession: MicMuteControllable {}
extension OnDeviceConversationSession: SpeakerControllable {}

// MARK: - TextTurnClient stub protocol
// Real implementation lands in commit 3 (TextTurnClient.swift). Defined
// here as a protocol so this commit compiles standalone.

protocol TextTurnClientProtocol {
    /// POST text to /text_turn and stream the PCM reply via onAudioChunk
    /// as it arrives. Returns the reply text (from the X-Reply-Text header).
    /// wavBase64 (0.2.31) is the utterance audio as a base64 16kHz mono
    /// PCM16 WAV for server-side speaker verification; nil omits the field.
    /// imageBase64 (0.2.45) is a downscaled JPEG for photo turns — the server
    /// saves it and hands desk-Gemma the file path; nil omits the field.
    func postText(
        _ text: String,
        speakerHint: String,
        sessionId: String,
        wavBase64: String?,
        imageBase64: String?,
        onTurnId: @escaping (String) -> Void,
        onAudioChunk: @escaping (Data) -> Void
    ) async throws -> TextTurnResult

    /// Fetch the full reply text for a completed turn keyed on the server's
    /// X-Turn-Id (0.2.32). Returns nil when the reply isn't ready yet or the
    /// rid is unknown. Used only on the streaming path, where X-Reply-Text
    /// (→ replyText) came back empty.
    func fetchReplyText(rid: String) async throws -> String?
}

struct TextTurnResult {
    let replyText: String
    /// Server-minted turn id (X-Turn-Id header). Present on every response;
    /// nil only if the header was missing. On the streaming path replyText is
    /// empty and the reply is fetched afterwards via fetchReplyText(rid:).
    let rid: String?
    /// Brain that ACTUALLY answered (X-Brain header, lowercased: "gemma" |
    /// "jarvis" | "kai"). nil when the server predates the header. Differs
    /// from the requested agent on a busy-fallback turn — the UI badges it.
    var brain: String? = nil
}

/// Inert default client used if nothing else is wired. Returns a friendly
/// error so misconfiguration surfaces obviously rather than hanging.
struct StubTextTurnClient: TextTurnClientProtocol {
    func postText(_ text: String,
                  speakerHint: String,
                  sessionId: String,
                  wavBase64: String?,
                  imageBase64: String?,
                  onTurnId: @escaping (String) -> Void,
                  onAudioChunk: @escaping (Data) -> Void) async throws -> TextTurnResult {
        throw NSError(
            domain: "OnDeviceConversation",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "TextTurnClient not wired (see commit 3)"]
        )
    }

    func fetchReplyText(rid: String) async throws -> String? { nil }
}
