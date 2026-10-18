// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WakeStubPairingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WakeStubPairingTests: XCTestCase {

    private let conversation = UUID()

    /// Messages in the order the store holds them, oldest first.
    private func message(_ sender: SenderRole, _ text: String, synthetic: Bool = false,
                         source: MessageSource = .localUI, at offset: TimeInterval) -> ChatMessage {
        let m = ChatMessage(conversationId: conversation,
                            timestamp: Date(timeIntervalSince1970: 1_000_000 + offset),
                            sender: sender,
                            content: .markdownText(text))
        m.isSyntheticPrompt = synthetic
        m.messageSource = source
        return m
    }

    // MARK: - The defect

    /// ⚠️⚠️ THE REGRESSION TEST. Reproduces the OLD shape — a report with no user row in front of
    /// it — and pins that the pairing walk loses it. If this ever starts passing with the report
    /// present, the walk has changed and the stub may no longer be load-bearing.
    func testAnUnpairedReportIsLostByThePairingWalk() {
        let history = [
            message(.user, "run the build", at: 0),
            message(.agent, "started it", at: 1),
            // The woken report, orphaned exactly as it was before the stub was persisted.
            message(.agent, "The build finished, exit 0.", source: .backgroundTask, at: 2)
        ]

        let pairs = EpisodicHistoryFormatter.pairTurns(from: history)

        XCTAssertEqual(pairs.count, 1, "only the typed exchange should pair")
        XCTAssertFalse(
            pairs.contains { ($0.outcome ?? "").contains("finished") },
            "the orphaned report reached history — this test reproduces the OLD shape and must "
            + "show it being LOST; if it survives here, the pairing walk changed and the fix's "
            + "premise needs re-deriving"
        )
    }

    /// The fix: the stub gives the report something to pair with, so it survives.
    func testTheStubMakesTheReportSurviveIntoHistory() {
        let history = [
            message(.user, "run the build", at: 0),
            message(.agent, "started it", at: 1),
            message(.user, "Background task Build (bg_1) finished (exit 0).",
                    synthetic: true, source: .backgroundTask, at: 2),
            message(.agent, "The build finished, exit 0.", source: .backgroundTask, at: 3)
        ]

        let pairs = EpisodicHistoryFormatter.pairTurns(from: history)

        XCTAssertEqual(pairs.count, 2, "the woken exchange should pair like any other turn")
        XCTAssertTrue(
            pairs.contains { ($0.outcome ?? "").contains("finished, exit 0") },
            "the report the agent delivered is missing from its own history"
        )
    }

    /// ⚠️ The stub must not EAT the next real question. `pendingUser` is a single slot: a stub that
    /// were left unconsumed would pair with the user's NEXT message instead, and the model would
    /// see the user asking a question it had already answered with a task report.
    func testTheStubDoesNotSwallowTheNextRealQuestion() {
        let history = [
            message(.user, "Background task Build (bg_1) finished (exit 0).",
                    synthetic: true, source: .backgroundTask, at: 0),
            message(.agent, "It finished cleanly.", source: .backgroundTask, at: 1),
            message(.user, "what changed?", at: 2),
            message(.agent, "three files", at: 3)
        ]

        let pairs = EpisodicHistoryFormatter.pairTurns(from: history)

        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.last?.userQuery, "what changed?",
                       "the user's real question paired with the wrong turn")
    }

    // MARK: - The stub itself

    /// ⚠️ SHORTER THAN THE PROMPT, and the gap is the reason the stub exists at all. The prompt
    /// carries the task's raw output and is sent once via `promptOverride`; the stub is carried in
    /// EVERY later turn. Asserting the relationship rather than a character count keeps the test
    /// honest if either string is reworded.
    func testTheStubIsFarShorterThanTheWakePrompt() throws {
        let snapshot = try snapshotOfAFinishedTask(named: "Nightly build")
        let stub = BackgroundTaskWakeCoordinator.stub(for: snapshot)
        let prompt = BackgroundTaskWakeCoordinator.prompt(for: snapshot)

        XCTAssertLessThan(stub.count, prompt.count / 2,
                          "the stub is persisted on every turn — it must not approach the prompt's size")
    }

    func testTheStubNamesTheTaskAndItsOutcome() throws {
        let snapshot = try snapshotOfAFinishedTask(named: "Nightly build")
        let stub = BackgroundTaskWakeCoordinator.stub(for: snapshot)

        XCTAssertTrue(stub.contains("Nightly build"), "the stub should say WHICH task: \(stub)")
        XCTAssertTrue(stub.contains(snapshot.id), "the stub should carry the handle: \(stub)")
        XCTAssertTrue(stub.contains("exit 0"), "the stub should carry the outcome: \(stub)")
    }

    /// ⚠️ `name` is optional — the model often omits `task_name`. Without the fallback the stub
    /// read "Background task  finished", which is what a user sees on the divider.
    func testAnUnnamedTaskStillProducesAReadableStub() throws {
        let snapshot = try snapshotOfAFinishedTask(named: nil)
        let stub = BackgroundTaskWakeCoordinator.stub(for: snapshot)

        XCTAssertTrue(stub.contains(snapshot.id), "an unnamed task must still be identified: \(stub)")
        XCTAssertFalse(stub.contains("  "), "the missing name left a double space: \(stub)")
    }

    // MARK: - The wiring

    /// ⚠️⚠️ EVERY TEST ABOVE PASSES WITH THE FEATURE DEAD. They exercise `stub(for:)` and the
    /// pairing walk as separate pure functions; none of them can see whether
    /// `BackgroundTaskWakeCoordinator.wake` actually persists the stub, marks it synthetic, or
    /// routes the real output through `promptOverride`. Delete any of those three lines and this
    /// file stays green while the defect returns in full.
    ///
    /// `wake` takes a `MainApplicationViewModel`, which has no test seam, so a source scan is what
    /// is available. It is weaker than a behavioural test and is here because the alternative is
    /// nothing.
    ///
    /// ⚠️ THE THIRD ASSERTION IS THE SUBTLE ONE. `promptOverride` has a `= nil` default, so
    /// dropping it compiles — and the model would then be asked to report on a task using the
    /// one-line STUB in place of the task's output, producing a confident summary of nothing.
    func testTheWakeActuallyPersistsTheStubAndSendsTheRealPrompt() throws {
        // FOUR components: file → Utils → Core → DevgenticTests → repo root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot
            .appendingPathComponent("Devgentic/Core/Utils/BackgroundTaskWakeCoordinator.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "sources not reachable at \(source.path) — running outside a checkout")

        let code = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("addMessage(userMessage"),
                      "the wake no longer PERSISTS its user message — the report it produces will "
                      + "be an orphan again and the pairing walk will silently drop it")
        XCTAssertTrue(code.contains("isSyntheticPrompt = true"),
                      "the stub is no longer marked synthetic, so both transcripts will render it "
                      + "as a message the user appears to have typed")
        XCTAssertTrue(code.contains("promptOverride: Self.prompt(for: snapshot)"),
                      "the run is no longer given the task's OUTPUT — `promptOverride` defaults to "
                      + "nil, so the model would be asked to report from the one-line stub alone")
        XCTAssertTrue(code.contains("content: .markdownText(Self.stub(for: snapshot))"),
                      "the persisted content is no longer the stub — if it went back to the full "
                      + "prompt, the task's raw output rides every later turn's history")
    }

    // MARK: - Helpers

    private func snapshotOfAFinishedTask(named name: String?) throws -> BackgroundProcessRegistry.Snapshot {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wakestub-\(UUID().uuidString)", isDirectory: true)
        let registry = BackgroundProcessRegistry(rootDirectory: root)
        addTeardownBlock {
            registry.terminateAll()
            try? FileManager.default.removeItem(at: root)
        }

        let conversationID = UUID()
        let launched = try registry.launch(command: "echo done",
                                           workingDirectory: NSTemporaryDirectory(),
                                           timeout: 30,
                                           conversationID: conversationID,
                                           name: name,
                                           notifyOnCompletion: true)

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let s = registry.snapshot(conversationID: conversationID, taskID: launched.id),
               s.status.isTerminal {
                return s
            }
            usleep(20_000)
        }
        throw XCTSkip("the helper task did not finish in time — environment, not a regression")
    }
}
