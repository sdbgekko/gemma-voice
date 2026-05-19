import ActivityKit
import Foundation
import SwiftUI

/// Shared between the main GemmaVoice app and the GemmaVoiceWidgets
/// extension. Both targets reference this same file via xcodegen so the
/// ActivityKit payload schema stays in sync.
///
/// Payload is intentionally minimal — ActivityKit budgets push updates
/// aggressively and a large ContentState risks throttling. Anything
/// derived (label, color, SF symbol) is computed from `statusCode`.
@available(iOS 16.2, *)
public struct GemmaVoiceActivityAttributes: ActivityAttributes {
    public typealias ContentState = State

    public struct State: Codable, Hashable {
        public var statusCode: Int
        public var lastChanged: Date
        /// Active agent name (Gemma / Daisy / Mackenzie / Malia / Bobbi).
        /// Lives in State (not Attributes) so it can be swapped mid-session
        /// when the server flips voice routing.
        public var agentName: String

        public init(statusCode: Int, lastChanged: Date, agentName: String) {
            self.statusCode = statusCode
            self.lastChanged = lastChanged
            self.agentName = agentName
        }
    }

    /// Fixed across the activity's lifetime. Identifies the app, not the
    /// agent — that's in State.
    public let appLabel: String

    public init(appLabel: String = "GemmaVoice") {
        self.appLabel = appLabel
    }
}

/// Wire format codes — keep in sync with `Status` in ViewModel.swift.
/// Integer codes (not raw enum) so the payload survives Swift version
/// drift between widget + app targets.
public enum LiveActivityStatusCode: Int {
    case muted = 0
    case listening = 1
    case speaking = 2
    case heardYou = 3
    case thinking = 4
    case playing = 5
    case lostConnection = 6

    public var label: String {
        switch self {
        case .muted: return "Muted"
        case .listening: return "Listening"
        case .speaking: return "Hearing you"
        case .heardYou: return "Got it"
        case .thinking: return "Thinking"
        case .playing: return "Speaking"
        case .lostConnection: return "Lost connection"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .muted: return "mic.slash.fill"
        case .listening: return "mic.fill"
        case .speaking: return "waveform"
        case .heardYou: return "checkmark.circle.fill"
        case .thinking: return "ellipsis.circle.fill"
        case .playing: return "speaker.wave.2.fill"
        case .lostConnection: return "exclamationmark.triangle.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .muted: return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .listening: return Color(red: 0.20, green: 0.55, blue: 0.95)
        case .speaking: return Color(red: 0.30, green: 0.80, blue: 0.45)
        case .heardYou: return Color(red: 0.13, green: 0.84, blue: 0.48)
        case .thinking: return Color(red: 0.95, green: 0.65, blue: 0.20)
        case .playing: return Color(red: 0.60, green: 0.40, blue: 0.95)
        case .lostConnection: return Color(red: 0.55, green: 0.55, blue: 0.55)
        }
    }
}

public extension GemmaVoiceActivityAttributes.State {
    var code: LiveActivityStatusCode {
        LiveActivityStatusCode(rawValue: statusCode) ?? .listening
    }
}
