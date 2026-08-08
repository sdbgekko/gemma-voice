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

    /// Recurring ASR mishears → correct spellings. Ported from the voice-turn
    /// server's ASR_FIXES table (stream_server.py:466-502) so the on-device
    /// STT path gets the SAME corrections the Whisper/WS path has had all
    /// along (2026-08-07 roundtable A3 — which STT path a turn takes should
    /// not decide whether "Sekushi" gets typed correctly). Word-boundary,
    /// case-insensitive; replacement carries the proper casing.
    private static let asrFixes: [(pattern: String, replacement: String)] = [
        // Gemma
        ("\\bjumbo\\b", "Gemma"),
        ("\\bjemma\\b", "Gemma"),
        ("\\bjim\\b", "Gemma"),
        ("\\bgem\\b", "Gemma"),
        ("\\bjomo\\b", "Gemma"),
        ("\\bjoma\\b", "Gemma"),
        ("\\bgimme\\b(?=[\\s,]|$)", "Gemma"),
        ("\\bjumbos\\b", "Gemma's"),
        // Household / agents
        ("\\bsophie\\b", "Sophie"),
        ("\\bsophy\\b", "Sophie"),
        ("\\bmerlin\\b", "Merlin"),
        ("\\bjarvis\\b", "Jarvis"),
        ("\\bjarvus\\b", "Jarvis"),
        ("\\bjavis\\b", "Jarvis"),
        ("\\bkai\\b", "Kai"),
        ("\\bmalia\\b", "Malia"),
        ("\\bmaleah\\b", "Malia"),
        ("\\bkovica\\b", "Kavika"),
        ("\\bkovika\\b", "Kavika"),
        ("\\bkawika\\b", "Kavika"),
        ("\\bkaveeka\\b", "Kavika"),
        ("\\bcavika\\b", "Kavika"),
        ("\\bkavika\\b", "Kavika"),
        ("\\bhachi\\b", "Hachi"),
        // Businesses / projects
        ("\\bsekushi\\b", "Sekushi"),
        ("\\bsecushi\\b", "Sekushi"),
        ("\\bsakushi\\b", "Sekushi"),
        ("\\bscg\\b", "SCG"),
        ("\\baloha voice\\b", "AlohaVoice"),
        ("\\balohavoice\\b", "AlohaVoice"),
        ("\\bbellavino\\b", "Bellavino"),
        ("\\bbella vino\\b", "Bellavino"),
        ("\\bshelfsnap\\b", "ShelfSnap"),
        ("\\bplod\\b", "Plaud"),
        ("\\bklout\\b", "Plaud"),
        ("\\bplaid\\b", "Plaud"),
        ("\\bploud\\b", "Plaud"),
        // Hawaii
        ("\\boahu\\b", "Oahu"),
        // Infra / tools
        ("\\bscholi\\b", "Scally"),
        ("\\bex caliber\\b", "Excalibur"),
        ("\\bexcaliber\\b", "Excalibur"),
        ("\\bwave l m\\b", "WavLM"),
        ("\\bwhisperer\\b", "Whisper"),
        ("\\bpeerakit\\b", "Parakeet"),
        ("\\bparakit\\b", "Parakeet"),
        ("\\bkokaru\\b", "Kokoro"),
        ("\\bkokoro\\b", "Kokoro"),
        ("\\btestflight\\b", "TestFlight"),
        ("\\bx code\\b", "Xcode"),
    ]

    /// Apply the mishear table. Exposed for tests; polish() runs it on every
    /// transcript.
    static func applyASRFixes(_ text: String) -> String {
        var out = text
        for fix in asrFixes {
            out = out.replacingOccurrences(
                of: fix.pattern,
                with: fix.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    /// Apply light polish. Returns "" if the input was empty/whitespace.
    static func polish(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Collapse runs of internal whitespace.
        let collapsedRuns = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        // Fix recurring name mishears (server-parity, see asrFixes above).
        let collapsed = applyASRFixes(collapsedRuns)

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
