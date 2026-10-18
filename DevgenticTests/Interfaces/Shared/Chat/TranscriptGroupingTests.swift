// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TranscriptGroupingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class TranscriptGroupingTests: XCTestCase {

    private let conversation = UUID()
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func next() -> Date { clock = clock.addingTimeInterval(1); return clock }

    private func typed(_ text: String = "run the build") -> ChatMessage {
        ChatMessage(conversationId: conversation, timestamp: next(), sender: .user, content: .markdownText(text))
    }

    private func reply(_ text: String = "Started it.") -> ChatMessage {
        ChatMessage(conversationId: conversation, timestamp: next(), sender: .agent, content: .markdownText(text))
    }

    private func stub(log: String = "/l/\(UUID()).log", card: Bool = true) -> ChatMessage {
        let m = ChatMessage(conversationId: conversation, timestamp: next(), sender: .user,
                            content: .markdownText("Background task A (bg_5) finished (exit 0)."))
        m.messageSource = .backgroundTask
        m.isSyntheticPrompt = true
        if card { m.timelineEvents = [.backgroundTask(self.card(log: log, variant: nil))] }
        return m
    }

    private func card(log: String, variant: UUID?, status: BackgroundTaskStatus = .exited) -> BackgroundTaskData {
        BackgroundTaskData(id: UUID(), taskID: "bg_5", name: "A", command: "sleep 15", workingDirectory: "/tmp",
                           startedAt: clock, finishedAt: status == .running ? nil : clock, status: status,
                           exitCode: status == .exited ? 0 : nil, logPath: log, outputTail: "A",
                           logCharacterCount: 1, variantID: variant)
    }

    private func continuation(_ role: TranscriptGrouping.Role?) -> TranscriptGrouping.Continuation? {
        if case .continuation(let c)? = role { return c }
        return nil
    }

    // MARK: - Groups

    func testAConversationWithoutReportsIsUnchanged() {
        let messages = [typed(), reply(), typed(), reply()]
        let roles = TranscriptGrouping.roles(oldestFirst: messages)
        XCTAssertTrue(messages.allSatisfy { roles[$0.id] == .plain })
    }

    /// ⚠️ THE REPORTED SHAPE (the screenshot): one turn, two reports.
    func testReportsJoinTheTurnThatPrecedesThem() throws {
        let q = typed(), r = reply(), s1 = stub(), rep1 = reply("A done"), s2 = stub(), rep2 = reply("B done")
        let roles = TranscriptGrouping.roles(oldestFirst: [q, r, s1, rep1, s2, rep2])

        XCTAssertEqual(roles[q.id], .plain)
        XCTAssertEqual(roles[r.id], .head(groupEndID: rep2.id), "the turn's own action bar must move to the group's end")

        let stub1 = try XCTUnwrap(continuation(roles[s1.id]), "the stub is still drawn as a divider")
        XCTAssertTrue(stub1.isStub && stub1.hasReport, "a stub whose report follows is drawn BY the report")
        let report1 = try XCTUnwrap(continuation(roles[rep1.id]), "a report is drawn as a new exchange")
        XCTAssertEqual(report1.headID, r.id)
        XCTAssertEqual(report1.stubID, s1.id, "the report's header needs its stub's words")
        XCTAssertFalse(report1.isGroupEnd)
        XCTAssertTrue(try XCTUnwrap(continuation(roles[rep2.id])).isGroupEnd, "only the LAST member draws the bar")
    }

    /// A human message closes the group; a report that arrives after it joins the NEW turn, in time
    /// order, even though an earlier turn started its task.
    func testAReportAfterANewHumanTurnJoinsThatTurn() {
        let r1 = reply(), q2 = typed("something else"), r2 = reply(), s = stub(), rep = reply()
        let roles = TranscriptGrouping.roles(oldestFirst: [typed(), r1, q2, r2, s, rep])
        XCTAssertEqual(roles[r1.id], .plain, "the first turn has no continuations")
        XCTAssertEqual(roles[r2.id], .head(groupEndID: rep.id))
        XCTAssertEqual(continuation(roles[rep.id])?.headID, r2.id)
    }

    /// ⚠️ A typed message with no reply yet (its run failed before writing one) still closes the
    /// group: a report after it must not reach back over it into the older turn — the group's bar
    /// would then sit below the new question and act for the old one.
    func testAReportNeverJoinsAGroupAcrossATypedMessage() {
        let r1 = reply(), q2 = typed("and another thing"), s = stub(), rep = reply()
        let roles = TranscriptGrouping.roles(oldestFirst: [typed(), r1, q2, s, rep])
        XCTAssertEqual(roles[r1.id], .plain, "the older turn swallowed a report that came after a newer question")
        XCTAssertEqual(roles[s.id], .orphanStub)
    }

    /// A wake queued behind a run: the stub is saved, its report not yet started.
    func testAStubWithoutItsReportYetEndsTheGroupAndDrawsItself() throws {
        let r = reply(), s = stub()
        let roles = TranscriptGrouping.roles(oldestFirst: [typed(), r, s])
        let c = try XCTUnwrap(continuation(roles[s.id]))
        XCTAssertFalse(c.hasReport, "a lone stub would be drawn by a report that does not exist — i.e. not at all")
        XCTAssertTrue(c.isGroupEnd)
        XCTAssertEqual(roles[r.id], .head(groupEndID: s.id))
    }

    /// Nothing in front to continue: the divider stays, and the report is drawn as before.
    func testAStubAtTheStartOfTheConversationKeepsItsDivider() {
        let s = stub(), rep = reply()
        let roles = TranscriptGrouping.roles(oldestFirst: [s, rep, typed(), reply()])
        XCTAssertEqual(roles[s.id], .orphanStub)
        XCTAssertEqual(roles[rep.id], .plain)
    }

    /// ⚠️ THE TRANSCRIPT'S INVARIANT: no synthetic row is ever drawn as a user bubble, whatever
    /// surface wrote it. `.plain` IS the user bubble.
    func testNoSyntheticRowIsEverPlainWhateverItsSource() {
        for source in [MessageSource.backgroundTask, .localUI, .scheduled] {
            let m = stub()
            m.messageSource = source
            let alone = TranscriptGrouping.roles(oldestFirst: [m, reply()])[m.id]
            let inGroup = TranscriptGrouping.roles(oldestFirst: [typed(), reply(), m, reply()])[m.id]
            XCTAssertNotEqual(alone, .plain, "a \(source) synthetic row at the start renders as a user bubble")
            XCTAssertNotEqual(inGroup, .plain, "a \(source) synthetic row in a turn renders as a user bubble")
        }
    }

    /// A scheduled or ChatOps turn is a real question — it opens a group like a typed one.
    func testOnlyAWakeStubIsAContinuation() {
        let scheduled = typed("daily summary")
        scheduled.messageSource = .scheduled
        let r = reply()
        let roles = TranscriptGrouping.roles(oldestFirst: [typed(), reply(), scheduled, r])
        XCTAssertEqual(roles[scheduled.id], .plain)
        XCTAssertEqual(roles[r.id], .plain)
    }

    // MARK: - Folding reports from an earlier attempt

    /// The turn was redone: the task behind this report was started by attempt 1, attempt 2 is on
    /// screen — so the report is folded, not shown as an answer to attempt 2.
    func testAReportFromAnEarlierAttemptIsFolded() throws {
        let r = reply()
        let first = try XCTUnwrap(r.agentResponse?.variants.first?.variantId)
        XCTAssertTrue(r.beginRegenerationVariant(backendEntityId: nil))
        r.isStreaming = false
        let log = "/l/\(UUID()).log"
        r.timelineEvents = [.backgroundTask(card(log: log, variant: first))]
        let s = stub(log: log), rep = reply()

        let roles = TranscriptGrouping.roles(oldestFirst: [typed(), r, s, rep])
        XCTAssertEqual(continuation(roles[s.id])?.fold, TranscriptGrouping.Fold(isFirst: true, count: 1))
        XCTAssertEqual(continuation(roles[rep.id])?.fold, TranscriptGrouping.Fold(isFirst: false, count: 1),
                       "the report must fold with its stub, and only one of them draws the fold row")
    }

    func testAReportFromTheCurrentAttemptIsNotFolded() throws {
        let r = reply()
        let current = try XCTUnwrap(r.agentResponse?.variants.first?.variantId)
        let log = "/l/\(UUID()).log"
        r.timelineEvents = [.backgroundTask(card(log: log, variant: current))]
        let s = stub(log: log), rep = reply()
        let roles = TranscriptGrouping.roles(oldestFirst: [typed(), r, s, rep])
        XCTAssertNil(continuation(roles[rep.id])?.fold)
    }

    /// Anything written before the attempt was recorded is shown, never folded away.
    func testCardsWithoutAnAttemptAreNeverFolded() throws {
        let r = reply()
        XCTAssertTrue(r.beginRegenerationVariant(backendEntityId: nil))
        let log = "/l/\(UUID()).log"
        r.timelineEvents = [.backgroundTask(card(log: log, variant: nil))]
        let roles = TranscriptGrouping.roles(oldestFirst: [typed(), r, stub(log: log), reply()])
        XCTAssertTrue(roles.values.allSatisfy { continuation($0)?.fold == nil })
    }

    /// A report whose task another turn started is not an attempt of this head.
    func testAReportForAnotherTurnsTaskIsNotFolded() {
        let r = reply()
        XCTAssertTrue(r.beginRegenerationVariant(backendEntityId: nil))
        let roles = TranscriptGrouping.roles(oldestFirst: [typed(), r, stub(), reply()])
        XCTAssertTrue(roles.values.allSatisfy { continuation($0)?.fold == nil })
    }

    // MARK: - Header

    func testTheContinuationHeaderReadsAsTheStubPlusItsSteps() {
        XCTAssertEqual(AgentTimelineView.continuationTitle(lead: "Background task A (bg_5) finished (exit 0)", stepsCount: 3),
                       "↳ Background task A (bg_5) finished (exit 0) · 3 steps")
        XCTAssertEqual(AgentTimelineView.continuationTitle(lead: "X", stepsCount: 1), "↳ X · 1 step")
        XCTAssertEqual(AgentTimelineView.continuationTitle(lead: "X", stepsCount: 0), "↳ X")
        XCTAssertEqual(TranscriptGrouping.leadText(forStub: stub()), "Background task A (bg_5) finished (exit 0)")
    }

    // MARK: - Redo while the turn's task runs

    func testRedoIsRefusedWhileATaskThisTurnStartedIsRunning() {
        let r = reply()
        r.timelineEvents = [.backgroundTask(card(log: "/l/x.log", variant: nil, status: .running))]
        XCTAssertEqual(MessagingCoordinator.runningTaskID(startedBy: r), "bg_5")
        XCTAssertEqual(RunAdmissionPolicy.admitRegeneration(in: conversation, attempts: 1, live: [],
                                                            isReport: false, reportCardSaved: false,
                                                            runningTaskID: "bg_5"),
                       .backgroundTaskRunning(taskID: "bg_5"))
    }

    func testRedoIsAllowedOnceTheTaskEnds() {
        let r = reply()
        r.timelineEvents = [.backgroundTask(card(log: "/l/x.log", variant: nil, status: .exited))]
        XCTAssertNil(MessagingCoordinator.runningTaskID(startedBy: r))
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheTranscriptDrawsTheGroups() throws {
        let code = try source("Devgentic/Interfaces/Shared/Chat/ChatHistoryView.swift")
        XCTAssertTrue(code.contains("TranscriptGrouping.roles(oldestFirst: displayMessages)"), "the transcript is not grouped")
        XCTAssertTrue(code.contains("groupStyle: .continuation(lead: TranscriptGrouping.leadText(forStub: stub))"),
                      "a report is not drawn as a continuation")
        XCTAssertTrue(code.contains("AgentMessageActionsView(message: head, groupMessages: members"),
                      "the group has no action bar")
    }

    /// The Redo buttons and both runtime checks go through `regenerationRefusal`; it must pass the
    /// running task in, or the policy's refusal is never reached.
    func testRedoChecksForTheTurnsRunningTask() throws {
        let code = try source("Devgentic/Interfaces/Main/MessagingCoordinator.swift")
        XCTAssertTrue(code.contains("runningTaskID: Self.runningTaskID(startedBy: agentMessage)"),
                      "Redo never asks whether the turn's task is still running")
    }

    func testAGroupedBubbleWithholdsItsOwnBarAndCarriesTheLead() throws {
        let bubble = try source("Devgentic/Interfaces/Shared/Chat/AgentBubbleContentView.swift")
        XCTAssertTrue(bubble.contains("if groupStyle == .standalone && !message.isStreaming"),
                      "a grouped bubble still draws its own action bar")
        XCTAssertTrue(bubble.contains("AgentTimelineView(message: message, continuationLead: groupStyle.lead)"),
                      "the report's header does not carry the stub's lead-in")
    }
}

/// The attempt stamp that folding reads — something must actually write it.
@MainActor
final class BackgroundTaskAttemptStampTests: XCTestCase {

    func testTheCardRecordsTheAttemptThatStartedIt() throws {
        let conversation = UUID()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("attempt-\(UUID())")
        let registry = BackgroundProcessRegistry(rootDirectory: root)
        defer { registry.terminateAll(); try? FileManager.default.removeItem(at: root) }

        let message = ChatMessage(conversationId: conversation, sender: .agent, content: .markdownText(""))
        XCTAssertTrue(message.beginRegenerationVariant(backendEntityId: nil))
        let attempt = try XCTUnwrap(BackgroundTaskObserver.currentVariantID(of: message))
        XCTAssertNotEqual(attempt, message.agentResponse?.variants.first?.variantId, "the redo's attempt must be the NEW one")

        let observer = BackgroundTaskObserver(registry: registry)
        observer.start { id in id == conversation ? message : nil }
        try registry.launch(command: "sleep 0.3; echo hi", workingDirectory: NSTemporaryDirectory(),
                            timeout: 30, conversationID: conversation)

        func row() -> BackgroundTaskData? {
            message.timelineEvents.lazy.compactMap { if case .backgroundTask(let d) = $0 { return d }; return nil }.first
        }
        let deadline = Date().addingTimeInterval(8)
        while row()?.status != .exited, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        XCTAssertEqual(row()?.status, .exited, "the task never finished")
        XCTAssertEqual(row()?.variantID, attempt,
                       "the attempt is missing — or was dropped by the update that recorded the ending")
    }
}
