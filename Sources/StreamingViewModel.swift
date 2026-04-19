import AVFoundation
import Foundation
import SwiftUI

/// Streaming replacement for ViewModel. Same @Published surface so
/// ContentView is unchanged. All heavy lifting lives on the server over
/// a single WebSocket — Silero VAD decides speech boundaries; mic frames
/// stream up as float32 PCM; Kokoro TTS streams back as int16 PCM chunks
/// that an AVAudioPlayerNode schedules for playback.
@MainActor
final class StreamingViewModel: ObservableObject {
    @Published var transcript: [Turn] = []
    @Published var status: Status = .muted
    @Published var errorMessage: String?
    @Published var currentLevel: Float = 0
    @Published var levelHistory: [Float] = Array(repeating: 0, count: 40)
    @Published var hadSpeechFlag = false
    @Published var lastSendAttempt: Date?
    @Published var lastSendResult: String = "-"

    private var session: StreamingSession?
    private let endpoint: URL
    private let maxTurns = 20
    /// User tapped mute. Stays true until they tap unmute, regardless of
    /// playback state, so the UI doesn't flip colors while TTS plays over
    /// a muted mic.
    private var userMuted = false

    init() {
        // JMM Tailscale IP, streaming server port 9201.
        self.endpoint = URL(string: "ws://100.80.225.86:9201")!
    }

    func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                if granted {
                    self.startSession()
                } else {
                    self.errorMessage = "Microphone permission denied. Enable it in Settings."
                }
            }
        }
    }

    func toggleMute() {
        if userMuted {
            userMuted = false
            session?.unmute()
            status = .listening
        } else {
            userMuted = true
            session?.mute()
            status = .muted
        }
    }

    func forceSend() {
        session?.forceCut()
    }

    private func startSession() {
        if session == nil {
            guard let s = StreamingSession(url: endpoint) else {
                errorMessage = "Could not create audio session."
                return
            }
            s.onEvent = { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            self.session = s
        }
        do {
            try session?.start()
            session?.unmute()
            status = .listening
        } catch {
            errorMessage = "Mic error: \(error.localizedDescription)"
            status = .muted
        }
    }

    private func handle(_ event: StreamingSession.Event) {
        switch event {
        case .level(let level):
            currentLevel = level
            var h = levelHistory
            h.removeFirst()
            h.append(level)
            levelHistory = h
        case .speechStart:
            if userMuted { break }
            if status == .listening { status = .speaking_ }
            hadSpeechFlag = true
        case .speechEnd:
            if userMuted { break }
            status = .thinking
        case .transcriptYou(let text, _):
            if !text.isEmpty {
                appendTurn(text: text, isGemma: false, source: nil)
            }
        case .transcriptGemma(let text, let source):
            if !text.isEmpty {
                appendTurn(text: text, isGemma: true, source: source)
            }
            // Only flip UI to .playing if user isn't muted; mute is sticky.
            if !userMuted { status = .playing }
        case .ttsEnd:
            if userMuted {
                status = .muted
            } else if status == .playing || status == .thinking {
                status = .listening
            }
        case .dropped:
            if userMuted {
                status = .muted
            } else if status == .thinking {
                status = .listening
            }
        case .connectionClosed(let error):
            errorMessage = error.map { "Connection closed: \($0.localizedDescription)" }
                ?? "Connection closed"
            status = .muted
        }
    }

    private func appendTurn(text: String, isGemma: Bool, source: String?) {
        transcript.append(Turn(text: text, isGemma: isGemma, source: source))
        if transcript.count > maxTurns {
            transcript.removeFirst(transcript.count - maxTurns)
        }
    }
}
