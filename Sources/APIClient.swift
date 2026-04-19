import Foundation

struct VoiceTurnResponse: Decodable {
    let speaker: String?
    let text_you: String
    let text_gemma: String
    let audio_url: String
}

final class APIClient {
    static let shared = APIClient()
    private let endpoint = URL(string: "http://100.80.225.86:9200/voice_turn")!

    func postVoiceTurn(audio: Data, completion: @escaping (Result<VoiceTurnResponse, Error>) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        let boundary = "----GemmaVoiceBoundary\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let b = "--\(boundary)\r\n"
        body.append(b.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"capture.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        request.timeoutInterval = 90

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain: "APIClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "No data"])))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let body = String(data: data, encoding: .utf8) ?? ""
                completion(.failure(NSError(domain: "APIClient", code: http.statusCode,
                                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(VoiceTurnResponse.self, from: data)
                completion(.success(decoded))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
    }
}
