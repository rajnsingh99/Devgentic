// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EpisodicErrorCapTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class EpisodicErrorCapTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 5_000_000)

    // MARK: - Fixtures

    private func failedTurn(output: String) -> [ChatMessage] {
        let user = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0,
                               sender: .user, content: .plainText("build it"))
        let agent = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(1),
                                sender: .agent, content: .plainText("Build failed."))
        agent.timelineEvents = [.toolExecution(ToolExecutionData(
            id: UUID(), name: "execute_shell", params: #"{"command":"swift build"}"#,
            output: output, isSuccess: false,
            failureCategory: .executionThrew, isExecuting: false
        ))]
        return [user, agent]
    }

    /// A realistic Swift compiler error. At 150 chars the model saw the file and line and
    /// lost the actual diagnostic — the part it needed to fix anything.
    private var compilerError: String {
        """
        /Users/me/Project/Sources/App/BackendOrchestrationService.swift:288:41: error: \
        cannot convert value of type 'HistoryStrategy?' to expected argument type 'HistoryStrategy'
            strategy: config.profile.resolvedHistoryStrategy,
                      ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        /Users/me/Project/Sources/App/ContextWindowGauge.swift:211:34: error: \
        value of optional type 'ProviderConfig?' must be unwrapped
        """
    }

    // MARK: - The cap

    func testShortErrorIsUntouched() {
        let text = "Permission denied"
        XCTAssertEqual(EpisodicHistoryFormatter.cappedError(text), text)
    }

    func testErrorAtExactLimitIsUntouched() {
        let text = String(repeating: "e", count: EpisodicHistoryFormatter.errorCharacterLimit)
        XCTAssertEqual(EpisodicHistoryFormatter.cappedError(text), text, "the boundary must not clip")
    }

    /// The marker is the point: "..." says something was dropped, not how much, so the model
    /// cannot tell a two-line clip from a thousand-line one.
    func testOversizedErrorIsClippedAndSaysHowMuchWasLost() {
        let text = String(repeating: "e", count: EpisodicHistoryFormatter.errorCharacterLimit + 500)
        let capped = EpisodicHistoryFormatter.cappedError(text)

        XCTAssertTrue(capped.contains("truncated 500 characters of error output"),
                      "the loss must be quantified: \(capped.suffix(80))")
        XCTAssertLessThan(capped.count, text.count)
        XCTAssertTrue(capped.hasPrefix(String(repeating: "e", count: 100)), "the head survives")
    }

    // MARK: - The case that motivated it

    /// A compiler error survives now. Under the old 150-char cap the diagnostic itself — the
    /// only actionable part — fell off the end.
    func testCompilerErrorSurvivesIntoTheXML() {
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: failedTurn(output: compilerError))

        XCTAssertGreaterThan(compilerError.count, 150, "sanity: this would have been clipped before")
        XCTAssertTrue(xml.contains("cannot convert value of type"),
                      "the first diagnostic must survive:\n\(xml)")
        XCTAssertTrue(xml.contains("must be unwrapped"),
                      "so must the second — the real cause is often not the first line")
        XCTAssertFalse(xml.contains("truncated"), "a normal compiler error fits under the cap")
    }

    /// Still bounded. A runaway log must not ride every subsequent prompt in full.
    func testPathologicalErrorIsStillBounded() {
        let runaway = String(repeating: "stack frame\n", count: 5_000)
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: failedTurn(output: runaway))

        XCTAssertLessThan(xml.count, EpisodicHistoryFormatter.errorCharacterLimit + 2_000,
                          "the blob stays bounded regardless of output size")
        XCTAssertTrue(xml.contains("characters of error output"), "and says so")
    }

    /// Success carries no output at all — the cap governs failures only, and raising it must
    /// not start smuggling successful reads into every prompt.
    func testSuccessfulOutputIsStillNotCarried() {
        let user = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0,
                               sender: .user, content: .plainText("read it"))
        let agent = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(1),
                                sender: .agent, content: .plainText("Done."))
        agent.timelineEvents = [.toolExecution(ToolExecutionData(
            id: UUID(), name: "read_file", params: #"{"path":"/tmp/a.txt"}"#,
            output: "SENTINEL_FILE_CONTENTS", isSuccess: true, isExecuting: false
        ))]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: [user, agent])
        XCTAssertTrue(xml.contains("read_file"), "the CALL is recorded")
        XCTAssertFalse(xml.contains("SENTINEL_FILE_CONTENTS"),
                       "…but a repeatable read's output is not carried:\n\(xml)")
    }
}
