//
//  RunInteractionMemoryTests.swift
//  DevgenticTests
//
//  Locks the Loop Safety prevention contract: identical clarification re-asks replay the
//  stored response (including skips), identical previously-denied requests are recognized,
//  and both are keyed robustly (whitespace/case-insensitive questions; canonical params).
//

import XCTest
@testable import devgentic

final class RunInteractionMemoryTests: XCTestCase {

    // MARK: - Clarifications

    func testStoredResponse_ReplaysAnswerForIdenticalQuestion() async {
        let memory = RunInteractionMemory()
        await memory.recordAnswer(question: "Which environment should I target?", response: "staging")

        let stored = await memory.storedResponse(forQuestion: "Which environment should I target?")
        XCTAssertEqual(stored, .some("staging"))
    }

    func testStoredResponse_QuestionKeyIgnoresWhitespaceAndCase() async {
        let memory = RunInteractionMemory()
        await memory.recordAnswer(question: "Which  Environment should\nI target?", response: "staging")

        let stored = await memory.storedResponse(forQuestion: "which environment should i target?")
        XCTAssertEqual(stored, .some("staging"), "Incidental formatting must not defeat the replay")
    }

    func testStoredResponse_SkipIsStoredAndReplayed() async {
        let memory = RunInteractionMemory()
        await memory.recordAnswer(question: "Optional detail?", response: nil)

        // Outer .some = "was asked"; inner nil = "user skipped" — must be distinguishable
        // from never-asked (outer nil).
        let stored = await memory.storedResponse(forQuestion: "Optional detail?")
        XCTAssertEqual(stored, .some(nil), "A skip must be stored (and replayed), not treated as never-asked")

        let neverAsked = await memory.storedResponse(forQuestion: "A different question?")
        XCTAssertNil(neverAsked)
    }

    // MARK: - Denials

    func testIsDenied_MatchesIdenticalRequestOnly() async {
        let memory = RunInteractionMemory()
        await memory.recordDenial(toolName: "write_file", params: "{\"path\":\"/a\"}")

        let sameRequest = await memory.isDenied(toolName: "write_file", params: "{\"path\":\"/a\"}")
        let differentArgs = await memory.isDenied(toolName: "write_file", params: "{\"path\":\"/b\"}")
        let differentTool = await memory.isDenied(toolName: "delete_file", params: "{\"path\":\"/a\"}")

        XCTAssertTrue(sameRequest, "The identical request must be auto-denied")
        XCTAssertFalse(differentArgs, "Different arguments must still reach the user")
        XCTAssertFalse(differentTool, "A different tool must still reach the user")
    }
}
