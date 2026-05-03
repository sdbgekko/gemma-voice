//
//  TextTurnClient.swift
//  GemmaVoice
//
//  HTTP client for the voice-turn server's POST /text_turn endpoint
//  (added in voice-turn change 1, v0.2.16). The endpoint accepts JSON
//  {text, speaker_hint, session_id} and streams 24kHz mono int16 PCM
//  back as the response body (Content-Type: audio/L16;rate=24000).
//
//  We use URLSession's bytes(for:) async API to get an AsyncBytes stream
//  and forward chunks to the caller as they arrive — same UX as the
//  WebSocket TTS path, just delivered over HTTP chunked transfer.
//
//  The endpoint runs on the aiohttp side of the voice-turn process, port
//  9202 (the WebSocket lives on 9201). Different port than the dispatch
//  text said — the WS server can't share its port with HTTP routes
//  cleanly, so we ride the existing aiohttp /say neighbour at +1.
//
//  Auth (added v0.2.16, voice-turn auth hardening): every request now
//  carries an X-Voice-Auth: <hex> header, where <hex> is
//  HMAC-SHA256(VoiceAuthSecret, request_body). The server rejects
//  mismatches with 401 and fires a Discord alert. If the secret has
//  not been provisioned (Keychain empty), we surface a clear error
//  rather than 401 from the server — the user-visible string points
//  at Settings → Voice-turn secret.
//

import Foundation
import CryptoKit

final class TextTurnClient: TextTurnClientProtocol {
    /// Tailscale IP of JMM. Same host as the WebSocket. HTTP port 9202.
    static let defaultBase = URL(string: "http://100.80.225.86:9202")!

    enum TextTurnError: Error {
        case badResponse(Int)
        case passphraseRequired(matchedKeyword: String, preview: String)
        case decodeError(String)
        case timeout
        /// The HMAC shared secret has not been provisioned in Keychain
        /// yet. The user must open Settings → Voice-turn secret and
        /// paste the value the JMM server printed once on install.
        case secretNotProvisioned
        /// The server rejected our HMAC. Either the secret rotated and
        /// our copy is stale, or the request body was mutated in flight
        /// (TLS terminator, content-encoding rewrite). User-actionable:
        /// re-paste the secret from JMM.
        case authFailed
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = TextTurnClient.defaultBase, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            // No request timeout — the body streams; resource timeout caps total
            // turn latency at a generous 90s so a stuck Kokoro doesn't hang us
            // forever.
            cfg.timeoutIntervalForRequest = 90
            cfg.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Compute hex-encoded HMAC-SHA256 of `bodyBytes` using `secret`.
    /// Pure helper, no side effects — straightforward to unit-test.
    static func hmacSHA256Hex(secret: String, bodyBytes: Data) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: bodyBytes, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    func postText(
        _ text: String,
        speakerHint: String,
        sessionId: String,
        onAudioChunk: @escaping (Data) -> Void
    ) async throws -> TextTurnResult {
        var req = URLRequest(url: baseURL.appendingPathComponent("text_turn"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String] = [
            "text": text,
            "speaker_hint": speakerHint,
            "session_id": sessionId,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        req.httpBody = bodyData

        // Sign the body with the Keychain-stored shared secret. If no
        // secret is provisioned yet, fail FAST with a user-actionable
        // error — don't bother the server with a guaranteed-401 request.
        guard let secret = VoiceAuthSecret.read() else {
            throw TextTurnError.secretNotProvisioned
        }
        let mac = TextTurnClient.hmacSHA256Hex(secret: secret, bodyBytes: bodyData)
        req.setValue(mac, forHTTPHeaderField: "X-Voice-Auth")

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TextTurnError.badResponse(-1)
        }

        // 401 = HMAC mismatch (or no secret configured server-side).
        // Surface a distinct error so the UI can route the user to the
        // re-paste flow rather than showing a generic "request failed".
        if http.statusCode == 401 {
            // Drain the body to free the connection.
            for try await _ in bytes { }
            throw TextTurnError.authFailed
        }

        // 403 with JSON body = passphrase required. We have to consume the
        // body here ourselves (bytes(for:) doesn't deliver a Data on
        // non-2xx by default — it streams whatever the server sent).
        if http.statusCode == 403 {
            var bodyData = Data()
            for try await b in bytes { bodyData.append(b) }
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let kw = json["matched_keyword"] as? String {
                let preview = (json["preview"] as? String) ?? ""
                let err = NSError(
                    domain: "TextTurn",
                    code: 403,
                    userInfo: [
                        NSLocalizedDescriptionKey: "passphrase required for '\(kw)'",
                        "matchedKeyword": kw,
                        "preview": preview,
                    ]
                )
                throw err
            }
            throw TextTurnError.badResponse(403)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TextTurnError.badResponse(http.statusCode)
        }

        // Reply text is in the X-Reply-Text header (ASCII-clean,
        // length-capped at 512 by the server). The body is raw PCM.
        let replyText = (http.value(forHTTPHeaderField: "X-Reply-Text") ?? "").trimmingCharacters(in: .whitespaces)

        // Stream PCM bytes to caller in ~32ms-equivalent chunks. Kokoro
        // emits 24kHz int16 mono = 48000 bytes/sec, so a 1024-byte chunk
        // is roughly 21ms — small enough to feel streamed, large enough
        // that scheduleBuffer overhead doesn't dominate.
        var pending = Data()
        let flushSize = 1024
        for try await byte in bytes {
            pending.append(byte)
            if pending.count >= flushSize {
                // PCM16 needs even byte alignment.
                let n = pending.count - (pending.count % 2)
                let chunk = pending.prefix(n)
                pending.removeFirst(n)
                onAudioChunk(Data(chunk))
            }
        }
        if !pending.isEmpty {
            let n = pending.count - (pending.count % 2)
            if n > 0 { onAudioChunk(pending.prefix(n)) }
        }

        return TextTurnResult(replyText: replyText)
    }
}
