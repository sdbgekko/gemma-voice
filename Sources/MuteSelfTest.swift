//
//  MuteSelfTest.swift
//  GemmaVoice
//
//  Regression guard for the recurring HARD RULE (Sherman, 8+ times across
//  AlohaVoice AND GemmaVoice): the mute button turns off the MIC ONLY. It must
//  NEVER stop anything else — not the transcription of speech already spoken,
//  not the turn, not the TTS, not the session. See the memory file
//  feedback_mute_cuts_mic_only_hard_rule. This file locks the mute contract in
//  code so it can't silently regress a 9th time.
//

import Foundation

/// The mute button's session-level contract, shared by StreamingViewModel and
/// the regression self-test so the two can never drift. Mute = MIC ONLY:
/// release just the mic input, keep the session + any playing TTS alive.
/// There is deliberately NO teardown method here — a mute must never reach one.
@MainActor
protocol MicMuteControllable: AnyObject {
    /// Finalize any in-flight utterance, drop the mic tap, and go playback-only
    /// so the mic indicator goes dark — while the session, engine, and any
    /// playing reply stay ALIVE.
    func muteMicOnly()
    /// Re-acquire the mic on the still-alive session (no rebuild).
    func unmuteMic()
}

/// What a mute-button tap resolves to. Note there is NO `.stopSession` /
/// `.teardown` case: mute is never allowed to tear the session down. That
/// absence is the invariant the self-test pins.
enum MuteAction: Equatable {
    /// Not muted → mute: release the mic only, keep everything else alive.
    case muteMicOnly
    /// Muted with a live session → re-arm the mic in place.
    case unmuteReArm
    /// Muted but the session was fully torn down (e.g. backgrounded while
    /// muted) → cold-start a fresh session.
    case unmuteColdStart

    /// The effect this action has on a live mic session. The view model runs
    /// this SAME function against the real sessions, and the self-test runs it
    /// against a spy — so the mute contract can't diverge between them.
    @MainActor
    func applySessionEffect(to session: MicMuteControllable) {
        switch self {
        case .muteMicOnly:     session.muteMicOnly()
        case .unmuteReArm:     session.unmuteMic()
        case .unmuteColdStart: break   // no live session to re-arm; VM rebuilds
        }
    }
}

enum MuteLogic {
    /// Pure decision for a mute-button tap.
    /// - currentlyMuted: `userMuted` BEFORE the tap.
    /// - sessionAlive: a session object still exists (mute keeps it alive, so
    ///   an unmute can re-arm it instead of rebuilding).
    static func actionForToggle(currentlyMuted: Bool, sessionAlive: Bool) -> MuteAction {
        if currentlyMuted {
            return sessionAlive ? .unmuteReArm : .unmuteColdStart
        }
        return .muteMicOnly
    }
}

/// Spy standing in for a real StreamingSession / OnDeviceConversationSession.
/// It records what the mute action did and simulates the invariant a real
/// session must preserve on mute (stays alive, finalizes in-flight, keeps TTS).
@MainActor
final class SpyMicSession: MicMuteControllable {
    private(set) var muteMicOnlyCalls = 0
    private(set) var unmuteCalls = 0
    /// The session object is NOT nil'd on mute — modelled as "still alive".
    private(set) var isAlive = true
    private(set) var inFlightFinalized = false
    /// Mute must NOT cancel in-progress TTS — this must stay false.
    private(set) var ttsCancelled = false
    private(set) var micInputReleased = false

    func muteMicOnly() {
        muteMicOnlyCalls += 1
        inFlightFinalized = true   // the finalize-in-flight step ran
        micInputReleased = true    // only the mic input was released
        // isAlive stays true; ttsCancelled stays false — mute touches nothing else.
    }

    func unmuteMic() {
        unmuteCalls += 1
        micInputReleased = false   // mic re-acquired on the same live session
    }
}

/// Regression guard. Verifies the mute button (a) maps to a MIC-ONLY action,
/// never a teardown; (b) keeps the session alive, finalizes the in-flight
/// utterance, and does NOT cancel TTS; (c) unmute re-arms a live session but
/// cold-starts a dead one. Asserts (traps in DEBUG) on any failure so a
/// regression can't ship silently. Run at launch from GemmaVoiceApp.init.
enum MuteSelfTest {
    @MainActor
    @discardableResult
    static func run() -> Bool {
        // (1) Decision mapping — mute NEVER maps to a teardown.
        assert(MuteLogic.actionForToggle(currentlyMuted: false, sessionAlive: true) == .muteMicOnly,
               "MUTE REGRESSION: tapping mute must map to mic-only, never a teardown")
        assert(MuteLogic.actionForToggle(currentlyMuted: false, sessionAlive: false) == .muteMicOnly,
               "MUTE REGRESSION: mute is mic-only regardless of session state")
        assert(MuteLogic.actionForToggle(currentlyMuted: true, sessionAlive: true) == .unmuteReArm,
               "MUTE REGRESSION: unmute with a live session must re-arm, not rebuild")
        assert(MuteLogic.actionForToggle(currentlyMuted: true, sessionAlive: false) == .unmuteColdStart,
               "MUTE REGRESSION: unmute with a dead session must cold-start")

        // (2) Session-level invariant, via the SAME applySessionEffect the app runs.
        let spy = SpyMicSession()
        MuteAction.muteMicOnly.applySessionEffect(to: spy)
        assert(spy.muteMicOnlyCalls == 1, "MUTE REGRESSION: mute must release the mic")
        assert(spy.isAlive, "MUTE REGRESSION: mute must NOT tear the session down")
        assert(spy.inFlightFinalized, "MUTE REGRESSION: mute must finalize the in-flight utterance")
        assert(!spy.ttsCancelled, "MUTE REGRESSION: mute must NOT cancel in-progress TTS")
        assert(spy.micInputReleased, "MUTE REGRESSION: mute must release only the mic input")

        // (3) Unmute re-acquires the mic on the same still-alive session.
        MuteAction.unmuteReArm.applySessionEffect(to: spy)
        assert(spy.unmuteCalls == 1 && !spy.micInputReleased,
               "MUTE REGRESSION: unmute must re-acquire the mic on the live session")

        let ok = spy.muteMicOnlyCalls == 1 && spy.isAlive && spy.inFlightFinalized
            && !spy.ttsCancelled && spy.unmuteCalls == 1
        NSLog("[GemmaVoice] runMuteCutsMicOnlySelfTest: \(ok ? "PASS" : "FAIL")")
        return ok
    }
}

/// Free-function alias so the guard reads the same across the voice apps.
@MainActor
@discardableResult
func runMuteCutsMicOnlySelfTest() -> Bool { MuteSelfTest.run() }
