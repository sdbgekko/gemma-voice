//  OutboundPush.swift
//  GemmaVoice 0.2.62 — Gemma-initiated conversations, Phase 1 (client half).
//
//  The server (stream_server.py + outbound_push.py) enqueues gated outbound
//  intents and rings an APNs doorbell. This file is everything the app does
//  with that doorbell:
//    - push authorization + GEMMA_OUTBOUND category (Listen / Not now / Mute)
//    - device-token registration and scene heartbeats (HMAC'd like /text_turn)
//    - the LISTEN flow: fetch pending → let the normal session connect →
//      ask the server to /say the frozen line → ack spoken
//
//  SPEAK GATE (non-negotiable, Chief design §5.3): the ONLY code path that
//  leads to Gemma's voice from an outbound intent is handleListen(), and
//  handleListen() runs ONLY from a user notification response (tap / Listen).
//  Nothing here activates audio from background delivery, silent push, or
//  scene changes. If you are adding a call site to handleListen(), stop.

import Foundation
import SwiftUI
import UIKit
import UserNotifications
import CryptoKit

// MARK: - App delegate adaptor (token callback lives here)

final class PushAppDelegate: NSObject, UIApplicationDelegate {
    // 0.2.63 cold-start fix: when the app is LAUNCHED by a notification tap,
    // iOS delivers the response to the center delegate during launch. Our
    // delegate used to be set in SwiftUI .task — after launch — so the tap
    // event was silently dropped and the app "just sat there listening"
    // (Sherman's 2026-08-28 killed-app test). Registering here, before the
    // launch response is delivered, is the documented fix.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = OutboundPushManager.shared
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        OutboundPushManager.shared.registerToken(hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Fire-and-forget feature: log locally, never block the voice app.
        print("[outbound] APNs registration failed: \(error.localizedDescription)")
    }
}

// MARK: - Manager

final class OutboundPushManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OutboundPushManager()

    static let categoryId = "GEMMA_OUTBOUND"
    private static let masterKey = "gemmaCanInitiate"       // Settings master switch
    private static let deviceIdKey = "outbound.deviceId"

    private var heartbeatTimer: Timer?

    /// Master switch (default ON — Sherman approved the feature). Off = we
    /// stop fetching/speaking; the server also holds its own master gate.
    static var masterOn: Bool {
        UserDefaults.standard.register(defaults: [masterKey: true])
        return UserDefaults.standard.bool(forKey: masterKey)
    }

    private var deviceId: String {
        let d = UserDefaults.standard
        if let existing = d.string(forKey: Self.deviceIdKey) { return existing }
        let fresh = UUID().uuidString
        d.set(fresh, forKey: Self.deviceIdKey)
        return fresh
    }

    // Called once from GemmaVoiceApp init. Safe to call repeatedly.
    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let listen = UNNotificationAction(
            identifier: "LISTEN", title: "Listen",
            options: [.foreground])
        let notNow = UNNotificationAction(
            identifier: "NOT_NOW", title: "Not now", options: [])
        let muteSource = UNNotificationAction(
            identifier: "MUTE_SOURCE", title: "Mute this source",
            options: [.destructive])
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [listen, notNow, muteSource],
            intentIdentifiers: [],
            options: [.customDismissAction])   // swipe-away counts as an ignore
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound, .badge,
                                              .providesAppNotificationSettings]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    // MARK: server calls (HMAC'd with the same shared secret as /text_turn)

    private func post(_ path: String, _ payload: [String: Any],
                      completion: ((Bool) -> Void)? = nil) {
        guard let secret = VoiceAuthSecret.read(),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion?(false); return
        }
        var req = URLRequest(url: TextTurnClient.defaultBase.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(TextTurnClient.hmacSHA256Hex(secret: secret, bodyBytes: body),
                     forHTTPHeaderField: "X-Voice-Auth")
        req.httpBody = body
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            completion?((resp as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    func registerToken(_ hexToken: String) {
        guard Self.masterOn else { return }
        // TestFlight and App Store builds use the production APNs environment;
        // only a direct Xcode-to-device debug run is sandbox. Debug builds are
        // the only ones compiled with DEBUG, so this maps exactly.
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        post("push/register", [
            "device_id": deviceId,
            "apns_token": hexToken,
            "environment": env,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.shermanbrown.gemmavoice",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "capabilities": ["time_sensitive": true, "communication": false,
                             "live_activity": true],
        ])
    }

    /// Scene heartbeat — the server's context-mute gates (sleep / driving /
    /// in-session) read these. Called on scenePhase changes and every 5 min
    /// while foreground.
    func heartbeat(scenePhase: String, activeSession: Bool) {
        post("push/heartbeat", [
            "device_id": deviceId,
            "scene_phase": scenePhase,
            "active_session": activeSession,
            "focus_hint": "unknown",   // iOS does not expose Focus to apps; server treats unknown leniently
            "in_call": false,
            "last_user_turn_end_ts": 0,
        ])
    }

    func startHeartbeats(activeSession: @escaping () -> Bool) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard UIApplication.shared.applicationState == .active else { return }
            self?.heartbeat(scenePhase: "active", activeSession: activeSession())
        }
    }

    private func ack(intentId: String, status: String, source: String? = nil) {
        var p: [String: Any] = ["device_id": deviceId,
                                "intent_id": intentId, "status": status]
        if let source { p["source"] = source }
        post("outbound/ack", p)
    }

    // MARK: the Listen flow — the one and only outbound speak path

    /// Runs ONLY from didReceive (user tapped the notification or Listen).
    /// Fetch → wait for the normal session to come up → server /say → ack.
    private func handleListen() {
        guard Self.masterOn else { return }
        guard let secret = VoiceAuthSecret.read() else { return }
        var comps = URLComponents(
            url: TextTurnClient.defaultBase.appendingPathComponent("outbound/pending"),
            resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
        var req = URLRequest(url: comps.url!)
        req.setValue(TextTurnClient.hmacSHA256Hex(secret: secret, bodyBytes: Data()),
                     forHTTPHeaderField: "X-Voice-Auth")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let intents = obj["intents"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                UNUserNotificationCenter.current().setBadgeCount(0)
            }
            guard !intents.isEmpty else { return }   // expired/acked: speak nothing
            // Give the foregrounded app a moment to bring the WS session up —
            // the same machinery a normal app-open uses — then have the server
            // speak into it. Two attempts, then leave the intent fetched (the
            // sweeper will expire it; we never force audio).
            self.sayPending(intents, attempt: 1)
        }.resume()
    }

    private func sayPending(_ intents: [[String: Any]], attempt: Int) {
        // 0.2.63: cold starts need longer — the WS session can take several
        // seconds to connect after a notification launch. Three 4s attempts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            let lines = intents.compactMap { $0["speak_text"] as? String }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            var req = URLRequest(url: TextTurnClient.defaultBase.appendingPathComponent("say"))
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let joined = lines.joined(separator: ". ")
            req.httpBody = "text=\(joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined)"
                .data(using: .utf8)
            req.timeoutInterval = 15
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self else { return }
                let clients = ((try? JSONSerialization.jsonObject(with: data ?? Data())
                                as? [String: Any])?["clients"] as? Int) ?? 0
                if clients > 0 {
                    for i in intents {
                        if let id = i["id"] as? String {
                            self.ack(intentId: id, status: "spoken",
                                     source: i["source"] as? String)
                        }
                    }
                } else if attempt < 3 {
                    self.sayPending(intents, attempt: attempt + 1)
                }
            }.resume()
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let intentId = userInfo["intent_id"] as? String
        switch response.actionIdentifier {
        case "LISTEN", UNNotificationDefaultActionIdentifier:
            handleListen()
        case "NOT_NOW", UNNotificationDismissActionIdentifier:
            if let intentId { ack(intentId: intentId, status: "dismissed") }
        case "MUTE_SOURCE":
            if let intentId { ack(intentId: intentId, status: "mute_source") }
        default:
            break
        }
        completionHandler()
    }

    /// Foreground delivery: show a quiet banner. Never auto-speak — the
    /// server's in_session gate should prevent this case entirely; if a push
    /// slips through while the app is open, it stays visual only.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .badge])
    }

    /// The gear on our notifications in system Settings deep-links here.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                openSettingsFor notification: UNNotification?) {
        // Single-screen app: foregrounding is enough; the master switch lives
        // in the in-app Settings sheet.
    }
}
