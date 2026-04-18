//
//  ChatExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 07/02/26.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatExecutor")

/// A lightweight executor for direct "Bot" interactions.
/// Unlike the ReActAgentExecutor, this does not loop, reason, or use tools.
/// It simply constructs messages and streams the model's response.
actor ChatExecutor: Executor {

    // MARK: - Properties

    nonisolated let executorLabel: String = "Chat"

    // MARK: - Execution Entry Point

    nonisolated func execute(
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        return AsyncThrowingStream(AgentStreamEvent.self) { continuation in
            // [CRITICAL FIX] Capture the task to allow cancellation propagation
            let task = Task {
                do {
                    // Check cancellation before starting
                    try Task.checkCancellation()

                    // 1. Trace: Start (UI Feedback)
                    // We map the "Chat" state to "Thinking" so the UI shows activity.
                    let traceSpan = input.traceContext.newSpan()

                    onTraceUpdate(AgentTraceLog(
                        traceID: traceSpan.traceID,
                        spanID: traceSpan.spanID,
                        parentSpanID: traceSpan.parentSpanID,
                        stepNumber: 0,
                        state: .thinking(.reasoning),
                        content: "Preparing response..."
                    ))

                    // Optional: Emit a thought event so the new UI can also show this state
                    continuation.yield(.thought("Preparing response..."))

                    // 2. Construct Messages
                    // We combine instructions, RAG context, history, and the user query.
                    let messages = self.buildMessages(input: input)

                    logger.info("--- 🤖 CHAT EXECUTOR START 🤖 ---")
                    logger.info("Model: \(model.modelName)")
                    if let instructions = input.instructions {
                        logger.info("Instructions: \(instructions.prefix(100))...")
                    }

                    onTraceUpdate(AgentTraceLog(
                        traceID: traceSpan.traceID,
                        spanID: traceSpan.spanID,
                        parentSpanID: traceSpan.parentSpanID,
                        stepNumber: 1,
                        state: .thinking(.reasoning),
                        content: "Processing request...",
                        metadata: ["prompt_tokens": "\(input.chatHistory.count)"]
                    ))

                    var didSetFinalizing = false
                    var fullResponse = ""

                    // Stream thoughts & content
                    // IMPORTANT: ChatExecutor currently uses the base LLMProvider.stream method
                    // until streamChat is formally added to the protocol.
                    for try await chunk in model.stream(messages: messages, tools: nil) {
                        try Task.checkCancellation()
                        fullResponse += chunk
                        
                        if !didSetFinalizing {
                             onTraceUpdate(AgentTraceLog(
                                traceID: traceSpan.traceID,
                                spanID: traceSpan.spanID,
                                parentSpanID: traceSpan.parentSpanID,
                                stepNumber: 2,
                                state: .thinking(.finalizing),
                                content: "Generating final answer..."
                            ))
                            didSetFinalizing = true
                        }
                        
                        continuation.yield(.content(chunk))
                    }

                    logger.info("--- 🏁 CHAT EXECUTOR COMPLETE 🏁 ---")
                    logger.info("Final Response: \(fullResponse)")
                    logger.info("-----------------------------------")

                    // Emit token usage — estimated from character lengths since
                    // streaming responses don't include usage metadata for most providers.
                    let inputChars = messages.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
                    continuation.yield(.tokenUsage(
                        .estimated(inputChars: inputChars, outputChars: fullResponse.count)
                    ))

                    // 4. Trace: End
                    onTraceUpdate(AgentTraceLog(
                        traceID: traceSpan.traceID,
                        spanID: traceSpan.spanID,
                        parentSpanID: traceSpan.parentSpanID,
                        stepNumber: 3,
                        state: .thinking(.finalizing),
                        content: "Response Complete"
                    ))

                    continuation.finish()

                } catch is CancellationError {
                    logger.info("ChatExecutor stream cancelled.")
                    continuation.finish()
                } catch {
                    logger.error("ChatExecutor Error: \(error.localizedDescription)")
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }

            // [CRITICAL FIX] Ensure stream termination kills the inner task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Message Construction

    /// Builds the messages array using the unified `PromptBuilder`.
    /// Bot uses `.bot` layer config: task, instructions, environment, RAG, episodic history.
    /// The user's current query is passed as `userMessagePrefix` so it appears as the
    /// final user message — maintaining natural conversational flow.
    nonisolated private func buildMessages(input: AgentInput) -> [[String: String]] {
        // Workflow-aware branch
        if let wfCtx = input.workflowContext {
            return buildWorkflowMessages(input: input, workflowContext: wfCtx)
        }

        let context = buildSemanticContext(from: input)

        // Determine native flow from which history field AgentConnect populated
        let isNativeFlow = input.nativeHistoryTurns != nil

        return PromptBuilder.buildStandardMessages(
            context: context,
            isNativeFlow: isNativeFlow,
            layerConfig: .bot,
            userMessagePrefix: input.userInput
        )
    }

    // MARK: - Workflow Message Building

    /// Builds workflow bot messages using the unified `PromptBuilder` with `.workflow` config.
    nonisolated private func buildWorkflowMessages(
        input: AgentInput,
        workflowContext: WorkflowExecutionContext
    ) -> [[String: String]] {
        logger.info("[Workflow] Building workflow messages for bot node '\(workflowContext.nodeName)'")

        let context = buildSemanticContext(from: input, taskDescription: workflowContext.taskDescription)

        let prefix: String
        if workflowContext.isFirstNode {
            prefix = "Execute your task."
        } else if workflowContext.upstreamInput.isEmpty {
            prefix = "No input data provided. Execute your task based on the task description."
        } else {
            prefix = "<input>\n\(workflowContext.upstreamInput)\n</input>"
        }

        return PromptBuilder.buildStandardMessages(
            context: context,
            layerConfig: .workflow,
            userMessagePrefix: prefix
        )
    }

    // MARK: - SemanticContext Construction

    /// Builds a lightweight SemanticContext from AgentInput for Bot/Workflow-Bot usage.
    /// Bot-irrelevant fields (tools, working memory, guardrails, skills) are empty/nil.
    nonisolated private func buildSemanticContext(
        from input: AgentInput,
        taskDescription: String? = nil
    ) -> SemanticContext {
        let envFacts = EnvironmentFacts(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            shellType: "Zsh (Non-Interactive Mode)",
            userName: NSUserName(),
            currentDate: Date().formatted(date: .numeric, time: .shortened)
        )

        return SemanticContext(
            instructions: input.instructions,
            environmentFacts: envFacts,
            longTermMemory: input.longTermMemory,
            recentHistory: input.recentHistory,
            nativeHistoryTurns: input.nativeHistoryTurns,
            originalQuery: input.userInput,
            currentIteration: 0,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: [],
            userProfile: nil,
            skillManifests: nil,
            taskDescription: taskDescription,
            promptLayerConfig: taskDescription != nil ? .workflow : .bot
        )
    }
}
