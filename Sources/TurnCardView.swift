import SwiftUI
import UIKit

/// One card in the turn ledger: a lifecycle track (Heard → Sent → Working →
/// Speaking), the user's words, Gemma's reply, and a live equalizer while she
/// speaks. Purely a function of its `LedgerTurn` — no state of its own except
/// the equalizer animation.
struct TurnCardView: View {
    let turn: LedgerTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            lifecycleTrack
            // Photo turn (0.2.45): the sent picture, above the caption.
            if let data = turn.thumbnailData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 180)
                    .clipped()
                    .cornerRadius(12)
                    .accessibilityLabel("Photo you sent")
            }
            if !turn.youText.isEmpty {
                Text(turn.youText)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reply = turn.reply, !reply.isEmpty {
                replyBlock(reply)
            }
            if case .dropped(let reason) = turn.phase {
                droppedBlock(reason)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    // MARK: Header — speaker + elapsed timer

    private var header: some View {
        HStack(spacing: 8) {
            Text(speakerName)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Spacer()
            elapsed
        }
    }

    private var speakerName: String {
        if let s = turn.speaker, !s.isEmpty { return s.capitalized }
        return "You"
    }

    /// Elapsed timer. Runs off a TimelineView (no Timer object) while the turn
    /// is .working; once it leaves .working the TimelineView is gone so the
    /// value freezes at the answered-minus-started delta.
    @ViewBuilder
    private var elapsed: some View {
        if let started = turn.startedAt {
            if turn.phase == .working {
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    Text(Self.elapsedString(from: started, to: ctx.date))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Color.gemmaGoldText)
                }
            } else if let done = turn.answeredAt {
                Text(Self.elapsedString(from: started, to: done))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private static func elapsedString(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Lifecycle track

    private static let steps: [(TurnPhase, String)] = [
        (.heard, "Heard"),
        (.sent, "Sent"),
        (.working, "Working"),
        (.speaking, "Speaking"),
    ]

    private func rank(_ p: TurnPhase) -> Int {
        switch p {
        case .heard:   return 0
        case .sent:    return 1
        case .working: return 2
        case .speaking: return 3
        case .answered: return 4
        case .dropped:  return -1
        }
    }

    private var lifecycleTrack: some View {
        let current = rank(turn.phase)
        return HStack(spacing: 6) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { idx, step in
                let stepRank = rank(step.0)
                let done = current > stepRank
                let active = current == stepRank
                HStack(spacing: 4) {
                    stepDot(done: done, active: active, isWorking: step.0 == .working && active)
                    Text(step.1)
                        .font(.caption2.weight(active ? .semibold : .regular))
                        .foregroundColor(done || active ? .primary : .secondary)
                }
                if idx < Self.steps.count - 1 {
                    Rectangle()
                        .fill(current > stepRank ? Color.gemmaGoldText : Color(.systemGray4))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .opacity(rank(turn.phase) < 0 ? 0.4 : 1.0)   // dim the track on a dropped turn
    }

    @ViewBuilder
    private func stepDot(done: Bool, active: Bool, isWorking: Bool) -> some View {
        if done {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)
        } else if isWorking {
            // pulsing dot for the in-flight "working" state
            Circle()
                .fill(Color.gemmaGoldText)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier())
        } else if active {
            Circle()
                .fill(Color.gemmaGoldText)
                .frame(width: 8, height: 8)
        } else {
            Circle()
                .stroke(Color(.systemGray4), lineWidth: 1.5)
                .frame(width: 8, height: 8)
        }
    }

    // MARK: Reply + dropped blocks

    private func replyBlock(_ reply: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(sourceLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Color.gemmaGoldText)   // AA-safe gold-as-text token
                if turn.phase == .speaking {
                    SpeakingEqualizer()
                }
            }
            Text(reply)
                .font(.callout)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(12)
    }

    private var sourceLabel: String {
        switch turn.source {
        case "gemma":     return "Gemma"
        case "claude":    return "Claude API"
        case "jarvis":    return "Jarvis"
        case "kai":       return "Kai"
        case "on-device": return "Gemma"
        case .some(let s): return s
        case .none:       return "Gemma"
        }
    }

    private func droppedBlock(_ reason: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle")
            Text(reason.isEmpty ? "dropped" : "dropped · \(reason)")
        }
        .font(.caption2)
        .foregroundColor(.secondary)
    }
}

/// Slow scale pulse for the in-flight working dot. Self-contained so the card
/// stays stateless.
private struct PulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.35 : 0.85)
            .opacity(on ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Tiny 4-bar equalizer shown while Gemma is speaking. Decorative (not wired to
/// audio levels — the dock waveform carries the real signal); it just says
/// "voice is playing" at a glance.
struct SpeakingEqualizer: View {
    @State private var animate = false
    private let bars = 4

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(Color.gemmaGoldText)
                    .frame(width: 2.5, height: animate ? 12 : 4)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.12),
                        value: animate
                    )
            }
        }
        .frame(height: 12)
        .onAppear { animate = true }
    }
}
