// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalInferencePolicyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class LocalInferencePolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let budget: UInt64 = 16 << 30

    private func decide(_ m: InferenceRunManifest, _ lock: LocalLockState = LocalLockState()) -> CoordinatorDecision {
        LocalInferencePolicy.decide(m, lock: lock, now: now)
    }

    // MARK: Rule 1 — cloud bypass (D3)

    func testACloudOnlyRunIsAdmittedEvenWhileTheLockIsHeld() {
        let busy = LocalLockState(holder: UUID(), queue: [QueuedRun(runID: UUID(), priority: .attended, enqueuedAt: now)])
        XCTAssertEqual(decide(LIFixtures.manifest(models: [LIFixtures.claude]), busy), .admit(.noLocalModel))
    }

    func testAnUnresolvedWorkflowNodeCountsAsLocal() {
        let m = LIFixtures.manifest(shape: .workflow(nodeCount: 2), models: [LIFixtures.claude], unresolvedNodes: 1)
        XCTAssertTrue(m.needsLocalLock)
        let holder = UUID()
        XCTAssertEqual(decide(m, LocalLockState(holder: holder)), .hold(behind: holder, position: 1))
    }

    func testOllamaIsLocal() {
        let m = LIFixtures.manifest(models: [ModelRequirement(engine: .ollama(baseURL: "http://localhost:11434"), modelID: "llama3", role: .primary)])
        XCTAssertTrue(m.needsLocalLock)
        XCTAssertEqual(decide(m), .admit(.lockFree))
    }

    // MARK: Rule 2 — D5 sub-agent fallback guard

    func testALocalDelegatingRunIsDenied() {
        let m = LIFixtures.manifest(shape: .delegating, models: [LIFixtures.mlxQwen])
        XCTAssertEqual(decide(m), .deny(.subAgentsUnsupportedLocally))
    }

    func testACloudDelegatingRunIsNotDenied() {
        let m = LIFixtures.manifest(shape: .delegating, models: [LIFixtures.claude])
        XCTAssertEqual(decide(m), .admit(.noLocalModel))
    }

    // MARK: Rule 3 — a concern ASKS (phase 7), never refuses outright

    private func decideWithBudget(_ m: InferenceRunManifest, _ lock: LocalLockState = LocalLockState()) -> CoordinatorDecision {
        LocalInferencePolicy.decide(m, lock: lock, budgetBytes: budget, now: now)
    }

    private func oversized(origin: RunOrigin = .composer, attended: Bool = true) -> InferenceRunManifest {
        LIFixtures.manifest(origin: origin, attended: attended, models: [LIFixtures.mlxQwen],
                            footprints: [LIFixtures.mlxQwen.residencyKey: budget * 4])
    }

    /// ⚠️ Regression (device, 2026-10-08): a 3B model was REFUSED as "needs ~20 GB". A concern now asks
    /// its user — whether the lock is free or held.
    func testAnAttendedRunWithAConcernIsAskedNotRefused() {
        let expected = CoordinatorDecision.confirm([.memory(modelID: "qwen", estimatedBytes: budget * 4, budgetBytes: budget)])
        XCTAssertEqual(decideWithBudget(oversized()), expected)
        XCTAssertEqual(decideWithBudget(oversized(), LocalLockState(holder: UUID())), expected)
    }

    /// Owner, 2026-10-08: a run nobody is watching just runs — and so does an Orb run until the voice
    /// HUD can ask.
    func testAnUnattendedOrOrbRunWithAConcernRunsWithoutAsking() {
        XCTAssertEqual(decideWithBudget(oversized(origin: .scheduled, attended: false)), .admit(.lockFree))
        XCTAssertEqual(decideWithBudget(oversized(origin: .chatOps(.telegram), attended: false)), .admit(.lockFree))
        XCTAssertEqual(decideWithBudget(oversized(origin: .orb)), .admit(.lockFree))
        let holder = UUID()
        XCTAssertEqual(decideWithBudget(oversized(origin: .scheduled, attended: false), LocalLockState(holder: holder)),
                       .hold(behind: holder, position: 1))
    }

    /// The D5 guard comes first: a delegating local run is refused, not asked about.
    func testTheSubAgentGuardOutranksAConcern() {
        let m = LIFixtures.manifest(shape: .delegating, models: [LIFixtures.mlxQwen],
                                    footprints: [LIFixtures.mlxQwen.residencyKey: budget * 4])
        XCTAssertEqual(decideWithBudget(m), .deny(.subAgentsUnsupportedLocally))
    }

    func testOnlyAModelAboveTheBudgetRaisesAConcern() {
        let m = LIFixtures.manifest(models: [LIFixtures.mlxQwen, LIFixtures.mlxLlama],
                                    footprints: [LIFixtures.mlxQwen.residencyKey: budget + 1,
                                                 LIFixtures.mlxLlama.residencyKey: budget])
        XCTAssertEqual(LocalInferencePolicy.concerns(m, budgetBytes: budget),
                       [.memory(modelID: "qwen", estimatedBytes: budget + 1, budgetBytes: budget)],
                       "only the model ABOVE the budget; one exactly at it is not")
    }

    func testAnUnknownFootprintOrBudgetRaisesNothing() {
        XCTAssertTrue(LocalInferencePolicy.concerns(LIFixtures.manifest(models: [LIFixtures.mlxQwen]), budgetBytes: budget).isEmpty)
        let m = LIFixtures.manifest(models: [LIFixtures.mlxQwen], footprints: [LIFixtures.mlxQwen.residencyKey: 99 << 30])
        XCTAssertTrue(LocalInferencePolicy.concerns(m, budgetBytes: 0).isEmpty, "no budget known → nothing to compare against")
        XCTAssertEqual(decideWithBudget(LIFixtures.manifest(models: [LIFixtures.mlxQwen])), .admit(.lockFree))
    }

    /// The auto-deny reads "Auto-denied" over the reason, with the wait it gave the user.
    func testTheAutoDenyNamesTheConcernAndTheWait() {
        let reason = DenyReason.notConfirmed(concerns: [.memory(modelID: "qwen", estimatedBytes: 20 << 30, budgetBytes: 18 << 30)], after: 120)
        XCTAssertEqual(reason.title, "Auto-denied")
        XCTAssertTrue(reason.description.hasPrefix("'qwen' is estimated at ~"), reason.description)
        XCTAssertTrue(reason.description.hasSuffix("Nobody chose Proceed within 2 min, so the run was not started"), reason.description)
        XCTAssertEqual(DenyReason.subAgentsUnsupportedLocally.title, "Not started")
    }

    /// Exactly two deny reasons, both owner decisions: the D5 guard, and a question nobody answered.
    /// A third would refuse a run without asking — capability describes, never enforces.
    func testTheOnlyDenyReasonsAreTheSubAgentGuardAndAnUnansweredQuestion() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let code = try? String(contentsOf: repoRoot.appendingPathComponent("Devgentic/Core/LocalInference/LocalInferencePolicy.swift"), encoding: .utf8) else {
            throw XCTSkip("sources not reachable — running outside a checkout")
        }
        let body = code.components(separatedBy: "enum DenyReason")[1].components(separatedBy: "var title")[0]
        let cases = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("case ") }
        XCTAssertEqual(cases, ["case subAgentsUnsupportedLocally", "case notConfirmed(concerns: [RunConcern], after: TimeInterval)"])
    }

    // MARK: Rules 4–5 — free, or wait

    func testTheSecondLocalRunWaitsBehindTheHolder() {
        let holder = UUID()
        let m = LIFixtures.manifest(models: [LIFixtures.mlxLlama])
        XCTAssertEqual(decide(m, LocalLockState(holder: holder)), .hold(behind: holder, position: 1))
    }

    /// ⚠️ The window between a release and the next admission: no holder, but a queue. Admitting the
    /// arrival there would let it jump everyone already waiting.
    func testAnArrivalDoesNotOvertakeAQueueWhenNoOneHoldsTheLock() {
        let head = UUID()
        let lock = LocalLockState(holder: nil, queue: [QueuedRun(runID: head, priority: .unattended, enqueuedAt: now)])
        let m = LIFixtures.manifest(origin: .scheduled, attended: false, models: [LIFixtures.mlxQwen])
        XCTAssertEqual(decide(m, lock), .hold(behind: head, position: 2))
    }

    func testAnAttendedArrivalIsPlacedAheadOfWaitingUnattendedRuns() {
        let holder = UUID()
        let lock = LocalLockState(holder: holder, queue: [
            QueuedRun(runID: UUID(), priority: .unattended, enqueuedAt: now),
            QueuedRun(runID: UUID(), priority: .remote, enqueuedAt: now),
        ])
        let m = LIFixtures.manifest(origin: .composer, models: [LIFixtures.mlxQwen])
        XCTAssertEqual(decide(m, lock), .hold(behind: holder, position: 1))
    }

    // MARK: Priority classes

    func testPriorityClassPerOrigin() {
        XCTAssertEqual(PriorityClass.of(origin: .composer, attended: true), .attended)
        XCTAssertEqual(PriorityClass.of(origin: .code, attended: true), .attended)
        XCTAssertEqual(PriorityClass.of(origin: .orb, attended: true), .attended)
        XCTAssertEqual(PriorityClass.of(origin: .regenerate, attended: true), .attended)
        // ChatOps is bound unattended at the Mac, but a person waits remotely.
        XCTAssertEqual(PriorityClass.of(origin: .chatOps(.telegram), attended: false), .remote)
        XCTAssertEqual(PriorityClass.of(origin: .scheduled, attended: false), .unattended)
        XCTAssertEqual(PriorityClass.of(origin: .backgroundTask, attended: false), .unattended)
        // A surface bound unattended by its caller (e.g. a workflow the scheduler started) drops.
        XCTAssertEqual(PriorityClass.of(origin: .workflow, attended: false), .unattended)
    }

    // MARK: Aging and order

    func testAgingPromotesOneClassPerIntervalAndStopsAtAttended() {
        let run = QueuedRun(runID: UUID(), priority: .backgroundIC, enqueuedAt: now)
        let interval: TimeInterval = 300
        XCTAssertEqual(LocalInferencePolicy.effectivePriority(run, now: now.addingTimeInterval(299), agingInterval: interval), .backgroundIC)
        XCTAssertEqual(LocalInferencePolicy.effectivePriority(run, now: now.addingTimeInterval(300), agingInterval: interval), .unattended)
        XCTAssertEqual(LocalInferencePolicy.effectivePriority(run, now: now.addingTimeInterval(900), agingInterval: interval), .attended)
        XCTAssertEqual(LocalInferencePolicy.effectivePriority(run, now: now.addingTimeInterval(9_000), agingInterval: interval), .attended,
                       "aging never reaches P0, which is reserved for runs resuming after a HITL answer")
    }

    func testOrderIsByClassThenFirstComeFirstServed() {
        let a = QueuedRun(runID: UUID(), priority: .unattended, enqueuedAt: now)
        let b = QueuedRun(runID: UUID(), priority: .attended, enqueuedAt: now.addingTimeInterval(10))
        let c = QueuedRun(runID: UUID(), priority: .attended, enqueuedAt: now.addingTimeInterval(20))
        let ordered = LocalInferencePolicy.order([a, c, b], now: now.addingTimeInterval(30), agingInterval: 300)
        XCTAssertEqual(ordered.map(\.runID), [b.runID, c.runID, a.runID])
    }

    func testAStarvedUnattendedRunEventuallyOvertakesANewAttendedOne() {
        let old = QueuedRun(runID: UUID(), priority: .unattended, enqueuedAt: now)
        let fresh = QueuedRun(runID: UUID(), priority: .attended, enqueuedAt: now.addingTimeInterval(700))
        // 700 s waited at a 300 s interval → two promotions, capped at `.attended`; then it is older.
        XCTAssertEqual(LocalInferencePolicy.next(in: [fresh, old], now: now.addingTimeInterval(700), agingInterval: 300)?.runID, old.runID)
    }
}
