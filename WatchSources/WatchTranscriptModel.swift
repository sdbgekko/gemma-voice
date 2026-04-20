import Foundation
import WatchConnectivity

struct WatchTurn: Identifiable, Hashable {
    let id: UUID
    let text: String
    let isGemma: Bool
}

@MainActor
final class WatchTranscriptModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var turns: [WatchTurn] = []
    @Published var status: String = "connecting"

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.status = (state == .activated) ? "paired" : "offline"
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        guard let type = message["type"] as? String else { return }
        if type == "turn",
           let text = message["text"] as? String,
           let isGemma = message["isGemma"] as? Bool {
            let idStr = message["id"] as? String ?? UUID().uuidString
            let uuid = UUID(uuidString: idStr) ?? UUID()
            Task { @MainActor in
                self.turns.append(WatchTurn(id: uuid, text: text, isGemma: isGemma))
                if self.turns.count > 20 {
                    self.turns.removeFirst(self.turns.count - 20)
                }
            }
        } else if type == "status", let s = message["status"] as? String {
            Task { @MainActor in self.status = s }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        session(session, didReceiveMessage: userInfo)
    }
}
