//
//  VoiceAuthSetupView.swift
//  GemmaVoice
//
//  First-launch / rotation UI for the /text_turn HMAC shared secret.
//  Sherman pastes the 64-char hex string the JMM server printed once on
//  install (or after a rotation). The view writes it via VoiceAuthSecret.
//
//  Why a paste UI instead of baking the secret into the binary
//  (Option A in the dispatch): a build-time secret survives in every
//  IPA uploaded to TestFlight + App Store Connect, so "rotate the
//  shared secret" requires a new release. A pasted secret rotates with
//  one paste — the property the threat model actually wants.
//

import SwiftUI

struct VoiceAuthSetupView: View {
    /// When presented in Settings, dismiss after a save.
    @Environment(\.dismiss) private var dismiss

    /// Mutable input. Hidden behind a SecureField so over-the-shoulder
    /// + screenshot leaks need extra effort.
    @State private var input: String = ""
    @State private var saveError: String? = nil
    @State private var existingMasked: String? = VoiceAuthSecret.masked()
    @State private var showCleared: Bool = false

    /// Optional callback so the caller knows the secret changed and can
    /// retry whatever request previously 401'd.
    var onSaved: (() -> Void)? = nil

    var body: some View {
        Form {
            Section("Voice-turn shared secret") {
                Text("This 64-character hex string lets your phone prove to the voice-turn server that requests came from you and not from a smoke-test scanner. The server printed it once on the JMM Mac. Paste it here. It is stored in iOS Keychain and is never uploaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let masked = existingMasked {
                    LabeledContent("Current") { Text(masked).font(.caption.monospaced()) }
                }

                SecureField("Paste 64-char hex secret", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())

                if let err = saveError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if showCleared {
                    Text("Secret cleared.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Save") { save() }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Clear stored secret", role: .destructive) {
                    VoiceAuthSecret.delete()
                    existingMasked = nil
                    showCleared = true
                }
            }

            Section("Why this exists") {
                Text("Without this, anything reachable on the voice-turn HTTP port could spoof a turn as you and reach Gemma's CLI. With it, /text_turn rejects every request that doesn't carry an HMAC computed with this exact secret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Voice-turn secret")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Soft format check: should be hex-only, 32 bytes = 64 chars.
        // We accept other lengths (rotation may use a longer string) but
        // warn if it doesn't look hex at all.
        let hexCharset = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let invalid = trimmed.unicodeScalars.first { !hexCharset.contains($0) }
        if invalid != nil {
            saveError = "Secret should be hex characters only (0-9, a-f)."
            return
        }
        if trimmed.count < 32 {
            saveError = "Secret looks too short — expected 64 hex chars."
            return
        }
        guard VoiceAuthSecret.write(trimmed) else {
            saveError = "Could not write to Keychain. Try again."
            return
        }
        saveError = nil
        existingMasked = VoiceAuthSecret.masked()
        input = ""
        showCleared = false
        onSaved?()
        dismiss()
    }
}
