import SwiftUI

@main
struct GemmaVoiceApp: App {
    @StateObject private var viewModel = StreamingViewModel()

    init() {
        // v0.2.16: rename AppStorage("onDeviceSTTFallback") -> "useOnDeviceSTT".
        // One-time migration: if the new key has never been written AND the
        // old key exists, carry the value forward. Old key is left in place
        // so a downgrade still has its preference. Idempotent across launches.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "useOnDeviceSTT") == nil,
           let legacy = defaults.object(forKey: "onDeviceSTTFallback") as? Bool {
            defaults.set(legacy, forKey: "useOnDeviceSTT")
        }
        // P0-4: SettingsView's @AppStorage defaults useOnDeviceSTT to true, but
        // StreamingViewModel reads UserDefaults.bool(forKey:) which returns false
        // when the key was never written — so Settings lied about the active STT
        // path on a fresh install. Register the true default so the registration
        // domain backs bool(forKey:) and both agree. Runs AFTER the legacy
        // migration above so `object(forKey:) == nil` still detects unwritten keys.
        defaults.register(defaults: ["useOnDeviceSTT": true])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
