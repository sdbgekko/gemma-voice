import SwiftUI
import WidgetKit

@main
struct GemmaVoiceWidgetsBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 17.0, *) {
            // 0.2.44: home-screen widget — one tap into gemmavoice://talk.
            GemmaVoiceHomeWidget()
        }
        if #available(iOS 16.2, *) {
            GemmaVoiceLiveActivity()
        }
    }
}
