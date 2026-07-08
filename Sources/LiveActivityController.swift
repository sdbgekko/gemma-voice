import ActivityKit
import Combine
import Foundation
import SwiftUI

/// Thin wrapper around ActivityKit that the view models call without
/// having to know about iOS 16.2 guards or Activity lifecycles.
///
/// The Live Activity surfaces the same state the app's main UI shows —
/// muted / listening / speaking / got-it / thinking / playing — but on
/// the lock screen and in the Dynamic Island. Direct fix for Sherman's
/// "can you hear me from the pocket?" loop: he can see the state
/// transition without unlocking.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private init() {}

    @available(iOS 16.2, *)
    private var activity: Activity<GemmaVoiceActivityAttributes>? {
        get { _activity as? Activity<GemmaVoiceActivityAttributes> }
        set { _activity = newValue }
    }
    private var _activity: Any?

    /// Mirrored copy of last-known state so partial updates (just status,
    /// or just agent name) don't blank the other field.
    private var lastAgentName: String = "Gemma"
    private var lastStatus: LiveActivityStatusCode = .listening

    /// Start a Live Activity. No-op if Live Activities are disabled,
    /// or if the iOS version doesn't support them.
    func start(agentName: String = "Gemma", initialStatus: LiveActivityStatusCode = .listening) {
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[LiveActivity] not enabled — user disabled in Settings → GemmaVoice")
            return
        }

        // Tear down any stale activity first; a single session = a single
        // Live Activity.
        endInternal()

        self.lastAgentName = agentName
        self.lastStatus = initialStatus
        let attrs = GemmaVoiceActivityAttributes(appLabel: "GemmaVoice")
        let state = GemmaVoiceActivityAttributes.ContentState(
            statusCode: initialStatus.rawValue,
            lastChanged: Date(),
            agentName: agentName
        )
        do {
            self.activity = try Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            NSLog("[LiveActivity] started for \(agentName) state=\(initialStatus.label)")
        } catch {
            NSLog("[LiveActivity] start failed: \(error.localizedDescription)")
        }
    }

    /// Push a new content state. ActivityKit dedupes near-identical
    /// payloads; caller doesn't need to throttle.
    func update(to code: LiveActivityStatusCode) {
        lastStatus = code
        pushState()
    }

    /// Update just the agent name (e.g. server flipped routing from
    /// Gemma to Daisy). Keeps current status as-is.
    func updateAgentName(_ name: String) {
        guard !name.isEmpty else { return }
        lastAgentName = name
        pushState()
    }

    private func pushState() {
        guard #available(iOS 16.2, *), let activity = self.activity else { return }
        let state = GemmaVoiceActivityAttributes.ContentState(
            statusCode: lastStatus.rawValue,
            lastChanged: Date(),
            agentName: lastAgentName
        )
        // staleDate of 30s — if the app dies without ending the activity,
        // ActivityKit will visually de-emphasize after 30s instead of
        // looking falsely-alive forever.
        let staleDate = Date().addingTimeInterval(30)
        Task {
            await activity.update(.init(state: state, staleDate: staleDate))
        }
    }

    /// End the activity and remove it from the lock screen / Island.
    func end() {
        guard #available(iOS 16.2, *) else { return }
        endInternal()
    }

    @available(iOS 16.2, *)
    private func endInternal() {
        guard let activity = self.activity else { return }
        Task {
            await activity.end(activity.content, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}

/// Translate the app's Status enum to the Live Activity wire-format
/// code. Kept here so both ViewModels can call it.
extension Status {
    var liveActivityCode: LiveActivityStatusCode {
        switch self {
        case .muted:      return .muted
        case .listening:  return .listening
        case .speaking_:  return .speaking
        case .heardYou:   return .heardYou
        case .thinking:   return .thinking
        case .playing:    return .playing
        case .disconnected: return .lostConnection
        }
    }
}
