// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  IntegrationTestHelpers.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import Foundation
@testable import devgentic

// MARK: - TraceContext Factory

enum TestTraceContext {
    /// Creates a minimal TraceContext for test scenarios.
    static func make() -> TraceContext {
        TraceContext(subAgentName: "test-agent", provider: .ollama)
    }
}

// MARK: - AgentTool Factory

enum TestToolFactory {
    /// Creates a simple tool that returns a fixed output.
    static func make(
        name: String,
        description: String = "A test tool.",
        output: String = "Tool executed successfully.",
        requiresConfirmation: Bool = false
    ) -> AgentTool {
        AgentTool(
            name: name,
            description: description,
            parameters: SchemaBuilder.object(
                properties: [("input", "string", "The input value.")],
                required: ["input"]
            ),
            requiresConfirmation: requiresConfirmation,
            textOnlyRun: { _ in output }
        )
    }

    /// Creates a tool with a per-tool timeout configured.
    static func makeWithTimeout(
        name: String,
        timeout: TimeInterval,
        timeoutMessage: String? = nil,
        output: String = "Tool executed successfully."
    ) -> AgentTool {
        AgentTool(
            name: name,
            description: "A test tool with timeout.",
            parameters: SchemaBuilder.object(
                properties: [("input", "string", "The input value.")],
                required: ["input"]
            ),
            timeout: timeout,
            timeoutMessage: timeoutMessage,
            textOnlyRun: { _ in output }
        )
    }

    /// Creates a tool that takes `delay` seconds before returning.
    static func makeSlow(
        name: String,
        delay: TimeInterval,
        output: String = "Slow tool completed."
    ) -> AgentTool {
        AgentTool(
            name: name,
            description: "A tool that sleeps before returning.",
            parameters: SchemaBuilder.object(
                properties: [("input", "string", "The input value.")],
                required: ["input"]
            ),
            textOnlyRun: { _ in
                try await Task.sleep(for: .seconds(delay))
                return output
            }
        )
    }

    /// Creates a slow tool with a per-tool timeout configured.
    static func makeSlowWithTimeout(
        name: String,
        delay: TimeInterval,
        timeout: TimeInterval,
        timeoutMessage: String? = nil,
        output: String = "Slow tool completed."
    ) -> AgentTool {
        AgentTool(
            name: name,
            description: "A slow tool with timeout.",
            parameters: SchemaBuilder.object(
                properties: [("input", "string", "The input value.")],
                required: ["input"]
            ),
            timeout: timeout,
            timeoutMessage: timeoutMessage,
            textOnlyRun: { _ in
                try await Task.sleep(for: .seconds(delay))
                return output
            }
        )
    }

    /// Creates a tool that fails with an error message.
    static func makeFailing(name: String, error: String = "Tool execution failed.") -> AgentTool {
        AgentTool(
            name: name,
            description: "A tool that always fails.",
            parameters: SchemaBuilder.object(
                properties: [("input", "string", "The input value.")],
                required: ["input"]
            ),
            textOnlyRun: { _ in throw NSError(domain: "TestTool", code: 500, userInfo: [NSLocalizedDescriptionKey: error]) }
        )
    }
}

// MARK: - PendingToolCall Factory

enum TestToolCallFactory {
    /// Creates a PendingToolCall for the given tool name with a simple string argument.
    static func make(name: String, input: String = "test") -> PendingToolCall {
        PendingToolCall(
            id: UUID().uuidString,
            name: name,
            arguments: ["input": .string(input)]
        )
    }
}

// MARK: - AgentInput Factory

enum TestAgentInputFactory {
    /// Creates a minimal AgentInput suitable for integration tests.
    static func make(
        query: String = "Test query",
        tools: [AgentTool] = [],
        workingMemory: (any WorkingMemoryStrategy)? = nil,
        maxIterations: Int = 15,
        errorRecovery: ErrorRecovery = ErrorRecovery(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        instructions: String? = nil,
        generatorStrategy: (any CognitiveGenerator)? = nil,
        /// [WF-SE6] Lets a test drive the WORKFLOW-NODE agent path — the plumbing that carries
        /// `unattendedAutoApprove` into `ToolExecutionLoop`.
        workflowContext: WorkflowExecutionContext? = nil
    ) -> AgentInput {
        let memory = workingMemory ?? WindowedLinearMemory(
            config: MemoryBudgetConfig.derive(contextWindow: 8192, tier: .small)
        )

        return AgentInput(
            userInput: query,
            chatHistory: [],
            conversationID: UUID(),
            tools: tools,
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            generatorStrategy: generatorStrategy ?? MockCognitiveGenerator(),
            workingMemory: memory,
            rateLimitKey: "test",
            rateLimitCategory: .local,
            instructions: instructions,
            retryPolicy: retryPolicy,
            errorRecovery: errorRecovery,
            workflowContext: workflowContext,
            traceContext: TestTraceContext.make()
        )
    }
}

// MARK: - Stream Event Collection

enum StreamCollector {
    /// Consumes an agent stream and collects all events into an array.
    /// Throws if the stream produces an error.
    static func collect(from stream: AsyncThrowingStream<AgentStreamEvent, Error>) async throws -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    /// Extracts all `.content` text from collected events.
    static func contentText(from events: [AgentStreamEvent]) -> String {
        events.compactMap { event -> String? in
            if case .content(let text) = event { return text }
            return nil
        }.joined()
    }

    /// Extracts all `.thought` messages from collected events.
    static func thoughts(from events: [AgentStreamEvent]) -> [String] {
        events.compactMap { event -> String? in
            if case .thought(let msg, _, _) = event { return msg }
            return nil
        }
    }

    /// Extracts all tool-output payloads (both success and failure) from collected events.
    /// The legacy unified `.toolOutput` case was split into `.toolSucceeded` / `.toolFailed`;
    /// this helper flattens both back into a single `[ToolOutput]` so call sites that assert
    /// on counts + `isSuccess` semantics continue to work without changes.
    static func toolOutputs(from events: [AgentStreamEvent]) -> [ToolOutput] {
        events.compactMap { event -> ToolOutput? in
            switch event {
            case .toolSucceeded(let output, _, _):
                return output
            case .toolFailed(let output, _, _, _):
                return output
            default:
                return nil
            }
        }
    }

    /// Checks if any thought contains the given substring.
    static func hasThoughtContaining(_ substring: String, in events: [AgentStreamEvent]) -> Bool {
        thoughts(from: events).contains { $0.contains(substring) }
    }

    /// Extracts all `.warning` messages from collected events. (Memory-pressure,
    /// circuit-breaker, parse-failure, etc. surface as `.warning`, NOT `.thought`.)
    static func warnings(from events: [AgentStreamEvent]) -> [String] {
        events.compactMap { event -> String? in
            if case .warning(_, let message, _, _) = event { return message }
            return nil
        }
    }

    /// Checks if any warning contains the given substring.
    static func hasWarningContaining(_ substring: String, in events: [AgentStreamEvent]) -> Bool {
        warnings(from: events).contains { $0.contains(substring) }
    }
}
