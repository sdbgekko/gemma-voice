import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct GemmaVoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GemmaVoiceActivityAttributes.self) { context in
            // Lock screen / banner UI
            LockScreenView(
                agentName: context.attributes.agentName,
                state: context.state
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded — when long-pressing or when device has the
                // room. Four regions: leading, trailing, center, bottom.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.circle.fill")
                            .foregroundStyle(.yellow)
                            .font(.system(size: 22, weight: .semibold))
                        Text(context.attributes.agentName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 6) {
                        Image(systemName: context.state.code.sfSymbol)
                            .foregroundStyle(context.state.code.tint)
                            .font(.system(size: 16, weight: .semibold))
                        Text(context.state.code.label)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(context.state.code.tint)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(relativeTime(from: context.state.lastChanged))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } compactLeading: {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(.yellow)
            } compactTrailing: {
                Image(systemName: context.state.code.sfSymbol)
                    .foregroundStyle(context.state.code.tint)
            } minimal: {
                Image(systemName: context.state.code.sfSymbol)
                    .foregroundStyle(context.state.code.tint)
            }
            .widgetURL(URL(string: "gemmavoice://open"))
            .keylineTint(context.state.code.tint)
        }
    }

    private func relativeTime(from date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 2 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        let mins = Int(elapsed / 60)
        return "\(mins)m ago"
    }
}

@available(iOS 16.2, *)
private struct LockScreenView: View {
    let agentName: String
    let state: GemmaVoiceActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(state.code.tint.opacity(0.20))
                    .frame(width: 44, height: 44)
                Image(systemName: state.code.sfSymbol)
                    .foregroundStyle(state.code.tint)
                    .font(.system(size: 20, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(agentName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(state.code.label)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(state.code.tint)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("GemmaVoice")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}
