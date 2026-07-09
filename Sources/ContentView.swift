import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var viewModel: StreamingViewModel
    @AppStorage("appearance") private var appearance: String = "system"
    @State private var showSettings = false

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // follow system
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            if let err = viewModel.errorMessage {
                errorChip(err)
            }
            ledgerList
            dock
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .preferredColorScheme(preferredScheme)
        .onAppear { viewModel.requestMicPermission() }
        .sheet(isPresented: $showSettings) {
            SettingsView(appearance: $appearance)
        }
    }

    // MARK: - Connection bar (honest socket state + settings)

    private var connectionBar: some View {
        HStack(spacing: 8) {
            // P0-1: when the socket is down this reads "disconnected — tap to
            // reconnect" and forces a fresh connection. Hit-testing is only
            // enabled while disconnected so it never swallows normal taps.
            Button(action: { viewModel.reconnect() }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 8, height: 8)
                    Text(connectionLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(viewModel.status == .disconnected)
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var connectionLabel: String {
        viewModel.status == .disconnected ? "disconnected — tap to reconnect" : "connected"
    }

    private var connectionColor: Color {
        viewModel.status == .disconnected ? Color(hex: "#9A9A9A") : Color(hex: "#22D67A")
    }

    // MARK: - Inline error chip (replaces the modal .alert for transient events)

    private func errorChip(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(msg)
                .font(.footnote)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: { viewModel.errorMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    // MARK: - Ledger list

    private var ledgerList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if viewModel.ledger.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.ledger) { turn in
                            TurnCardView(turn: turn)
                                .id(turn.id)
                        }
                    }
                }
                .padding(16)
            }
            // New card appended → scroll to it. Also re-scroll when the newest
            // card changes phase (reply lands, card grows) so the latest stays
            // in view.
            .onChange(of: viewModel.ledger.last?.id) { _, id in
                scrollToLatest(proxy, id)
            }
            .onChange(of: viewModel.ledger.last?.phase) { _, _ in
                scrollToLatest(proxy, viewModel.ledger.last?.id)
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, _ id: UUID?) {
        guard let id = id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("Tap to talk — your turns show up here.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Dock (live state + waveform + real labeled mute button)

    private var dock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusLabel)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            WaveformView(
                samples: viewModel.levelHistory,
                active: viewModel.status == .speaking_ || viewModel.status == .playing
            )
            .frame(height: 40)
            .padding(.horizontal, 24)
            muteButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom))
    }

    private var muteButton: some View {
        Button(action: { viewModel.toggleMute() }) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.status == .muted ? "mic.slash.fill" : "mic.fill")
                Text(viewModel.status == .muted ? "Tap to talk" : "Mute")
                    .font(.headline)
            }
            .foregroundColor(.white)   // white-on-gemmaMicBlue clears AA (contrast fix)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(viewModel.status == .muted ? Color(hex: "#6E6E73") : Color.gemmaMicBlue)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }

    private var statusLabel: String {
        switch viewModel.status {
        case .muted: return "muted — tap to talk"
        case .listening: return "listening"
        case .speaking_: return "hearing you..."
        case .heardYou: return "got it — processing"
        case .thinking: return "thinking..."
        case .playing: return "speaking..."
        case .disconnected: return "disconnected — tap to reconnect"
        }
    }

    // Bug fix: the old local switch mapped BOTH .muted and .speaking_ to
    // .red (a collision that read as "error" for a normal speaking state).
    // Repoint to the single source of truth — Status.tintHex in ViewModel.swift
    // (gray muted, green speaking, gold playing, etc. — already correct there).
    private var statusColor: Color {
        Color(hex: viewModel.status.tintHex)
    }
}

#Preview {
    ContentView().environmentObject(StreamingViewModel())
}

struct WaveformView: View {
    let samples: [Float]
    let active: Bool

    // Tuned so a modest level (~0.1) fills about half the bar height.
    private func normalized(_ v: Float) -> CGFloat {
        CGFloat(min(1.0, max(0.04, Double(v) * 5.5)))
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, v in
                    Capsule()
                        .fill(gold)
                        .frame(width: max(2, (geo.size.width - CGFloat(samples.count - 1) * 3) / CGFloat(samples.count)),
                               height: max(3, geo.size.height * normalized(v)))
                        .opacity(active ? 1.0 : 0.35)
                        .animation(.linear(duration: 0.08), value: v)
                }
            }
        }
    }

    // Soft gold to echo the logo.
    private var gold: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.85, green: 0.70, blue: 0.32),
                Color(red: 0.95, green: 0.80, blue: 0.40),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - Design color tokens
//
// Two WCAG contrast fixes plus a hex helper so Status.tintHex (defined in
// ViewModel.swift) can drive SwiftUI colors directly.

extension UIColor {
    /// "#RRGGBB" (leading '#' optional). Falls back to opaque black on a
    /// malformed string rather than trapping.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v & 0xFF0000) >> 16) / 255
        let g = CGFloat((v & 0x00FF00) >> 8) / 255
        let b = CGFloat(v & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(UIColor(hex: hex)) }

    /// Contrast fix: brand gold #D4A44A is only 2.28:1 as TEXT on white (AA
    /// fail). Keep #D4A44A for accents/fills/glows, but text uses this token —
    /// #D4A44A in dark mode (on the dark ground it clears AA), darkened to
    /// #8A6414 in light mode (~4.6:1 on white). Dynamic so the appearance
    /// picker resolves it live.
    static let gemmaGoldText = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: "#D4A44A")
                                           : UIColor(hex: "#8A6414")
    })

    /// Contrast fix: white label on system blue is ~3.26:1 (borderline).
    /// #2E6FD6 lifts white-on-blue to ~4.6:1 (AA).
    static let gemmaMicBlue = Color(hex: "#2E6FD6")
}
