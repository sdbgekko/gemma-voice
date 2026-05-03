//
//  TranscriptPostProcessor.swift
//  GemmaVoice
//
//  Light, local, rule-based polish for on-device STT transcripts before
//  they're sent to the LLM. The dispatch was explicit: NO LLM call here,
//  latency matters. Apple's on-device model emits unpunctuated text in
//  most cases; a missing period sometimes confuses the LLM about whether
//  the user is done speaking, and "what time is it" reads better as
//  "What time is it?" in the conversation transcript UI.
//
//  Rules (all cheap):
//    1. trim whitespace
//    2. capitalize the first letter
//    3. collapse runs of internal whitespace to single space
//    4. append "." if the result has no terminal . ! or ?  (heuristic:
//       if the utterance starts with a question word, prefer "?")
//
//  This file replaces the inline `postProcess` stub in
//  OnDeviceConversationSession.swift (which now delegates here).
//

import Foundation

enum TranscriptPostProcessor {
    /// Words that typically indicate a question. Used only to pick "?" vs
    /// "." for the terminal punctuation when none was supplied.
    private static let questionStarters: Set<String> = [
        "what", "where", "when", "why", "who", "whose", "whom",
        "how", "which", "is", "are", "was", "were", "do", "does",
        "did", "can", "could", "will", "would", "should", "may",
        "might", "shall", "have", "has", "had",
    ]

    /// Apply light polish. Returns "" if the input was empty/whitespace.
    static func polish(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Collapse runs of internal whitespace.
        let collapsed = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        // Capitalize first letter without lowering the rest (preserve any
        // proper-noun casing the on-device model already produced).
        let firstUp = collapsed.prefix(1).uppercased() + collapsed.dropFirst()

        // Terminal punctuation? If yes, leave it alone.
        guard let last = firstUp.last else { return firstUp }
        if ".!?".contains(last) { return firstUp }

        // Pick "." vs "?" based on first word.
        let firstWord = firstUp
            .prefix { !$0.isWhitespace }
            .lowercased()
        let terminator = questionStarters.contains(String(firstWord)) ? "?" : "."
        return firstUp + terminator
    }
}
