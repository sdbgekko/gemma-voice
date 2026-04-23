import Foundation

/// One release's worth of user-facing hints. Add a new entry at the TOP
/// of `entries` on every commit that will produce a new TestFlight build.
struct ChangelogEntry: Identifiable {
    let id = UUID()
    let version: String    // e.g. "0.2 (build 37)"
    let date: String       // "Apr 20"
    let hints: [String]
}

enum Changelog {
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "0.2.2",
            date: "Apr 23",
            hints: [
                "Speaker name + timestamp caption under each turn bubble",
                "User turns show the recognized speaker (or \"You\" if unidentified)",
                "Gemma turns show \"Gemma\" — timestamp in local h:mm a format",
            ]
        ),
        ChangelogEntry(
            version: "0.2.1",
            date: "Apr 20",
            hints: [
                "Mic tap rebuilds on Bluetooth or headphone route change",
                "What's new section polished — headline version, accent bullets",
            ]
        ),
        ChangelogEntry(
            version: "0.2",
            date: "Apr 20",
            hints: [
                "Settings gear top-right with appearance and earback volume",
                "WebSocket streaming + server-side Silero VAD",
                "WavLM speaker filter",
                "Parakeet STT replacing Whisper",
                "Earback tone + haptic on speech end",
                "Adaptive silence cutoff so you're not cut off mid-thought",
                "Adaptive ambient floor on the waveform for noisy cars",
                "Background audio mode — keeps listening when switched apps",
                "Bluetooth output routing for car audio",
                "Heartbeat pulse on the logo",
            ]
        ),
    ]
}
