import SwiftUI

struct SettingsView: View {
    @Binding var appearance: String
    @AppStorage("earbackVolume") private var earbackVolume: Double = 0.5
    @AppStorage("useOnDeviceSTT") private var useOnDeviceSTT: Bool = true
    @AppStorage("bargeInEnabled") private var bargeInEnabled: Bool = false
    @State private var onDeviceAuthResult: String? = nil
    @State private var sttTestState: STTTestState = .idle
    @State private var sttTestPartial: String = ""
    @State private var sttTestFinal: String = ""
    @State private var sttTestError: String? = nil
    @Environment(\.dismiss) private var dismiss

    private enum STTTestState { case idle, recording, transcribing, done }

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
    private var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section("Earback Tone") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundColor(.secondary)
                        Slider(value: $earbackVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundColor(.secondary)
                    }
                    Button("Test") {
                        EarbackTone.shared.play()
                    }
                }
                Section("Interaction") {
                    Toggle("Allow interrupting Gemma", isOn: $bargeInEnabled)
                    Text("When ON, speaking over Gemma's reply will cut her off. Currently experimental — may self-trigger from background noise.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Transcription") {
                    Toggle("Use on-device transcription", isOn: $useOnDeviceSTT)
                    Text("When ON, the conversation flow records and transcribes on-device (no audio leaves the phone for STT), then sends the text to the server for the LLM reply. When OFF, audio streams to the server as before.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Check permission") {
                        OnDeviceSTT.shared.requestAuthorizationIfNeeded { granted in
                            let avail = OnDeviceSTT.shared.isAvailable
                            onDeviceAuthResult = granted
                                ? (avail ? "Granted · on-device model ready"
                                         : "Granted · but on-device model unavailable on this device")
                                : "Denied — enable in iOS Settings"
                        }
                    }
                    if let r = onDeviceAuthResult {
                        Text(r).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Test on-device transcription") {
                    Text("Records from the mic and transcribes entirely on-device (no audio leaves the phone). Compare the result against what you said to gauge accuracy versus the server path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: toggleSTTTest) {
                        HStack {
                            Image(systemName: sttTestState == .recording ? "stop.circle.fill" : "mic.circle.fill")
                            Text(sttTestButtonLabel)
                        }
                    }
                    .disabled(sttTestState == .transcribing)
                    if sttTestState == .recording && !sttTestPartial.isEmpty {
                        Text(sttTestPartial).font(.callout).foregroundStyle(.secondary)
                    }
                    if sttTestState == .done && !sttTestFinal.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Transcript").font(.caption).foregroundStyle(.secondary)
                            Text(sttTestFinal).font(.callout)
                        }
                    }
                    if let err = sttTestError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Security") {
                    NavigationLink {
                        VoiceAuthSetupView()
                    } label: {
                        HStack {
                            Image(systemName: "lock.shield")
                            VStack(alignment: .leading) {
                                Text("Voice-turn shared secret")
                                if let masked = VoiceAuthSecret.masked() {
                                    Text(masked).font(.caption.monospaced()).foregroundStyle(.secondary)
                                } else {
                                    Text("Not set — server will reject requests").font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    Text("Required for the on-device transcription path. Without it, /text_turn POSTs are rejected by JMM.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("About") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Build", value: build)
                }

                Section {
                    ForEach(Changelog.entries) { entry in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.version)
                                    .font(.headline)
                                Spacer()
                                Text(entry.date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(entry.hints, id: \.self) { hint in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 7)
                                    Text(hint)
                                        .font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("What's new")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var sttTestButtonLabel: String {
        switch sttTestState {
        case .idle: return "Start recording"
        case .recording: return "Stop"
        case .transcribing: return "Transcribing…"
        case .done: return "Test again"
        }
    }

    private func toggleSTTTest() {
        switch sttTestState {
        case .idle, .done:
            sttTestPartial = ""
            sttTestFinal = ""
            sttTestError = nil
            OnDeviceSTT.shared.requestAuthorizationIfNeeded { granted in
                guard granted else {
                    sttTestError = "Speech Recognition not authorized — enable in iOS Settings"
                    return
                }
                guard OnDeviceSTT.shared.isAvailable else {
                    sttTestError = "On-device speech model unavailable on this device"
                    return
                }
                sttTestState = .recording
                OnDeviceSTT.shared.startLive(
                    onPartial: { partial in
                        Task { @MainActor in sttTestPartial = partial }
                    },
                    onFinal: { result in
                        Task { @MainActor in
                            switch result {
                            case .success(let text):
                                sttTestFinal = text
                            case .failure(let err):
                                sttTestError = String(describing: err)
                            }
                            sttTestState = .done
                        }
                    }
                )
            }
        case .recording:
            sttTestState = .transcribing
            OnDeviceSTT.shared.stopLive()
        case .transcribing:
            break
        }
    }
}
