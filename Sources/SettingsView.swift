import SwiftUI

struct SettingsView: View {
    @Binding var appearance: String
    @AppStorage("earbackVolume") private var earbackVolume: Double = 0.5
    @Environment(\.dismiss) private var dismiss

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
}
