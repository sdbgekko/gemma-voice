//
//  WhatsNewSheet.swift
//  GemmaVoice
//
//  0.2.61: in-app What's New — auto-presents once per new version so the
//  update story lives inside the app (previously only TestFlight's own
//  notes screen showed it). Crucially, the mic is GATED while this sheet
//  is up: Sherman's 8/26 report was a cough firing a turn underneath the
//  update screen while he was reading. ContentView calls the view model's
//  overlayAppeared()/overlayDismissed() around presentation.
//

import SwiftUI

struct WhatsNewSheet: View {
    let entry: ChangelogEntry
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New")
                        .font(.title2.bold())
                    Text("\(entry.version) · \(entry.date)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "mic.slash.fill")
                    .foregroundColor(.orange)
                    .accessibilityLabel("Microphone paused while this screen is open")
            }
            Text("Mic is paused while you read — nothing you say here becomes a turn.")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(entry.hints.indices, id: \.self) { i in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkle")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                                .padding(.top, 3)
                            Text(entry.hints[i])
                                .font(.subheadline)
                        }
                    }
                }
            }

            Button(action: onDismiss) {
                Text("Got it — start listening")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(20)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(false)
    }
}
