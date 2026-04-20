import SwiftUI

@main
struct GemmaVoiceWatchApp: App {
    @StateObject private var model = WatchTranscriptModel()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(model)
        }
    }
}
