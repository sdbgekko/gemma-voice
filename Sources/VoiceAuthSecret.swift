//
//  VoiceAuthSecret.swift
//  GemmaVoice
//
//  Keychain wrapper for the /text_turn HMAC shared secret (added v0.2.16,
//  voice-turn auth hardening). The secret is generated on the JMM server
//  side and pasted here once via VoiceAuthSetupView; from then on every
//  TextTurnClient request signs its body with HMAC-SHA256(secret, body).
//
//  Why Keychain (not UserDefaults / Info.plist):
//   - UserDefaults is plaintext on disk → trivially extracted from a
//     backup or a jailbroken device.
//   - Info.plist baked at build time means the secret is in every IPA
//     uploaded to TestFlight/App Store Connect; rotating it requires a
//     new build instead of just a paste.
//   - Keychain is hardware-backed on devices with Secure Enclave and
//     stays out of iCloud/iTunes backups (kSecAttrSynchronizable=false,
//     accessible whenAfterFirstUnlock).
//

import Foundation
import Security

enum VoiceAuthSecret {
    /// Service identifier used for the keychain item. Must be unique
    /// within the app's keychain access group.
    private static let service = "com.shermanbrown.gemmavoice.voice-turn-hmac"
    /// Account is just a stable label — we only ever store one secret.
    private static let account = "default"

    /// Read the stored secret, or nil if none has been provisioned yet.
    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Persist a new secret, overwriting any existing one.
    /// Returns true on success.
    @discardableResult
    static func write(_ secret: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Delete any existing entry first — SecItemUpdate would also
        // work but Add+Delete is simpler and the secret rarely changes.
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Belt + suspenders: don't sync to iCloud Keychain. The secret is
        // tied to this physical device + the JMM server's .env.
        addQuery[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Remove the stored secret. Used by Settings "Clear" affordance.
    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Convenience for the UI — show a masked preview without leaking
    /// the full hex value into a screenshot or log.
    static func masked() -> String? {
        guard let s = read(), s.count >= 8 else { return nil }
        let head = s.prefix(4)
        let tail = s.suffix(4)
        return "\(head)…\(tail)  (\(s.count) chars)"
    }
}
