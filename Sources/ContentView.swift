import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var viewModel: StreamingViewModel
    @AppStorage("appearance") private var appearance: String = "system"
    @State private var showSettings = false
    /// Heartbeat — subtle scale pulse on the logo so Sherman can tell at a
    /// glance that the app is alive and rendering. Freezes if the view
    /// stops updating (connection dropped, app hung, stuck render).
    @State private var heartbeat = false

    private var backgroundImage: UIImage? {
        UIImage(named: "GoldGemma")
    }

    private var mutedImage: UIImage? {
        UIImage(named: "GoldGemmaMuted")
    }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // follow system
        }
    }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    // Logo fit into the upper portion of the screen. Tap anywhere on
                    // the logo to toggle mute; a red square highlights the CPU chip
                    // position to show muted state.
                    let logoFrameWidth = geo.size.width
                    let logoFrameHeight = geo.size.height * 0.7
                    let logoCenterY = geo.size.height * 0.38
                    // GoldGemma.png is 1536x1024 (1.5:1 landscape). With aspectRatio .fit
                    // and frame wider than tall, the rendered image height = width / 1.5.
                    let renderedImageHeight = min(logoFrameHeight, logoFrameWidth / 1.5)
                    let imageTopY = logoCenterY - renderedImageHeight / 2
                    // The CPU chip in the source image sits at ~27% from top, centered.
                    let chipScreenY = imageTopY + renderedImageHeight * 0.27
                    let chipSize: CGFloat = renderedImageHeight * 0.08
                    Button(action: { viewModel.toggleMute() }) {
                        // Always render the gold logo as the base; the
                        // red-CPU variant lives on top with opacity driven
                        // by mute state, so toggling produces a crossfade
                        // that visually reads as "the CPU chip turns red".
                        ZStack {
                            if let img = backgroundImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: logoFrameWidth, height: logoFrameHeight)
                            }
                            if let muted = mutedImage {
                                Image(uiImage: muted)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: logoFrameWidth, height: logoFrameHeight)
                                    .opacity(viewModel.status == .muted ? 1.0 : 0.0)
                                    .animation(.easeInOut(duration: 0.35),
                                               value: viewModel.status == .muted)
                            }
                        }
                        .scaleEffect(heartbeat ? 1.018 : 1.0)
                        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                                   value: heartbeat)
                    }
                    .buttonStyle(.plain)
                    .position(x: logoFrameWidth / 2, y: logoCenterY)
                    // Gold waveform just below the logo.
                    WaveformView(samples: viewModel.levelHistory, active: viewModel.status == .speaking_)
                        .frame(width: geo.size.width * 0.75, height: 48)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.62)
                    // Status label above the logo.
                    VStack {
                        statusBar
                        Spacer()
                    }
                    // Transcript strip at the very bottom.
                    VStack {
                        Spacer()
                        transcriptStrip
                            .frame(height: geo.size.height * 0.28)
                            .padding(.bottom, 24)
                    }
                }
            }
        }
        .preferredColorScheme(preferredScheme)
        .onAppear {
            viewModel.requestMicPermission()
            heartbeat = true
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil), actions: {
            Button("OK") { viewModel.errorMessage = nil }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
        .sheet(isPresented: $showSettings) {
            SettingsView(appearance: $appearance)
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusLabel)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var transcriptStrip: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.transcript.suffix(6)) { turn in
                        turnBubble(turn)
                            .id(turn.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.0), Color.white.opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: viewModel.transcript.last?.id) { _, newId in
                // Tracking last-id, not count — the maxTurns trim keeps count
                // pinned at 6 once the transcript fills up, so count-based
                // onChange stops firing. Also re-fire a beat later so scroll
                // lands after layout finishes laying out the new bubble.
                guard let id = newId else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func turnBubble(_ turn: Turn) -> some View {
        HStack {
            if turn.isGemma { Spacer(minLength: 40) }
            VStack(alignment: turn.isGemma ? .trailing : .leading, spacing: 2) {
                Text(turn.text)
                    .font(.callout)
                    .padding(8)
                    .background(turn.isGemma ? Color(.systemGray5) : Color.blue.opacity(0.85))
                    .foregroundColor(turn.isGemma ? .primary : .white)
                    .cornerRadius(12)
                if turn.isGemma, let src = turn.source {
                    Text(sourceLabel(src))
                        .font(.caption2)
                        .foregroundColor(sourceColor(src))
                        .padding(.horizontal, 6)
                }
                Text(captionFor(turn))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, alignment: turn.isGemma ? .trailing : .leading)
            if !turn.isGemma { Spacer(minLength: 40) }
        }
    }

    private func captionFor(_ turn: Turn) -> String {
        let name: String
        if turn.isGemma {
            name = "Gemma"
        } else if let s = turn.speaker, !s.isEmpty {
            name = s
        } else {
            name = "You"
        }
        return "\(name) · \(Self.timeFormatter.string(from: turn.timestamp))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private func sourceLabel(_ src: String) -> String {
        switch src {
        case "gemma":  return "Gemma"
        case "claude": return "Claude API"
        case "jarvis": return "Jarvis (fallback)"
        default:       return src
        }
    }

    private func sourceColor(_ src: String) -> Color {
        switch src {
        case "gemma":  return .green
        case "claude": return .blue
        case "jarvis": return .orange
        default:       return .secondary
        }
    }

    private var statusLabel: String {
        switch viewModel.status {
        case .muted: return "muted — tap the CPU to unmute"
        case .listening: return "listening"
        case .speaking_: return "hearing you..."
        case .thinking: return "thinking..."
        case .playing: return "speaking..."
        }
    }

    private var statusColor: Color {
        switch viewModel.status {
        case .muted: return .red
        case .listening: return .blue
        case .speaking_: return .red
        case .thinking: return .orange
        case .playing: return .green
        }
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
