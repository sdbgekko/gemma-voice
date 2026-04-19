import AVFoundation
import Foundation
import SwiftUI

struct Turn: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isGemma: Bool
    let timestamp = Date()
}

enum Status {
    case muted
    case listening    // engine running, waiting for speech
    case speaking_    // user is talking (RMS above gate)
    case thinking     // sending to backend
    case playing      // Gemma TTS playing back
}

@MainActor
final class ViewModel: ObservableObject {
    @Published var transcript: [Turn] = []
    @Published var status: Status = .muted
    @Published var errorMessage: String?
    @Published var currentLevel: Float = 0
    @Published var levelHistory: [Float] = Array(repeating: 0, count: 40)
    @Published var hadSpeechFlag = false
    @Published var lastSendAttempt: Date?
    @Published var lastSendResult: String = "-"

    private let recorder = AudioRecorder()
    private let player = AudioPlayer()
    private let maxTurns = 20

    // VAD state.
    private let speechGate: Float = 0.005       // RMS threshold (0..1) for "user is talking"
    private let silenceCutoffMs: Int = 800      // silence duration that ends an utterance
    private let minUtteranceMs: Int = 500       // drop chunks shorter than this
    private let maxUtteranceMs: Int = 30_000    // force-cut runaway utterances
    private var hadSpeech = false
    private var lastSpeechAt: Date?
    private var utteranceStartAt: Date?
    /// Ignore incoming audio levels until this moment — absorbs TTS tail echo.
    private var ttsCooldownUntil: Date = Date(timeIntervalSince1970: 0)
    private var vadTimer: Timer?
    private var coastOutTimer: Timer?

    init() {
        player.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                NSLog("[GemmaVoice] player.onFinish status=\(self.status)")
                // After TTS finishes, return to listening (not muted).
                if self.status == .playing {
                    self.hadSpeech = false
                    self.lastSpeechAt = nil
                    self.utteranceStartAt = nil
                    // 800ms tail cooldown: mic-picked echo of my last words won't
                    // be interpreted as the start of a new user utterance.
                    self.ttsCooldownUntil = Date().addingTimeInterval(0.8)
                    // Cold restart the recorder. Warm resume after TTS playback
                    // has been flaky — the first utterance gets eaten while the
                    // tap reattaches. Full stop+start costs ~100ms but is reliable.
                    _ = self.recorder.stopAndProduceWAV()
                    do {
                        try self.recorder.start()
                        self.status = .listening
                        self.startVADTimer()
                    } catch {
                        NSLog("[GemmaVoice] cold-restart after TTS failed: \(error)")
                        self.status = .muted
                        self.errorMessage = "Mic restart failed: \(error.localizedDescription)"
                    }
                }
            }
        }
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.onAudioLevel(level)
            }
        }
    }

    func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                if granted {
                    self.startListening()
                } else {
                    self.errorMessage = "Microphone permission denied. Enable it in Settings."
                }
            }
        }
    }

    /// Force-cut whatever's in the buffer right now and send it. For debugging VAD.
    func forceSend() {
        guard status == .listening || status == .speaking_ else { return }
        cutAndSend()
    }

    func toggleMute() {
        if status == .muted {
            startListening()
        } else {
            stopListening()
        }
    }

    private func startListening() {
        guard status == .muted else { return }
        do {
            // Always force a cold restart — the warm resume path has been flaky
            // after a mute/unmute cycle. The expensive part is the AVAudioSession
            // reactivation, which is fine for a user-initiated tap.
            _ = recorder.stopAndProduceWAV()
            coastOutTimer?.invalidate(); coastOutTimer = nil
            try recorder.start()
            hadSpeech = false
            lastSpeechAt = nil
            utteranceStartAt = nil
            // If the user muted during TTS playback, ttsCooldownUntil was set to
            // 60s out and onFinish never fired (guarded on status==.playing).
            // Reset it so the mic isn't silently gated after unmute.
            ttsCooldownUntil = Date(timeIntervalSince1970: 0)
            status = .listening
            startVADTimer()
        } catch {
            errorMessage = "Mic error: \(error.localizedDescription)"
            status = .muted
        }
    }

    private func stopListening() {
        // Mute = mic only. Don't touch TTS playback — Gemma's voice keeps playing.
        vadTimer?.invalidate(); vadTimer = nil
        _ = recorder.stopAndProduceWAV()   // full engine stop; unmute will cold-start
        status = .muted
        hadSpeech = false
        lastSpeechAt = nil
        utteranceStartAt = nil
        currentLevel = 0
        // Coast the waveform out: keep scrolling old samples off the right edge
        // until the buffer is fully zeroed. Matches the live tick cadence.
        coastOutTimer?.invalidate()
        coastOutTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }
                guard self.status == .muted else { timer.invalidate(); return }
                var h = self.levelHistory
                h.removeFirst()
                h.append(0)
                self.levelHistory = h
                if h.allSatisfy({ $0 == 0 }) {
                    timer.invalidate()
                }
            }
        }
    }

    private func startVADTimer() {
        vadTimer?.invalidate()
        vadTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.vadTick()
            }
        }
    }

    private func onAudioLevel(_ level: Float) {
        currentLevel = level
        // Roll the history buffer.
        var h = levelHistory
        h.removeFirst()
        h.append(level)
        levelHistory = h
        // Only react during listening/speaking_ state.
        guard status == .listening || status == .speaking_ else { return }
        // TTS cooldown — ignore audio coming in during my speech and for 800ms after.
        if Date() < ttsCooldownUntil {
            recorder.resetBuffer()
            return
        }
        if level >= speechGate {
            if !hadSpeech {
                utteranceStartAt = Date()
            }
            hadSpeech = true
            lastSpeechAt = Date()
            if status == .listening {
                status = .speaking_
            }
        }
    }

    private func vadTick() {
        guard status == .listening || status == .speaking_ else { return }
        guard hadSpeech, let lastSpeech = lastSpeechAt, let started = utteranceStartAt else { return }

        let sinceLastSpeechMs = Int(Date().timeIntervalSince(lastSpeech) * 1000)
        let utterLenMs = Int(Date().timeIntervalSince(started) * 1000)

        if sinceLastSpeechMs >= silenceCutoffMs || utterLenMs >= maxUtteranceMs {
            if utterLenMs < minUtteranceMs {
                // too short, reset
                recorder.resetBuffer()
                hadSpeech = false
                lastSpeechAt = nil
                utteranceStartAt = nil
                status = .listening
                return
            }
            cutAndSend()
        }
    }

    private func cutAndSend() {
        guard let wav = recorder.snapshotAndReset() else {
            hadSpeech = false
            lastSpeechAt = nil
            utteranceStartAt = nil
            status = .listening
            return
        }
        hadSpeech = false
        lastSpeechAt = nil
        utteranceStartAt = nil
        status = .thinking
        vadTimer?.invalidate(); vadTimer = nil

        APIClient.shared.postVoiceTurn(audio: wav) { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success(let response):
                    if response.text_you.isEmpty, response.text_gemma.isEmpty {
                        // Dropped by speaker filter — silently resume listening.
                        self.resumeListening()
                        return
                    }
                    self.appendTurn(text: response.text_you, isGemma: false)
                    self.appendTurn(text: response.text_gemma, isGemma: true)
                    self.playResponseAudio(urlString: response.audio_url)
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    self.resumeListening()
                }
            }
        }
    }

    private func playResponseAudio(urlString: String) {
        guard let url = URL(string: urlString) else {
            resumeListening()
            return
        }
        status = .playing
        // While speaking + 800ms tail, ignore any audio the mic picks up.
        ttsCooldownUntil = Date().addingTimeInterval(60)    // big upper bound; onFinish clamps it
        player.play(url: url) { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error {
                    self.errorMessage = "Playback: \(error.localizedDescription)"
                    self.resumeListening()
                }
            }
        }
    }

    private func resumeListening() {
        guard status != .muted else { return }
        recorder.resetBuffer()
        hadSpeech = false
        lastSpeechAt = nil
        utteranceStartAt = nil
        status = .listening
        startVADTimer()
    }

    private func appendTurn(text: String, isGemma: Bool) {
        transcript.append(Turn(text: text, isGemma: isGemma))
        if transcript.count > maxTurns {
            transcript.removeFirst(transcript.count - maxTurns)
        }
    }
}
