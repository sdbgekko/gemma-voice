import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject var model: WatchTranscriptModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    if let img = UIImage(named: "GoldGemma") {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 60)
                            .padding(.top, 4)
                    }
                    Text(model.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                              ? Color(red: 0.85, green: 0.70, blue: 0.32).opacity(0.28)
                              : Color.blue.opacity(0.85))
                )
                .foregroundStyle(turn.isGemma ? Color.primary : Color.white)
                .frame(maxWidth: .infinity, alignment: turn.isGemma ? .trailing : .leading)
            if !turn.isGemma { Spacer(minLength: 10) }
        }
    }
}
