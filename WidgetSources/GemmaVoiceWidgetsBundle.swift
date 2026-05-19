import SwiftUI
import WidgetKit

@main
struct GemmaVoiceWidgetsBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) {
            GemmaVoiceLiveActivity()
        }
    }
}
