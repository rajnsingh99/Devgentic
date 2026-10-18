// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DialectCorrectiveAlertTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class DialectCorrectiveAlertTests: XCTestCase {

    // MARK: - 1. Policy

    /// The load-bearing property, stated once: for every dialect, the corrective names THAT
    /// dialect's shape.
    ///
    /// ⚠️ Written from the invariant, not from the strings. It asserts the corrective contains
    /// `dialect.formatReminder` — whatever that text is — so correcting a dialect's documented
    /// shape does not fail this test, while routing a dialect to the WRONG shape does. Asserting
    /// the literals instead would have to be rewritten every time a format was corrected, and
    /// would have happily gone green on the defect if the literals were transcribed from it.
    func testEveryDialectIsToldItsOwnFormat() {
        for dialect in ModelDialect.allCases {
            let alert = LLMRetryStrategy.correctiveAlert(dialect: dialect, attempt: 1, maxAttempts: 3)
            XCTAssertTrue(
                alert.contains(dialect.formatReminder),
                "\(dialect.rawValue) must be told its own format. Got: \(alert)"
            )
        }
    }

    /// ⚠️ THE ASSERTION THAT MATTERS MOST, and the one that fails on the old code.
    ///
    /// No dialect may be handed the `.nativeJSON` prescription unless it IS a JSON dialect. The
    /// old single string failed this for 16 of 18 cases. `toolCalls` is the discriminator because
    /// it is the key unique to our own `{reasoning, toolCalls}` envelope — `arguments` and `name`
    /// appear legitimately in most families' shapes, so testing for those would be vacuous.
    func testNonJSONDialectsAreNeverToldToEmitTheNativeJSONEnvelope() {
        let jsonEnvelopeDialects: Set<ModelDialect> = [.nativeJSON, .heuristicJson]

        for dialect in ModelDialect.allCases where !jsonEnvelopeDialects.contains(dialect) {
            let alert = LLMRetryStrategy.correctiveAlert(dialect: dialect, attempt: 1, maxAttempts: 3)
            XCTAssertFalse(
                alert.contains("toolCalls"),
                "\(dialect.rawValue) was told to emit the nativeJSON envelope — the exact defect "
                + "this test exists for. Its parser cannot read that. Got: \(alert)"
            )
        }
    }

    /// The inverse, so a fix that simply deleted all format guidance cannot pass the test above.
    func testJSONDialectsAreStillToldTheJSONEnvelope() {
        for dialect in [ModelDialect.nativeJSON, .heuristicJson] {
            let alert = LLMRetryStrategy.correctiveAlert(dialect: dialect, attempt: 1, maxAttempts: 3)
            XCTAssertTrue(alert.contains("toolCalls"),
                          "\(dialect.rawValue) genuinely uses this envelope: \(alert)")
        }
    }

    /// ⚠️ The two formats whose requirement the old text stated backwards. Both put their
    /// arguments INSIDE a ```json fence, and the old corrective's closing sentence was
    /// "No prose or markdown fences (```json)" — an instruction to break them.
    func testFenceRequiringDialectsAreNotToldToDropTheFence() {
        for dialect in [ModelDialect.deepseekV3JsonFence, .commandRAction] {
            let alert = LLMRetryStrategy.correctiveAlert(dialect: dialect, attempt: 1, maxAttempts: 3)
            XCTAssertFalse(
                alert.localizedCaseInsensitiveContains("no prose or markdown fences"),
                "\(dialect.rawValue) REQUIRES a ```json fence; forbidding it breaks the format: \(alert)"
            )
            XCTAssertTrue(alert.contains("json"),
                          "\(dialect.rawValue) should still see its fence in the reminder: \(alert)")
        }
    }

    /// A transport-native run has no text dialect — the tool call rides in the protocol. Saying
    /// anything about text shape there is noise the model cannot act on.
    func testNativeFlowIsGivenNoTextFormatAtAll() {
        let alert = LLMRetryStrategy.correctiveAlert(dialect: nil, attempt: 2, maxAttempts: 3)

        XCTAssertFalse(alert.contains("toolCalls"), "native flows must not be sent a text envelope: \(alert)")
        XCTAssertFalse(alert.contains("["), "native flows must not be sent a marker shape: \(alert)")
        XCTAssertTrue(alert.contains("native tool-calling API"), "it should name what IS true: \(alert)")
        XCTAssertTrue(alert.contains("2/3"), "the attempt counter survives: \(alert)")
    }

    /// Every corrective leaves the model an exit. A model that has finished but cannot express it
    /// in the expected shape needs `final_answer`, not another reformatting lesson.
    func testEveryCorrectiveOffersTheTerminator() {
        var alerts = ModelDialect.allCases.map {
            LLMRetryStrategy.correctiveAlert(dialect: $0, attempt: 1, maxAttempts: 3)
        }
        alerts.append(LLMRetryStrategy.correctiveAlert(dialect: nil, attempt: 1, maxAttempts: 3))

        for alert in alerts {
            XCTAssertTrue(alert.contains("final_answer"), "no exit offered: \(alert)")
        }
    }

    /// Distinctness — proves the switch actually branches rather than returning one string with a
    /// dialect name interpolated into it, which would satisfy `testEveryDialectIsToldItsOwnFormat`
    /// while re-creating the defect.
    func testDialectsWithDifferentWireFormatsGetDifferentCorrectives() {
        let alerts = ModelDialect.allCases.map {
            LLMRetryStrategy.correctiveAlert(dialect: $0, attempt: 1, maxAttempts: 3)
        }
        // Qwen/Hermes and Granite 4 share a shape deliberately (ParserFactory routes both to
        // QwenHermesJsonParser), as do nativeJSON and heuristicJson — so expect 2 collisions.
        XCTAssertEqual(Set(alerts).count, ModelDialect.allCases.count - 2,
                       "each distinct wire format needs its own corrective")
    }

    // MARK: - 2. Structure

    /// ⚠️ DRIFT TEST over real source. The corrective is only correct if the dialect a generator
    /// DECLARES is the dialect it PARSES with — otherwise we would name one format and read
    /// another, which is the defect wearing a different hat.
    ///
    /// Anchored on structure, not on values: it asserts no generator passes a dialect *literal*
    /// to `CognitiveParsePipeline`. A literal is how the two drift apart; referencing the declared
    /// property makes them one value and cannot. Asserting the literals themselves would go green
    /// on a generator that declared `.mistralXML` and parsed `.reactMarkdown`.
    func testGeneratorsParseWithTheDialectTheyDeclare() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let strategies = repoRoot
            .appendingPathComponent("Devgentic/Core/Backends/TextGen/ReAct/Generation/Strategies")

        guard FileManager.default.fileExists(atPath: strategies.path) else {
            throw XCTSkip("source not reachable — running outside a checkout")
        }

        let files = try FileManager.default
            .contentsOfDirectory(at: strategies, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 6, "expected the generator strategies to be here")

        // Scan only the `CognitiveParsePipeline(…)` construction in each file — the site where the
        // dialect is USED. A dialect literal inside a `static func` factory is where the value is
        // CHOSEN and is correct there, so anchoring on the pipeline call rather than on every
        // `expectedDialect:` line is what keeps this precise instead of heuristic.
        var checkedCallSites = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")

            guard let start = lines.firstIndex(where: { $0.contains("CognitiveParsePipeline(") }) else {
                continue  // NativeStructuredGenerator uses NativeParsePipeline — no text dialect.
            }
            let argument = lines[start...]
                .prefix(while: { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(")") })
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("expectedDialect:") })

            let arg = try XCTUnwrap(argument,
                                    "\(file.lastPathComponent): CognitiveParsePipeline built with no expectedDialect:")
            checkedCallSites += 1
            XCTAssertFalse(
                arg.contains("expectedDialect: ."),
                "\(file.lastPathComponent): parses with a dialect LITERAL (`\(arg.trimmingCharacters(in: .whitespaces))`). "
                + "It must parse with the dialect it DECLARES, or the corrective can name a format "
                + "this generator does not read back."
            )
        }
        XCTAssertGreaterThanOrEqual(checkedCallSites, 5,
                                    "the scan matched too few generators — it would pass vacuously")
    }

    /// Every prompted generator declares a dialect; every native one declares none. This is what
    /// makes `nil` mean "native", which the corrective relies on.
    func testPromptedGeneratorsDeclareADialectAndNativeDoesNot() {
        XCTAssertNil(NativeStructuredGenerator(
            toolAdapter: NativeJSONSchemaAdapter(),
            toolTurnAdapter: OpenAIToolTurnAdapter()
        ).expectedDialect, "a transport-native generator has no text dialect")

        XCTAssertEqual(MarkdownStructuredGenerator().expectedDialect, .reactMarkdown)
        XCTAssertEqual(XMLStructuredGenerator().expectedDialect, .mistralXML)
        XCTAssertEqual(MLXNativeStructuredGenerator().expectedDialect, .heuristicJson)
        XCTAssertEqual(NativeToolTemplateGenerator.mistralV11().expectedDialect, .mistralV11Flat)
        XCTAssertEqual(NativeToolTemplateGenerator.qwenHermes().expectedDialect, .qwenHermesToolCall)
    }
}
