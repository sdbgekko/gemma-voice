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
            version: "0.2.32",
            date: "Jul 12",
            hints: [
                "Gemma starts talking sooner. She now begins speaking her reply as soon as the first sentence is ready instead of waiting for the whole thing — so there's much less silence after you finish. Her written reply fills in on the card a moment after her voice, which is normal.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.31",
            date: "Jul 11",
            hints: [
                "GemmaVoice now sends a short clip of your voice with each turn so Gemma can check who's actually talking. Nothing is blocked yet — she's in watch mode, learning to recognize you reliably before the your-voice-only lock turns on.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.30",
            date: "Jul 10",
            hints: [
                "Teach Gemma your voice. Settings → Voice Enrollment walks anyone in the house through 8 short clips (about 3 minutes) so Gemma can learn who's talking — the first step toward her ignoring the TV and answering only to voices she knows.",
                "Hand the phone around: Sherman, Andrea, and Kavika each have a one-tap button; anyone else can type their name.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.29",
            date: "Jul 10",
            hints: [
                "Pause and keep going. If you stop mid-sentence to think and then keep talking, GemmaVoice now adds your continued words onto the same thought instead of starting a whole new turn. You're conveying one idea, so it's one turn.",
                "A little more room to pause before it sends — so a short breath mid-sentence won't cut you off.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.28",
            date: "Jul 10",
            hints: [
                "She answers quicker. GemmaVoice now starts understanding you *while* you're still talking instead of waiting until you finish — so there's less of a pause before she replies.",
                "It no longer clips the start of longer things you say. If you speak a few sentences with a pause in the middle, your whole thought comes through now, not just the tail end.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.27",
            date: "Jul 10",
            hints: [
                "Closing the app now actually closes it. If you swipe GemmaVoice away, it fully stops and lets go of the microphone — no more coming back to life in the background with the mic light stuck on. That orange dot means the mic is truly in use, and now it goes dark when it should.",
                "Muting fully releases the microphone now, not just silences it — so the mic indicator turns off when you mute.",
                "On purpose: if you're mid-conversation and lock the screen or switch apps, she keeps listening — that hands-free/in-the-car behavior is intentional and unchanged.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.26",
            date: "Jul 9",
            hints: [
                "New main screen: a turn ledger. Instead of one guessing status pill, every exchange is now its own card that shows exactly where it is — heard you, thinking, speaking back, done. When there's a wait, you can see it's a real wait and not a frozen app.",
                "The connection bar is honest. It tells you the true state of the link to Gemma at a glance, and doesn't pretend to be listening when it isn't.",
                "The mute button is a real labeled button now, not a color you have to decode.",
                "Cleaner in dark mode, and two spots that were hard to read got fixed for contrast.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.25",
            date: "Jul 8",
            hints: [
                "The app stops lying about its connection. If the link to Gemma drops, you now see 'disconnected — tap to reconnect' instead of a fake 'listening.' It reconnects on its own with backoff and pings to catch silent drops — no more force-quit to wake it up.",
                "Gemma's mic goes deaf while she's talking. True half-duplex: the mic stays closed until her voice actually finishes playing (not just finishes sending), so she never hears — or echoes — herself. This is the real fix for the echo you saw.",
                "No more ghost bubbles. Gemma's own words picked up by the mic are dropped before they ever reach your screen or her brain — handled on both the server and the app now.",
                "Settings finally tells the truth about speech recognition. The on-device vs server toggle and what's actually running now agree (they didn't before on a fresh install).",
            ]
        ),
        ChangelogEntry(
            version: "0.2.24",
            date: "May 19",
            hints: [
                "Live Activity now shows the active agent name (Gemma / Daisy / Mackenzie / Malia / Bobbi) instead of always 'Gemma'. The voice-turn server announces which household agent the channel is bound to on every connect; the lock-screen label updates immediately.",
                "Agent name lives in the activity's content state (not attributes), so a future mid-session agent swap will be a smooth update rather than a re-launch.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.23",
            date: "May 19",
            hints: [
                "Live Activity + Dynamic Island — GemmaVoice now publishes its current state to the lock screen and the Dynamic Island. Glance at your phone in your pocket and see whether Gemma is listening, got-it, thinking, or speaking back, without unlocking. Direct fix for the 'can you hear me?' loop.",
                "Status icons + tints match the in-app pill: blue ear for listening, green check for got-it, amber dots for thinking, purple speaker for speaking, gray slash for muted.",
                "If you don't see the Live Activity on lock screen: Settings → GemmaVoice → toggle Allow Live Activities ON. iOS asks once on first launch after this update.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.22",
            date: "May 18",
            hints: [
                "New 'got it' state in the status pill: between you finishing speaking and Gemma's reply starting, the indicator turns bright green with a 'got it — processing' label and a success haptic. Kill-shot for the 'can you hear me?' loop — you'll know Gemma heard you within ~200ms of stopping, before STT and the LLM finish.",
                "Status pipeline expanded: muted → listening → speaking → got-it → thinking → speaking-back. Each state now has a distinct color and label so the app's behavior is legible even when audio playback is delayed.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.21",
            date: "May 6",
            hints: [
                "Cold-launch crash fix: AVAudioEngine connect was reading mainMixerNode.outputFormat before the output graph materialized, getting a 0-channel format, throwing an uncatchable NSInvalidArgumentException. Now uses outputNode.inputFormat with a channelCount guard and 48kHz fallback.",
                "Resume-from-background: re-asserts the audio session and restarts the engine on UIApplication.didBecomeActiveNotification. Prior versions silently broke after a phone call or home-button trip — required relaunch.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.20",
            date: "May 5",
            hints: [
                "Fix: v0.2.19's flat 1.5s mic-suspend tail was eating Sherman's first words after a turn. Now polls playerNode.isPlaying every 100ms and releases the gate the moment playback drains. Hard cap at 2s so a stuck node can't latch the mic shut.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.19",
            date: "May 5",
            hints: [
                "Echo loop fix without re-introducing voiceChat — gates mic-frame upload while Gemma's TTS is playing on both the WebSocket path (StreamingSession) and the on-device path (OnDeviceConversationSession).",
                "On-device path was the worse offender: the defer that flipped isProcessing back to false fired the instant /text_turn finished streaming, but Kokoro audio queued in playerNode was still playing for another 1-3s. Mic re-opened mid-playback and self-transcribed. Now isProcessing holds for an extra 1.5s after stream completion.",
                "Barge-in still works — RMS detection runs before the gating check.",
                "Until iOS hardware AEC can be re-enabled cleanly, headphones still kill the echo cleanest.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.18",
            date: "May 5",
            hints: [
                "Rolled back voiceChat audio mode after v0.2.17 silent-playback regression in the field — same failure shape as the v0.2.8 rollback, the resampler change wasn't enough on its own.",
                "Audio session is back on .spokenAudio. Echo loop returns; mute when you're done speaking remains the workaround.",
                "Echo cancellation will return once the voiceChat path can be tested on-device with the resampler chain (still in the codebase, just inert).",
            ]
        ),
        ChangelogEntry(
            version: "0.2.17",
            date: "May 5",
            hints: [
                "Echo cancellation is back — switched the audio session to .voiceChat mode, which enables iOS hardware AEC + AGC + noise suppression. The mic no longer re-captures Gemma's own TTS as if you said it.",
                "Playback graph rebuilt to match voiceChat's preferred sample rate — the v0.2.8 silent-TTS regression is fixed. PlayerNode now connects at the engine's actual output rate; Kokoro 24kHz chunks are resampled per-chunk before scheduling.",
                "If TTS sounds muffled or off-pitch on your phone after this update, that's the resampler — let Sherman know and he'll tune it.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.16",
            date: "May 2",
            hints: [
                "On-device transcription is now the default conversation path — your phone transcribes locally and only sends the text to the server. Toggle in Settings → Transcription → Use on-device transcription (defaults ON).",
                "Beats server STT on proper nouns Sherman tested today: Gemma, Excalibur, KPC all correct (server had transcribed Gemma as John).",
                "New voice-turn endpoint POST /text_turn skips Whisper entirely; Kokoro reply streams back over chunked HTTP for the same TTS feel as the WebSocket path.",
                "Light local polish on transcripts (capitalize, terminal . or ?) — no LLM call, latency stays tight.",
                "Existing WebSocket audio path is untouched — flip the toggle OFF to fall back to it.",
                "Security hardening: /text_turn now requires an HMAC-SHA256 header signed with a shared secret (Settings → Security → Voice-turn shared secret). Closes a smoke-test spoof vector where unauthenticated POSTs could relay arbitrary text into Gemma's CLI as if Sherman had voiced it.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.15",
            date: "May 2",
            hints: [
                "Fix: using Settings → Test on-device transcription no longer strands the conversation — the audio session category is restored to .playAndRecord/.spokenAudio on cleanup so you can resume talking without force-quitting",
                "First confirmed B1 win: on-device model correctly transcribed 'Gemma' where the server STT heard 'John'",
            ]
        ),
        ChangelogEntry(
            version: "0.2.14",
            date: "May 2",
            hints: [
                "Settings → Test on-device transcription — record a short utterance and see what Apple's on-device speech model gives back, no audio leaves the phone",
                "Verification only — the conversation flow still uses server transcription. The 'On-device fallback' toggle persists for the future fallback wire-up but doesn't change behavior yet",
                "Use this to compare on-device accuracy against the server (Parakeet/Whisper) before committing to a fallback path",
            ]
        ),
        ChangelogEntry(
            version: "0.2.13",
            date: "Apr 30",
            hints: [
                "Barge-in is now OFF by default — cuts the self-interrupt loop where Gemma's own TTS bleeding through the mic was triggering false interrupts",
                "Settings → Allow interrupting Gemma — toggle ON if you want to be able to cut Gemma off mid-sentence (experimental)",
            ]
        ),
        ChangelogEntry(
            version: "0.2.12",
            date: "Apr 30",
            hints: [
                "Barge-in tuning v3 — RMS threshold raised back to 0.04 and trigger window to 4 frames (~128ms)",
                "Added 600ms grace period at the start of each TTS turn — prevents the player-warmup tail and TTS-bleed-through-mic from self-triggering an interrupt",
                "Fixes the bug where Gemma's reply cut off after the first word",
            ]
        ),
        ChangelogEntry(
            version: "0.2.11",
            date: "Apr 30",
            hints: [
                "Mute UI v3 — Sherman provided a hand-edited GoldGemmaRed asset (gold logo with red CPU chip)",
                "Tapping the logo to mute now crossfades the red-CPU variant in over the gold base — visually reads as the CPU turning red",
                "Pixel-perfect alignment, 350ms ease-in-out fade",
            ]
        ),
        ChangelogEntry(
            version: "0.2.10",
            date: "Apr 30",
            hints: [
                "Barge-in tuning — lowered RMS threshold from 0.05 to 0.02 and reduced trigger window from 3 frames (~96ms) to 2 (~64ms)",
                "Catches normal speaking volume in cars and quiet rooms; previously you had to almost shout to interrupt",
            ]
        ),
        ChangelogEntry(
            version: "0.2.9",
            date: "Apr 30",
            hints: [
                "Crash fix — barge-in was calling playerNode methods from the audio thread, which AVAudioEngine doesn't allow. Moved playerNode.stop / reset to the main thread.",
                "Should resolve the intermittent crashes seen on v0.2.5 through v0.2.8.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.8",
            date: "Apr 30",
            hints: [
                "TTS audio fix — rolled back voiceChat audio mode (broke playback), back to spokenAudio with defaultToSpeaker",
                "Echo cancellation will return in a future build once the playback graph is rebuilt to match voiceChat's preferred sample rate",
            ]
        ),
        ChangelogEntry(
            version: "0.2.7",
            date: "Apr 30",
            hints: [
                "Mute indicator redesigned — instead of a soft-red wash behind the entire logo, a rose-gold square now lights up over the CPU chip in the logo when the mic is muted",
                "Cleaner, on-brand, lighter visual weight",
            ]
        ),
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
