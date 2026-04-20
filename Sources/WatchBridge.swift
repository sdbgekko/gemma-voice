import Foundation
import WatchConnectivity

/// Thin wrapper around WCSession to push each turn + status change to the
/// paired Apple Watch. Silently no-ops when no watch is paired.
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func sendTurn(id: UUID, text: String, isGemma: Bool) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let payload: [String: Any] = [
            "type": "turn",
            "id": id.uuidString,
            "text": text,
            "isGemma": isGemma,
        ]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // If live-reachable send fails, queue for next wake.
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func sendStatus(_ status: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let payload: [String: Any] = ["type": "status", "status": status]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in }
        }
    }

    // MARK: WCSessionDelegate stubs
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
