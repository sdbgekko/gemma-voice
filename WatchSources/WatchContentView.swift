import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var model: WatchTranscriptModel

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            if let img = UIImage(named: "GoldGemma") {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .opacity(0.18)
                    .padding(24)
                    .allowsHitTesting(false)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        Text(model.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        if model.turns.isEmpty {
                            Text("Waiting for dialogue…")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 24)
                        } else {
                            ForEach(model.turns) { turn in
                                turnBubble(turn)
                                    .id(turn.id)
                            }
                        }
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: model.turns.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
        }
    }

    @ViewBuilder
    private func turnBubble(_ turn: WatchTurn) -> some View {
        HStack {
            if turn.isGemma { Spacer(minLength: 10) }
            Text(turn.text)
                .font(.caption)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(turn.isGemma
                              ? Color(red: 0.85, green: 0.70, blue: 0.32).opacity(0.92)
                              : Color.blue.opacity(0.92))
                )
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: turn.isGemma ? .trailing : .leading)
            if !turn.isGemma { Spacer(minLength: 10) }
        }
    }
}
