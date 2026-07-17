import Foundation

/// A brain the voice app can route to. Data-driven so the full household roster
/// (Sophie, Ava, Daisy, Mackenzie, Iris, Merlin) can be added in Phase 2 by
/// appending to `all` — the picker UI and the server `?agent=` wiring need no
/// further changes.
///
/// `id` is the wire value sent to the voice-turn server as the `?agent=` query
/// param on the WebSocket; the server routes the turn to the matching brain.
struct VoiceAgent: Identifiable, Hashable {
    let id: String          // wire value: "gemma" | "jarvis" | "kai"
    let displayName: String
    let subtitle: String    // where it runs — shown in the picker menu

    static let gemma  = VoiceAgent(id: "gemma",  displayName: "Gemma",  subtitle: "desk")
    static let jarvis = VoiceAgent(id: "jarvis", displayName: "Jarvis", subtitle: "Excalibur")
    static let kai    = VoiceAgent(id: "kai",    displayName: "Kai",    subtitle: "KPC")

    /// Phase 1 roster. Add the Claude roster agents here for Phase 2.
    static let all: [VoiceAgent] = [.gemma, .jarvis, .kai]

    /// Resolve a stored id back to an agent, defaulting to Gemma for anything
    /// unrecognized (e.g. a removed agent or a corrupt persisted value).
    static func by(id: String) -> VoiceAgent {
        all.first { $0.id == id } ?? .gemma
    }
}
