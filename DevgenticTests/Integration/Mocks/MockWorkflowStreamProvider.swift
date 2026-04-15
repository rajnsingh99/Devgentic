//
//  MockWorkflowStreamProvider.swift
//  DevgenticTests
//
//  Scriptable mock for WorkflowStreamProvider.
//  Maps profile UUIDs to pre-configured event sequences or errors,
//  enabling deterministic workflow integration tests without LLM calls.
//  Thread-safe for concurrent parallel node invocations.
//

import Foundation
@testable import devgentic

/// Each scripted response is a set of events, a throwing error, or a slow stream.
enum ScriptedResponse {
    case events([AgentStreamEvent])
    case error(Error)
    /// Yields initial events then blocks indefinitely (for cancellation testing).
    case slow([AgentStreamEvent])
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

    // MARK: - WorkflowStreamProvider

    func streamAgentResponse(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String?,
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
                continuation.onTermination = { @Sendable _ in }
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

        // Compose userInput for the existing scripted response lookup
        let composedInput = workflowContext.isFirstNode
            ? workflowContext.taskDescription
            : workflowContext.upstreamInput

        // Delegate to the existing streamAgentResponse which handles scripted queues
        return streamAgentResponse(
            for: profile,
            userInput: composedInput,
            chatHistory: [],
            conversationID: conversationID,
            ragContext: nil,
            traceContext: traceContext,
            onTraceUpdate: onTraceUpdate
        )
    }
}
