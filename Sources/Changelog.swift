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
            version: "0.2.6",
            date: "Apr 30",
            hints: [
                "Echo cancellation — switched audio session mode from spokenAudio to voiceChat, which enables iOS's built-in AEC, automatic gain control, and noise suppression",
                "Fixes the feedback loop where Gemma's TTS was being picked back up by the mic and re-transcribed as if you said it",
                "Speaker output now defaults to the loudspeaker (not earpiece) when no headset is connected — matches how you actually use the app",
            ]
        ),
        ChangelogEntry(
            version: "0.2.5",
            date: "Apr 30",
            hints: [
                "Barge-in! You can now talk over Gemma mid-sentence — she stops mid-word and listens.",
                "Detection: ~96ms of speech-over-TTS triggers an interrupt. RMS threshold 0.05.",
                "On interrupt: local audio buffer is flushed instantly + server stops streaming the rest of the reply.",
                "Server adds tts_interrupted message so client knows the turn was cut short.",
                "Smaller TTS chunks (32ms) for noticeably faster perceived latency.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.4",
            date: "Apr 30",
            hints: [
                "Background audio fix — mic indicator now stays lit when the app is backgrounded so you can keep talking while in other apps",
                "Audio session is re-primed on background entry, foreground return, and after audio interruptions (phone calls, Siri, other apps)",
                "AVAudioEngine restarts automatically if iOS suspends it during a transition",
                "Server-side: Kokoro TTS now streams chunks as they're generated — first audio arrives ~100ms instead of waiting for the full render",
            ]
        ),
        ChangelogEntry(
            version: "0.2.3",
            date: "Apr 24",
            hints: [
                "On-device speech recognition scaffolding (SFSpeechRecognizer, on-device forced)",
                "Settings → Transcription: toggle + permission check",
                "Conversation-flow wiring coming in 0.2.4 — this build only ships the capability",
            ]
        ),
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
