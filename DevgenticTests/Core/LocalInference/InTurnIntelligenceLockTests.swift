// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InTurnIntelligenceLockTests.swift
//  DevgenticTests
//
//  In-turn Core Intelligence calls (RAG query rewrite, response synthesis) and the local lock
//  (2026-10-13; "DEFERRED 2" of the coordinator plan). They used to generate on the IC MLX model
//  with no lock at all, alongside another conversation's local run. Now they never WAIT for the
//  lock: inside their own run's lock they proceed, on a free lock they claim it for the call, and
//  on a busy one the step is SKIPPED and the caller's fallback runs.
//

import XCTest
@testable import devgentic

@MainActor
final class InTurnIntelligenceLockTests: XCTestCase {

    private var savedICModel: String?

    override func setUp() async throws {
        try await super.setUp()
        savedICModel = UserDefaults.standard.string(forKey: AppSettings.coreIntelligenceModelKey)
        UserDefaults.standard.set("mlx-community/test-ic-model", forKey: AppSettings.coreIntelligenceModelKey)
    }

    override func tearDown() async throws {
        if let savedICModel {
            UserDefaults.standard.set(savedICModel, forKey: AppSettings.coreIntelligenceModelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppSettings.coreIntelligenceModelKey)
        }
        QueryRewritingService.coordinatorOverride = nil
        ResponseSynthesizer.coordinatorOverride = nil
        try await super.tearDown()
    }

    private func coordinator(_ mode: LocalInferenceCoordinator.Mode = .enforce) -> LocalInferenceCoordinator {
        LocalInferenceCoordinator(mode: mode, beginQueueWait: { _ in }, endQueueWait: { _ in })
    }

    /// A local run of another conversation holding the lock.
    @discardableResult
    private func holdLock(_ coordinator: LocalInferenceCoordinator) -> UUID {
        let run = LIFixtures.manifest(models: [LIFixtures.mlxQwen])
        guard case .admit(.lockFree) = coordinator.register(run) else {
            XCTFail("precondition: the holder takes the free lock")
            return run.runID
        }
        return run.runID
    }

    // MARK: - The four cases

    func testAFreeLockIsClaimedForTheCall_AndReleasedAfter() throws {
        let coordinator = coordinator()
        let slot = try coordinator.claimForInTurnIntelligence(feature: "rewrite", callerRunID: nil)

        guard case .claimed(let runID) = slot else { return XCTFail("expected a claim, got \(slot)") }
        XCTAssertEqual(coordinator.lock.holder, runID, "a local run arriving now queues behind the call")
        XCTAssertEqual(coordinator.manifest(for: runID)?.models.first?.role, .intelligenceCore)

        coordinator.releaseInTurnIntelligence(slot)
        XCTAssertNil(coordinator.lock.holder)
    }

    /// THE defect: a cloud turn's IC call while another run holds the lock.
    func testABusyLockSkipsTheCall_AndLeavesTheHolderAlone() throws {
        let coordinator = coordinator()
        let holder = holdLock(coordinator)

        XCTAssertThrowsError(try coordinator.claimForInTurnIntelligence(feature: "rewrite", callerRunID: UUID())) { error in
            XCTAssertTrue(error is LocalInferenceCoordinator.LocalSlotBusy, "got \(error)")
        }
        XCTAssertEqual(coordinator.lock.holder, holder)
        XCTAssertEqual(coordinator.inTurnIntelligenceSkips, 1)
    }

    /// A local turn holds the lock itself: its IC call is part of that run.
    func testTheTurnsOwnRunProceedsInsideItsLock() throws {
        let coordinator = coordinator()
        let ownRun = holdLock(coordinator)

        XCTAssertEqual(try coordinator.claimForInTurnIntelligence(feature: "synthesis", callerRunID: ownRun), .ownRun)
        XCTAssertEqual(coordinator.lock.holder, ownRun)
    }

    /// Runs waiting in line: the call does not jump it.
    func testWaitingRunsAreNotJumped() throws {
        let coordinator = coordinator()
        holdLock(coordinator)
        coordinator.register(LIFixtures.manifest(models: [LIFixtures.mlxLlama]))   // queued behind
        _ = coordinator.unregister(runID: coordinator.lock.holder!)                 // the lock passes on
        XCTAssertThrowsError(try coordinator.claimForInTurnIntelligence(feature: "rewrite", callerRunID: nil))
    }

    func testShadowModeAndNoICModelAreUncoordinated() throws {
        let shadow = coordinator(.shadow)
        holdLock(shadow)
        XCTAssertEqual(try shadow.claimForInTurnIntelligence(feature: "rewrite", callerRunID: nil), .uncoordinated)

        UserDefaults.standard.removeObject(forKey: AppSettings.coreIntelligenceModelKey)
        let enforce = coordinator()
        holdLock(enforce)
        XCTAssertEqual(try enforce.claimForInTurnIntelligence(feature: "rewrite", callerRunID: nil), .uncoordinated,
                       "with no IC model selected the IC refuses to load anyway; nothing to coordinate")
    }

    /// The nonisolated wrapper reads the CALLER's run id and never runs the work on a busy lock.
    func testTheWrapperReadsTheCallersRunAndSkipsWithoutRunningTheWork() async throws {
        let coordinator = coordinator()
        let ownRun = holdLock(coordinator)

        let insideOwnRun = try await LocalInferenceScope.$runID.withValue(ownRun) {
            try await LocalInferenceCoordinator.inTurnIntelligence(feature: "rewrite", on: coordinator) { "ran" }
        }
        XCTAssertEqual(insideOwnRun, "ran")

        var ran = false
        do {
            _ = try await LocalInferenceCoordinator.inTurnIntelligence(feature: "rewrite", on: coordinator) { ran = true; return "ran" }
            XCTFail("a busy lock must throw")
        } catch is LocalInferenceCoordinator.LocalSlotBusy {}
        XCTAssertFalse(ran, "the IC generation must not start on a busy lock")
    }

    // MARK: - Wiring

    /// Through the REAL rewrite service: a busy lock gives back the user's own query, and the skip
    /// was the coordinator's (not an IC load failure that happens to fall back the same way).
    func testTheRewriteServiceSkipsOnABusyLock() async throws {
        let coordinator = coordinator()
        holdLock(coordinator)
        QueryRewritingService.coordinatorOverride = coordinator
        let history = [ChatMessage(id: UUID(), conversationId: UUID(), timestamp: Date(), sender: .user, content: .plainText("Tell me about Swift actors."))]

        let rewritten = await QueryRewritingService.shared.rewriteQuery("and how do they isolate state?", history: history)

        XCTAssertEqual(rewritten, "and how do they isolate state?")
        XCTAssertEqual(coordinator.inTurnIntelligenceSkips, 1, "the rewrite must ask the coordinator before generating")
    }

    /// Synthesis's IC path needs a provider opt-in to reach, so its wiring is pinned in source:
    /// every IC generate call sits inside the in-turn wrapper, and a busy lock falls back.
    func testSynthesisRunsItsICCallThroughTheWrapper() throws {
        let source = try Self.read("Devgentic/Core/Backends/TextGen/ResponseSynthesizer.swift")
        XCTAssertNotNil(source.range(of: #"LocalInferenceCoordinator\.inTurnIntelligence\([\s\S]{0,200}?IntelligenceCoreService\.shared\.generate\("#,
                                     options: .regularExpression))
        XCTAssertEqual(source.components(separatedBy: "IntelligenceCoreService.shared.generate(").count - 1, 1)
        XCTAssertNotNil(source.range(of: #"catch let busy as LocalInferenceCoordinator\.LocalSlotBusy[\s\S]{0,400}?return buildDeterministicFallback"#,
                                     options: .regularExpression))
        XCTAssertNotNil(source.range(of: "ResponseSynthesizer.coordinatorOverride") ?? source.range(of: "coordinatorOverride ?? .shared"))
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("source not found: \(relativePath)")
        return ""
    }
}
