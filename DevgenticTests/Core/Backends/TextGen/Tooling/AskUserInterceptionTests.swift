// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AskUserInterceptionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class AskUserInterceptionTests: XCTestCase {

    /// The property every fallback must satisfy: a complete, terminated question the user can
    /// actually answer. Deliberately not an equality check against the current wording — that is
    /// what made two of these tests red for no behavioural reason.
    private func assertUsableQuestion(_ text: String?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let text else {
            return XCTFail("expected a question, got nil. \(message)", file: file, line: line)
        }
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "a dead-end empty prompt. \(message)", file: file, line: line)
        XCTAssertTrue("?.!".contains(text.last ?? " "),
                      "an unterminated prompt reads as truncated: \(text.debugDescription). \(message)",
                      file: file, line: line)
    }

    // MARK: - extractQuestion

    func testExtractQuestion_AskUserWithQuestion_ReturnsQuestion() {
        let result = AskUserInterceptor.extractQuestion(
            toolName: "ask_user",
            arguments: ["question": .string("What file should I read?")]
        )
        XCTAssertEqual(result, "What file should I read?")
    }

    func testExtractQuestion_NonAskUser_ReturnsNil() {
        let result = AskUserInterceptor.extractQuestion(
            toolName: "read_file",
            arguments: ["question": .string("What file?")]
        )
        XCTAssertNil(result, "only ask_user is intercepted — anything else must dispatch normally")
    }

    func testExtractQuestion_AskUserNoQuestion_ReturnsUsableFallback() {
        let result = AskUserInterceptor.extractQuestion(toolName: "ask_user", arguments: [:])
        assertUsableQuestion(result, "a model that called ask_user with no question still blocks the run")
    }

    func testExtractQuestion_AskUserNonStringQuestion_ReturnsTheSameFallback() {
        let nonString = AskUserInterceptor.extractQuestion(
            toolName: "ask_user",
            arguments: ["question": .number(42)]
        )
        let absent = AskUserInterceptor.extractQuestion(toolName: "ask_user", arguments: [:])

        assertUsableQuestion(nonString)
        XCTAssertEqual(nonString, absent,
                       "a wrong-typed question and a missing one are the same situation to the user")
    }

    /// ⚠️ WIRING. `extractQuestion` must route through `sanitizeQuestion` — testing the repair on
    /// `sanitizeQuestion` alone would stay green if this call stopped applying it.
    func testExtractQuestion_AppliesTheDanglingConnectorRepair() {
        let result = AskUserInterceptor.extractQuestion(
            toolName: "ask_user",
            arguments: ["question": .string("Could you clarify what you mean by ")]
        )
        XCTAssertEqual(result, "Could you clarify what you mean?")
    }

    // MARK: - sanitizeQuestion: the truncated-generation repair
    //
    // ⚠️ This is what the type exists for and it had no tests at all. Weak local models stop
    // generating mid-sentence and emit a valid-JSON but unfinished question — "…what you mean by "
    // — which reaches the user as a dead-end prompt unless it is re-terminated here.

    func testSanitize_TrailingConnector_IsTrimmedAndReterminated() {
        XCTAssertEqual(AskUserInterceptor.sanitizeQuestion("Could you please clarify what you mean by "),
                       "Could you please clarify what you mean?")
    }

    func testSanitize_MultipleTrailingConnectors_AllTrimmed() {
        // "…refer to with the" — three connectors deep.
        XCTAssertEqual(AskUserInterceptor.sanitizeQuestion("Which file do you refer to with the"),
                       "Which file do you refer?")
    }

    func testSanitize_ConnectorMatchIsCaseInsensitive() {
        XCTAssertEqual(AskUserInterceptor.sanitizeQuestion("What do you mean BY"),
                       "What do you mean?")
    }

    func testSanitize_AlreadyTerminated_IsLeftExactlyAsIs() {
        // ⚠️ Including a question that ENDS in a connector word but is properly terminated —
        // the terminal-punctuation check must win before any trimming happens.
        for text in ["What file should I read?", "Pick one.", "Stop!", "Which one do you mean by?"] {
            XCTAssertEqual(AskUserInterceptor.sanitizeQuestion(text), text,
                           "a well-formed prompt must not be rewritten")
        }
    }

    func testSanitize_UnterminatedButComplete_IsNotGivenAQuestionMark() {
        // No dangling connector was removed, so nothing was repaired and nothing is appended —
        // the model's own phrasing is preserved rather than guessed at.
        XCTAssertEqual(AskUserInterceptor.sanitizeQuestion("Tell me the target path"),
                       "Tell me the target path")
    }

    func testSanitize_EmptyOrWhitespace_ReturnsUsableFallback() {
        for raw in ["", "   ", "\n\t "] {
            assertUsableQuestion(AskUserInterceptor.sanitizeQuestion(raw), "input: \(raw.debugDescription)")
        }
    }

    func testSanitize_NothingButConnectors_ReturnsUsableFallback() {
        // Trimming consumes the entire string — must fall back rather than emit "?" alone.
        let result = AskUserInterceptor.sanitizeQuestion("by the")
        assertUsableQuestion(result)
        XCTAssertNotEqual(result, "?", "a bare question mark is a dead-end prompt")
    }

    // MARK: - extractOptions (zero prior coverage)

    func testExtractOptions_Absent_ReturnsNil() {
        XCTAssertNil(AskUserInterceptor.extractOptions([:]))
    }

    func testExtractOptions_RealValues_AreTrimmedAndKept() {
        let result = AskUserInterceptor.extractOptions([
            "options": .array([.string("  Yes "), .string("No")])
        ])
        XCTAssertEqual(result, ["Yes", "No"], "whitespace must not reach the chip labels")
    }

    func testExtractOptions_BlankEntries_AreDropped() {
        let result = AskUserInterceptor.extractOptions([
            "options": .array([.string("Yes"), .string("   "), .string("")])
        ])
        XCTAssertEqual(result, ["Yes"], "a blank entry renders as a dead, inert chip")
    }

    func testExtractOptions_AllBlankOrEmptyArray_ReturnsNilNotEmptyArray() {
        // nil and [] are different downstream: [] would render an empty chip row.
        XCTAssertNil(AskUserInterceptor.extractOptions(["options": .array([.string(" "), .string("")])]))
        XCTAssertNil(AskUserInterceptor.extractOptions(["options": .array([])]))
    }

    func testExtractOptions_NonArrayOrNonStringMembers_DoNotCrashOrLeak() {
        XCTAssertNil(AskUserInterceptor.extractOptions(["options": .string("Yes")]),
                     "a bare string is not an options list")
        XCTAssertEqual(AskUserInterceptor.extractOptions(["options": .array([.number(1), .string("Yes")])]),
                       ["Yes"], "non-string members are skipped, not stringified")
    }

    // MARK: - extractMultiline (zero prior coverage)
    //
    // ⚠️ The coercion exists because weak models emit `"1"`/`"true"`/`"yes"`/`1` rather than a JSON
    // bool. Its own comment says so; nothing tested it.

    func testExtractMultiline_Absent_IsFalse() {
        XCTAssertFalse(AskUserInterceptor.extractMultiline([:]))
    }

    func testExtractMultiline_ProperBool_IsHonoured() {
        XCTAssertTrue(AskUserInterceptor.extractMultiline(["multiline": .bool(true)]))
        XCTAssertFalse(AskUserInterceptor.extractMultiline(["multiline": .bool(false)]))
    }

    func testExtractMultiline_TruthyStrings_AreCoerced() {
        for raw in ["1", "true", "TRUE", "yes", "Y", " true "] {
            XCTAssertTrue(AskUserInterceptor.extractMultiline(["multiline": .string(raw)]),
                          "\(raw.debugDescription) is how a weak model says true")
        }
    }

    func testExtractMultiline_FalsyAndUnknownStrings_AreFalse() {
        for raw in ["0", "false", "no", "maybe", ""] {
            XCTAssertFalse(AskUserInterceptor.extractMultiline(["multiline": .string(raw)]),
                           "\(raw.debugDescription) must not open a multiline editor")
        }
    }

    func testExtractMultiline_Numbers_NonZeroIsTrue() {
        XCTAssertTrue(AskUserInterceptor.extractMultiline(["multiline": .number(1)]))
        XCTAssertFalse(AskUserInterceptor.extractMultiline(["multiline": .number(0)]))
    }
}
