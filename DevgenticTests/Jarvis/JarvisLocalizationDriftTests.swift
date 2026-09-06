//
//  JarvisLocalizationDriftTests.swift
//  DevgenticTests
//
//  Keeps the Jarvis surface from drifting back to half-translated.
//
//  ⚠️ WHY THE DRIFT HAPPENED, because it explains what these scan for. SwiftUI localizes string
//  LITERALS for free — `Text("STANDBY")`, `Button("Retry Voice")` and `.help("Switch profile")` all
//  take a `LocalizedStringKey` and land in the String Catalogue with no ceremony. But every one of
//  those APIs also has a `StringProtocol` overload, and passing a `String` variable silently selects
//  it. So routing the same words through a `String`-returning property — `statusText`, `orbTooltip`
//  — opted them out of localization with no warning, no error and nothing to see at the call site.
//  That is how one subsystem ended up with `JarvisRunNarration` fully translated and the orb's own
//  status label not, in the same session.
//
//  ⚠️ WHAT IS DELIBERATELY *NOT* LOCALIZED, so a future reader does not "fix" it:
//   • Wake-word variants, cancel phrases, voice commands and approval keywords. These are matched
//     against ASR output, not shown to anyone. `wakeWordCanMatch(language:)` already documents that
//     a non-English recognizer cannot produce a match — translating the vocabulary would not fix
//     that and would break the English path.
//   • `spokenStyleHint`. It is a prompt to the MODEL, not a sentence for the user.
//   • Log strings. They are for whoever is reading a device log, and that is not the end user.
//

import XCTest
@testable import devgentic

final class JarvisLocalizationDriftTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/DevgenticTests/Jarvis/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = repoRoot.appendingPathComponent("Devgentic/Jarvis/\(name).swift")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("\(name).swift not reachable from \(repoRoot.path) — running outside a checkout")
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The body of a `switch`-style computed property, so a scan stays inside it.
    private func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    }") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    // MARK: - Spoken output

    /// ⚠️ Everything Jarvis SAYS goes through these two calls. A raw literal at either is a phrase
    /// the user hears in English regardless of their language — and it is invisible, because the
    /// code reads identically to the localized form.
    func testNothingIsSpokenFromARawLiteral() throws {
        let source = try source("JarvisSessionController")
        for call in ["speakWithWatchdog(\"", "voice.speak(\""] {
            XCTAssertFalse(source.contains(call),
                           "A raw literal is spoken at `\(call)…` — wrap it in String(localized:).")
        }
    }

    /// The outcome phrases are the ONLY thing a voice-only user hears about how a run ended, so
    /// they are the least acceptable place to fall back to English.
    func testTheOutcomeAnnouncementsAreLocalized() throws {
        let source = try source("JarvisSessionController")
        guard let announcement = body(of: "static func announcement(for outcome: ExecutionOutcome?, reason: String?) -> String {",
                                      in: source) else {
            return XCTFail("could not locate announcement(for:reason:) — re-point this test rather than deleting it")
        }
        let bareReturns = announcement
            .split(separator: "\n")
            .filter { $0.contains("return \"") }
        XCTAssertTrue(bareReturns.isEmpty,
                      "Un-localized outcome phrase(s): \(bareReturns.map { $0.trimmingCharacters(in: .whitespaces) })")
    }

    // MARK: - The orb's visible surface

    /// ⚠️ THE EXACT TRAP. `Text(statusText)` takes a `String`, which is the non-localizing
    /// initializer — so these words are only translated if they are localized HERE. Written as
    /// `Text("STANDBY")` they would have been free; as a `String` property they are opt-in.
    func testTheStatusCapsuleIsLocalized() throws {
        let source = try source("JarvisFloatingView")
        guard let statusText = body(of: "private var statusText: String {", in: source) else {
            return XCTFail("could not locate statusText")
        }
        XCTAssertFalse(statusText.contains("return \""),
                       "statusText returns a raw literal; Text(String) will not translate it.")
        XCTAssertTrue(statusText.contains("String(localized:"), "statusText should localize its labels")
    }

    /// The tooltip is the only text in orb mode, and in `.voiceUnavailable` it is the only place
    /// the failure is explained at all.
    func testTheOrbTooltipIsLocalized() throws {
        let source = try source("JarvisFloatingView")
        guard let tooltip = body(of: "private var orbTooltip: String {", in: source) else {
            return XCTFail("could not locate orbTooltip")
        }
        // The `.voiceUnavailable(let reason)` arm forwards an already-localized sentence.
        let bare = tooltip
            .split(separator: "\n")
            .filter { $0.contains("return \"") }
        XCTAssertTrue(bare.isEmpty,
                      "Un-localized tooltip(s): \(bare.map { $0.trimmingCharacters(in: .whitespaces) })")
    }

    /// ⚠️ Both `.help` and `.accessibilityLabel` have a non-localizing `StringProtocol` overload,
    /// so a `String` property silently opts a label out. The type is the guard.
    func testTheBubbleButtonLabelCannotSilentlyOptOut() throws {
        let source = try source("JarvisFloatingView")
        XCTAssertTrue(source.contains("let help: LocalizedStringKey"),
                      "JarvisBubbleButton.help must be a LocalizedStringKey — a String selects the non-localizing overload of .help and .accessibilityLabel.")
    }

    // MARK: - The deliberate exclusions

    /// ⚠️ These must stay untranslated, and the reason is not laziness: they are compared against
    /// what the speech recognizer produced, not shown to anyone. A localized wake word would tell
    /// the user to say a word that can never match.
    func testTheMatchingVocabulariesAreNotLocalized() throws {
        let source = try source("JarvisSessionController")
        for vocabulary in ["wakeWordVariants", "cancelPhrases", "repeatPhrases",
                           "tellMeMorePhrases", "newConversationPhrases"] {
            guard let line = source.split(separator: "\n").first(where: { $0.contains("let \(vocabulary)") }) else {
                continue   // renamed or moved; the other tests still cover the visible surface
            }
            XCTAssertFalse(line.contains("String(localized:"),
                           "\(vocabulary) is matched against ASR output — localizing it breaks matching without helping anyone.")
        }
    }

    /// The style hint instructs the model, not the user.
    func testTheModelPromptIsNotLocalized() throws {
        let source = try source("JarvisSessionController")
        guard let hint = body(of: "static func spokenStyleHint(for mode: JarvisSpokenResponses) -> String {",
                              in: source) else { return }
        XCTAssertFalse(hint.contains("String(localized:"),
                       "spokenStyleHint is a prompt to the model; localizing it changes what the model is asked for, not what the user reads.")
    }
}
