import SwiftUI
import UIKit
import WidgetKit

@main
struct GemmaVoiceApp: App {
    @StateObject private var viewModel = StreamingViewModel()
    @Environment(\.scenePhase) private var scenePhase
    // 0.2.62: token callback for Gemma-initiated conversations (OutboundPush.swift)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    init() {
        // v0.2.16: rename AppStorage("onDeviceSTTFallback") -> "useOnDeviceSTT".
        // One-time migration: if the new key has never been written AND the
        // old key exists, carry the value forward. Old key is left in place
        // so a downgrade still has its preference. Idempotent across launches.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "useOnDeviceSTT") == nil,
           let legacy = defaults.object(forKey: "onDeviceSTTFallback") as? Bool {
            defaults.set(legacy, forKey: "useOnDeviceSTT")
        }
        // P0-4: SettingsView's @AppStorage defaults useOnDeviceSTT to true, but
        // StreamingViewModel reads UserDefaults.bool(forKey:) which returns false
        // when the key was never written — so Settings lied about the active STT
        // path on a fresh install. Register the true default so the registration
        // domain backs bool(forKey:) and both agree. Runs AFTER the legacy
        // migration above so `object(forKey:) == nil` still detects unwritten keys.
        defaults.register(defaults: ["useOnDeviceSTT": true])

        // Speaker output defaults ON (Gemma is audible). Registered so
        // StreamingViewModel's `speakerOn = bool(forKey:)` reads true on a fresh
        // install; the toggle persists the user's choice thereafter.
        defaults.register(defaults: ["speakerOn": true])

        // 0.2.47 (task #16, mid-speech cutoff): barge-in defaults ON. The
        // half-duplex gate drops mic frames while Gemma's TTS plays; with
        // barge-in OFF, talking over her was silently swallowed and read as
        // "cut off mid-sentence." StreamingSession refreshes this key at
        // TTS-start via bool(forKey:), which returns false for an unwritten
        // key — register true so existing installs that never touched the
        // toggle get barge-in without losing an explicit user choice.
        defaults.register(defaults: ["bargeInEnabled": true])
        // Echo cancellation (Apple VPIO) — beta, OFF by default. When ON, the
        // engine enables voice-processing so the mic can stay open during TTS.
        // Default false so the shipped build behaves exactly as before until the
        // user opts in from Settings; a regression is a one-tap revert.
        defaults.register(defaults: ["aecEnabled": false])

        // Regression guard for the mute-cuts-mic-only hard rule. Asserts (traps
        // in DEBUG) if the mute contract regresses; a no-op in release builds
        // (assert is compiled out). See MuteSelfTest.swift.
        runMuteCutsMicOnlySelfTest()

        // Regression guard for the speaker-toggle-cuts-output-LIVE rule: a
        // speaker toggle moves the output volume NOW (even mid-utterance), never
        // gates the next turn. See SpeakerSelfTest.swift.
        runSpeakerToggleCutsOutputLiveSelfTest()

        // A2 (2026-08-07 roundtable, seat 17): lifecycle beacon — report how
        // the PRIOR run ended so jetsam kills are self-reporting instead of a
        // black box. Fire-and-forget; silent on failure.
        LifecycleBeacon.fireLaunchBeacon()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                // Lifecycle teardown. Without this a bare WindowGroup never
                // tears the mic down on background/terminate, so a force-quit
                // app that iOS resurrects in the background re-grabs a hot mic
                // and re-shows its Live Activity. handleScenePhase releases the
                // mic + audio session + Live Activity when there is NO active
                // conversation, and (on foreground) resumes listening if we're
                // idle. An active conversation (unmuted-listening / turn in
                // flight) is deliberately KEPT alive across backgrounding so
                // the hands-free / locked-screen / car use still works.
                // 0.2.62: push authorization + category registration for
                // Gemma-initiated conversations. Runs after the scene is up
                // (not in init) so registerForRemoteNotifications has a live
                // UIApplication. Mic permission stays a separate, earlier ask.
                .task {
                    OutboundPushManager.shared.setup()
                    OutboundPushManager.shared.startHeartbeats { [weak viewModel] in
                        (viewModel?.status ?? .muted) != .muted
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    LifecycleBeacon.notePhase(newPhase)
                    viewModel.handleScenePhase(newPhase)
                    // 0.2.62: scene heartbeat feeds the server's context-mute
                    // gates (no push while a live session is up, etc.).
                    let phaseName: String
                    switch newPhase {
                    case .active: phaseName = "active"
                    case .inactive: phaseName = "inactive"
                    case .background: phaseName = "background"
                    @unknown default: phaseName = "unknown"
                    }
                    OutboundPushManager.shared.heartbeat(
                        scenePhase: phaseName,
                        activeSession: viewModel.status != .muted)
                    // 0.2.44: refresh the home-screen widget's pipeline state
                    // whenever the app comes to the foreground — the 15-min
                    // timeline policy covers the rest of the day.
                    if newPhase == .active {
                        WidgetCenter.shared.reloadTimelines(ofKind: GemmaWidgetKind.home)
                    }
                }
                // A4 (2026-08-07 roundtable): the Live Activity's widgetURL
                // (gemmavoice://open, GemmaVoiceLiveActivity.swift) was dead —
                // no CFBundleURLTypes (now in project.yml) and no handler. The
                // app is single-screen, so "route to the conversation view" =
                // come to the foreground and make sure we're listening.
                // Foreground-only is fine here per
                // feedback_ios_url_scheme_foreground_only.
                .onOpenURL { url in
                    guard url.scheme == "gemmavoice" else { return }
                    // 0.2.43: gemmavoice://talk = the Action-Button fast path
                    // over the URL scheme, so the widget / Live Activity can
                    // reuse it. Raises the same TalkActivation the App Intent
                    // uses — force-unmute + start listening immediately.
                    // gemmavoice://open (and anything else) keeps the 0.2.42
                    // behavior: foreground + resume-if-idle.
                    if url.host == "talk" {
                        TalkActivation.request(source: "url-scheme")
                    }
                    viewModel.handleScenePhase(.active)
                }
        }
    }
}

/// A2 (2026-08-07 roundtable, seat 17): app-side jetsam visibility. iOS offers
/// no simple "why was I killed" API, so we keep a clean-exit breadcrumb in
/// UserDefaults: pessimistically false at launch, set true only when
/// willTerminate fires. On the next launch, false means the prior run ended
/// WITHOUT a terminate callback — jetsam, crash, or a suspended swipe-kill —
/// and we POST that to the voice-turn server so memory kills stop being
/// invisible. Fire-and-forget with silent failure. The server's /beacon
/// endpoint (stream_server.py http_beacon) logs each report and appends it
/// to beacons.jsonl; since 0.2.44 the payload also carries `environment`.
enum LifecycleBeacon {
    private static let cleanExitKey = "beacon.lastRunEndedClean"
    private static let lastPhaseKey = "beacon.lastKnownScenePhase"
    private static let hasRunKey = "beacon.hasRunBefore"
    /// Retained so the willTerminate observer lives for the process lifetime.
    private static var terminateObserver: NSObjectProtocol?

    static func fireLaunchBeacon() {
        let defaults = UserDefaults.standard
        let firstLaunch = !defaults.bool(forKey: hasRunKey)
        let endedClean = defaults.bool(forKey: cleanExitKey)
        let lastPhase = defaults.string(forKey: lastPhaseKey) ?? "unknown"
        let reason: String
        if firstLaunch {
            reason = "first_launch"
        } else if endedClean {
            reason = "clean_exit"
        } else {
            // No terminate callback last run — jetsam / crash / suspended kill.
            reason = "unclean_exit_possible_jetsam"
        }
        defaults.set(true, forKey: hasRunKey)
        defaults.set(false, forKey: cleanExitKey)   // pessimistic until willTerminate

        // willTerminate fires on foreground quits; a jetsam or suspended
        // swipe-kill never reaches it — which is exactly the signal we want.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            UserDefaults.standard.set(true, forKey: cleanExitKey)
        }

        var req = URLRequest(url: TextTurnClient.defaultBase.appendingPathComponent("beacon"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        let payload: [String: String] = [
            "prior_termination_reason": reason,
            "last_known_phase": lastPhase,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            // 0.2.44: "simulator"/"device" — server-side handling landed with
            // tonight's stream_server.py beacon work; keeps sim smoke-test
            // launches out of the device jetsam rollups.
            "environment": GemmaVoiceServer.environment,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()   // silent
    }

    /// Breadcrumb: the phase the app was last seen in, giving the beacon's
    /// unclean-exit reports context (jetsam almost always hits in background).
    static func notePhase(_ phase: ScenePhase) {
        let name: String
        switch phase {
        case .active: name = "active"
        case .inactive: name = "inactive"
        case .background: name = "background"
        @unknown default: name = "unknown"
        }
        UserDefaults.standard.set(name, forKey: lastPhaseKey)
    }
}
