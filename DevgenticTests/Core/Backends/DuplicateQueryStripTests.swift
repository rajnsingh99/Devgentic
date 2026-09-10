// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DuplicateQueryStripTests.swift
//  DevgenticTests
//
//  The current question must not appear twice: once as the request's `userQuery` and again as the
//  last row of the history that accompanies it.
//
//  `BackendOrchestrationService` stripped it by TEXT EQUALITY against `conversationHistory.last`,
//  and that failed in two independent ways that both shipped:
//
//    IDENTITY — Jarvis sends the model a DECORATED query (the spoken command plus a TTS style
//    hint) while persisting the clean command. The texts differ, so the strip never fired, the
//    message survived into the blob, and `EpisodicHistoryFormatter.pairTurns` emitted it through
//    its orphan handler as `wasCancelled` / "Agent never responded to this query". Every voice
//    turn in the spoken modes told the model that the question it was being asked had already
//    been abandoned.
//
//    POSITION — `.last` is the current message only if history is ascending. `SchedulerCoordinator`
//    shipped a DESCENDING array, where `.last` is the OLDEST row: the strip could not fire, so the
//    query was double-prompted — and on a RECURRING scheduled task, where every firing sends the
//    same prompt, that oldest row had identical text and `removeLast()` silently DELETED the
//    conversation's first turn from model context.
//
//  ⚠️ THESE TESTS CALL THE PRODUCTION RULE. They did not until 2026-09-07: the file carried a
//  private `strip(_:userQuery:currentUserMessageID:)` that RE-IMPLEMENTED the two branches, and
//  every test called that copy. Nothing in the repo reached
//  `BackendOrchestrationService.strippingCurrentQuery` by any route, so deleting the production
//  branches outright left all six green — and because `currentUserMessageID` carries a `= nil`
//  default, dropping the argument at its one call site still COMPILED, silently reverting every
//  surface to the text compare with the suite untouched. That is the shape this project's own
//  memory records as "policy tests go green over broken wiring". The copy is gone; the rule was
//  extracted to `nonisolated static` so it can be called here with no service and no backend, and
//  `testTheCallSiteStillPassesTheMessageId` guards the argument that makes any of it run.
//

import XCTest
@testable import devgentic


@MainActor
final class DuplicateQueryStripTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func message(_ offset: Int, sender: SenderRole, text: String) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: convID,
                    timestamp: t0.addingTimeInterval(TimeInterval(offset)),
                    sender: sender, content: .plainText(text))
    }

    /// The production rule. No local reimplementation — that is the point of this file.
    private func strip(_ history: [ChatMessage],
                       userQuery: String,
                       currentUserMessageID: UUID?) -> [ChatMessage] {
        BackendOrchestrationService.strippingCurrentQuery(
            from: history, userQuery: userQuery, currentUserMessageID: currentUserMessageID
        ).history
    }

    private func outcome(_ history: [ChatMessage],
                         userQuery: String,
                         currentUserMessageID: UUID?) -> BackendOrchestrationService.CurrentQueryStripOutcome {
        BackendOrchestrationService.strippingCurrentQuery(
            from: history, userQuery: userQuery, currentUserMessageID: currentUserMessageID
        ).outcome
    }

    // MARK: - Identity: the Jarvis defect

    /// ⚠️ THE DEFECT. A decorated query and a clean persisted message share an ID and differ in
    /// TEXT. Identity strips it; text cannot.
    func testADecoratedQueryStillStripsItsOwnCleanMessage() {
        let question = message(2, sender: .user, text: "summarise the release notes")
        let history = [message(0, sender: .user, text: "hello"),
                       message(1, sender: .agent, text: "hi"),
                       question]
        let decorated = "summarise the release notes\n\n(This request was spoken aloud; reply conversationally.)"

        let byID = strip(history, userQuery: decorated, currentUserMessageID: question.id)
        let byText = strip(history, userQuery: decorated, currentUserMessageID: nil)

        XCTAssertFalse(byID.contains { $0.id == question.id },
                       "the id matches even though the text does not — this is the fix")
        XCTAssertTrue(byText.contains { $0.id == question.id },
                      "and text equality demonstrably fails on the same input, which is why every "
                      + "Jarvis turn arrived as an orphan marked \"Agent never responded\"")
    }

    /// The orphan is what the surviving row becomes downstream, so pin the actual consequence
    /// rather than only the strip's output.
    func testTheSurvivingQuestionIsWhatPairTurnsReportsAsAbandoned() {
        let question = message(2, sender: .user, text: "summarise the release notes")
        let history = [message(0, sender: .user, text: "hello"),
                       message(1, sender: .agent, text: "hi"),
                       question]

        let notStripped = strip(history, userQuery: "decorated form", currentUserMessageID: nil)
        let turns = EpisodicHistoryFormatter.pairTurns(from: notStripped)

        XCTAssertEqual(turns.last?.terminalReason, "Agent never responded to this query",
                       "the un-stripped current question is reported to the model as abandoned")
        XCTAssertTrue(turns.last?.wasCancelled ?? false)

        let stripped = strip(history, userQuery: "decorated form", currentUserMessageID: question.id)
        let cleanTurns = EpisodicHistoryFormatter.pairTurns(from: stripped)
        XCTAssertNotEqual(cleanTurns.last?.terminalReason, "Agent never responded to this query",
                          "stripping by id removes the orphan entirely")
    }

    // MARK: - Position: the recurring-scheduled-task defect

    /// ⚠️ THE WORST ONE. A recurring task sends the same prompt every firing. On a descending
    /// array `.last` is the conversation's FIRST-EVER message, whose text is identical — so the
    /// text strip deleted a real historical turn. An id strip cannot: it removes the row that IS
    /// the current message, wherever it sits.
    func testARecurringPromptDoesNotDeleteTheOldestIdenticalTurn() {
        let prompt = "daily standup summary"
        let firstFiring = message(0, sender: .user, text: prompt)
        let reply = message(1, sender: .agent, text: "yesterday you…")
        let thisFiring = message(2, sender: .user, text: prompt)
        let descending = [thisFiring, reply, firstFiring]      // what the scheduler used to ship

        let byText = strip(descending, userQuery: prompt, currentUserMessageID: nil)
        let byID = strip(descending, userQuery: prompt, currentUserMessageID: thisFiring.id)

        XCTAssertFalse(byText.contains { $0.id == firstFiring.id },
                       "text-at-.last deleted the conversation's FIRST turn — the historical bug")
        XCTAssertTrue(byID.contains { $0.id == firstFiring.id },
                      "id strip leaves history intact…")
        XCTAssertFalse(byID.contains { $0.id == thisFiring.id },
                       "…and removes the row that actually is the current question")
    }

    /// Position independence, stated directly: the strip must find the current message wherever
    /// it sits, not only at the end.
    func testTheCurrentMessageIsStrippedFromAnyPosition() {
        let question = message(1, sender: .user, text: "q")
        for history in [[question, message(2, sender: .agent, text: "a")],
                        [message(0, sender: .user, text: "older"), question],
                        [question]] {
            let out = strip(history, userQuery: "q", currentUserMessageID: question.id)
            XCTAssertFalse(out.contains { $0.id == question.id })
            XCTAssertEqual(out.count, history.count - 1, "exactly one row removed")
        }
    }

    // MARK: - ⚠️ The text fallback must be gated on the id being ABSENT, not on the lookup failing

    /// ⚠️ THE REGRESSION THIS SECTION EXISTS FOR (found and fixed 2026-09-07). The text branch was
    /// written as `else if let lastMsg = …` chained to the whole id condition — including the
    /// `firstIndex` LOOKUP. So a supplied id that matched nothing fell through to text equality,
    /// and `removeLast()` deleted a row that was NOT the current question: the id scan's entire
    /// purpose, defeated through its own fallback. It also pre-empted the `idNotFound` error
    /// written for exactly that state, so the loud line could never fire.
    ///
    /// This is the resume/regenerate shape: the question sits outside the resolved window, and the
    /// last row is a DIFFERENT user turn that happens to carry the same text (a retry, or a
    /// recurring scheduled prompt).
    func testASuppliedIdThatMatchesNothingNeverFallsBackToText() {
        let olderIdenticalTurn = message(0, sender: .user, text: "retry the deploy")
        let history = [olderIdenticalTurn]
        let questionOutsideTheWindow = UUID()

        let out = strip(history, userQuery: "retry the deploy",
                        currentUserMessageID: questionOutsideTheWindow)

        XCTAssertEqual(out.map(\.id), [olderIdenticalTurn.id],
                       "the id was supplied and did not match; text equality must NOT then delete "
                       + "a different user turn that merely reads the same")
    }

    /// …and the state is reported, not swallowed — the caller logs `.error` on this outcome.
    func testAnUnmatchedIdIsReportedAsNotFound() {
        let history = [message(0, sender: .user, text: "retry the deploy")]
        let missing = UUID()

        XCTAssertEqual(outcome(history, userQuery: "retry the deploy", currentUserMessageID: missing),
                       .idNotFound(id: missing, rows: 1),
                       "the caller's .error branch depends on this outcome being distinguishable "
                       + "from a successful strip and from nothing-to-strip")
    }

    /// The text path still works for a caller that genuinely supplies no id, and says so.
    func testTheTextPathRemainsForACallerWithNoId() {
        let question = message(1, sender: .user, text: "q")
        let history = [message(0, sender: .agent, text: "a"), question]

        XCTAssertEqual(outcome(history, userQuery: "q", currentUserMessageID: nil), .strippedByText)
        XCTAssertEqual(strip(history, userQuery: "q", currentUserMessageID: nil).map(\.id),
                       [history[0].id])
    }

    // MARK: - It must not over-strip

    /// Two turns with identical text (a user repeating themselves) must lose only the current one.
    func testRepeatedTextLosesOnlyTheCurrentTurn() {
        let earlier = message(0, sender: .user, text: "retry")
        let current = message(2, sender: .user, text: "retry")
        let history = [earlier, message(1, sender: .agent, text: "ok"), current]

        let out = strip(history, userQuery: "retry", currentUserMessageID: current.id)

        XCTAssertEqual(out.map(\.id), [earlier.id, history[1].id])
    }

    /// Nothing matching and no id: history is returned untouched rather than losing its tail.
    func testAnUnrelatedLastRowIsLeftAlone() {
        let history = [message(0, sender: .user, text: "q"), message(1, sender: .agent, text: "a")]
        XCTAssertEqual(outcome(history, userQuery: "q", currentUserMessageID: nil), .nothingToStrip)
        XCTAssertEqual(strip(history, userQuery: "q", currentUserMessageID: nil).map(\.id),
                       history.map(\.id))
    }

    // MARK: - Wiring

    /// ⚠️ EVERY ASSERTION ABOVE IS WORTHLESS IF THE CALL SITE STOPS PASSING THE ID.
    /// `currentUserMessageID` has a `= nil` default, so deleting the argument at
    /// `ActiveStreamManager`'s call to `streamMessage` COMPILES and silently reverts every surface
    /// in the app to the text compare — the exact defect this file documents — with no test
    /// failing. A unit test structurally cannot see that; a source scan can.
    func testTheCallSiteStillPassesTheMessageId() throws {
        // FOUR components: file → Backends → Core → DevgenticTests → repo root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = repoRoot.appendingPathComponent("Devgentic")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sources.path),
                          "sources not reachable at \(sources.path) — running outside a checkout")

        func code(_ path: String) throws -> String {
            try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        let caller = try code("Devgentic/Core/Utils/ActiveStreamManager.swift")
        XCTAssertTrue(caller.contains("currentUserMessageID: userMessage.id"),
                      "the send path must identify the current question to the strip; without it "
                      + "the argument defaults to nil and every surface silently reverts to text "
                      + "equality, which cannot match a decorated Jarvis query")

        let service = try code("Devgentic/Core/Backends/BackendOrchestrationService.swift")
        XCTAssertTrue(service.contains("Self.strippingCurrentQuery("),
                      "the service must call the extracted rule, not re-inline the branches — "
                      + "an inlined copy is unreachable from this file and untestable")

        // ⚠️ JOINED, not line-by-line: the guard is written across two lines. A per-line scan
        // sees neither half and passes over the exact shape it exists to catch.
        XCTAssertTrue(service.contains("if currentUserMessageID {")
                      || service.contains("if let currentUserMessageID {"),
                      "the id branch must be entered on the id being PRESENT, with the lookup "
                      + "failing INSIDE it — chaining the text fallback to the lookup is what let "
                      + "a supplied-but-unmatched id delete an unrelated row")
    }
}
