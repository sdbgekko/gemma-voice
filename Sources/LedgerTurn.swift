import Foundation

/// Lifecycle of one conversational turn as the client observes it. The card UI
/// derives its checkpoint track from the *ordering* of these phases, so the
/// enum order matters (see `TurnCardView.rank`).
///
/// v1 is strictly serial: late events attach to the newest still-open card
/// (`StreamingViewModel.latestPendingIndex`). We do NOT yet correlate on a
/// server-echoed request id — `rid` is carried on the model for when the
/// server starts echoing it, but nothing reads it today. Flagged as a future
/// server ask.
enum TurnPhase: Equatable {
    case heard              // VAD closed the utterance; STT/brain not back yet
    case sent               // audio dispatched to the brain (track checkpoint)
    case working            // waiting on the reply; elapsed timer runs here
    case speaking           // reply arrived, TTS playing back
    case answered           // TTS finished
    case dropped(String)    // turn abandoned (self-echo, error, too short…)
}

/// One turn in the ledger. Fields fill in as events arrive; the struct lives in
/// a `@Published [LedgerTurn]` and is mutated in place by index.
struct LedgerTurn: Identifiable {
    let id = UUID()
    var youText: String       // what the user said (empty until transcriptYou)
    var speaker: String?      // recognized speaker name, if any
    var reply: String?        // Gemma's reply text (nil until transcriptGemma)
    var source: String?       // "gemma" | "claude" | "jarvis" | "on-device"
    var rid: String?          // future: server-echoed request id for correlation
    var phase: TurnPhase
    var startedAt: Date?      // when phase entered .working — anchors the timer
    var answeredAt: Date?     // when phase entered .answered — freezes the timer
}
