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

import Foundation

final class TextTurnClient: TextTurnClientProtocol {
    /// Tailscale IP of JMM. Same host as the WebSocket. HTTP port 9202.
    static let defaultBase = URL(string: "http://100.80.225.86:9202")!

    enum TextTurnError: Error {
        case badResponse(Int)
        case passphraseRequired(matchedKeyword: String, preview: String)
        case decodeError(String)
        case timeout
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
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TextTurnError.badResponse(-1)
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
