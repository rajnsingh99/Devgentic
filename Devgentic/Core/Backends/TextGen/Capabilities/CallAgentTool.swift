// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CallAgentTool.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CallAgentTool")

// MARK: - Concurrency Limiter

/// Actor-based semaphore that enforces a maximum number of concurrent spawned agents.
private actor ConcurrencyLimiter {
    private let maxConcurrent: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            active -= 1
        }
    }
}

// MARK: - CallAgentTool

enum CallAgentTool {

    /// Context window assumed for a spawned sub-agent, independent of the parent's real one.
    /// Conservative: sub-agents are short-lived leaf nodes, sized for the smallest model the parent might run.
    /// The working-memory config and the native payload cap both derive from it, so they agree.
    static let spawnedContextWindow = 8_192

    /// Creates the `call_agent` AgentTool for injection into the parent agent's tool set.
    /// Spawned agents reuse the parent's model, tools (already excluding call_agent), generator strategy, rate-limit
    /// category and provider; `config` sets concurrency and iteration limits, `conversationID` propagates context.
    static func create(
        config: AgentDelegationConfig,
        parentModel: any LLMProvider,
        parentTools: [AgentTool],
        parentGeneratorStrategy: any CognitiveGenerator,
        parentRateLimitKey: String,
        parentRateLimitCategory: RateLimitCategory,
        parentProvider: ApiProvider,
        conversationID: UUID
    ) -> AgentTool {

        let limiter = ConcurrencyLimiter(maxConcurrent: config.maxConcurrentAgents)
        let maxIterations = config.maxIterationsPerAgent

        let parameters = ToolParameters(
            type: "object",
            properties: [
                "task": ToolParameterProperty(
                    type: "string",
                    description: "Clear, self-contained description of the subtask to delegate to a spawned agent. The agent will have access to the same tools as you.",
                    items: nil
                )
            ],
            required: ["task"]
        )

        return AgentTool(
            name: "call_agent",
            description: """
                Spawn a focused sub-agent to work on a subtask in parallel. The spawned agent \
                uses the same model and tools as you but operates independently with its own \
                reasoning loop. Use this to parallelize work or isolate complex subtasks. \
                Each agent receives only the task description — provide all necessary context in it.
                """,
            parameters: parameters,
            requiresConfirmation: false,
            run: { data in
                // Parse arguments
                guard let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let taskDescription = args["task"] as? String
                else {
                    return (output: "Error: call_agent requires a 'task' (string) parameter.", artifacts: [])
                }

                logger.info("Spawning agent for a task of \(taskDescription.count) chars")

                // Enforce concurrency limit
                await limiter.acquire()
                defer { Task { await limiter.release() } }

                do {
                    // Build minimal AgentInput — no history, no instructions.
                    // Conservative memory budget: spawned agents are short-lived leaf nodes.
                    let traceContext = TraceContext(subAgentName: "spawned-agent", provider: parentProvider)
                    // Sized like every other run: the room its fixed prompt (task + tool text) leaves.
                    var spawnedMemory = WindowedLinearMemory(
                        config: MemoryBudgetConfig.derive(
                            contextWindow: spawnedContextWindow, tier: .small,
                            reservedChars: taskDescription.count + ToolSchemaSizes.chars(for: parentTools.map(\.name)))
                    )
                    // Delegated runs follow the gauge's global cut setting (they have no profile of
                    // their own to carry per-tool overrides).
                    let spawnedCutPolicy = ToolCutPolicy(defaultStrategy: ContextCutStrategy.globalDefault)
                    spawnedMemory.cutPolicy = spawnedCutPolicy
                    var input = AgentInput(
                        userInput: taskDescription,
                        chatHistory: [],
                        conversationID: conversationID,
                        tools: parentTools,
                        longTermMemory: StaticGroundingMemory(ragContext: ""),
                        generatorStrategy: parentGeneratorStrategy,
                        workingMemory: spawnedMemory,
                        rateLimitKey: parentRateLimitKey,
                        rateLimitCategory: parentRateLimitCategory,
                        instructions: nil,
                        traceContext: traceContext
                    )
                    // Sub-agents use the same provider class as the parent; otherwise they would default to cloud-class transport
                    // policy and lose e.g. Ollama's fast-fail "is the server running?" handling.
                    input.resiliencePolicy = .resolved(for: ProviderClass(apiProvider: parentProvider))
                    input.cutPolicy = spawnedCutPolicy
                    // Bounds the spawned agent's native turn payload; the default 0 disables compaction.
                    // Derived from `PromptFitCheck` so the cap is priced in the same `charsPerToken` units as every other budget.
                    input.nativeContextBudgetChars = PromptFitCheck.nativePayloadCharBudget(
                        forContextWindow: spawnedContextWindow
                    )

                    // Run plain ReAct — NO capabilities, NO call_agent
                    let executor = ReActAgentExecutor(maxIterations: maxIterations)
                    let stream = executor.execute(model: parentModel, input: input) { _ in }

                    var output = ""
                    var artifacts: [MediaArtifact] = []

                    for try await event in stream {
                        switch event {
                        case .content(let text):
                            output += text
                        case .artifactProduced(let artifact):
                            artifacts.append(artifact)
                        default:
                            break
                        }
                    }

                    logger.info("Spawned agent completed. Output length: \(output.count)")

                    return (
                        output: output.isEmpty ? "Agent completed the task but produced no output." : output,
                        artifacts: artifacts
                    )
                } catch {
                    logger.error("Spawned agent failed: \(error.localizedDescription)")
                    return (output: "Spawned agent failed: \(error.localizedDescription)", artifacts: [])
                }
            }
        )
    }
}
