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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
