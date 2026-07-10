//
//  VoiceEnrollClient.swift
//  GemmaVoice
//
//  HTTP client for the voice-turn server's POST /enroll_voice endpoint
//  (voice enrollment, v0.2.30). Uploads one 16kHz mono PCM16 WAV clip at
//  a time; the server forwards it to the KPC WavLM voiceprint service and
//  stores the resulting reference embedding for the speaker.
//
//  Contract (server built in parallel — keep in sync):
//    POST http://<voice-turn host>:9202/enroll_voice
//    Body (JSON): {
//      "speaker_id": "andrea",        // lowercase id
//      "clip_index": 3,               // 1-based position of this clip
//      "clip_count": 8,               // total clips in this enrollment
//      "wav_base64": "<base64 of the complete WAV file bytes>"
//    }
//    Auth: X-Voice-Auth = hex(HMAC-SHA256(secret, raw_body_bytes)) — the
//    same header scheme and Keychain secret as /text_turn; we reuse
//    TextTurnClient.hmacSHA256Hex + VoiceAuthSecret directly.
//    Response: {"ok":true,"enrolled":"andrea","n_refs":N}
//           or {"error":"<human-readable reason>"} (e.g. the voiceprint
//              server is asleep).
//

import Foundation

struct VoiceEnrollClient {
    enum EnrollError: LocalizedError {
        /// No HMAC secret in Keychain — same provisioning gap as /text_turn.
        case secretNotProvisioned
        /// Server answered with {"error": "..."} — surface its text plainly.
        case server(String)
        /// Non-2xx without a parseable error body.
        case badStatus(Int)
        /// Response body wasn't the JSON we expect.
        case badPayload

        var errorDescription: String? {
            switch self {
            case .secretNotProvisioned:
                return "Voice-turn secret not set — open Settings → Security and paste it first."
            case .server(let msg):
                return msg
            case .badStatus(let code):
                return "The voice server answered with an error (HTTP \(code)) — try again in a minute."
            case .badPayload:
                return "The voice server sent an unexpected reply — try again in a minute."
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = TextTurnClient.defaultBase, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            // A clip is ≤6s of 16kHz PCM16 (~192KB → ~256KB base64); 30s is
            // generous even over a slow Tailscale hop.
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Upload one enrollment clip. Returns the server's total reference
    /// count (`n_refs`) for the speaker after this clip.
    func uploadClip(
        wav: Data,
        speakerId: String,
        clipIndex: Int,
        clipCount: Int
    ) async throws -> Int {
        var req = URLRequest(url: baseURL.appendingPathComponent("enroll_voice"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "speaker_id": speakerId,
            "clip_index": clipIndex,
            "clip_count": clipCount,
            "wav_base64": wav.base64EncodedString(),
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        req.httpBody = bodyData

        // Same fail-fast as TextTurnClient: no secret → don't bother the
        // server with a guaranteed-401.
        guard let secret = VoiceAuthSecret.read() else {
            throw EnrollError.secretNotProvisioned
        }
        req.setValue(
            TextTurnClient.hmacSHA256Hex(secret: secret, bodyBytes: bodyData),
            forHTTPHeaderField: "X-Voice-Auth"
        )

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw EnrollError.badStatus(-1)
        }

        // The server reports failures as {"error": "..."} — sometimes with a
        // 200, sometimes with a 4xx/5xx. Check the body first either way so
        // the user sees the server's own words ("the voice server is asleep…").
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let errMsg = json?["error"] as? String {
            throw EnrollError.server(errMsg)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw EnrollError.badStatus(http.statusCode)
        }
        guard let json, (json["ok"] as? Bool) == true else {
            throw EnrollError.badPayload
        }
        return (json["n_refs"] as? Int) ?? clipIndex
    }
}
