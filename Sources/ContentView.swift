import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var viewModel: ViewModel

    private var backgroundImage: UIImage? {
        guard let path = Bundle.main.path(forResource: "GoldGemma", ofType: "png") else { return nil }
        return UIImage(contentsOfFile: path)
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
                        ZStack {
                            // Soft red aura behind the logo when muted.
                            if viewModel.status == .muted, let img = backgroundImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: logoFrameWidth, height: logoFrameHeight)
                                    .blur(radius: 36)
                                    .colorMultiply(Color.red)
                                    .opacity(0.55)
                            }
                            if let img = backgroundImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: logoFrameWidth, height: logoFrameHeight)
                            } else {
                                Color.clear.frame(width: logoFrameWidth, height: logoFrameHeight)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .position(x: logoFrameWidth / 2, y: logoCenterY)
                    // Silence compile-unused warnings for chipSize/chipScreenY (kept for future).
                    let _ = chipSize
                    let _ = chipScreenY
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
        .preferredColorScheme(.light)
        .onAppear { viewModel.requestMicPermission() }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil), actions: {
            Button("OK") { viewModel.errorMessage = nil }
        }, message: {
            Text(viewModel.errorMessage ?? "")
        })
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
            Text("GemmaVoice")
                .font(.caption)
                .foregroundColor(.secondary)
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
            .onChange(of: viewModel.transcript.count) { _, _ in
                if let last = viewModel.transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func turnBubble(_ turn: Turn) -> some View {
        HStack {
            if turn.isGemma { Spacer(minLength: 40) }
            Text(turn.text)
                .font(.callout)
                .padding(8)
                .background(turn.isGemma ? Color(.systemGray5) : Color.blue.opacity(0.85))
                .foregroundColor(turn.isGemma ? .primary : .white)
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: turn.isGemma ? .trailing : .leading)
            if !turn.isGemma { Spacer(minLength: 40) }
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
    ContentView().environmentObject(ViewModel())
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
