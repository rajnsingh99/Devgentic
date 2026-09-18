// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ParseFailureCorrectiveTests.swift
//  DevgenticTests
//
//  `ParseFailureReason.modelCorrectiveAlert` must name the format THIS RUN parses back.
//
//  ⚠️ THE DEFECT THIS PINS — the sibling of invariant 80, on the path that actually fires. Five of
//  the eleven arms stated a wire shape and every one of them stated the `.nativeJSON` envelope:
//
//      .schemaKeyMismatch  → "Correct shape: {\"name\": \"...\", \"arguments\": {...}}."
//      .dialectDrift       → "…Emit JSON tool calls of shape {\"name\": …, \"arguments\": …}."
//      .toolNameInProse    → "…Emit: {\"name\": \"X\", \"arguments\": {...}}."
//      .noStructuredOutput → "Emit a JSON tool call…"
//      .malformedJSON      → "…use double quotes, and produce strict JSON syntax."
//
//  `LLMRetryStrategy` carried the same text and was fixed first, but it only fires on UNCLASSIFIED
//  thrown errors — generators return `.failed(reason)` rather than throwing, so this is the path a
//  real parse failure takes and it fires far more often.
//
//  ⚠️ This file is also the FIRST test coverage `ParseFailureReason` has ever had: before it,
//  `grep -rln 'ParseFailureReason' DevgenticTests/` returned nothing, which is how five arms came
//  to agree on the wrong shape.
//

import XCTest
@testable import devgentic

final class ParseFailureCorrectiveTests: XCTestCase {

    // MARK: - Fixtures

    private let tools = ["read_file", "final_answer"]

    /// One sample per case. ⚠️ Kept honest by `kindLabel` below rather than by review.
    private var allReasons: [ParseFailureReason] {
        [
            .emptyOutput,
            .noStructuredOutput(snippet: "I think I should look at the file."),
            .proseDescribedIntent(snippet: "I will now call read_file on /tmp."),
            .malformedJSON(syntaxDetail: "unescaped newline at 42", rawSnippet: "{\"name\":"),
            .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: ["function_name"], rawSnippet: "{}"),
            .unknownToolName(attempted: "reed_file", suggestions: ["read_file"]),
            .argSchemaMismatch(attempted: "reed_file", resolvedTo: "read_file",
                               missingArgs: ["path"], unexpectedArgs: []),
            .dialectDrift(expected: "Native JSON", detected: "Mistral XML"),
            .toolNameInProse(toolName: "read_file", snippet: "read_file path: \"/tmp\""),
            .gatedTool(attempted: "update_project_context", unlockHint: "Read 2 more source files"),
        ]
    }

    /// ⚠️ Exhaustive switch with no `default:` — this is what makes `allReasons` trustworthy.
    /// Adding a `ParseFailureReason` case BREAKS THIS BUILD, which is the only way a new arm
    /// cannot quietly ship with the nativeJSON envelope hardcoded into it.
    private func kindLabel(_ reason: ParseFailureReason) -> String {
        switch reason {
        case .emptyOutput:          return "emptyOutput"
        case .noStructuredOutput:   return "noStructuredOutput"
        case .proseDescribedIntent: return "proseDescribedIntent"
        case .malformedJSON:        return "malformedJSON"
        case .schemaKeyMismatch:    return "schemaKeyMismatch"
        case .unknownToolName:      return "unknownToolName"
        case .argSchemaMismatch:    return "argSchemaMismatch"
        case .dialectDrift:         return "dialectDrift"
        case .toolNameInProse:      return "toolNameInProse"
        case .gatedTool:            return "gatedTool"
        }
    }

    func testTheReasonSampleCoversEveryCase() {
        XCTAssertEqual(Set(allReasons.map(kindLabel)).count, allReasons.count,
                       "each sample must be a distinct case")
        XCTAssertEqual(allReasons.count, 10,
                       "a case was added or removed — add it to allReasons, then re-read every "
                       + "assertion below to decide whether the new arm should state a shape")
    }

    // MARK: - The headline property

    /// ⚠️ THE ASSERTION THAT MATTERS MOST, and the one that fails on the old code: no alert may
    /// state a wire shape OTHER than this run's own.
    ///
    /// ⚠️ The discriminator took two attempts, and the first one was wrong in a way worth
    /// recording. It asserted `!alert.contains("\"arguments\": {...}")` — but that substring is
    /// part of the CORRECT format for eight dialects (`.mistralXML`'s real shape is
    /// `<tool_call>{"name": "...", "arguments": {...}}</tool_call>`), so it failed on correct
    /// output and would have forced the fix to make those reminders wrong to go green. The
    /// property is not "this envelope never appears", it is "no envelope appears EXCEPT as part of
    /// this dialect's own reminder" — so the reminder is removed first and the remainder checked.
    func testNoAlertStatesAShapeOtherThanTheRunsOwn() {
        // Envelope literals that must only ever reach a model via `formatReminder`.
        let shapeLiterals = ["\"arguments\": {...}", "toolCalls", "\"parameters\": {...}", "[TOOL_CALLS]"]

        for dialect in ModelDialect.allCases {
            for reason in allReasons {
                let alert = reason.modelCorrectiveAlert(availableToolNames: tools, dialect: dialect)
                let outsideTheReminder = alert.replacingOccurrences(of: dialect.formatReminder, with: "")

                for literal in shapeLiterals {
                    XCTAssertFalse(
                        outsideTheReminder.contains(literal),
                        "\(kindLabel(reason)) on \(dialect.rawValue) states `\(literal)` outside its "
                        + "own format reminder — a shape its parser may not read. Got: \(alert)"
                    )
                }
            }
        }
    }

    /// Every arm that states a shape must state THIS dialect's shape. Written from the invariant:
    /// it asserts `dialect.formatReminder` is present, whatever that text says, so correcting a
    /// documented format does not fail this test while routing to the wrong one does.
    func testShapeStatingArmsNameTheRunsOwnFormat() {
        let shapeStating: [ParseFailureReason] = [
            .noStructuredOutput(snippet: "prose"),
            .proseDescribedIntent(snippet: "prose"),
            .malformedJSON(syntaxDetail: "bad", rawSnippet: "{"),
            .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: ["fn"], rawSnippet: "{}"),
            .dialectDrift(expected: "Native JSON", detected: "Mistral XML"),
            .toolNameInProse(toolName: "read_file", snippet: "read_file …"),
        ]

        for dialect in ModelDialect.allCases {
            for reason in shapeStating {
                let alert = reason.modelCorrectiveAlert(availableToolNames: tools, dialect: dialect)
                XCTAssertTrue(
                    alert.contains(dialect.formatReminder),
                    "\(kindLabel(reason)) on \(dialect.rawValue) did not name its own format. Got: \(alert)"
                )
            }
        }
    }

    /// ⚠️ The inverse, so "append the format to every arm" cannot pass the test above. These four
    /// are about NAMES and POLICY, not shape — bolting a wire format onto "tool X does not exist"
    /// adds noise to an alert whose whole job is to redirect the model to a different tool.
    func testNameAndPolicyArmsStayShapeFree() {
        let shapeFree: [ParseFailureReason] = [
            .emptyOutput,
            .unknownToolName(attempted: "reed_file", suggestions: ["read_file"]),
            .argSchemaMismatch(attempted: "reed_file", resolvedTo: "read_file",
                               missingArgs: ["path"], unexpectedArgs: []),
            .gatedTool(attempted: "update_project_context", unlockHint: "Read 2 more"),
        ]

        for reason in shapeFree {
            let alert = reason.modelCorrectiveAlert(availableToolNames: tools, dialect: .mistralV11Flat)
            XCTAssertFalse(
                alert.contains(ModelDialect.mistralV11Flat.formatReminder),
                "\(kindLabel(reason)) is about names/policy, not shape: \(alert)"
            )
        }
    }

    // MARK: - nil dialect (transport-native)

    /// On a native flow the tool call rides in the protocol — there is no text shape to correct.
    func testNativeFlowIsNeverGivenATextShape() {
        for reason in allReasons {
            let alert = reason.modelCorrectiveAlert(availableToolNames: tools, dialect: nil)
            XCTAssertFalse(alert.contains("\"arguments\": {...}"),
                           "\(kindLabel(reason)) gave a native flow a text envelope: \(alert)")
            XCTAssertFalse(alert.contains("This model's tool-call format is"),
                           "\(kindLabel(reason)) named a format on a native flow: \(alert)")
        }
    }

    /// …but `.toolNameInProse` must still redirect the model off prose, since that IS actionable
    /// on a native flow: it has a tool-calling API and used text instead.
    func testNativeFlowStillRedirectsProseToTheToolCallingAPI() {
        let alert = ParseFailureReason
            .toolNameInProse(toolName: "read_file", snippet: "read_file path: \"/tmp\"")
            .modelCorrectiveAlert(availableToolNames: tools, dialect: nil)

        XCTAssertTrue(alert.contains("read_file"), "targeting is the point of this case: \(alert)")
        XCTAssertTrue(alert.contains("native tool-calling API"), "got: \(alert)")
    }

    // MARK: - The one arm that needed a second distinction

    /// JSON syntax advice belongs only where the arguments are JSON. Telling a pythonic model to
    /// "use double quotes and produce strict JSON" instructs it away from `True`/`False`/`None`.
    func testJSONSyntaxAdviceOnlyWhereArgumentsAreJSON() {
        for dialect in ModelDialect.allCases {
            let alert = ParseFailureReason
                .malformedJSON(syntaxDetail: "unescaped newline", rawSnippet: "{")
                .modelCorrectiveAlert(availableToolNames: tools, dialect: dialect)

            XCTAssertEqual(
                alert.contains("strict JSON syntax"), dialect.argumentsAreJSON,
                "\(dialect.rawValue): JSON syntax advice must track argumentsAreJSON. Got: \(alert)"
            )
        }
    }

    /// The three non-JSON-argument dialects, named explicitly — so a careless flip of
    /// `argumentsAreJSON` to a blanket `true` cannot pass the test above by agreeing with itself.
    func testTheNonJSONArgumentDialectsAreExactlyTheseThree() {
        let nonJSON = ModelDialect.allCases.filter { !$0.argumentsAreJSON }
        XCTAssertEqual(Set(nonJSON), [.pythonicBracketList, .qwen3CoderDeepXml, .deepseekV32Dsml],
                       "got: \(nonJSON.map(\.rawValue))")
    }

    // MARK: - Both correctives agree

    /// ⚠️ The two correctives in this codebase must describe a format identically. They are
    /// separate code paths — thrown errors vs returned `.failed` — and the whole defect class is
    /// two places disagreeing about one format.
    func testBothCorrectivesDescribeTheFormatIdentically() {
        for dialect in ModelDialect.allCases {
            let retryAlert = LLMRetryStrategy.correctiveAlert(dialect: dialect, attempt: 1, maxAttempts: 3)
            let parseAlert = ParseFailureReason
                .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: ["fn"], rawSnippet: "{}")
                .modelCorrectiveAlert(availableToolNames: tools, dialect: dialect)

            XCTAssertTrue(retryAlert.contains(dialect.formatReminder))
            XCTAssertTrue(parseAlert.contains(dialect.formatReminder),
                          "\(dialect.rawValue): the two correctives must not describe one format "
                          + "two ways. retry=\(retryAlert) parse=\(parseAlert)")
        }
    }

    // MARK: - schemaKeyMismatch quotes what the model emitted

    /// ⚠️ THE DEFECT THIS PINS. The enum has carried `rawSnippet` since it was declared and the
    /// corrective discarded it (`case .schemaKeyMismatch(let expected, let found, _)`). With a
    /// recognisable wrong key the model got `You used keys ["function_name"]…` — usable. When the
    /// key regex matched nothing (smart quotes) it got `You used keys []`: a sentence naming
    /// nothing it did. In the 2026-09-13 gemma:7b run that alert was byte-identical every
    /// iteration and failed to land 14 times. `.toolNameInProse` had quoted its snippet all along.
    func testSchemaKeyMismatchQuotesTheModelsOwnOutput() {
        let alert = ParseFailureReason
            .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: ["function_name"],
                               rawSnippet: #"{"function_name": "final_summary"}"#)
            .modelCorrectiveAlert(availableToolNames: tools, dialect: .heuristicJson)

        XCTAssertTrue(alert.contains(#"{"function_name": "final_summary"}"#),
                      "the snippet the producer captured must reach the model: \(alert)")
        XCTAssertTrue(alert.contains("You used keys"), "the found-keys clause must survive: \(alert)")
        XCTAssertTrue(alert.contains(ModelDialect.heuristicJson.formatReminder),
                      "quoting the wrong thing must not displace the right one: \(alert)")
    }

    /// ⚠️ The gemma shape. `HeuristicCognitiveParser.extractTopLevelKeys` matches ASCII `"key":`
    /// only, so smart-quoted output yields `foundKeys: []`. The alert must then say what WAS
    /// emitted rather than print an empty list as though it were information.
    func testNoRecognisedKeysSaysSoAndShowsTheOutputInsteadOfEmptyBrackets() {
        let smartQuoted = #"{" content":"Executing `ls -R`",  "tool”: ":",   “arguments”:{ “path"#
        let alert = ParseFailureReason
            .schemaKeyMismatch(expectedKeys: ["name", "arguments", "tool_calls", "content"],
                               foundKeys: [], rawSnippet: smartQuoted)
            .modelCorrectiveAlert(availableToolNames: tools, dialect: .heuristicJson)

        XCTAssertFalse(alert.contains("keys []"),
                       "`You used keys []` names nothing the model did: \(alert)")
        XCTAssertTrue(alert.contains("“arguments”"),
                      "the smart-quoted output IS the diagnosis and must be shown: \(alert)")
        XCTAssertTrue(alert.contains("tool_calls"), "the expected keys must still be listed: \(alert)")
    }

    /// The snippet lands in the scratchpad's un-evictable alert block, one `- [SYSTEM ALERT]` line
    /// per alert. It is bounded to 80 chars — the window `.toolNameInProse` uses — and one line.
    func testTheQuotedSnippetIsBoundedAndSingleLine() {
        let long = String(repeating: "x", count: 300)
        let bounded = ParseFailureReason
            .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: ["fn"], rawSnippet: long)
            .modelCorrectiveAlert(availableToolNames: tools, dialect: .heuristicJson)
        XCTAssertTrue(bounded.contains(String(repeating: "x", count: 80)))
        XCTAssertFalse(bounded.contains(String(repeating: "x", count: 81)),
                       "a 200-char pretty-printed capture must not reach the prompt whole")

        let multiLine = "{\n  \"fn\": \"a\",\n  \"opts\": {}\n}"
        let flat = ParseFailureReason
            .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: ["fn"], rawSnippet: multiLine)
            .modelCorrectiveAlert(availableToolNames: tools, dialect: .heuristicJson)
        XCTAssertFalse(flat.contains("\n"),
                       "an alert renders as ONE line; a newline inside it puts a bare JSON "
                       + "fragment on the next line of the prompt with no framing: \(flat)")
        XCTAssertTrue(flat.contains(#"{ "fn": "a", "opts": {} }"#), "got: \(flat)")
    }

    /// ⚠️ Collapse happens BEFORE the window. Producers capture pretty-printed JSON whose first 80
    /// chars can be mostly indentation; bounding first would quote whitespace and drop the keys.
    func testWhitespaceIsCollapsedBeforeTheWindowIsApplied() {
        let indented = String(repeating: " ", count: 100) + #"{"fn": 1}"#
        let alert = ParseFailureReason
            .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: ["fn"], rawSnippet: indented)
            .modelCorrectiveAlert(availableToolNames: tools, dialect: .heuristicJson)
        XCTAssertTrue(alert.contains(#"{"fn": 1}"#),
                      "bounding before collapsing would have quoted 80 spaces: \(alert)")
    }

    /// A producer that captured nothing must not leave an empty quotation behind.
    func testAnEmptySnippetLeavesNoEmptyQuotation() {
        let alert = ParseFailureReason
            .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: ["fn"], rawSnippet: "   \n  ")
            .modelCorrectiveAlert(availableToolNames: tools, dialect: .heuristicJson)
        XCTAssertFalse(alert.contains("you emitted"), "got: \(alert)")
        XCTAssertFalse(alert.contains("``"), "got: \(alert)")
        XCTAssertTrue(alert.contains("You used keys"), "the keys clause must survive alone: \(alert)")
    }

    /// ⚠️ The interaction with the alert dedupe (invariant 85). Identical output still yields an
    /// identical alert, so a model repeating itself collapses to one `(repeated Nx)` line; but
    /// DIFFERENT output now yields a different alert. Before, every schema failure in a run
    /// produced the same bytes regardless of what the model actually did.
    func testDifferentOutputsYieldDifferentAlertsAndIdenticalOutputsDoNot() {
        func alert(_ snippet: String) -> String {
            ParseFailureReason
                .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: [], rawSnippet: snippet)
                .modelCorrectiveAlert(availableToolNames: tools, dialect: .heuristicJson)
        }
        XCTAssertNotEqual(alert(#"{"tool": "a"}"#), alert(#"{"tool": "b"}"#),
                          "two different attempts must not produce one byte-identical alert")
        XCTAssertEqual(alert(#"{"tool": "a"}"#), alert(#"{"tool": "a"}"#))
    }
}
