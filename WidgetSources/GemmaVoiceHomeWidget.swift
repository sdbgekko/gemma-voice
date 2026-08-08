import SwiftUI
import WidgetKit

// 0.2.44: home-screen widget (small + medium). One tap anywhere on the
// widget opens gemmavoice://talk — the 0.2.43 Action-Button fast path —
// so the app comes up already listening, mic hot.
//
// The medium widget additionally shows pipeline state fetched from the
// voice-turn server's GET /health (same host the app uses, via
// GemmaVoiceServer in Shared/). Design is deliberately spartan: a state
// dot and "Talk to Gemma" — legible at a glance, no chrome.

/// Tri-state pipeline health as the widget can honestly know it.
enum PipelineState {
    /// /health returned ok=true.
    case online
    /// The server answered but reported a broken pipeline (503 / ok=false).
    case degraded
    /// The server didn't answer at all (unreachable, timeout, bad body).
    case offline

    var label: String {
        switch self {
        case .online: return "Online"
        case .degraded: return "Degraded"
        case .offline: return "Offline"
        }
    }

    var tint: Color {
        switch self {
        case .online: return Color(red: 0.13, green: 0.84, blue: 0.48)
        case .degraded: return Color(red: 0.95, green: 0.65, blue: 0.20)
        case .offline: return Color(red: 0.55, green: 0.55, blue: 0.55)
        }
    }
}

struct PipelineEntry: TimelineEntry {
    let date: Date
    let state: PipelineState
    /// Component detail for the medium widget, from /health's JSON:
    /// brain = tmux_session_found, voice = kokoro primary OR fallback,
    /// ears = whisper_ok.
    let brainUp: Bool
    let voiceUp: Bool
    let earsUp: Bool

    static let placeholder = PipelineEntry(
        date: Date(), state: .online, brainUp: true, voiceUp: true, earsUp: true)
}

struct PipelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PipelineEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (PipelineEntry) -> Void) {
        // Gallery preview / transient snapshot: show the happy path rather
        // than block on a network round-trip.
        if context.isPreview {
            completion(.placeholder)
            return
        }
        fetchHealth(completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PipelineEntry>) -> Void) {
        fetchHealth { entry in
            // ~15min refresh; the app additionally reloads this timeline on
            // every foreground (GemmaVoiceApp scenePhase → .active), so the
            // widget is fresh whenever Sherman has just used the app.
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    /// GET /health with a tight timeout — a widget refresh must never hang.
    /// Unreachable/undecodable = .offline shown gracefully, never an error UI.
    private func fetchHealth(completion: @escaping (PipelineEntry) -> Void) {
        var req = URLRequest(url: GemmaVoiceServer.healthURL)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            // /health returns 200 (ok) or 503 (degraded) — BOTH carry the
            // JSON body, so parse the body and ignore the status code.
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(PipelineEntry(date: Date(), state: .offline,
                                         brainUp: false, voiceUp: false, earsUp: false))
                return
            }
            let ok = json["ok"] as? Bool ?? false
            let brain = json["tmux_session_found"] as? Bool ?? false
            let voice = (json["kokoro_primary_ok"] as? Bool ?? false)
                || (json["kokoro_fallback_ok"] as? Bool ?? false)
            let ears = json["whisper_ok"] as? Bool ?? false
            completion(PipelineEntry(date: Date(), state: ok ? .online : .degraded,
                                     brainUp: brain, voiceUp: voice, earsUp: ears))
        }.resume()
    }
}

@available(iOS 17.0, *)
struct GemmaVoiceHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: GemmaWidgetKind.home, provider: PipelineProvider()) { entry in
            HomeWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(.systemBackground)
                }
                // One tap → straight into listening (0.2.43 fast path).
                .widgetURL(URL(string: "gemmavoice://talk"))
        }
        .configurationDisplayName("Talk to Gemma")
        .description("One tap to start listening. Medium size also shows whether the voice pipeline is up.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@available(iOS 17.0, *)
private struct HomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PipelineEntry

    var body: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: Small — the talk button, plus a single honest state dot.

    private var small: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("Talk to Gemma")
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
            stateRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Medium — talk affordance left, pipeline detail right.

    private var medium: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.yellow)
                Text("Talk to Gemma")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                stateRow
                componentRow("Brain", up: entry.brainUp)
                componentRow("Voice", up: entry.voiceUp)
                componentRow("Ears", up: entry.earsUp)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stateRow: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(entry.state.tint)
                .frame(width: 8, height: 8)
            Text(entry.state.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func componentRow(_ name: String, up: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: up ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(up ? PipelineState.online.tint : PipelineState.offline.tint)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        // When the server itself is unreachable the component flags are
        // meaningless — dim them so "Offline" is the story, not three ✕s.
        .opacity(entry.state == .offline ? 0.4 : 1.0)
    }
}
