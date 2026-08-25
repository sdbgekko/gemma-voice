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
            version: "0.2.57",
            date: "Aug 25",
            hints: [
                "The status orb is now alive: it gently breathes while she's listening or thinking, and the icon smoothly morphs between states (ear → dots → speaker). The point is the ~2-second wait after you speak no longer looks like a frozen app — you can see at a glance she's awake and working, even from a cupholder.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.56",
            date: "Aug 25",
            hints: [
                "New at-a-glance status: the little colored dot is now a big glanceable orb with an icon for each state — an ear when she's listening, a check when she's got your words, dots while she's thinking, a speaker when she's talking back. Made to read from a cupholder without focusing, so a short wait doesn't feel like a dead app. The color and the 'got it' haptic are unchanged — this just makes the current state impossible to miss.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.55",
            date: "Aug 20",
            hints: [
                "Talking over Gemma now only cuts her voice when you say actual words — Sherman's design, after a throat-clear false-triggered the cut. A loud sound wakes the speech recognizer for about a second and a half; only a transcribed word fires the cut, so coughs, throat-clears, and bumps stand down silently and she keeps talking. Real interruptions feel about a quarter-second slower — that's the recognizer confirming you actually spoke.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.54",
            date: "Aug 20",
            hints: [
                "Talk over Gemma to cut her voice — the feature the last three builds were building toward. With Echo cancellation ON, just start talking while she's speaking: her voice stops almost instantly, the reply text stays on screen so you can finish reading what she was saying (it runs a beat ahead of her voice), and your words become your next turn. It takes about a sixth of a second of sustained speech to trigger, so a cough or a bump shouldn't cut her off, and there's a short guard at the start of each reply so her own voice can't trigger it. With Echo cancellation OFF, nothing changes.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.53",
            date: "Aug 20",
            hints: [
                "The reply text now keeps pace with Gemma's voice. Before, on the streaming path the text card only filled in after the entire reply finished playing — on a long answer that meant hearing her for 30+ seconds while the bubble stayed empty. Now the server publishes each sentence's text the moment it's spoken and the app polls for it while the audio plays, so the words stream into the card roughly in step with her voice. This also lays the groundwork for the next feature: talking over her to stop her voice while keeping the text to read.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.52",
            date: "Aug 20",
            hints: [
                "Echo cancellation — new, in beta, and OFF by default. There's a new switch in Settings called \"Echo cancellation.\" Today, while Gemma is speaking, the app has to mute your mic so it doesn't hear its own voice come back — which is why the mic shuts off once she starts replying. With this turned on, it uses Apple's built-in echo canceller to subtract Gemma's voice out of the mic, so the mic can stay open the whole time and you can talk over her or keep adding to your thought without waiting. It's off by default and completely safe to leave off; if you turn it on and anything sounds wrong (silent, tinny, or garbled — especially on AirPods), just flip it back off and it reverts instantly.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.51",
            date: "Aug 20",
            hints: [
                "Fixed a case where speech-to-text could silently hang a turn. If the on-device recognizer ended without a final result — a clean cancel, or you went quiet without saying anything — the app was left waiting on a callback that never arrived, so the turn just sat there unfinished. All three recognition paths now always resolve, so a turn can't get stuck that way. (Caught on night one of the automated Jarvis + Kai code reviews.)",
            ]
        ),
        ChangelogEntry(
            version: "0.2.50",
            date: "Aug 19",
            hints: [
                "Fixed the mic occasionally going deaf. If a phone call, Siri, or switching away from the app landed in the middle of Gemma's reply, the audio could get stuck in a state where she stopped hearing you until you force-quit and reopened — because the app was waiting on a playback signal that never arrived. There's now a watchdog that always reopens the mic once she's done speaking, no matter what, so it can't get wedged shut anymore.",
                "Fixed a rare crash when connecting or disconnecting AirPods/headphones mid-conversation. The audio converter could be swapped out from under the microphone while it was mid-use; each mic tap now owns its own converter so that can't happen.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.49",
            date: "Aug 19",
            hints: [
                "Closed one more gap that could freeze a reply on \"Working\". There's a brief moment right after Gemma's words arrive but before her voice starts playing — if you switched back to the app in exactly that instant, it could still rebuild the connection and strand the turn. The app now treats that in-between moment as \"still replying\" and leaves the connection alone until she's actually done, so switching apps mid-answer is safe throughout the whole reply.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.48",
            date: "Aug 18",
            hints: [
                "Fixed replies getting stuck on \"Working\" with no text. When you switched away from the app, or it briefly reconnected while Gemma was still answering, the app was tearing down its own connection in the middle of her reply — so her words never landed and the turn froze on \"Working\" forever, even though you could still hear her voice. Now the app keeps a healthy connection instead of rebuilding it on every foreground, and never drops it while she's still speaking. If a turn does get cut off by a real disconnect, it clears itself and asks you to tap the mic and try again, instead of hanging.",
                "Reconnects are gentler and safer. Each turn now carries its own ID, so a reconnect can no longer cause the same turn to be processed twice, and the app stops reconnecting in a lockstep rush that used to pile up right after the server restarted.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.47",
            date: "Aug 8",
            hints: [
                "Talking over Gemma no longer drops your words. The mic stays closed while she speaks (so she can't hear herself), but until now anything you said over her reply was silently thrown away — the server heard nothing and cut your turn, which felt like being cut off mid-sentence. Interrupting is now ON by default: speak over her for a beat and she stops talking, the mic opens, and your words go through as a normal turn. The mic also reopens faster after her last word (0.3s instead of 0.8s). You can turn interrupting off in Settings if it misfires in a noisy room.",
                "Fixed the repeated-message loop after reconnect. If a reply never arrived (like when her voice pipeline was down), the recovery logic could redeliver the same turn over and over on every reconnect — one message repeated 15+ times. Recovery now runs at most twice per turn, remembers which turns were already answered so they can never replay, and still gives up entirely after 10 minutes.",
                "You can now paste a copied photo. The photo button is a menu: Photo Library as before, plus Paste Image whenever there's a picture on your clipboard — copied from Safari, Messages, a screenshot, anywhere. It sends exactly like a picked photo, caption and all.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.46",
            date: "Aug 7",
            hints: [
                "No more two voices at once. A picture or typed reply and a spoken reply could both start playing at the same moment — you'd hear Gemma talking over herself. Now there's a single audio owner: whichever reply starts speaking, the other one stops, so you only ever hear one voice.",
                "Gemma stops mishearing her own voice. While any reply is playing — including a picture or typed reply — the microphone stays closed, so her words can't be picked up and answered as if you'd said them. Muting still only affects the mic; the speaker button still only affects her voice.",
                "A reply keeps talking when you leave the app. Switching apps, locking the screen, or pulling down Control Center mid-answer no longer cuts her off — the audio stays alive while a turn is in flight or a reply is playing, and only lets go once the mic is off and nothing's speaking. A dropped connection now also reconnects while you're away instead of waiting for you to come back.",
                "Note: two small server-side hardening fixes (Gemma not double-speaking an announcement, and better filtering of her own echoed voice) need tonight's server update on her side to take effect — the app changes above work on their own.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.45",
            date: "Aug 7",
            hints: [
                "Send Gemma a picture. There's a photo button next to the message box — pick something from your library, add a caption if you like (or don't — she'll be asked what she thinks of it), and it lands in the conversation like any other turn. She can actually look at the picture on her side and talk about it with you.",
                "The photo shows up in the conversation card along with your caption and her reply, and if the connection drops while she's looking, the reply is recovered the same way dropped voice replies are.",
                "Note: talking about pictures needs tonight's server update on Gemma's side — until that restart lands, a photo turn gets a normal reply that can't see the image yet.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.44",
            date: "Aug 7",
            hints: [
                "GemmaVoice now has a home-screen widget (small and medium). One tap anywhere on it and you're straight into listening — the same fast path as the Action Button. The medium size also shows whether the voice pipeline is up: a state dot plus Brain / Voice / Ears, refreshed about every 15 minutes and whenever you open the app. If the server can't be reached it just says Offline.",
                "Dropped replies come back. Twice tonight a reply was lost because the connection died while Gemma was still thinking — now the app remembers the turn it was waiting on, and when you come back (reopen the app, or the connection returns) it fetches the answer from the server and shows it in the conversation. Recovered replies appear as text; the spoken audio for that turn is gone with the old connection.",
                "Leaving the app mid-turn no longer kills the turn. With a question in flight, the app now asks iOS for extra background time to finish the wait, and the lock screen shows Thinking so you can see it's still working. If iOS suspends it anyway, the recovered-reply fix above catches the answer on your return.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.43",
            date: "Aug 7",
            hints: [
                "GemmaVoice can live on your iPhone's Action Button. Set it once (Settings → Action Button → Shortcuts → Talk to Gemma) and a single press opens the app straight into listening — mic hot, no hunting for the app, no extra taps. Unmutes automatically if you'd left it muted.",
                "Siri knows the way in too: say \"Talk to GemmaVoice\" — or just \"Talk to Gemma\" / \"Hey Gemma\" — and you land in the same ready-to-listen state. It also shows up in the Shortcuts app for automations.",
                "Under the hood the same fast path answers gemmavoice://talk, so the widget and Live Activity can jump straight into listening in a future build.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.42",
            date: "Aug 7",
            hints: [
                "Fixed the invisible memory leak that was getting the app killed by iOS during long sessions. The mic buffer used to quietly grow forever between your sentences — hours of listening could end in a silent shutdown. It's bounded now, so an all-day session stays up.",
                "Names come through right in on-device transcription. Sekushi, Kokoro, Merlin, Kai, Jarvis, Malia, Kavika, and the rest of the household vocabulary are now taught to the on-device recognizer and auto-corrected when it still mishears — same fixes the server path has had all along.",
                "The reply card now names who actually answered. If Gemma was busy and Jarvis stepped in, the card says Jarvis — no one wears Gemma's label anymore.",
                "Tapping the Live Activity on the lock screen or Dynamic Island now opens the app. That tap was dead before.",
                "Turns get the time they need. The app used to give up at 90 seconds while the brain was still working; it now waits out the server's full window, so slow turns finish instead of erroring.",
                "Phone calls, Siri, and Bluetooth switches no longer silently kill the mic on the default path — the session now rebuilds itself the way the streaming path always did.",
                "If unmuting fails, the app says so instead of showing \"listening\" over a dead mic.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.41",
            date: "Jul 31",
            hints: [
                "When Gemma speaks up on her own — a follow-up or an update you didn't just ask for — you now see her words on screen too, not only hear them. Before, those came through as voice only with nothing in the list; now they show up as a card like every other reply.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.40",
            date: "Jul 30",
            hints: [
                "The waveform settles when you mute. It used to freeze mid-wave like a stopped clock — now the bars drop to the quiet baseline the moment you tap mute.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.39",
            date: "Jul 18",
            hints: [
                "Type a message. There's a new message box at the bottom — tap it, type, and send, and you get an answer without saying a word. It goes to whoever's picked in the top-left, shows up in the same list as your spoken turns, and she reads it back out loud if the speaker's on. Talking still works exactly the same; this is just another way in.",
                "Each agent has its own voice now. Gemma sounds like Gemma, Jarvis answers in his own voice, and Kai in his — so you can tell by ear who you're talking to.",
                "If a brain is offline, it says so. Ask Jarvis or Kai when they're down and instead of hanging on \"working\" forever, it tells you they're offline so you can pick someone else.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.38",
            date: "Jul 17",
            hints: [
                "New agent picker in the top-left corner — tap it to choose who answers you: Gemma, Jarvis, or Kai.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.37",
            date: "Jul 13",
            hints: [
                "The speaker button is a bigger, cleaner speaker icon now — the word is gone since the icon says it all. Tap to silence Gemma's voice, tap again to hear her.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.36",
            date: "Jul 13",
            hints: [
                "The speaker button is now a plain, simple speaker icon instead of gold — cleaner and quieter next to the Mute button. Same behavior: tap it to silence Gemma's voice, tap again to hear her.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.35",
            date: "Jul 13",
            hints: [
                "New speaker button, next to Mute. There are now two separate controls: Mute turns off your microphone, and the new speaker button turns Gemma's voice on or off. Tap the speaker to silence her — it cuts her voice right away, even in the middle of a sentence — and tap it again to hear her. Silencing her voice doesn't stop the mic, and muting the mic doesn't stop her voice; the two work independently, and the speaker setting is remembered.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.34",
            date: "Jul 12",
            hints: [
                "Mute now turns off the microphone only — nothing else. If you speak and then tap Mute mid-sentence, Gemma still hears what you already said and answers it, and if she's already talking she keeps talking. Only the mic goes quiet (the orange dot goes dark); tap again to talk. Muting no longer freezes a card on \"Heard\" or cuts Gemma off.",
            ]
        ),
        ChangelogEntry(
            version: "0.2.33",
            date: "Jul 12",
            hints: [
                "Swipe a card away to delete it. If GemmaVoice picked up the wrong thing — a cough, the TV, half a word — swipe that card to the left and it's gone. If Gemma was still working on it, swiping it away also stops her working on it. Your other cards and the conversation keep going.",
            ]
        ),
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
