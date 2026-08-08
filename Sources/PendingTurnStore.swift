import Foundation

// 0.2.44: reconnect-redelivery (the dropped-reply fix). While a voice turn
// awaits the brain (25–160s), the transport can die under it — the app gets
// suspended, the socket resets, iOS jetsams the process. The SERVER keeps the
// reply: stream_server.py calls `_store_turn_reply(turn_id, reply)` before it
// streams a single audio byte, and GET /reply_text?rid=<id> serves it for 10
// minutes. What the app was missing is a durable record of WHICH turn was in
// flight. This store is that record: written when a /text_turn dispatches,
// upgraded with the server's X-Turn-Id the moment response headers arrive,
// cleared when the reply renders — and persisted in UserDefaults so it
// survives suspension and even a full relaunch after a jetsam kill.

/// The one turn currently awaiting the brain (the voice path is strictly
/// serial, so a single slot is the correct capacity).
struct PendingTurn: Codable {
    /// Server-minted turn id (X-Turn-Id). nil until response headers arrive —
    /// a turn that dies BEFORE headers has no fetch key and is unrecoverable
    /// by design (see report: server would need a client-supplied turn id).
    var rid: String?
    /// What the user said — used to re-attach the redelivered reply to the
    /// right ledger card (or synthesize one after a relaunch).
    var text: String
    var startedAt: Date
}

enum PendingTurnStore {
    private static let key = "pendingTurn.v1"
    /// Matches the server's `_REPLY_BY_TURN_TTL` (600s) — beyond that the
    /// reply is gone server-side, so the record is unrecoverable noise.
    static let maxAge: TimeInterval = 600

    /// A turn just dispatched. Overwrites any prior record — correct for the
    /// continuation-merge re-send, which supersedes the same logical turn.
    static func begin(text: String) {
        write(PendingTurn(rid: nil, text: text, startedAt: Date()))
    }

    /// Response headers arrived: the turn now has its server fetch key.
    static func assignRid(_ rid: String) {
        guard !rid.isEmpty, var p = read() else { return }
        p.rid = rid
        write(p)
    }

    /// Turn resolved (reply rendered, user deleted it, or non-recoverable
    /// failure) — nothing left to redeliver.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// The pending turn, if one exists and is still within the server's
    /// reply-retention window. A stale record is cleared on read.
    static func pending() -> PendingTurn? {
        guard let p = read() else { return nil }
        if Date().timeIntervalSince(p.startedAt) > maxAge {
            clear()
            return nil
        }
        return p
    }

    private static func read() -> PendingTurn? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PendingTurn.self, from: data)
    }

    private static func write(_ p: PendingTurn) {
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
