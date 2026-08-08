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
    /// 0.2.44: sourced from Shared/ServerConfig.swift so the widget's /health
    /// poll and the app agree on one host constant.
    static let defaultBase = GemmaVoiceServer.httpBase

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
    /// Picker agent this client routes to (0.2.39). When set, it's sent as the
    /// `agent` field so the server routes the turn to Gemma / Jarvis / Kai — the
    /// HTTP twin of the WebSocket `?agent=` param. nil omits the field, so the
    /// server defaults to Gemma (byte-identical to the old on-device path).
    private let agent: String?

    init(baseURL: URL = TextTurnClient.defaultBase, agent: String? = nil, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.agent = agent
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            // No request timeout — the body streams; resource timeout caps total
            // turn latency so a stuck Kokoro doesn't hang us forever. 175s:
            // the server's own turn timeout is 170s (stream_server.py
            // TURN_TIMEOUT_S, 2026-08-07) — the client must outlive it so the
            // server always gets to answer (or fall back to Jarvis) before we
            // give up. Was 90s, which expired mid-turn on a busy brain.
            cfg.timeoutIntervalForRequest = 175
            cfg.timeoutIntervalForResource = 175
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
        wavBase64: String?,
        onTurnId: @escaping (String) -> Void,
        onAudioChunk: @escaping (Data) -> Void
    ) async throws -> TextTurnResult {
        var req = URLRequest(url: baseURL.appendingPathComponent("text_turn"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: String] = [
            "text": text,
            "speaker_hint": speakerHint,
            "session_id": sessionId,
            // 0.2.44: "simulator"/"device" so sim smoke traffic stops
            // polluting device telemetry (server reads this since tonight's
            // stream_server.py per-turn metrics work).
            "environment": GemmaVoiceServer.environment,
        ]
        // Per-turn speaker verification (0.2.31): the utterance audio as a
        // base64 16kHz mono PCM16 WAV. Optional — the server behaves exactly
        // as before when the field is absent.
        if let wavBase64 {
            payload["wav_base64"] = wavBase64
        }
        // Route this turn to the selected picker agent (0.2.39). Omitted when
        // nil so the server keeps its Gemma default.
        if let agent {
            payload["agent"] = agent
        }
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
        // In sentence-streaming mode the header can't carry the reply (it's
        // sent before the reply text exists), so X-Reply-Text is ABSENT and
        // this is empty — the reply is fetched afterwards via /reply_text
        // keyed on X-Turn-Id below.
        let replyText = (http.value(forHTTPHeaderField: "X-Reply-Text") ?? "").trimmingCharacters(in: .whitespaces)
        // X-Turn-Id: the server-minted request id, present on every response
        // (streaming and classic). Used to fetch the reply text after the
        // audio finishes when X-Reply-Text was absent.
        let turnId = (http.value(forHTTPHeaderField: "X-Turn-Id") ?? "").trimmingCharacters(in: .whitespaces)
        // 0.2.44 redelivery: surface the turn id the moment headers arrive —
        // BEFORE the audio body streams — so the caller can persist it. If the
        // connection dies mid-body, the persisted id is the fetch key that
        // recovers this turn's reply via GET /reply_text.
        if !turnId.isEmpty { onTurnId(turnId) }
        // X-Brain (2026-08-07): the brain that ACTUALLY answered ("gemma" |
        // "jarvis" | "kai"). On a busy-fallback turn this differs from the
        // requested agent — the UI badges the reply with the real source so
        // Jarvis never silently wears Gemma's label.
        let brain = (http.value(forHTTPHeaderField: "X-Brain") ?? "").trimmingCharacters(in: .whitespaces)

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

        return TextTurnResult(replyText: replyText,
                              rid: turnId.isEmpty ? nil : turnId,
                              brain: brain.isEmpty ? nil : brain.lowercased())
    }

    /// Fetch the full reply text for a completed turn from the server's
    /// GET /reply_text?rid=<rid> endpoint. Returns the reply once ready, or
    /// nil if the server reports it isn't ready yet ({"reply": null}) or the
    /// rid is unknown. Read-only, no HMAC — the rid is an opaque server-minted
    /// uuid. Used by the streaming path to backfill the Gemma text card after
    /// the audio has played, since X-Reply-Text was absent on the turn.
    func fetchReplyText(rid: String) async throws -> String? {
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent("reply_text"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        comps.queryItems = [URLQueryItem(name: "rid", value: rid)]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // {"reply": "<text>"} → the string; {"reply": null} → NSNull → nil.
        return json["reply"] as? String
    }
}
