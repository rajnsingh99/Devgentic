//
//  SemanticFailureDetectionTests.swift
//  DevgenticTests
//
//  TDD: T1 — Semantic Failure Detection
//

import XCTest
@testable import devgentic

final class SemanticFailureDetectionTests: XCTestCase {

    // MARK: - T1a: Empty String

    func testIsSemanticFailure_EmptyString_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure(""))
    }

    // MARK: - T1b: Short Valid Output "OK"

    func testIsSemanticFailure_OK_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("OK"), "\"OK\" is valid output, should not be flagged as failure")
    }

    // MARK: - T1c: Literal "null"

    func testIsSemanticFailure_Null_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("null"))
    }

    // MARK: - T1d: Normal Success Output

    func testIsSemanticFailure_SuccessMessage_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("Successfully listed 5 files"))
    }

    // MARK: - T1e: Error Prefix

    func testIsSemanticFailure_ErrorPrefix_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("Error: file not found"))
    }

    // MARK: - T1f: "error" Embedded (Not Prefix)

    func testIsSemanticFailure_ErrorEmbedded_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("The error rate was 0.5%"), "\"error\" in middle of string should not trigger hasPrefix check")
    }

    // MARK: - T1g: Whitespace-Only

    func testIsSemanticFailure_WhitespaceOnly_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("   \n  \t  "))
    }

    // MARK: - T1h: Literal "nil"

    func testIsSemanticFailure_Nil_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("nil"))
    }

    // MARK: - T1i: Short Valid Output "No"

    func testIsSemanticFailure_No_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("No"), "\"No\" is valid output, should not be flagged as failure")
    }

    // MARK: - T1j: Short Numeric Output "42"

    func testIsSemanticFailure_NumericOutput_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("42"), "Numeric output should not be flagged as failure")
    }

    // MARK: - #19 (A): narrowed "error" heuristic

    func testIsSemanticFailure_LongErrorContainingContent_ReturnsFalse() {
        // A multi-KB log/build output that merely BEGINS with "error" is legitimate content,
        // not a tool failure. Pre-#19 the bare hasPrefix("error") flagged it.
        let longLog = "error " + String(repeating: "x", count: 600)
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure(longLog),
                       "Long error-containing content (>maxSemanticErrorLength) must not be flagged")
    }

    func testIsSemanticFailure_ErrorNotALeadingWord_ReturnsFalse() {
        // "errors"/"error_log" — "error" is not a standalone word followed by ':' or whitespace.
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("errors found: 0"))
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("error_log.txt opened"))
    }

    func testIsSemanticFailure_ErrorReadingShape_StillTrue() {
        // Intentional soft-failure shapes real tools emit must still be caught.
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("Error reading file: no such file"))
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("error"), "bare 'error' token is a failure")
    }

    func testIsSemanticFailure_ErrorHeaderWithLongMultilineBody_StillTrue() {
        // A soft-failure that interpolates a long body ("Error: <header>\n<2KB stderr>") has a
        // SHORT first line and must still be flagged — the length bound is on the first line,
        // not the whole output (#19, review fix #2). Whole length here far exceeds 512.
        let interpolated = "Error: AppleScript failed\n" + String(repeating: "detail line\n", count: 80)
        XCTAssertGreaterThan(interpolated.count, 512)
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure(interpolated),
                      "Error-headed soft-failure with a long body must still be flagged")
    }

    // MARK: - #19 (B): per-tool opt-out (contentMayLookLikeError)

    private func emptySchema() -> ToolParameters {
        SchemaBuilder.object(properties: [("input", "string", "in")], required: [])
    }

    func testExecutePreparedTool_OptOutTool_ErrorOutputIsSuccess() async {
        // A tool that legitimately surfaces error text (contentMayLookLikeError = true)
        // returning "error: ..." is a SUCCESS, not a semantic failure.
        let mediator = ToolExecutionMediator()
        let tool = AgentTool(
            name: "shelly",
            description: "shell",
            parameters: emptySchema(),
            contentMayLookLikeError: true,
            textOnlyRun: { _ in "error: build failed with 3 errors" }
        )
        let result = await mediator.executePreparedTool(
            toolName: "shelly",
            arguments: ["input": .string("x")],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )
        XCTAssertTrue(result.isSuccess, "Opt-out tool's error-shaped output should be success")
    }

    func testExecutePreparedTool_NonOptOutTool_ErrorOutputIsSemanticFailure() async {
        // Control: the same output WITHOUT the opt-out is still a semantic failure.
        let mediator = ToolExecutionMediator()
        let tool = AgentTool(
            name: "reader",
            description: "reader",
            parameters: emptySchema(),
            textOnlyRun: { _ in "Error: File not found" }
        )
        let result = await mediator.executePreparedTool(
            toolName: "reader",
            arguments: ["input": .string("x")],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )
        XCTAssertFalse(result.isSuccess, "Non-opt-out tool's 'Error:' output should be a semantic failure")
        if case .semanticFailure = result {} else { XCTFail("Expected .semanticFailure, got \(result)") }
    }

    // MARK: - #19 (review fix #1): opted-out tool must THROW its operational failures

    /// A tool that sets `outputMayContainErrorText` switches OFF the mediator's output sniffing,
    /// so for that tool a returned string can never be classified as a failure whatever it says.
    /// Throwing is the only channel its operational failures have left — return an "Error:" string
    /// instead and the failure is silently recorded as a success, and the circuit breaker never
    /// counts it.
    ///
    /// This was originally pinned on `xcode_orchestrator`, which was deleted 2026-07-31 as
    /// unreachable. It is re-pinned rather than removed because the invariant belongs to the
    /// OPT-OUT, not to that tool: `execute_shell` is now the only tool setting the flag, so it is
    /// where the property has to hold. A refused command is used because it exercises the throw
    /// path without running anything.
    func testOptedOutTool_OperationalFailure_ThrowsRatherThanReturning() async throws {
        let optedOut = TerminalTool()
        XCTAssertTrue(optedOut.outputMayContainErrorText,
                      "if this tool stops opting out, re-point this test at whichever tool does")

        let args = try JSONDecoder().decode(
            TerminalTool.Arguments.self,
            from: Data(#"{"command":"vim"}"#.utf8)   // refused by ShellCommandGuard; nothing runs
        )
        do {
            let output = try await optedOut.call(arguments: args)
            XCTFail("a refused command must throw, not return an 'Error:' string: \(output)")
        } catch {
            // expected — a thrown error becomes .systemError at the mediator (a counted failure)
        }
    }
}
