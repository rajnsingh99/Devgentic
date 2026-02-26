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

    // We default to ReAct or a generic type since this executor doesn't strictly follow an agentic architecture.
    // This satisfies the protocol requirement.
    nonisolated let architecture: AgentArchitecture = .reAct

    // MARK: - Execution Entry Point

    nonisolated func execute(
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        return AsyncThrowingStream { continuation in
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
                        state: .thinking,
                        content: "Preparing response..."
                    ))

                    // Optional: Emit a thought event so the new UI can also show this state
                    continuation.yield(.thought("Preparing response..."))

                    // 2. Construct Messages
                    // We combine instructions, RAG context, history, and the user query.
                    let messages = self.buildMessages(input: input)

                    // 3. Stream Response
                    // Phase 1: Added tools: nil
                    let tokenStream = model.stream(messages: messages, tools: nil)

                    for try await chunk in tokenStream {
                        // Explicitly check cancellation inside the loop for responsiveness
                        try Task.checkCancellation()

                        // Stream Handling: Yield text chunks directly as content events
                        continuation.yield(.content(chunk))
                    }

                    // 4. Trace: End
                    onTraceUpdate(AgentTraceLog(
                        traceID: traceSpan.traceID,
                        spanID: traceSpan.spanID,
                        parentSpanID: traceSpan.parentSpanID,
                        stepNumber: 1,
                        state: .finalizing,
                        content: "Response Complete"
                    ))

                    continuation.finish()

                } catch is CancellationError {
                    logger.info("ChatExecutor stream cancelled.")
                    continuation.finish()
                } catch {
                    logger.error("ChatExecutor Error: \(error.localizedDescription)")
                    // Stream Handling: Emit error event before throwing
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

    // MARK: - Helper Methods

    /// Builds the messages array in OpenAI-compatible format from the AgentInput.
    nonisolated private func buildMessages(input: AgentInput) -> [[String: String]] {
        var messages: [[String: String]] = []

        // A. System Instructions / RAG Context
        var systemTextParts: [String] = []

        if let instructions = input.instructions, !instructions.isEmpty {
            systemTextParts.append(instructions)
        }

        // If RAG context is present, we inject it into the system prompt or as a preamble.
        // For Bots, we typically prepend it to ensure adherence.
        if let ragContext = input.ragContext, !ragContext.isEmpty {
            let contextBlock = """
            ### CONTEXT FROM KNOWLEDGE BASE
            \(ragContext)
            ### END CONTEXT
            (Please use the context above if relevant to answer the following question)
            """
            systemTextParts.append(contextBlock)
        }

        if !systemTextParts.isEmpty {
            let combinedSystem = systemTextParts.joined(separator: "\n\n")
            messages.append(["role": "system", "content": combinedSystem])
        }

        // B. Chat History
        for msg in input.chatHistory {
            guard let text = msg.content.textContent else { continue }
            if msg.sender == .user {
                messages.append(["role": "user", "content": text])
            } else {
                messages.append(["role": "assistant", "content": text])
            }
        }

        // C. Current User Input
        // Note: Some models expect the last entry to be the user prompt.
        messages.append(["role": "user", "content": input.userInput])

        return messages
    }
}
