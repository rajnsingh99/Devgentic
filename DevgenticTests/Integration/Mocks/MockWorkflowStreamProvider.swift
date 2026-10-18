// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MockWorkflowStreamProvider.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import Foundation
@testable import devgentic

/// Each scripted response is a set of events, a throwing error, or a slow stream.
enum ScriptedResponse {
    case events([AgentStreamEvent])
    case error(Error)
    /// Yields initial events then blocks indefinitely (for cancellation testing).
    case slow([AgentStreamEvent])
    /// Sleeps, THEN yields and finishes normally — a node that is slow but succeeds.
    ///
    /// ⚠️ Distinct from `.slow`, and the difference is the whole point: `.slow` never completes, so
    /// it can only prove that cancellation happened. This one proves the opposite — that a sibling
    /// branch was NOT cancelled and its result still reached the answer. The sleep is cancellation-
    /// sensitive (`Task.sleep` throws), so if anything aborts the group this node dies instead of
    /// finishing, and the assertion on its output fails.
    case delayed([AgentStreamEvent], milliseconds: Int)
}

final class MockWorkflowStreamProvider: WorkflowStreamProvider, @unchecked Sendable {

    /// Lock protecting mutable state for concurrent parallel node access.
    private let lock = NSLock()

    // MARK: - Scripted Responses

    /// Queued responses keyed by profile UUID. Supports mixed event/error sequences
    /// for retry testing (e.g., [error, error, events] = fail twice then succeed).
    private var scriptedQueues: [UUID: [ScriptedResponse]] = [:]

    // MARK: - Invocation Tracking

    /// Every call to `streamAgentResponse` is recorded here for assertions.
    private(set) var invocations: [(profileID: UUID, userInput: String)] = []

    /// Every call to `streamWorkflowNodeResponse` is recorded here for assertions.
    private(set) var workflowInvocations: [(profileID: UUID, context: WorkflowExecutionContext)] = []

    // MARK: - Cancellation test seams (WF-TS2)

    /// Fired once per `streamAgentResponse`, AFTER the lock is released.
    ///
    /// ⚠️ A DETERMINISTIC BARRIER, replacing `Task.sleep`. The cancellation tests used to cancel
    /// after a fixed 100 ms and hope the executor had got far enough; on a loaded machine that is a
    /// coin flip in the other direction (the "A was invoked" assertions are the ones that flake).
    /// Awaiting this instead means the test cancels at EXACTLY the state it needs: the provider has
    /// been called and, for `.slow`, is now blocked forever.
    ///
    /// ⚠️ MUST be invoked outside `lock`. This provider is called concurrently from the executor's
    /// parallel `withTaskGroup` node tasks, and running arbitrary test code under the lock risks a
    /// hang — which in this repo presents as "test runner hung before establishing connection" and
    /// then poisons every later run.
    ///
    /// ⚠️ Do NOT use `.workflowNodeStarted` as the barrier instead: the executor yields it BEFORE
    /// calling the provider, so cancelling on it reintroduces the very race the sleep had. And node
    /// `.content` is accumulated into the node's output rather than forwarded, so a scripted
    /// `.content` can never serve as one either — it looks like a barrier and never fires.
    var onInvoke: (@Sendable (UUID) -> Void)?

    /// Profile IDs whose `.slow` stream was torn down by the consumer — i.e. the node task really
    /// was cancelled. Without this, "Stop reached the running node" is unobservable: the old
    /// `.slow` arm had an empty `onTermination` stub, so teardown left no trace at all.
    private var _tornDownProfileIDs: [UUID] = []
    var tornDownProfileIDs: [UUID] {
        lock.lock(); defer { lock.unlock() }
        return _tornDownProfileIDs
    }

    // MARK: - Concurrency observation (WF-TS12)

    /// Wall-clock span of one `.delayed` script, measured INSIDE the producer.
    /// ⚠️ Producer-side on purpose: stamping the arrival of `.workflowNodeCompleted` on the
    /// consumer instead lets stream buffering stretch an interval forward, which can manufacture a
    /// FALSE overlap under a sequential executor — i.e. a test that cannot fail on the very
    /// mutation it targets.
    struct InvocationSpan: Sendable {
        let profileID: UUID
        let start: ContinuousClock.Instant
        let end: ContinuousClock.Instant
    }
    private var _spans: [InvocationSpan] = []
    var spans: [InvocationSpan] {
        lock.lock(); defer { lock.unlock() }
        return _spans
    }
    private func recordSpan(_ span: InvocationSpan) {
        lock.lock(); _spans.append(span); lock.unlock()
    }

    // MARK: - Configuration (call from setUp, before tests — single-threaded)

    /// Script a sequence of events for a profile node.
    /// Call multiple times for the same profileID to queue responses for retry tests.
    func scriptStream(for profileID: UUID, events: [AgentStreamEvent]) {
        lock.lock()
        defer { lock.unlock() }
        scriptedQueues[profileID, default: []].append(.events(events))
    }

    /// Script a failure for a profile node.
    /// Call multiple times for the same profileID to queue failures then success.
    func scriptError(for profileID: UUID, error: Error) {
        lock.lock()
        defer { lock.unlock() }
        scriptedQueues[profileID, default: []].append(.error(error))
    }

    /// Script a slow stream that yields initial events, then blocks until cancelled.
    /// Useful for testing cancellation mid-stream.
    func scriptSlowStream(for profileID: UUID, initialEvents: [AgentStreamEvent]) {
        lock.lock()
        defer { lock.unlock() }
        scriptedQueues[profileID, default: []].append(.slow(initialEvents))
    }

    /// Script a stream that sleeps, then succeeds. See `ScriptedResponse.delayed`.
    func scriptDelayedStream(for profileID: UUID, events: [AgentStreamEvent], milliseconds: Int = 250) {
        lock.lock()
        defer { lock.unlock() }
        scriptedQueues[profileID, default: []].append(.delayed(events, milliseconds: milliseconds))
    }

    // MARK: - Action-node tool scripting

    /// Tools an Action node can resolve, keyed by tool NAME.
    ///
    /// The default `resolveWorkflowTool` returns nil, so before this every Action-node path —
    /// argument binding, confirmation, timeout, retry, the error port — was unreachable from a
    /// test, and the node kind with the highest privilege in the subsystem (it calls
    /// `AgentTool.run` directly, bypassing `ToolExecutionMediator`) had zero coverage.
    private var scriptedTools: [String: AgentTool] = [:]

    /// Invocation counts per scripted tool name, incremented every time ANY scripted tool's `run`
    /// executes for real — regardless of which registration method created it. Lets a test assert
    /// "the tool ran exactly N times" (e.g. "never a second time after Stop") without needing its
    /// own synchronization.
    private var _toolInvocationCounts: [String: Int] = [:]
    func toolInvocationCount(for name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _toolInvocationCounts[name] ?? 0
    }
    private func recordToolInvocation(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        _toolInvocationCounts[name, default: 0] += 1
        return _toolInvocationCounts[name]!
    }

    /// Registers a tool an Action node will resolve, returning `output` when run.
    ///
    /// `contentMayLookLikeError` mirrors the real opt-out for tools whose legitimate output
    /// surfaces error text (shell stderr, build-log readers).
    func scriptTool(
        name: String,
        output: String,
        artifacts: [MediaArtifact] = [],
        requiresConfirmation: Bool = false,
        contentMayLookLikeError: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        scriptedTools[name] = AgentTool(
            name: name,
            description: "Scripted test tool",
            parameters: ToolParameters(type: "object", properties: [:], required: []),
            requiresConfirmation: requiresConfirmation,
            contentMayLookLikeError: contentMayLookLikeError,
            run: { [weak self] _ in
                _ = self?.recordToolInvocation(name)
                return (output, artifacts)
            }
        )
    }

    /// Registers a tool that THROWS when run — the transient-failure shape the retry loop handles.
    func scriptThrowingTool(name: String, error: Error, requiresConfirmation: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        scriptedTools[name] = AgentTool(
            name: name,
            description: "Scripted throwing test tool",
            parameters: ToolParameters(type: "object", properties: [:], required: []),
            requiresConfirmation: requiresConfirmation,
            contentMayLookLikeError: false,
            run: { [weak self] _ in
                _ = self?.recordToolInvocation(name)
                throw error
            }
        )
    }

    /// Registers a tool that fires `onInvoke` then throws `error` — a deterministic barrier for
    /// tests that must cancel the ambient Task at the exact moment a tool attempt starts (WF-CC4),
    /// mirroring `onInvoke` (WF-TS2) for the Action-node tool path rather than the LLM-stream path.
    /// `onInvoke` receives the 1-based invocation count, so a test can cancel on exactly the first
    /// attempt and later assert no further attempt occurred.
    func scriptThrowingToolWithBarrier(name: String, error: Error, onInvoke: @escaping @Sendable (Int) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        scriptedTools[name] = AgentTool(
            name: name,
            description: "Scripted throwing test tool with invocation barrier",
            parameters: ToolParameters(type: "object", properties: [:], required: []),
            requiresConfirmation: false,
            contentMayLookLikeError: false,
            run: { [weak self] _ in
                let count = self?.recordToolInvocation(name) ?? 0
                onInvoke(count)
                throw error
            }
        )
    }

    func resolveWorkflowTool(_ tool: Tool, conversationID: UUID) async -> AgentTool? {
        lock.lock()
        defer { lock.unlock() }
        return scriptedTools[tool.name]
    }

    // MARK: - WorkflowStreamProvider

    func streamAgentResponse(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String?,
        attachmentContext: String?,
        knowledgeBaseContext: String?,
        toolGuidanceContext: String?,
        userPayload: Payload?,
        resumeState: TimelineReconstruction?,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        lock.lock()
        invocations.append((profileID: profile.id, userInput: userInput))
        let profileID = profile.id

        // Pop first queued response, or cycle last if exhausted
        let response: ScriptedResponse
        if var queue = scriptedQueues[profileID], !queue.isEmpty {
            if queue.count > 1 {
                response = queue.removeFirst()
                scriptedQueues[profileID] = queue
            } else {
                response = queue[0] // Cycle last entry
            }
        } else {
            response = .events([]) // No script — empty stream
        }
        lock.unlock()

        // ⚠️ AFTER `lock.unlock()`, never under it — see `onInvoke`.
        onInvoke?(profileID)

        switch response {
        case .error(let error):
            return AsyncThrowingStream { $0.finish(throwing: error) }
        case .events(let events):
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        case .slow(let initialEvents):
            return AsyncThrowingStream { continuation in
                for event in initialEvents {
                    continuation.yield(event)
                }
                // ⚠️ Records the teardown instead of discarding it (WF-TS2). This closure firing IS
                // the proof that Stop propagated all the way to the in-flight node's provider
                // stream; with the previous empty stub, "the running node was cancelled" had no
                // observable consequence anywhere in the suite.
                continuation.onTermination = { @Sendable [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    self._tornDownProfileIDs.append(profileID)
                    self.lock.unlock()
                }
            }
        case .delayed(let events, let milliseconds):
            return AsyncThrowingStream { continuation in
                // Unstructured on purpose: an unstructured Task does NOT inherit the caller's
                // cancellation, so the ONLY way this sleep is interrupted is the consumer tearing
                // the stream down — i.e. the node task actually being cancelled. That keeps the
                // signal clean: output missing ⇒ something really did abort this branch.
                let start = ContinuousClock.now
                let task = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .milliseconds(milliseconds))
                        // WF-TS12: the span is closed here, before any yield, so it measures the
                        // producer's own occupancy and never the consumer's drain rate.
                        self?.recordSpan(InvocationSpan(profileID: profileID,
                                                        start: start,
                                                        end: ContinuousClock.now))
                        for event in events {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }
    }

    // MARK: - Workflow Node Streaming

    func streamWorkflowNodeResponse(
        for profile: BackendProfileModel,
        workflowContext: WorkflowExecutionContext,
        conversationID: UUID,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        lock.lock()
        workflowInvocations.append((profileID: profile.id, context: workflowContext))
        lock.unlock()

        // One input channel (2026-08-29) — mirrors the production default bridge in
        // `WorkflowStreamProvider`, which no longer branches on `isFirstNode` either.
        // Delegate to the existing streamAgentResponse which handles scripted queues
        return streamAgentResponse(
            for: profile,
            userInput: workflowContext.input,
            chatHistory: [],
            conversationID: conversationID,
            ragContext: nil,
            attachmentContext: nil,
            knowledgeBaseContext: nil,
            toolGuidanceContext: nil,
            userPayload: nil,
            resumeState: nil,
            traceContext: traceContext,
            onTraceUpdate: onTraceUpdate
        )
    }
}
