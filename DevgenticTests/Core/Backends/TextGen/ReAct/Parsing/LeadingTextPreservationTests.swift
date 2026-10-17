// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LeadingTextPreservationTests.swift
//  devgenticTests
//
//  Readiness CR-5: a reply that STARTS with non-English text keeps its opening.
//
//  ⚠️ THE DEFECT. `OutputSanitizer.stripLeadingArtifacts` was meant to remove a BOM and garbage
//  bytes, but it dropped EVERY leading scalar outside printable ASCII: "Привет мир" became " мир",
//  "Übersicht" became "bersicht", "✅ Done" lost its emoji — and an all-CJK reply became "", which
//  the cascade reports as `.emptyOutput` and answers with a corrective retry, on every prompted
//  generator, forever. Another member of the content-corruption class: a transform that removed
//  text because of what its bytes looked like.
//

import XCTest
@testable import devgentic

final class LeadingTextPreservationTests: XCTestCase {

    private let tools = ["final_answer", "read_file", "ask_user"].map { TestToolFactory.make(name: $0) }

    private let replies = [
        "Привет мир — вот ответ.",
        "Übersicht: alles erledigt.",
        "✅ Done — the build passes.",
        "好的，答案是四十二。",
        "こんにちは、世界。",
        "مرحبا بالعالم",
        "🚀",
    ]

    // MARK: - The sanitizer

    func testLeadingNonEnglishTextIsKept() {
        for reply in replies {
            XCTAssertEqual(OutputSanitizer.sanitize(reply).cleaned, reply, "the opening was eaten")
        }
    }

    /// The controls — what the strip is FOR still goes.
    func testInvisibleAndGarbageLeadingScalarsAreStillStripped() {
        for junk in ["\u{FEFF}", "\u{0}", "\u{200B}", "\u{2060}", "\u{FFFD}", "\u{1}\u{FEFF}"] {
            XCTAssertEqual(OutputSanitizer.sanitize(junk + "Привет").cleaned, "Привет",
                           "leading \(junk.unicodeScalars.map { String($0.value, radix: 16) }) must still be stripped")
        }
    }

    /// Only LEADING junk is the sanitizer's business; the same scalar inside text is left alone.
    func testOnlyTheLeadingRunIsTouched() {
        let text = "\u{FEFF}a\u{200B}b"
        XCTAssertEqual(OutputSanitizer.sanitize(text).cleaned, "a\u{200B}b")
    }

    // MARK: - The pipeline (where the retry loop came from)

    /// ⚠️⚠️ An all-CJK reply was sanitized to "" and became `.failed(.emptyOutput)` → corrective
    /// retry, on every dialect, every time. It must be an answer with every character intact.
    func testANonEnglishAnswerIsAnAnswerOnEveryDialect() {
        var wrong: [String] = []
        for dialect in ModelDialect.allCases {
            for reply in replies {
                let step = CognitiveParsePipeline(expectedDialect: dialect, registeredTools: tools).parse(raw: reply)
                guard case .genuineCompletion = step.parseOutcome else {
                    wrong.append("\(dialect.rawValue) × \(reply): \(step.parseOutcome)"); continue
                }
                if step.reasoning != reply { wrong.append("\(dialect.rawValue) × \(reply): got '\(step.reasoning)'") }
            }
        }
        XCTAssertTrue(wrong.isEmpty, "non-English answers damaged:\n" + wrong.joined(separator: "\n"))
    }
}
