import AVFoundation
import Foundation

final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    func play(data: Data) throws {
        try configureSession()
        player = try AVAudioPlayer(data: data)
        player?.delegate = self
        player?.volume = 1.0
        player?.prepareToPlay()
        player?.play()
    }

    func play(url: URL, completion: @escaping (Error?) -> Void) {
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { completion(error) }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(NSError(domain: "AudioPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio data"]))
                }
                return
            }
            DispatchQueue.main.async {
                do {
                    try self.play(data: data)
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
        task.resume()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // If the recorder already activated the session as playAndRecord/.voiceChat,
        // don't clobber it — just ensure it's active. Only set the category fresh
        // when nothing has activated a session yet (standalone playback).
        if session.category != .playAndRecord {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
        try session.setActive(true, options: [])
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
