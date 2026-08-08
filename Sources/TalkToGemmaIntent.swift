import AppIntents
import Foundation
import os

/// 0.2.43: Action-Button / Siri entry point. "Talk to Gemma" opens the app
/// STRAIGHT into an active listening state — no unlock-then-hunt, no extra
/// taps beyond what iOS requires.
///
/// How activation reaches the audio path (no audio logic lives here — the
/// intent only signals; StreamingViewModel.startListeningNow() reuses the
/// exact manual session-start code):
///  - `openAppWhenRun = true` foregrounds (or launches) the app, then iOS
///    calls `perform()` in the app process.
///  - `perform()` raises TalkActivation: a pending flag + a posted
///    notification. Whichever the view model sees first wins; both are
///    idempotent. The flag covers the cold-launch race (perform() before the
///    view model's observer exists — consumed on the first scene .active);
///    the notification covers the warm case (app already frontmost, no
///    scene-phase transition guaranteed).
///  - gemmavoice://talk (widget / Live Activity fast path) raises the same
///    TalkActivation from GemmaVoiceApp.onOpenURL.
struct TalkToGemmaIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Gemma"
    static let description = IntentDescription(
        "Opens GemmaVoice and starts listening immediately."
    )
    /// The whole point: this intent is a doorway into the app, so the system
    /// foregrounds it before perform() runs.
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        TalkActivation.request(source: "app-intent")
        return .result()
    }
}

/// The "start listening on activation" handshake between the entry points
/// (App Intent, gemmavoice://talk) and StreamingViewModel. In-process only —
/// openAppWhenRun intents run inside the app process, so a static suffices
/// (no App Group needed).
enum TalkActivation {
    static let notification = Notification.Name("gemmavoice.talkActivationRequested")
    private static let log = Logger(subsystem: "com.shermanbrown.gemmavoice", category: "TalkActivation")
    @MainActor private static var pending = false

    /// Mark a talk activation requested and nudge any live listener.
    @MainActor static func request(source: String) {
        log.info("talk activation requested (source: \(source, privacy: .public))")
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// One-shot: true exactly once per request(). Both the notification
    /// observer and the scene-phase .active path call this; the first
    /// consumer wins and the other falls through to normal behavior.
    @MainActor static func consume() -> Bool {
        defer { pending = false }
        if pending { log.info("talk activation consumed") }
        return pending
    }
}

/// Publishes the intent to the Action Button picker, the Shortcuts app, and
/// Siri — automatically, no user setup beyond choosing it. Every phrase must
/// interpolate \(.applicationName); "Gemma" works as an app name via the
/// INAlternateAppNames entry in the app's Info.plist (project.yml).
struct GemmaVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToGemmaIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Hey \(.applicationName)",
                "Start listening in \(.applicationName)",
            ],
            shortTitle: "Talk to Gemma",
            systemImageName: "waveform"
        )
    }
}
