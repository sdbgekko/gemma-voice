import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Streaming replacement for ViewModel. Same @Published surface so
/// ContentView is unchanged. All heavy lifting lives on the server over
/// a single WebSocket — Silero VAD decides speech boundaries; mic frames
/// stream up as float32 PCM; Kokoro TTS streams back as int16 PCM chunks
/// that an AVAudioPlayerNode schedules for playback.
@MainActor
final class StreamingViewModel: ObservableObject {
    @Published var transcript: [Turn] = []
    /// UI source of truth for the turn-ledger view. Maintained alongside
    /// `transcript` (which still feeds WatchBridge). Strictly serial in v1:
    /// late events attach to the newest still-open card.
    @Published var ledger: [LedgerTurn] = []
    @Published var status: Status = .muted
    @Published var errorMessage: String?
    @Published var currentLevel: Float = 0
    @Published var levelHistory: [Float] = Array(repeating: 0, count: 40)
    @Published var hadSpeechFlag = false
    @Published var lastSendAttempt: Date?
    @Published var lastSendResult: String = "-"

    private var session: StreamingSession?
    private var onDeviceSession: OnDeviceConversationSession?
    /// Snapshot of the toggle at start time — switching mid-session is
    /// out of scope; the value here is whichever was active when the
    /// user first granted mic permission this launch.
    private var useOnDevice: Bool = false
    private let endpoint: URL
    private let maxTurns = 20
    /// User tapped mute. Stays true until they tap unmute, regardless of
    /// playback state, so the UI doesn't flip colors while TTS plays over
    /// a muted mic.
    private var userMuted = false
    /// Rolling window of recent raw RMS samples. Used to derive an
    /// adaptive ambient floor so the waveform shows *delta above ambient*
    /// rather than absolute level — matters in cars, on trains, anywhere
    /// with loud-but-stationary background noise.
    private var recentLevels: [Float] = []
    private let recentLevelsCap = 80   // ~2.5s at 32ms/frame
    private var statusCancellable: AnyCancellable?
    private var liveActivityStarted = false
    private var currentAgentName: String = "Gemma"
    /// True once a capture session's engine has actually started, false after
    /// any stop/teardown/mute. Distinct from `session != nil` — the session
    /// objects outlive a stop(); this tracks whether the mic is really hot.
    private var isCapturing = false

    /// A conversation is "active" only when the mic engine is running AND the
    /// user hasn't muted — i.e. we are (or should be) holding the mic to
    /// listen, carry a turn in flight, or play Gemma's reply. This is the sole
    /// condition under which audio is KEPT alive across backgrounding (the
    /// hands-free / locked-screen / car feature) and the sole condition under
    /// which a foreground transition re-asserts the audio session. Muted or
    /// not-yet-started = not active = release the mic + session + Live Activity.
    private var conversationActive: Bool { isCapturing && !userMuted }

    init() {
        // JMM Tailscale IP, streaming server port 9201.
        self.endpoint = URL(string: "ws://100.80.225.86:9201")!

        // v0.2.21 fix: when iOS suspends + resumes the app (phone call, home button,
        // background), AVAudioSession deactivates silently and the WebSocket can
        // drop without notification. UIApplication.didBecomeActiveNotification fires
        // on every foreground transition; re-assert the audio session and let the
        // active session's resume path rebuild the engine if needed.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                // Only re-assert the audio session when a conversation is
                // genuinely active. Doing this unconditionally re-activated the
                // session (and lit the mic) on every foreground of an idle/muted
                // app — part of the "holds a hot mic when it shouldn't" bug.
                guard self.conversationActive else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                // If a session is mid-flight, give it a chance to recover; the session's
                // own foreground hook handles engine restart specifics.
                self.session?.handleAppDidBecomeActive()
                self.onDeviceSession?.handleAppDidBecomeActive()
            }
        }

        // Best-effort teardown if iOS terminates us. Unreliable on a suspended
        // swipe-kill (the process may be killed outright), but when it does
        // fire it releases the mic/session and ends the Live Activity so a kill
        // leaves nothing hot behind. The reliable teardown is the scenePhase
        // .background path (handleScenePhase) plus the resurrection guard in
        // startSession() that stops a background-relaunched app grabbing the mic.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated { self.teardownAudio() }
        }

        // Push every status change to the Live Activity. The first non-muted
        // transition starts the activity; .connectionClosed ends it.
        statusCancellable = $status
            .removeDuplicates { lhs, rhs in
                // Treat .speaking_ as the same state as itself even when
                // the timestamp would otherwise force a refresh — we
                // only want to push transitions, not every audio frame.
                String(describing: lhs) == String(describing: rhs)
            }
            .sink { [weak self] newStatus in
                guard let self = self else { return }
                let code = newStatus.liveActivityCode
                if !self.liveActivityStarted && newStatus != .muted {
                    LiveActivityController.shared.start(
                        agentName: self.currentAgentName,
                        initialStatus: code
                    )
                    self.liveActivityStarted = true
                } else if self.liveActivityStarted {
                    LiveActivityController.shared.update(to: code)
                }
            }
    }

    deinit {
        statusCancellable?.cancel()
        Task { @MainActor in
            LiveActivityController.shared.end()
        }
    }

    func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                if granted {
                    self.startSession()
                } else {
                    self.errorMessage = "Microphone permission denied. Enable it in Settings."
                }
            }
        }
    }

    func toggleMute() {
        if userMuted {
            // Unmute → re-acquire the mic and resume listening. Muting fully
            // released the audio session (mic indicator off), so this rebuilds
            // a fresh capture session rather than just flipping a deaf flag.
            userMuted = false
            startSession()
        } else {
            // Mute → release the mic entirely so the indicator goes dark, not
            // just go deaf. Idle/muted must never hold a hot mic.
            userMuted = true
            stopCapture()
            status = .muted
        }
    }

    func forceSend() {
        session?.forceCut()
        onDeviceSession?.forceCut()
    }

    /// P0-1: user tapped the "disconnected — tap to reconnect" pill. Force a
    /// fresh WebSocket immediately (no backoff wait). The on-device path has
    /// no socket, so this is a no-op there. .connectionOpened confirms the
    /// live state; we don't optimistically flip to listening here.
    func reconnect() {
        session?.reconnectNow()
    }

    private func startSession() {
        // Never grab the mic while backgrounded. iOS resurrects a force-quit
        // app in the BACKGROUND (applicationState == .background); this guard is
        // what makes a resurrected/idle app hold NOTHING. A genuine foreground
        // open re-drives this via ContentView.onAppear / scenePhase → .active.
        guard UIApplication.shared.applicationState != .background else { return }

        // Snapshot toggle once at session start; mid-session switching is
        // out of scope for v0.2.16. Sherman flips → taps mute/unmute or
        // relaunches → engages the new path.
        useOnDevice = UserDefaults.standard.bool(forKey: "useOnDeviceSTT")

        if useOnDevice {
            if onDeviceSession == nil {
                guard let s = OnDeviceConversationSession(client: TextTurnClient()) else {
                    errorMessage = "Could not create on-device audio session."
                    return
                }
                s.onEvent = { [weak self] event in
                    Task { @MainActor in self?.handleOnDevice(event) }
                }
                self.onDeviceSession = s
            }
            // Make sure on-device STT permission is granted before we start
            // the engine — otherwise the first transcribe call fails late.
            OnDeviceSTT.shared.requestAuthorizationIfNeeded { [weak self] granted in
                guard let self = self else { return }
                Task { @MainActor in
                    if !granted {
                        self.errorMessage = "Speech Recognition not authorized — enable in iOS Settings, or turn off Use on-device transcription in app Settings."
                        return
                    }
                    do {
                        try self.onDeviceSession?.start()
                        self.onDeviceSession?.unmute()
                        self.isCapturing = true
                        self.status = .listening
                    } catch {
                        self.errorMessage = "Mic error: \(error.localizedDescription)"
                        self.status = .muted
                    }
                }
            }
            return
        }

        if session == nil {
            guard let s = StreamingSession(url: endpoint) else {
                errorMessage = "Could not create audio session."
                return
            }
            s.onEvent = { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            self.session = s
        }
        do {
            try session?.start()
            session?.unmute()
            isCapturing = true
            status = .listening
        } catch {
            errorMessage = "Mic error: \(error.localizedDescription)"
            status = .muted
        }
    }

    // MARK: - Lifecycle teardown / resume

    /// Stop the mic + deactivate the audio session, releasing the mic
    /// indicator. The session objects are dropped so the next start()
    /// rebuilds a fresh AVAudioEngine (avoids re-attaching a node to an
    /// already-attached engine on the mute→unmute cycle). Called on mute and
    /// from teardownAudio.
    private func stopCapture() {
        session?.stop()
        onDeviceSession?.stop()
        session = nil
        onDeviceSession = nil
        isCapturing = false
    }

    /// Release the mic + audio session AND end the Live Activity. Called when
    /// the app backgrounds/resigns without an active conversation, and on
    /// termination — so a killed or backgrounded-idle app leaves nothing hot
    /// and no lingering lock-screen / Dynamic Island indicator.
    private func teardownAudio() {
        stopCapture()
        LiveActivityController.shared.end()
        liveActivityStarted = false
    }

    /// Driven by the App's scenePhase observer.
    /// - `.background` / `.inactive`: release everything UNLESS a conversation
    ///   is active (the hands-free / locked-screen / car feature is kept alive).
    /// - `.active`: if we're foreground, idle, and not muted, resume listening.
    ///   This covers a resurrected app the user has now actually opened — the
    ///   background relaunch grabbed nothing, and opening it starts a clean
    ///   session.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if !isCapturing && !userMuted {
                requestMicPermission()
            }
        case .background, .inactive:
            if !conversationActive {
                teardownAudio()
            }
        @unknown default:
            break
        }
    }

    /// Map OnDeviceConversationSession events onto the same UI surface as
    /// the WebSocket path so ContentView doesn't need to know which path
    /// is active.
    private func handleOnDevice(_ event: OnDeviceConversationSession.Event) {
        switch event {
        case .level(let level):
            // No ambient floor here yet — surface raw level. Adding the
            // 20th-percentile ambient floor logic from the WS path is
            // tracked for a follow-up; v0.2.16 ships with raw.
            currentLevel = level
            var h = levelHistory
            h.removeFirst()
            h.append(level)
            levelHistory = h
        case .speechStart:
            if userMuted { break }
            if status == .listening { status = .speaking_ }
            hadSpeechFlag = true
        case .speechEnd:
            if userMuted { break }
            EarbackTone.shared.play()
            status = .thinking
            ledgerAppendHeard()
        case .continuationHeard:
            // A resume merged into the open turn — ack it, but do NOT open a
            // second card. transcriptContinued grows the existing one in place.
            if userMuted { break }
            EarbackTone.shared.play()
            status = .thinking
        case .transcriptContinued(let text):
            // The same turn's text grew ("…first part …continued part"). Update
            // the last user turn + grow the open ledger card; no new card.
            if !text.isEmpty {
                replaceLastUserTurn(text: text, speaker: "sherman")
                ledgerGrowYou(text)
            }
            if !userMuted { status = .thinking }
        case .transcriptYou(let text):
            if !text.isEmpty {
                appendTurn(text: text, isGemma: false, source: "on-device", speaker: "sherman")
                ledgerFillYou(text, speaker: "sherman")
            }
        case .transcriptGemma(let text):
            if !text.isEmpty {
                appendTurn(text: text, isGemma: true, source: "gemma", speaker: nil)
                ledgerSetReply(text, source: "gemma")
            }
            if !userMuted { status = .playing }
        case .ttsEnd:
            ledgerAnswered()
            if userMuted {
                status = .muted
            } else if status == .playing || status == .thinking {
                status = .listening
            }
        case .dropped(let reason):
            ledgerDropped(reason)
            if userMuted {
                status = .muted
            } else if status == .thinking {
                status = .listening
            }
            errorMessage = reason.isEmpty ? nil : "Dropped: \(reason)"
        case .sessionError(let err):
            errorMessage = err.localizedDescription
            status = .listening
        }
    }

    private func handle(_ event: StreamingSession.Event) {
        switch event {
        case .level(let level):
            // Rolling window.
            recentLevels.append(level)
            if recentLevels.count > recentLevelsCap {
                recentLevels.removeFirst(recentLevels.count - recentLevelsCap)
            }
            // Ambient floor = 20th-percentile of recent samples. Robust to
            // speech bursts (which drive the top percentiles) while tracking
            // slowly-changing background noise like road drone.
            let floor: Float
            if recentLevels.count >= 20 {
                let sorted = recentLevels.sorted()
                floor = sorted[sorted.count / 5]
            } else {
                floor = 0
            }
            let adjusted = max(0, level - floor)
            currentLevel = adjusted
            var h = levelHistory
            h.removeFirst()
            h.append(adjusted)
            levelHistory = h
        case .speechStart:
            if userMuted { break }
            if status == .listening { status = .speaking_ }
            hadSpeechFlag = true
        case .speechEnd:
            if userMuted { break }
            // Audible + haptic ack: sub-200ms signal that I heard you,
            // before the pipeline starts chewing. Roundtable synthesis 2026-05-18
            // ranked this state as #1 fix — the kill-shot for "can you hear me?".
            EarbackTone.shared.play()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            status = .heardYou
            ledgerAppendHeard()
        case .transcriptYou(let text, let speaker):
            if !text.isEmpty {
                appendTurn(text: text, isGemma: false, source: nil, speaker: speaker)
                ledgerFillYou(text, speaker: speaker)
            }
            // STT result arrived — promote heardYou → thinking, waiting for reply.
            if status == .heardYou { status = .thinking }
        case .transcriptGemma(let text, let source):
            if !text.isEmpty {
                appendTurn(text: text, isGemma: true, source: source, speaker: nil)
                ledgerSetReply(text, source: source)
            }
            // Only flip UI to .playing if user isn't muted; mute is sticky.
            if !userMuted { status = .playing }
        case .ttsEnd:
            ledgerAnswered()
            if userMuted {
                status = .muted
            } else if status == .playing || status == .thinking || status == .heardYou {
                status = .listening
            }
        case .dropped(let reason):
            // P0-3 belt-and-suspenders: the server now drops self-echo BEFORE
            // sending transcript_you, so ghost bubbles should already be gone.
            // As a client safety net, if the server reports a self-echo drop,
            // remove the most-recent non-Gemma turn appended within the last
            // ~10s (a ghost that slipped through an older server).
            if reason.hasPrefix("self-echo"),
               let idx = transcript.lastIndex(where: { !$0.isGemma }),
               Date().timeIntervalSince(transcript[idx].timestamp) <= 10 {
                transcript.remove(at: idx)
            }
            ledgerDropped(reason)
            if userMuted {
                status = .muted
            } else if status == .thinking || status == .heardYou {
                status = .listening
            }
        case .connectionClosed:
            // P0-1: the socket is down. Show an honest .disconnected state in
            // the pill (never a false "listening") instead of popping a modal
            // alert on every background→foreground blip — the session backs
            // off and reconnects on its own, and .connectionOpened restores
            // the live state. Sticky mute wins over disconnected display.
            if !userMuted { status = .disconnected }
            errorMessage = nil
            // Tear down the Live Activity so the lock-screen indicator
            // doesn't lie about an alive session.
            LiveActivityController.shared.end()
            liveActivityStarted = false
        case .connectionOpened:
            // P0-1: WebSocket handshake completed — the socket is genuinely
            // live, so it's honest to show listening again (unless muted).
            errorMessage = nil
            if !userMuted && status == .disconnected { status = .listening }
        case .agent(let name):
            // Server is announcing which agent the voice channel is bound to.
            currentAgentName = name
            LiveActivityController.shared.updateAgentName(name)
        }
    }

    private func appendTurn(text: String, isGemma: Bool, source: String?, speaker: String? = nil) {
        let turn = Turn(text: text, isGemma: isGemma, source: source, speaker: speaker)
        transcript.append(turn)
        if transcript.count > maxTurns {
            transcript.removeFirst(transcript.count - maxTurns)
        }
        WatchBridge.shared.sendTurn(id: turn.id, text: text, isGemma: isGemma)
    }

    /// Replace the most-recent user turn's text in place (utterance continuation).
    /// Turn is immutable, so we swap the element; falls back to append if no
    /// user turn exists yet. Keeps `transcript`/WatchBridge in step with the
    /// ledger card that grows on a merge.
    private func replaceLastUserTurn(text: String, speaker: String?) {
        if let idx = transcript.lastIndex(where: { !$0.isGemma }) {
            let old = transcript[idx]
            let merged = Turn(text: text, isGemma: false, source: old.source, speaker: speaker)
            transcript[idx] = merged
            WatchBridge.shared.sendTurn(id: merged.id, text: text, isGemma: false)
        } else {
            appendTurn(text: text, isGemma: false, source: "on-device", speaker: speaker)
        }
    }

    // MARK: - Turn ledger
    //
    // Event → phase mapping (v1 serial): speechEnd → append .heard;
    // transcriptYou → fill youText/speaker, .working, startedAt;
    // transcriptGemma → fill reply/source, .speaking; ttsEnd → .answered;
    // dropped → .dropped(reason). Connection events do NOT touch the ledger —
    // they drive the dock only.

    private let maxLedger = 20

    /// Newest card that hasn't reached a terminal phase (.answered/.dropped).
    /// v1 correlation is positional only — no server rid echo yet.
    private var latestPendingIndex: Int? {
        ledger.lastIndex { turn in
            switch turn.phase {
            case .answered, .dropped: return false
            default: return true
            }
        }
    }

    private func ledgerAppendHeard() {
        ledger.append(LedgerTurn(youText: "", speaker: nil, reply: nil, source: nil,
                                 rid: nil, phase: .heard, startedAt: nil, answeredAt: nil))
        if ledger.count > maxLedger {
            ledger.removeFirst(ledger.count - maxLedger)
        }
    }

    private func ledgerFillYou(_ text: String, speaker: String?) {
        guard let i = latestPendingIndex else {
            // No open card (missed speechEnd) — synthesize one already in flight.
            ledger.append(LedgerTurn(youText: text, speaker: speaker, reply: nil,
                                     source: nil, rid: nil, phase: .working,
                                     startedAt: Date(), answeredAt: nil))
            if ledger.count > maxLedger { ledger.removeFirst(ledger.count - maxLedger) }
            return
        }
        ledger[i].youText = text
        ledger[i].speaker = speaker
        ledger[i].phase = .working
        ledger[i].startedAt = Date()
    }

    /// A continuation merged new speech into the open turn: grow the same card's
    /// text in place and reset it to .working (a fresh reply is now in flight).
    /// Reuses latestPendingIndex — the still-open card from the first fragment.
    private func ledgerGrowYou(_ combinedText: String) {
        guard let i = latestPendingIndex else { return }
        ledger[i].youText = combinedText
        ledger[i].phase = .working
        ledger[i].startedAt = Date()
    }

    private func ledgerSetReply(_ text: String, source: String?) {
        guard let i = latestPendingIndex else { return }
        ledger[i].reply = text
        ledger[i].source = source
        ledger[i].phase = .speaking
    }

    private func ledgerAnswered() {
        guard let i = latestPendingIndex else { return }
        ledger[i].phase = .answered
        ledger[i].answeredAt = Date()
    }

    private func ledgerDropped(_ reason: String) {
        guard let i = latestPendingIndex else { return }
        ledger[i].phase = .dropped(reason)
    }
}
