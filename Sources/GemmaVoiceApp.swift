import SwiftUI

@main
struct GemmaVoiceApp: App {
    @StateObject private var viewModel = StreamingViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
