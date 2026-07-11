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
    private var latestPartial = ""
    private var streamFinalCont: CheckedContinuation<String, Error>?
    private var pendingStreamResult: Result<String, Error>?

    // State machine
    private var isRunning = false
    private var isMuted = false
    /// While TTS is playing we suspend new utterance detection so the user
    /// doesn't talk over Gemma's reply (and vice versa). 0.2.29: this is NO
    /// longer set the instant the utterance is cut — the continuation grace
    /// window (below) keeps the mic hot after the send so a resumed thought can
    /// merge. It's asserted when the reply's first audio arrives (half-duplex)
    /// or when the grace window expires. Re-enabled on tts_end / error via
    /// releaseProcessingAfterDrain().
    private var isProcessing = false

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
    /// Fires continuationGraceWindow after a send; closes the window if no
    /// resume and no reply-audio arrived (falls back to half-duplex).
    private var graceTimerTask: Task<Void, Never>?
    /// Set once the open turn's reply audio has begun — guards the grace/expiry
    /// paths from reopening the mic after playback has started.
    private var ttsStartedThisTurn = false
    /// Mic input before this instant is ignored (earback-tone guard). Set on the
    /// main actor at send time, read on the audio thread — a monotonic Date,
    /// same off-thread-read posture as isProcessing.
    private var micHotAfter = Date.distantPast

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
        if let cont = streamFinalCont {
            streamFinalCont = nil
            cont.resume(throwing: OnDeviceSTT.STTError.recognitionFailed("session stopped"))
        }
        pendingStreamResult = nil
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

    // MARK: - Mic loop

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        if isMuted || isProcessing {
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
        do {
            let result = try await textTurnClient.postText(
                text,
                speakerHint: "sherman",
                sessionId: sessionId,
                wavBase64: wavBase64,
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
            self.onEvent?(.transcriptGemma(result.replyText))
            self.onEvent?(.ttsEnd)
            finishTurn()
        } catch is CancellationError {
            return
        } catch {
            let ns = error as NSError
            if Task.isCancelled || ns.code == NSURLErrorCancelled { return }
            // A real failure ends the turn: release the gate, surface it.
            finishTurn()
            if let kw = ns.userInfo["matchedKeyword"] as? String {
                self.onEvent?(.dropped("passphrase required for '\(kw)'"))
            } else {
                self.onEvent?(.sessionError(error))
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
        pendingStreamResult = nil
        streamFinalCont = nil
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
        let mapped: Result<String, Error> = result.mapError { $0 as Error }
        if let cont = streamFinalCont {
            streamFinalCont = nil
            cont.resume(with: mapped)
        } else {
            pendingStreamResult = mapped
        }
    }

    /// Await the drained final for the just-cut utterance. Returns immediately if
    /// the final already arrived (stashed), else suspends until deliverStreamingFinal.
    private func awaitStreamingFinal() async throws -> String {
        if let pending = pendingStreamResult {
            pendingStreamResult = nil
            return try pending.get()
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            streamFinalCont = cont
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

// MARK: - TextTurnClient stub protocol
// Real implementation lands in commit 3 (TextTurnClient.swift). Defined
// here as a protocol so this commit compiles standalone.

protocol TextTurnClientProtocol {
    /// POST text to /text_turn and stream the PCM reply via onAudioChunk
    /// as it arrives. Returns the reply text (from the X-Reply-Text header).
    /// wavBase64 (0.2.31) is the utterance audio as a base64 16kHz mono
    /// PCM16 WAV for server-side speaker verification; nil omits the field.
    func postText(
        _ text: String,
        speakerHint: String,
        sessionId: String,
        wavBase64: String?,
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
                  wavBase64: String?,
                  onAudioChunk: @escaping (Data) -> Void) async throws -> TextTurnResult {
        throw NSError(
            domain: "OnDeviceConversation",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "TextTurnClient not wired (see commit 3)"]
        )
    }
}
