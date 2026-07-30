//
//  ShellExitCodeMemoryTests.swift
//  DevgenticTests
//
//  The shell tools read `terminationStatus` and put it in the observation, so a failed command
//  was visible on the turn that ran it — and gone by the next one. Successful tool output is
//  deliberately not carried (a read is repeatable), so the following prompt showed
//  `status="success"` with nothing to contradict it: an agent could read its own record of a
//  failed `swift build` and conclude the build passed.
//
//  A verdict is NOT repeatable. Re-running `swift build` after the agent edited the code
//  answers a different question than the original run did — the same argument that justifies
//  carrying `<effect>` for writes.
//
//  It is carried as `exit`, SEPARATE from `status`, and deliberately does not reclassify the
//  call: `grep` exits 1 for "no match" and `diff` for "files differ", and
//  `CognitiveCircuitBreaker` aborts a run after three consecutive tool failures.
//

import XCTest
@testable import devgentic

final class ShellExitCodeMemoryTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 10_000_000)

    // MARK: - Format / parse are one contract

    func testAnnotatedOutputRoundTrips() {
        for code: Int32 in [0, 1, 2, 127, 255] {
            let annotated = ShellExitStatus.annotate("some output", exitCode: code)
            XCTAssertEqual(ShellExitStatus.parse(annotated), code, "round trip for \(code)")
        }
    }

    func testUnannotatedOutputHasNoExitCode() {
        XCTAssertNil(ShellExitStatus.parse("just some output"))
        XCTAssertNil(ShellExitStatus.parse(nil))
        XCTAssertNil(ShellExitStatus.parse(""))
    }

    /// A tool that merely PRINTS something similar mid-output is not reporting a status.
    /// The parser must not read arbitrary payload — that is the mistake `isSemanticFailure`
    /// made, and three tool authors then defeated it with three different prefixes.
    func testTheParserOnlyTrustsItsOwnPrefixPosition() {
        XCTAssertNil(ShellExitStatus.parse("build log\nExit code: 1\nmore"),
                     "not at the start — this is content, not a status")
        XCTAssertNil(ShellExitStatus.parse("Exit code: abc\nx"), "not a number")
        XCTAssertNil(ShellExitStatus.parse("Exit code: "), "nothing after the prefix")
    }

    // MARK: - It reaches the next turn

    private func shellTurn(exitCode: Int32?) -> [ChatMessage] {
        var data = ToolExecutionData(
            id: UUID(), name: "execute_shell",
            params: #"{"command":"swift build"}"#,
            output: "compiler output", isSuccess: true, isExecuting: false
        )
        data.exitCode = exitCode
        let user = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0,
                               sender: .user, content: .plainText("build it"))
        let agent = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(1),
                                sender: .agent, content: .plainText("Ran the build."))
        agent.timelineEvents = [.toolExecution(data)]
        return [user, agent]
    }

    /// The defect, stated directly: this is what the NEXT prompt now shows.
    func testAFailedCommandIsVisibleOnTheFollowingTurn() {
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: shellTurn(exitCode: 1), limit: 10)
        XCTAssertTrue(xml.contains("exit=\"1\""), "the verdict must survive into the next prompt:\n\(xml)")
    }

    /// …without pretending the TOOL failed. That distinction is what keeps `grep` misses from
    /// tripping the circuit breaker.
    func testTheToolIsStillRecordedAsSucceeding() {
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: shellTurn(exitCode: 1), limit: 10)
        XCTAssertTrue(xml.contains("status=\"success\""), "the tool ran; the command is what failed")
        XCTAssertFalse(xml.contains("status=\"failed\""))
    }

    /// A zero exit is the default and is omitted — every successful command would otherwise
    /// pay for an attribute that says nothing.
    func testASuccessfulCommandAddsNothing() {
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: shellTurn(exitCode: 0), limit: 10)
        XCTAssertFalse(xml.contains("exit="), "\(xml)")
    }

    /// Non-shell tools never annotate, so they must never grow the attribute.
    func testNonShellToolsCarryNoExitCode() {
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: shellTurn(exitCode: nil), limit: 10)
        XCTAssertFalse(xml.contains("exit="))
    }

    /// A verdict is not a detail you can re-derive, so the pointer skeleton carries it too —
    /// same reasoning that put a counts-only `<effect>` there.
    func testPointerSkeletonAlsoCarriesTheVerdict() {
        let xml = EpisodicHistoryFormatter.buildPointerHistoryString(from: shellTurn(exitCode: 2))
        XCTAssertTrue(xml.contains("exit=\"2\""), "\(xml)")
    }

    // MARK: - Persistence

    /// It must survive a reopened conversation, like `effect` — and legacy rows without the
    /// key must still decode.
    func testExitCodeSurvivesPersistence() throws {
        var data = ToolExecutionData(id: UUID(), name: "execute_shell", params: "{}",
                                     output: "x", isSuccess: true, isExecuting: false)
        data.exitCode = 3
        let decoded = try JSONDecoder().decode(
            ToolExecutionData.self, from: try JSONEncoder().encode(data))
        XCTAssertEqual(decoded.exitCode, 3)
    }

    // MARK: - The seam between the two halves

    /// `annotate` and `parse` are both tested above, and the XML emission is tested above that,
    /// but the step that CONNECTS them had no coverage: `ActiveStreamManager` parses the
    /// annotation out of `ToolExecutionData.cappedOutput(...)`, not out of the raw output.
    ///
    /// That only works because the cap keeps the HEAD of the string. `annotate` puts
    /// `Exit code: N` on line 1 and `parse` insists on it at position 0, so switching the cap
    /// to keep the TAIL — an entirely reasonable "show the most recent output" change — would
    /// sever the chain while every test on either half went on passing.
    func testTheExitAnnotationSurvivesTheOutputCap() {
        let verbose = String(repeating: "build log line\n", count: 5_000)
        XCTAssertGreaterThan(verbose.count, ToolExecutionData.maxPersistedOutputLength,
                             "fixture must actually exceed the cap or this proves nothing")

        let capped = ToolExecutionData.cappedOutput(ShellExitStatus.annotate(verbose, exitCode: 42))

        XCTAssertLessThanOrEqual(capped.count,
                                 ToolExecutionData.maxPersistedOutputLength + 200,
                                 "it was capped")
        XCTAssertEqual(ShellExitStatus.parse(capped), 42,
                       "the verdict is the first line and must survive truncation")
    }

    /// A short output is not capped at all — the common case must not depend on the branch
    /// above being taken.
    func testTheAnnotationSurvivesWhenNoCappingHappens() {
        let capped = ToolExecutionData.cappedOutput(ShellExitStatus.annotate("brief", exitCode: 7))
        XCTAssertEqual(ShellExitStatus.parse(capped), 7)
    }

    func testLegacyRowsWithoutAnExitCodeStillDecode() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"execute_shell","params":"{}","isExecuting":false}
        """
        let decoded = try JSONDecoder().decode(ToolExecutionData.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.exitCode)
        XCTAssertEqual(decoded.name, "execute_shell")
    }
}
