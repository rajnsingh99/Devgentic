// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CallAgentTool.swift
//  Devgentic
//
//  Agent delegation tool: allows an LLM to spawn focused sub-agents for subtasks.
//  Spawned agents inherit the parent's LLM and tools (minus call_agent) and run
//  a plain ReAct loop. They are leaf nodes — they cannot delegate further.
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
    ///
    /// Deliberately conservative: sub-agents are short-lived leaf nodes with no chat history
    /// and no instructions, so they are sized for the smallest model the parent might be
    /// running rather than for the parent's window.
    ///
    /// Named because TWO budgets derive from it — the working-memory config and the native
    /// payload cap — and they must agree. They previously agreed only by a comment asking the
    /// next reader to keep two literals in step.
    static let spawnedContextWindow = 8_192

    /// Creates the `call_agent` AgentTool for injection into the parent agent's tool set.
    ///
    /// - Parameters:
    ///   - config: Delegation configuration (concurrency + iteration limits).
    ///   - parentModel: The parent agent's LLM provider (reused by spawned agents).
    ///   - parentTools: The parent agent's resolved tools (already excludes call_agent).
    ///   - parentGeneratorStrategy: The parent's cognitive generator strategy.
    ///   - parentRateLimitCategory: The parent's rate limit category.
    ///   - parentProvider: The parent's API provider (for trace context).
    ///   - conversationID: Current conversation for context propagation.
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

                logger.info("Spawning agent for a task of \(taskDescription.count) chars") // CR-57: the task is content

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
                    // Sub-agents talk to the SAME provider as the parent — without
                    // this they'd default to cloud-class transport policy and lose
                    // e.g. Ollama's fast-fail "is the server running?" handling.
                    input.resiliencePolicy = .resolved(for: ProviderClass(apiProvider: parentProvider))
                    input.cutPolicy = spawnedCutPolicy
                    // #22: bound the spawned agent's native turn payload too (it runs the
                    // same G12 native path on cloud/Ollama providers). Without this the
                    // field defaults to 0 = compaction disabled, reintroducing unbounded
                    // growth for delegated runs.
                    //
                    // Derived from `PromptFitCheck`, not hand-rolled. This line used to read
                    // `max(8000, Int(Double(8192) * 0.75) * 4)`, converting the window to
                    // chars at 4 chars/token while every budget and gauge in the app prices
                    // at `charsPerToken` (3.0). The intent was "75% of the window", but 24,576
                    // chars ÷ 3.0 is 8,192 tokens — the ENTIRE window. So the cap that exists
                    // to leave room for the response only engaged once history had already
                    // consumed all of it, which is the same as not having a cap.
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
