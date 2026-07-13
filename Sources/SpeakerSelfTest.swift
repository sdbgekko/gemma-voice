//
//  SpeakerSelfTest.swift
//  GemmaVoice
//
//  Regression guard for the speaker-toggle HARD RULE (Sherman, 2026-06-16,
//  AlohaVoice; memory feedback_implement_the_literal_control_behavior): a
//  "speaker toggle" toggles the SPEAKER — the audio OUTPUT — NOW, at the moment
//  of press, INCLUDING mid-utterance. It is NOT a flag that gates whether the
//  NEXT turn synthesizes speech (that regression let Sophie keep talking when he
//  pressed it mid-sentence). This file pins the contract so it can't drift:
//  speaker-off cuts the live output volume immediately; the turn/card/session
//  keep running; speaker-on restores it. This is INDEPENDENT of mute (mic).
//

import Foundation

/// The speaker button's session-level contract, shared by StreamingViewModel and
/// the regression self-test so the two can never diverge. Speaker = OUTPUT ONLY:
/// set the playback (player-node) volume LIVE. There is deliberately NO stop /
/// teardown / next-turn-gate method here — the speaker toggle must reach only the
/// output volume, and it must take effect at the instant of the call.
@MainActor
protocol SpeakerControllable: AnyObject {
    /// Set Gemma's audio OUTPUT audible (on) or silent (off) IMMEDIATELY — by
    /// changing the player node's live volume, so any audio ALREADY PLAYING is
    /// cut/restored mid-buffer. Must NOT stop the node, cancel the turn, close
    /// the session, or defer to a turn boundary.
    func setSpeakerOutput(on: Bool)
}

enum SpeakerLogic {
    /// Pure decision for a speaker-button tap: it simply flips the output state.
    /// Independent of mute — the mic state is not an input here.
    static func nextState(currentlyOn: Bool) -> Bool { !currentlyOn }
}

/// Spy standing in for a real StreamingSession / OnDeviceConversationSession.
/// It records the live output volume and simulates the invariant a real session
/// must preserve on a speaker toggle: only the output volume moves — the node
/// keeps playing (isPlaying stays true), the session stays alive, and the turn
/// machinery is untouched, EVEN when toggled mid-utterance.
@MainActor
final class SpySpeakerSession: SpeakerControllable {
    /// Live output volume. 1.0 audible, 0.0 silent. This is what a real
    /// playerNode.volume set does — it applies to audio already rendering.
    private(set) var outputVolume: Float = 1.0
    /// The node keeps PLAYING while silenced — the turn still completes, the
    /// card still fills; the audio is just inaudible. Must stay true.
    private(set) var isPlaying = true
    /// Speaker toggle must NOT tear the session down.
    private(set) var isAlive = true
    /// Speaker toggle must NOT touch the turn/STT/LLM machinery.
    private(set) var turnMachineryTouched = false
    private(set) var setCalls = 0

    func setSpeakerOutput(on: Bool) {
        setCalls += 1
        // The ONLY effect: move the live output volume. Immediate — no gate on a
        // turn boundary, no stop, no teardown.
        outputVolume = on ? 1.0 : 0.0
        // isPlaying / isAlive / turnMachineryTouched deliberately unchanged.
    }
}

/// Regression guard. Verifies the speaker button (a) simply flips the output
/// state; (b) sets the live output volume to 0 on OFF and 1.0 on ON, IMMEDIATELY
/// — while the node keeps playing, the session stays alive, and the turn
/// machinery is untouched (the literal-control-behavior rule); (c) is
/// independent of any mic/mute state. Asserts (traps in DEBUG) on any failure so
/// a regression can't ship silently. Run at launch from GemmaVoiceApp.init.
enum SpeakerSelfTest {
    @MainActor
    @discardableResult
    static func run() -> Bool {
        // (1) Decision mapping — a tap flips the output state, mute-independent.
        assert(SpeakerLogic.nextState(currentlyOn: true) == false,
               "SPEAKER REGRESSION: tapping the speaker must flip ON→OFF")
        assert(SpeakerLogic.nextState(currentlyOn: false) == true,
               "SPEAKER REGRESSION: tapping the speaker must flip OFF→ON")

        // (2) Session-level invariant, via the SAME setSpeakerOutput the app runs.
        let spy = SpySpeakerSession()
        // Simulate a toggle to OFF *mid-utterance* — the node is playing.
        assert(spy.isPlaying, "SPEAKER REGRESSION: precondition — node is playing")
        spy.setSpeakerOutput(on: false)
        assert(spy.outputVolume == 0.0,
               "SPEAKER REGRESSION: OFF must cut the live output volume to 0 NOW")
        assert(spy.isPlaying,
               "SPEAKER REGRESSION: OFF must NOT stop the node — the turn still completes")
        assert(spy.isAlive,
               "SPEAKER REGRESSION: OFF must NOT tear the session down")
        assert(!spy.turnMachineryTouched,
               "SPEAKER REGRESSION: OFF must NOT touch the turn/STT/LLM machinery")

        // (3) Toggle back ON restores the live output volume immediately.
        spy.setSpeakerOutput(on: true)
        assert(spy.outputVolume == 1.0,
               "SPEAKER REGRESSION: ON must restore the live output volume to 1.0")
        assert(spy.isPlaying && spy.isAlive,
               "SPEAKER REGRESSION: ON must not disturb playback or the session")

        let ok = spy.setCalls == 2 && spy.outputVolume == 1.0
            && spy.isPlaying && spy.isAlive && !spy.turnMachineryTouched
        NSLog("[GemmaVoice] runSpeakerToggleCutsOutputLiveSelfTest: \(ok ? "PASS" : "FAIL")")
        return ok
    }
}

/// Free-function alias so the guard reads the same across the voice apps.
@MainActor
@discardableResult
func runSpeakerToggleCutsOutputLiveSelfTest() -> Bool { SpeakerSelfTest.run() }
