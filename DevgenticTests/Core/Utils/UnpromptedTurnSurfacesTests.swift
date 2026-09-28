// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UnpromptedTurnSurfacesTests.swift
//  DevgenticTests
//
//  What survives a relaunch, and what the two "expect more here" surfaces agree on.
//
//  ⚠️ THE DURABILITY HALF IS NOT COSMETIC. Every UI branch for a woken report keys off
//  `messageSource` / `isSyntheticPrompt`. Before the columns existed both reset on load, so the
//  divider became a user bubble and the trimmed action row grew its Redo back — the same message
//  rendering differently depending on when you looked at it. A round-trip test is the only thing
//  standing between that and a silent regression, because nothing else fails when a column is
//  dropped from a writer.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class UnpromptedTurnPersistenceTests: XCTestCase {

    /// ⚠️ Through `ChatMessageSD.from(_:)` → `toChatMessage()`, which is the pair the INSERT path
    /// uses. The UPDATE path is a separate writer and is covered below — a field can round-trip
    /// here and still be lost on every flush after the first.
    func testAWokenReportKeepsItsSourceAcrossTheStore() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent,
                                  content: .markdownText("The build finished."))
        message.messageSource = .backgroundTask

        let restored = ChatMessageSD.from(message).toChatMessage()

        XCTAssertEqual(restored.messageSource, .backgroundTask,
                       "a reloaded report reads as if the user had typed it, so the UI branches wrongly")
    }

    func testASyntheticStubKeepsItsMarkerAcrossTheStore() {
        let message = ChatMessage(conversationId: UUID(), sender: .user,
                                  content: .markdownText("Background task Build (bg_1) finished (exit 0)."))
        message.isSyntheticPrompt = true

        let restored = ChatMessageSD.from(message).toChatMessage()

        XCTAssertTrue(restored.isSyntheticPrompt,
                      "the stub reloads as an ordinary user message and renders as a bubble — "
                      + "which puts words in the user's mouth")
    }

    /// ⚠️ THE DEFAULT MUST BE THE QUIET ONE. Legacy rows carry neither column; if absent decoded as
    /// anything but "typed here, not synthetic", every message written before today would render
    /// as a background report.
    func testRowsWrittenBeforeTheColumnsExistedReadAsOrdinaryMessages() {
        let legacy = ChatMessageSD(
            id: UUID(), conversationId: UUID(), timestamp: Date(), senderType: "agent",
            traceID: nil, contentData: try! JSONEncoder().encode(MessageContent.plainText("old")),
            agentResponseData: nil, timelineEventsData: nil
        )

        let restored = legacy.toChatMessage()

        XCTAssertEqual(restored.messageSource, .localUI)
        XCTAssertFalse(restored.isSyntheticPrompt)
    }

    /// ⚠️⚠️ THE LATE-STAMP CASE, and the reason both fields are written on UPDATE and not only on
    /// INSERT. `ActiveStreamManager` creates the agent message and the surface stamps
    /// `messageSource` AFTER `startMessageStream` returns, so the first flush of a run can reach
    /// disk while the field still reads `.localUI`. A writer that only set it on insert would
    /// persist every woken report as locally typed, and the bug would be invisible until reload.
    /// ⚠️ Drives the REAL `ChatPersistenceStore`, not a hand-rolled `context.save()`. An earlier
    /// draft of this test set `row.messageSourceRaw` itself and asserted it came back — which is a
    /// transcription of the production line, not a test of it: deleting that line from
    /// `ChatPersistenceStore`'s update branch left the test green. Going through `addMessage`
    /// twice is what makes the UPDATE writer the thing under test.
    func testASourceStampedAfterTheFirstFlushStillReachesDisk() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self,
            configurations: config
        )
        let store = ChatPersistenceStore.shared
        store.configureContainer(container)

        let conversationID = UUID()
        store.addConversation(from: Conversation(
            id: conversationID, messages: [], timestamp: Date(),
            userDefinedTitle: "wake", isPinned: false,
            backendType: nil, backendEntityId: nil
        ))

        let message = ChatMessage(conversationId: conversationID, sender: .agent,
                                  content: .markdownText("The build finished."))

        // First flush: the run has started but the surface has not stamped the source yet —
        // exactly the ordering `startMessageStream`'s own comment describes.
        await store.addMessage(message, toConversation: conversationID)

        // The surface stamps it; a later flush lands on the UPDATE branch.
        message.messageSource = .backgroundTask
        await store.addMessage(message, toConversation: conversationID)

        let reloaded = await store.fetchMessages(for: conversationID, offset: 0, limit: 10)
        let restored = try XCTUnwrap(reloaded.first { $0.id == message.id })
        XCTAssertEqual(restored.messageSource, .backgroundTask,
                       "the late stamp never reached disk — the UPDATE branch is not writing "
                       + "messageSourceRaw, so every woken report reloads as locally typed")
    }
}

/// The predicate the in-transcript footer and the sidebar badge SHARE.
///
/// ⚠️ Two surfaces, one function, on purpose. They answer different questions — "what should I
/// expect here" and "which conversation has something cooking" — and a drift between them would
/// show as a badge with no footer, or worse, a footer promising a message that never comes.
final class PendingBackgroundReportPredicateTests: XCTestCase {

    private func snapshot(notify: Bool, status: BackgroundProcessRegistry.Status)
        -> BackgroundProcessRegistry.Snapshot {
        BackgroundProcessRegistry.Snapshot(
            id: "bg_1", name: nil, command: "sleep 1", workingDirectory: "/tmp",
            startedAt: Date(), finishedAt: status.isTerminal ? Date() : nil,
            status: status, logURL: URL(fileURLWithPath: "/tmp/bg_1.log"),
            tail: "", notifyOnCompletion: notify, logCharacterCount: 0
        )
    }

    func testARunningTaskThatOptedInIsCounted() {
        let count = PendingBackgroundReports.count(in: [snapshot(notify: true, status: .running)])
        XCTAssertEqual(count, 1)
    }

    /// ⚠️ Load-bearing half one. A FINISHED task that opted in has already reported (or been
    /// refused by the hourly cap) — counting it leaves a footer up forever, promising a message
    /// that has already arrived.
    func testAFinishedTaskThatOptedInIsNotCounted() {
        let count = PendingBackgroundReports.count(in: [snapshot(notify: true, status: .exited(code: 0))])
        XCTAssertEqual(count, 0, "a task that has already reported must not keep the footer up")
    }

    /// ⚠️ Load-bearing half two. A RUNNING task that did NOT opt in ends silently, leaving its
    /// output on the card. Counting it promises a turn that will never be written.
    func testARunningTaskThatDidNotOptInIsNotCounted() {
        let count = PendingBackgroundReports.count(in: [snapshot(notify: false, status: .running)])
        XCTAssertEqual(count, 0, "a task that never asked to notify must not promise a report")
    }

    func testOnlyTheOptedInRunningTasksAreCounted() {
        let count = PendingBackgroundReports.count(in: [
            snapshot(notify: true, status: .running),
            snapshot(notify: true, status: .running),
            snapshot(notify: true, status: .exited(code: 1)),
            snapshot(notify: false, status: .running),
            snapshot(notify: false, status: .exited(code: 0))
        ])
        XCTAssertEqual(count, 2)
    }

    func testAnEmptyConversationPromisesNothing() {
        XCTAssertEqual(PendingBackgroundReports.count(in: []), 0)
    }

    /// ⚠️ THE ONLY ACTION A WOKEN REPORT KEEPS IS COPY, and Redo is why. `regenerateResponse`
    /// re-runs the user message preceding the reply — which for a report is the synthetic stub.
    /// Pressing it would ask the model to report on a task from a one-line stub, the output having
    /// lived in `promptOverride` and never been persisted, producing a confident answer about
    /// nothing. A wrong button that looks live is worse than an absent one.
    func testAWokenReportIsRecognisedAsUnprompted() {
        XCTAssertTrue(AgentMessageActionsView.isUnpromptedReport(source: .backgroundTask))
    }

    /// ⚠️ Every OTHER surface keeps its full action row. A predicate that answered "true" broadly
    /// would strip Redo, Read Aloud and the trace Report from ordinary chat — a far more visible
    /// regression than the one it exists to prevent, and one no other test would catch.
    func testOrdinaryAndRemoteTurnsKeepTheirFullActionRow() {
        for source: MessageSource in [.localUI, .telegram, .discord, .slack, .quickAccess, .orb] {
            XCTAssertFalse(AgentMessageActionsView.isUnpromptedReport(source: source),
                           "\(source.rawValue) lost its action row")
        }
    }

    /// ⚠️ A SCHEDULED run is unattended too, and is deliberately NOT folded in: it answers a
    /// question the user actually wrote when setting the task up, so Redo re-runs something real.
    func testAScheduledRunIsNotTreatedAsAWokenReport() {
        XCTAssertFalse(AgentMessageActionsView.isUnpromptedReport(source: .scheduled),
                       "scheduled runs lost Redo — their preceding message is a real user question")
    }

    /// ⚠️ A UNIT TEST CANNOT SEE THIS. The routing that keeps a stub out of a user bubble lives in
    /// a SwiftUI `ForEach` body, and there are TWO transcripts — the main window and the
    /// QuickAccess panel — showing the same conversations. Adding a third, or dropping the branch
    /// from either existing one, compiles cleanly and renders the stub as a message the user
    /// appears to have typed. A source scan is the only thing that notices.
    func testEveryTranscriptThatRendersBubblesKnowsAboutStubs() throws {
        // FOUR components: file → Utils → Core → DevgenticTests → repo root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = repoRoot.appendingPathComponent("Devgentic")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sources.path),
                          "sources not reachable at \(sources.path) — running outside a checkout")

        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sources,
                                                        includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = raw.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            // The DEFINITION names itself; only call sites are transcripts.
            guard code.contains("ChatBubbleView(message:"), !code.contains("struct ChatBubbleView")
            else { continue }
            // Either branch on the flag directly, or route through `TranscriptGrouping`, which
            // branches on it for every row (pinned behaviourally in `TranscriptGroupingTests`).
            if !code.contains("isSyntheticPrompt") && !code.contains("TranscriptGrouping.roles(") {
                offenders.append(url.lastPathComponent)
            }
        }

        XCTAssertTrue(offenders.isEmpty,
                      "these render ChatBubbleView without branching on isSyntheticPrompt, so a "
                      + "woken task's stub will draw as a user bubble there: "
                      + offenders.joined(separator: ", "))
    }

    /// ⚠️ Pins that the scan above has something to find. Written the obvious way it would pass
    /// vacuously the moment `ChatBubbleView(message:` were renamed — zero call sites, zero
    /// offenders, green. This fails instead.
    func testTheTranscriptScanActuallyFoundTranscripts() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = repoRoot.appendingPathComponent("Devgentic")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sources.path),
                          "sources not reachable — running outside a checkout")

        var callSites = 0
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let code = try? String(contentsOf: url, encoding: .utf8),
                  code.contains("ChatBubbleView(message:"),
                  !code.contains("struct ChatBubbleView") else { continue }
            callSites += 1
        }

        XCTAssertGreaterThanOrEqual(callSites, 2,
                                    "expected at least the main transcript and the QuickAccess "
                                    + "panel; found \(callSites) — the scan above is now vacuous")
    }

    /// A killed task is terminal too — `isTerminal` covers more than a clean exit, and a footer
    /// that only checked `case .exited` would hang around after every timeout.
    func testAKilledTaskIsTerminalAndStopsPromisingAReport() {
        XCTAssertEqual(PendingBackgroundReports.count(in: [snapshot(notify: true, status: .timedOut)]), 0)
        XCTAssertEqual(PendingBackgroundReports.count(in: [snapshot(notify: true, status: .stopped)]), 0)
    }
}
