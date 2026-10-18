// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowStructuralLaneStateIsolationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowStructuralLaneStateIsolationTests: XCTestCase {

    private var mockProvider: MockWorkflowStreamProvider!
    private var traceContext: TraceContext!
    private var innerBuilders: [InnerWorkflowBuilder] = []

    override func setUp() {
        super.setUp()
        mockProvider = MockWorkflowStreamProvider()
        traceContext = TestTraceContext.make()
        innerBuilders = []
    }

    override func tearDown() {
        for builder in innerBuilders { builder.cleanup() }
        innerBuilders = []
        super.tearDown()
    }

    private func execute(_ scenario: WorkflowTestScenario, userInput: String = "Test input") async throws -> [AgentStreamEvent] {
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let stream = executor.executeWorkflow(
            userInput: userInput,
            conversationID: UUID(),
            traceContext: traceContext,
            onTraceUpdate: { _ in },
            layout: scenario.layout,
            profileMap: scenario.profileMap,
            streamProvider: mockProvider
        )
        return try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: nil)
    }

    /// A Router config whose FIRST rule reads a workflow variable and asks "is it still empty?" —
    /// paired with a decoy second rule (`ConditionNodeConfig.minRules` requires at least 2) that can
    /// never match with no upstream wired in, so the pair stays deterministic and unambiguous. It
    /// never touches the AI Classifier UNLESS the real rule fails to match, which is exactly the
    /// observable this test needs: an installed-but-unreachable model name makes a reached
    /// classifier THROW and yield a catchable "AI Classifier failed" thought (the same technique
    /// `testAmbiguousInput_DoesNotInvokeTheClassifier` in WorkflowExecutorIntegrationTests.swift
    /// already established) instead of hanging or requiring a real MLX model.
    private func emptyVariableRouterConfig(model: String, variableName: String) -> ConditionNodeConfig {
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Empty", field: .variable, op: .isEmpty, value: "", variableName: variableName),
            ConditionRule(label: "Decoy", field: .upstreamOutput, op: .contains, value: "unreachable-\(UUID().uuidString)")
        ]
        config.llmFallbackEnabled = true
        config.llmPrompt = "classify"
        config.llmModelName = model
        return config
    }

    /// A NARROW regression guard: re-snapshotting `state` per lane must not creep into this call
    /// site. It does NOT prove lanes exist or that anything actually serializes — see
    /// `testTwoSubWorkflows_ActuallySerializeAtRuntime` for that, and the class header for why the
    /// two are deliberately separate tests.
    ///
    /// Three SAME-LEVEL entry nodes, no edges between them: a Code node that WRITES "risk", and two
    /// Routers on DIFFERENT MLX models (forcing `structuralDispatchLanes` to split them into two
    /// sequential lanes — pinned separately, in isolation, by `WorkflowStructuralDispatchLaneTests`).
    /// The unconstrained Code node always rides lane 0 alongside whichever Router claims that slot
    /// first, so the OTHER Router is always the one strictly-later lane — the one that, by the time
    /// it is dispatched, the Code node's write has ALREADY been applied to the live `state` the
    /// level-dispatch loop owns.
    ///
    /// Both Routers' rules read "risk" with `.isEmpty` — true only while "risk" is still unset. If
    /// EITHER Router observed the Code node's write, its rule would stop matching, fall through to
    /// the (unreachable, not-installed) AI Classifier, and throw. The absence of that failure for
    /// BOTH Routers — including whichever one landed in the later lane — is the proof that every
    /// lane shares one level-wide snapshot taken before any of them started, exactly matching
    /// today's un-partitioned behavior for every OTHER same-level structural pair.
    ///
    /// ⚠️ Measured against the bug this guards: re-snapshotting `state` per lane (mirroring
    /// `profileDispatchLanes`'s OWN per-lane re-snapshot, which is safe there only because profile
    /// nodes never read `state.variables` — see `structuralDispatchLanes`'s doc comment) would let
    /// the later-lane Router's snapshot include the Code node's already-applied write, flip its
    /// `.isEmpty` rule to non-matching, and surface exactly the "AI Classifier failed" thought this
    /// test asserts is absent. ⚠️ Post-review correction: this same assertion would ALSO pass
    /// against the reverted, fully-unpartitioned pre-fix code — that code took one level-wide
    /// snapshot too, just for a single un-split TaskGroup instead of N sequential lanes. This test's
    /// job is narrowly "don't re-snapshot per lane," not "lanes exist."
    func testSameLevelVariableWrite_IsInvisibleToBothLanes_RegardlessOfLaneOrder() async throws {
        let scenario = WorkflowTestScenario()
        let writer = scenario.addCodeNode(name: "Writer", template: "flagged", outputVariable: "risk")
        let routerA = scenario.addConditionNode(
            name: "RouterA",
            config: emptyVariableRouterConfig(model: "not-an-installed-model-A-\(UUID().uuidString.prefix(8))", variableName: "risk")
        )
        let routerB = scenario.addConditionNode(
            name: "RouterB",
            config: emptyVariableRouterConfig(model: "not-an-installed-model-B-\(UUID().uuidString.prefix(8))", variableName: "risk")
        )

        let events = try await execute(scenario)
        let thoughts = WorkflowStreamCollector.thoughtText(from: events)
        let started = Set(WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID))

        XCTAssertFalse(thoughts.contains("AI Classifier failed"),
                       "neither Router's same-level read of a variable the Code node writes may see that write — thoughts: \(thoughts)")
        XCTAssertTrue(started.contains(writer))
        XCTAssertTrue(started.contains(routerA))
        XCTAssertTrue(started.contains(routerB))
    }

    /// ⚠️ THE timing proof — the actual production defect WF-CC5 exists to fix (two same-level
    /// structural nodes thrashing the single global MLX slot) has no OTHER direct test anywhere in
    /// this diff. Mirrors `WorkflowExecutorIntegrationTests.testParallel_TwoDifferentMLXModels_Serialize`
    /// (the already-shipped WF-CC2 precedent) via the sub-workflow path: two same-level nested
    /// sub-workflows, each with a child canvas containing one delayed-stream bot node, asserting
    /// their spans do not overlap — i.e. the second sub-workflow's inner bot genuinely does not
    /// START until the first sub-workflow's entire lane has drained, not merely that they observe
    /// consistent state (that's the OTHER test in this file).
    ///
    /// A Router's AI Classifier call cannot be timed this way — it goes through the real
    /// `MLXService`, not the mockable `WorkflowStreamProvider` — so this proves the mechanism via
    /// the one structural node kind that CAN be timed. The call-site lane loop
    /// (`WorkflowExecutor.swift`, the `for (laneIndex, lane) in lanes.enumerated()` block) has no
    /// branch per node kind, so a Router dispatched through the same loop serializes identically.
    func testTwoSubWorkflows_ActuallySerializeAtRuntime() async throws {
        let scenario = WorkflowTestScenario()

        let innerA = InnerWorkflowBuilder()
        let botA = innerA.addBotNode(name: "Inner A")
        innerA.save()
        innerBuilders.append(innerA)
        for (id, profile) in innerA.profileMap { scenario.profileMap[id] = profile }

        let innerB = InnerWorkflowBuilder()
        let botB = innerB.addBotNode(name: "Inner B")
        innerB.save()
        innerBuilders.append(innerB)
        for (id, profile) in innerB.profileMap { scenario.profileMap[id] = profile }

        let subA = scenario.addSubWorkflowNode(name: "Nested A", workflowProfileID: innerA.workflowProfileID)
        let subB = scenario.addSubWorkflowNode(name: "Nested B", workflowProfileID: innerB.workflowProfileID)

        let aPid = innerA.profileID(for: botA)!
        let bPid = innerB.profileID(for: botB)!
        mockProvider.scriptDelayedStream(for: aPid, events: [.content("a done")], milliseconds: 250)
        mockProvider.scriptDelayedStream(for: bPid, events: [.content("b done")], milliseconds: 250)

        let events = try await execute(scenario)

        XCTAssertTrue(WorkflowStreamCollector.nodeFailedEvents(from: events).isEmpty, "a lane split must fail nothing")
        let completed = Set(WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID))
        XCTAssertTrue(completed.contains(subA), "Nested A must complete")
        XCTAssertTrue(completed.contains(subB), "Nested B must complete")

        let spans = mockProvider.spans
        let a = try XCTUnwrap(spans.first(where: { $0.profileID == aPid }), "no span for Inner A")
        let b = try XCTUnwrap(spans.first(where: { $0.profileID == bPid }), "no span for Inner B")
        XCTAssertFalse(a.start < b.end && b.start < a.end,
                       "two same-level sub-workflow nodes ran CONCURRENTLY — structuralDispatchLanes exists specifically to prevent two structural nodes independently reaching MLXService's single global container at once. A \(a.start)…\(a.end), B \(b.start)…\(b.end)")
    }
}
