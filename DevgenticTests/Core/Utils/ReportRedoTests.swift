// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReportRedoTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class ReportRedoTests: XCTestCase {

    private let conversationID = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func card(status: BackgroundTaskStatus = .exited, exitCode: Int32? = 0,
                      tail: String = "BUILD SUCCEEDED", name: String? = "Build") -> BackgroundTaskData {
        BackgroundTaskData(id: UUID(), taskID: "bg_5", name: name, command: "swift build",
                           workingDirectory: "/tmp/proj", startedAt: t0, finishedAt: t0.addingTimeInterval(42),
                           status: status, exitCode: exitCode, logPath: "/l/bg_5.log",
                           outputTail: tail, logCharacterCount: tail.count)
    }

    private func stub(with card: BackgroundTaskData?) -> ChatMessage {
        let message = ChatMessage(conversationId: conversationID, timestamp: t0.addingTimeInterval(43), sender: .user,
                                  content: .markdownText("Background task Build (bg_5) finished (exit 0)."))
        message.messageSource = .backgroundTask
        message.isSyntheticPrompt = true
        if let card { message.timelineEvents = [.backgroundTask(card)] }
        return message
    }

    private func report() -> ChatMessage {
        ChatMessage(conversationId: conversationID, timestamp: t0.addingTimeInterval(44), sender: .agent,
                    content: .markdownText("The build succeeded."))
    }

    // MARK: - The prompt a Redo sends

    /// ⚠️ THE DEFECT: the redo must carry the task's OUTPUT, not the one-line stub.
    func testTheRebuiltPromptCarriesTheOutputAndSaysThereAreNoTools() {
        let prompt = BackgroundTaskWakeCoordinator.prompt(for: card(tail: "error: missing semicolon"))
        XCTAssertTrue(prompt.contains("error: missing semicolon"), "the redo is not given the task's output")
        XCTAssertTrue(prompt.contains("swift build"))
        XCTAssertTrue(prompt.contains("Outcome: finished (exit 0)"), prompt)
        XCTAssertTrue(prompt.contains("Ran for: 42s"), prompt)
        XCTAssertTrue(prompt.contains("NO TOOLS"), "the redo must say it cannot act, like the original")
    }

    /// The redo asks the same question the original wake did — one wording, two sources.
    func testTheRebuiltPromptMatchesTheOriginalWakePrompt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("redo-\(UUID())")
        let registry = BackgroundProcessRegistry(rootDirectory: root)
        defer { registry.terminateAll(); try? FileManager.default.removeItem(at: root) }
        let launched = try registry.launch(command: "echo done", workingDirectory: NSTemporaryDirectory(),
                                           timeout: 30, conversationID: conversationID, name: "Echo")
        let deadline = Date().addingTimeInterval(8)
        var snapshot = registry.snapshot(conversationID: conversationID, taskID: launched.id)
        while snapshot?.status.isTerminal != true, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            snapshot = registry.snapshot(conversationID: conversationID, taskID: launched.id)
        }
        let finished = try XCTUnwrap(snapshot)
        XCTAssertTrue(finished.status.isTerminal, "the task never finished")

        XCTAssertEqual(BackgroundTaskWakeCoordinator.prompt(for: BackgroundTaskData(snapshot: finished)),
                       BackgroundTaskWakeCoordinator.prompt(for: finished),
                       "a redone report is asked a different question from the one it answered")
    }

    func testEveryOutcomeIsWordedLikeTheRegistry() {
        typealias W = BackgroundTaskWakeCoordinator
        XCTAssertEqual(W.outcomeLabel(for: card(exitCode: 0)), BackgroundProcessRegistry.Status.exited(code: 0).label)
        XCTAssertEqual(W.outcomeLabel(for: card(exitCode: 2)), BackgroundProcessRegistry.Status.exited(code: 2).label)
        XCTAssertEqual(W.outcomeLabel(for: card(status: .timedOut, exitCode: nil)), BackgroundProcessRegistry.Status.timedOut.label)
        XCTAssertEqual(W.outcomeLabel(for: card(status: .stopped, exitCode: nil)), BackgroundProcessRegistry.Status.stopped.label)
        XCTAssertEqual(W.outcomeLabel(for: card(status: .interrupted, exitCode: nil)), "ended when the app quit")
    }

    // MARK: - Finding the card

    func testTheCardIsReadBackFromTheStub() {
        let saved = card()
        XCTAssertEqual(BackgroundTaskWakeCoordinator.reportCard(behind: stub(with: saved)), saved)
    }

    /// A stub written before the card was kept has nothing to rebuild from.
    func testALegacyStubHasNoCard() {
        XCTAssertNil(BackgroundTaskWakeCoordinator.reportCard(behind: stub(with: nil)))
    }

    /// Only a WAKE stub counts — an ordinary user message carrying a card is not one.
    func testAnOrdinaryMessageIsNotAStub() {
        let typed = stub(with: card())
        typed.isSyntheticPrompt = false
        XCTAssertNil(BackgroundTaskWakeCoordinator.reportCard(behind: typed))
        let other = stub(with: card())
        other.messageSource = .scheduled
        XCTAssertNil(BackgroundTaskWakeCoordinator.reportCard(behind: other))
    }

    /// The card must survive the store, or Redo works only until the next relaunch.
    func testTheStubsCardSurvivesTheStore() {
        let saved = card()
        let restored = ChatMessageSD.from(stub(with: saved)).toChatMessage()
        XCTAssertEqual(BackgroundTaskWakeCoordinator.reportCard(behind: restored), saved,
                       "the card is lost on reload, so every report becomes un-redoable after a relaunch")
    }

    /// Transcript order is newest-first; the stub is the message just OLDER than the report.
    func testTheStubInFrontOfAReportIsFound() {
        let theStub = stub(with: card())
        let theReport = report()
        let earlier = report()
        let messages = [theReport, theStub, earlier]
        XCTAssertEqual(MessagingCoordinator.precedingWakeStub(for: theReport, in: messages)?.id, theStub.id)
        XCTAssertNil(MessagingCoordinator.precedingWakeStub(for: earlier, in: messages), "the oldest message has nothing in front")
    }

    /// Keyed on the STUB, so reports saved before they were stamped are still recognised.
    func testAnUnstampedReportIsStillRecognisedByItsStub() {
        let theReport = report()
        XCTAssertEqual(theReport.messageSource, .localUI)
        XCTAssertNotNil(MessagingCoordinator.precedingWakeStub(for: theReport, in: [theReport, stub(with: nil)]))
    }

    func testAReplyToATypedMessageIsNotAReport() {
        let typed = ChatMessage(conversationId: conversationID, sender: .user, content: .markdownText("hi"))
        let reply = report()
        XCTAssertNil(MessagingCoordinator.precedingWakeStub(for: reply, in: [reply, typed]))
    }

    // MARK: - Admission

    func testAReportWithoutACardIsRefused() {
        XCTAssertEqual(RunAdmissionPolicy.admitRegeneration(in: conversationID, attempts: 1, live: [],
                                                            isReport: true, reportCardSaved: false),
                       .reportOutputNotSaved)
    }

    func testAReportWithACardIsAdmitted() {
        XCTAssertNil(RunAdmissionPolicy.admitRegeneration(in: conversationID, attempts: 1, live: [],
                                                          isReport: true, reportCardSaved: true))
    }

    func testAnOrdinaryRedoIsUnaffected() {
        XCTAssertNil(RunAdmissionPolicy.admitRegeneration(in: conversationID, attempts: 1, live: []))
        XCTAssertNil(RunAdmissionPolicy.admitRegeneration(in: conversationID, attempts: 1, live: [],
                                                          isReport: false, reportCardSaved: false))
    }

    // MARK: - Wiring (source scans: `wake` and `continueRegeneration` need a full view model)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheWakeSavesTheCardAndStampsTheReport() throws {
        let code = try source("Devgentic/Core/Utils/BackgroundTaskWakeCoordinator.swift")
        XCTAssertTrue(code.contains("userMessage.timelineEvents = [.backgroundTask(BackgroundTaskData(snapshot: snapshot))]"),
                      "the stub no longer keeps the task card, so its report cannot be redone")
        XCTAssertTrue(code.contains("report.messageSource = .backgroundTask"),
                      "the report is not stamped, so the trimmed action row never applies to a real report")
    }

    func testRedoOnAReportSendsTheRebuiltPromptReportOnly() throws {
        let code = try source("Devgentic/Interfaces/Main/MessagingCoordinator.swift")
        XCTAssertTrue(code.contains("let promptOverride = reportCard.map(BackgroundTaskWakeCoordinator.prompt(for:))"),
                      "the redo does not rebuild the report prompt")
        XCTAssertTrue(code.contains("promptOverride: promptOverride"),
                      "the rebuilt prompt is not sent — the redo reports from the one-line stub")
        guard let bind = code.range(of: "ReportOnlyRun.$isActive.withValue(reportCard != nil)"),
              let send = code.range(of: "startMessageStream(", range: bind.upperBound..<code.endIndex) else {
            return XCTFail("a redone report runs with the profile's full toolset on untrusted output")
        }
        XCTAssertLessThan(bind.lowerBound, send.lowerBound)
        XCTAssertTrue(code.contains("reportCardSaved: stub.flatMap(BackgroundTaskWakeCoordinator.reportCard(behind:)) != nil"),
                      "admission does not check for the card, so a legacy report's redo is not refused")
    }

    func testTheButtonsAskTheSameRule() throws {
        let code = try source("Devgentic/Interfaces/Main/MainApplicationViewModel.swift")
        XCTAssertTrue(code.contains("messagingCoordinator.regenerationRefusal(for: message)"),
                      "the Redo/Retry buttons use a rule without the report check, so they stay live on a report that will be refused")
    }
}
