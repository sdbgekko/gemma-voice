import Foundation

/// 0.2.44: single source of truth for where the voice-turn server lives.
/// Lives in Shared/ so BOTH the app and the widget extension compile it —
/// the home-screen widget's TimelineProvider polls GET /health on the same
/// host the app talks to (feedback: reuse the app's server-host config, don't
/// fork a second constant that drifts).
public enum GemmaVoiceServer {
    /// Tailscale IP of JMM. Same host as the WebSocket (:9201); the aiohttp
    /// HTTP side (/text_turn, /reply_text, /health, /beacon) is :9202.
    public static let host = "100.80.225.86"
    public static let httpBase = URL(string: "http://\(host):9202")!
    /// GET /health — pipeline self-report (200 ok / 503 degraded, JSON body
    /// either way; see stream_server.py `_collect_health`).
    public static let healthURL = httpBase.appendingPathComponent("health")

    /// "simulator" | "device" — the 0.2.44 environment field the server
    /// expects on /beacon, /text_turn, and the WS `?env=` query param, so
    /// simulator smoke traffic stops polluting device telemetry.
    public static var environment: String {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        return "device"
        #endif
    }
}

/// Widget kinds shared between the app (which pokes timelines on foreground)
/// and the extension (which registers them).
public enum GemmaWidgetKind {
    public static let home = "GemmaVoiceHomeWidget"
}
