//
//  VoiceEnrollmentView.swift
//  GemmaVoice
//
//  In-app voice enrollment (v0.2.30). Settings → Voice Enrollment →
//  pick who's enrolling → 8 guided clips (tap-to-record, 3–6s each,
//  re-record allowed) → upload to the voice-turn server's /enroll_voice
//  (VoiceEnrollClient), which forwards to the KPC WavLM voiceprint
//  service. The app only captures + uploads; voiceprints live on the
//  home server, never on the phone.
//
//  Mic ownership: enrollment records with its own AudioRecorder (the
//  same 16kHz mono PCM16 WAV capture class the push-to-talk path uses),
//  which needs the mic to itself. The live conversation session is
//  STOPPED for as long as this screen is open (onAppear →
//  StreamingViewModel.beginEnrollment) and restarted when it closes
//  (onDisappear → endEnrollment) if it was running before.
//

import SwiftUI

// MARK: - Model

@MainActor
final class VoiceEnrollmentModel: ObservableObject {
    enum Step: Equatable {
        case name        // who is enrolling
        case capture     // recording the 8 clips
        case uploading   // POSTing clips one by one
        case done        // all clips accepted
        case failed      // an upload failed — retry resumes where it stopped
    }

    /// The 8 guided prompts. Variety on purpose: normal query, question,
    /// loud, quiet, far-field, noisy, and two free-talk — so the WavLM
    /// references cover the conditions the speaker gate will see live.
    static let prompts: [String] = [
        "Say: “Hey Gemma, what's the weather like today?”",
        "Ask any question — whatever comes to mind.",
        "Say something with excitement!",
        "Say something quietly.",
        "From across the room: say anything.",
        "With the TV or some noise on: say anything.",
        "Free talk: tell Gemma about your day.",
        "Free talk: say whatever you like.",
    ]

    static let minClipSeconds: Double = 3
    static let maxClipSeconds: Double = 6

    @Published var step: Step = .name
    /// Display name as tapped/typed ("Andrea"). The wire id is
    /// `speakerId` (lowercased).
    @Published var displayName: String = ""
    @Published var customName: String = ""

    // Capture state
    @Published var clipIndex: Int = 0          // 0-based into prompts
    @Published var isRecording = false
    @Published var elapsed: Double = 0
    @Published var levelHistory: [Float] = Array(repeating: 0, count: 40)
    /// Length of the just-recorded (not yet accepted) clip, nil if none.
    @Published var pendingClipSeconds: Double?
    @Published var recordError: String?

    // Upload state
    @Published var uploadedCount = 0
    @Published var uploadError: String?
    @Published var serverRefCount = 0

    private var finishedClips: [Data] = []     // accepted WAVs, in prompt order
    private var pendingClip: Data?
    private let recorder = AudioRecorder()
    private let client = VoiceEnrollClient()
    private var tickTimer: Timer?
    private var recordingStartedAt: Date?

    var clipCount: Int { Self.prompts.count }
    var currentPrompt: String { Self.prompts[min(clipIndex, clipCount - 1)] }
    var isLastClip: Bool { clipIndex == clipCount - 1 }
    var speakerId: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Name step

    func choose(name: String) {
        displayName = name
        step = .capture
    }

    // MARK: Capture step

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recordError = nil
        pendingClip = nil
        pendingClipSeconds = nil
        do {
            recorder.onLevel = { [weak self] level in
                Task { @MainActor in self?.pushLevel(level) }
            }
            try recorder.start()
        } catch {
            recordError = "Mic error: \(error.localizedDescription)"
            return
        }
        isRecording = true
        elapsed = 0
        recordingStartedAt = Date()
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isRecording, let startedAt = recordingStartedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Self.maxClipSeconds {
            stopRecording()   // auto-stop at 6s
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        tickTimer?.invalidate()
        tickTimer = nil
        isRecording = false
        levelHistory = Array(repeating: 0, count: 40)
        guard let wav = recorder.stopAndProduceWAV() else {
            recordError = "Nothing was recorded — try again."
            return
        }
        // Actual audio length from the WAV payload (16kHz mono PCM16,
        // 44-byte header): more honest than the wall-clock timer.
        let seconds = Double(max(0, wav.count - 44)) / 2.0 / 16_000.0
        if seconds < Self.minClipSeconds {
            recordError = "Too short — keep talking for at least \(Int(Self.minClipSeconds)) seconds."
            return
        }
        pendingClip = wav
        pendingClipSeconds = seconds
    }

    func reRecord() {
        pendingClip = nil
        pendingClipSeconds = nil
        recordError = nil
    }

    func acceptClipAndAdvance() {
        guard let wav = pendingClip else { return }
        finishedClips.append(wav)
        pendingClip = nil
        pendingClipSeconds = nil
        recordError = nil
        if finishedClips.count == clipCount {
            startUpload()
        } else {
            clipIndex += 1
        }
    }

    /// Stop the mic if the user backs out mid-recording. Safe to call anytime.
    func abortCapture() {
        tickTimer?.invalidate()
        tickTimer = nil
        if isRecording {
            isRecording = false
            _ = recorder.stopAndProduceWAV()   // discard
        }
    }

    private func pushLevel(_ level: Float) {
        guard isRecording else { return }
        var h = levelHistory
        h.removeFirst()
        h.append(level)
        levelHistory = h
    }

    // MARK: Upload step

    /// Upload clips sequentially starting from `uploadedCount`, so a retry
    /// after a failure resumes with the first clip the server hasn't taken.
    func startUpload() {
        step = .uploading
        uploadError = nil
        let clips = finishedClips
        let id = speakerId
        Task { [weak self] in
            guard let self else { return }
            var index = self.uploadedCount
            while index < clips.count {
                do {
                    let refs = try await self.client.uploadClip(
                        wav: clips[index],
                        speakerId: id,
                        clipIndex: index + 1,      // wire indices are 1-based
                        clipCount: clips.count
                    )
                    index += 1
                    self.uploadedCount = index
                    self.serverRefCount = refs
                } catch {
                    self.uploadError = Self.friendly(error)
                    self.step = .failed
                    return
                }
            }
            self.step = .done
        }
    }

    private static func friendly(_ error: Error) -> String {
        if let e = error as? VoiceEnrollClient.EnrollError {
            return e.errorDescription ?? "Upload failed."
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "Couldn't reach the voice server — check the home network or Tailscale, then retry."
        }
        return error.localizedDescription
    }
}

// MARK: - View

struct VoiceEnrollmentView: View {
    @EnvironmentObject var viewModel: StreamingViewModel
    @StateObject private var model = VoiceEnrollmentModel()
    @Environment(\.dismiss) private var dismiss

    private static let presetNames = ["Sherman", "Andrea", "Kavika"]

    var body: some View {
        Group {
            switch model.step {
            case .name:      nameStep
            case .capture:   captureStep
            case .uploading: uploadingStep
            case .done:      doneStep
            case .failed:    failedStep
            }
        }
        .navigationTitle("Voice Enrollment")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Enrollment owns the mic: park the live conversation session
            // while this screen is open.
            viewModel.beginEnrollment()
        }
        .onDisappear {
            model.abortCapture()
            viewModel.endEnrollment()
        }
    }

    // MARK: Step 1 — who's enrolling

    private var nameStep: some View {
        Form {
            Section {
                Text("Record 8 short clips so Gemma can learn this voice. Voiceprints are stored on the home server, not on this phone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Who is enrolling?") {
                ForEach(Self.presetNames, id: \.self) { name in
                    Button(action: { model.choose(name: name) }) {
                        HStack {
                            Image(systemName: "person.fill")
                                .foregroundColor(Color.gemmaMicBlue)
                            Text(name)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Someone else") {
                TextField("Name", text: $model.customName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button("Continue") {
                    model.choose(name: model.customName)
                }
                .disabled(model.customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: Step 2 — guided capture

    private var captureStep: some View {
        VStack(spacing: 16) {
            // Progress: "Clip 3 of 8" + dots for at-a-glance position.
            VStack(spacing: 6) {
                Text("Clip \(model.clipIndex + 1) of \(model.clipCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(0..<model.clipCount, id: \.self) { i in
                        Circle()
                            .fill(i < model.clipIndex ? Color.gemmaMicBlue
                                  : (i == model.clipIndex ? Color.gemmaMicBlue.opacity(0.45)
                                                          : Color(.systemGray4)))
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .padding(.top, 12)

            // The prompt card.
            VStack(spacing: 8) {
                Text(model.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.currentPrompt)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(14)
            .padding(.horizontal, 16)

            Spacer()

            // Live level while recording — same waveform language as the dock.
            WaveformView(samples: model.levelHistory, active: model.isRecording)
                .frame(height: 40)
                .padding(.horizontal, 40)

            if model.isRecording {
                Text(String(format: "%.1fs — recording stops at %.0fs",
                            model.elapsed, VoiceEnrollmentModel.maxClipSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let secs = model.pendingClipSeconds {
                Text(String(format: "Recorded %.1fs", secs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Aim for 3–6 seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let err = model.recordError {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Controls: record/stop, or re-record + next once a clip is held.
            if model.pendingClipSeconds == nil {
                recordButton
            } else {
                HStack(spacing: 12) {
                    Button(action: { model.reRecord() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Re-record").font(.headline)
                        }
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                    Button(action: { model.acceptClipAndAdvance() }) {
                        HStack(spacing: 8) {
                            Image(systemName: model.isLastClip ? "icloud.and.arrow.up" : "arrow.right")
                            Text(model.isLastClip ? "Upload" : "Next").font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.gemmaMicBlue)
                        .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 16)
    }

    private var recordButton: some View {
        Button(action: { model.toggleRecording() }) {
            HStack(spacing: 8) {
                Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                Text(model.isRecording ? "Tap to stop" : "Tap to record")
                    .font(.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(model.isRecording ? Color.red : Color.gemmaMicBlue)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: Step 3 — upload

    private var uploadingStep: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: Double(model.uploadedCount), total: Double(model.clipCount))
                .padding(.horizontal, 40)
            Text("Uploading clip \(min(model.uploadedCount + 1, model.clipCount)) of \(model.clipCount)…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Step 4 — done / failed

    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(Color(hex: "#22D67A"))
            Text("\(model.displayName) enrolled — \(model.clipCount) clips")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if model.serverRefCount > 0 {
                Text("The voice server now holds \(model.serverRefCount) reference clips for “\(model.speakerId)”.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Text("Done").font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.gemmaMicBlue)
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var failedStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text(model.uploadError ?? "Upload failed.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text("\(model.uploadedCount) of \(model.clipCount) clips made it — retrying picks up from there. Your recordings are kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            Button(action: { model.startUpload() }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry upload").font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.gemmaMicBlue)
                .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}
