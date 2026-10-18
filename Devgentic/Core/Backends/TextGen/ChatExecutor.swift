// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatExecutor.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ChatExecutor")

/// Thread-safe one-slot holder for a stream's real token usage, written once from the SSE reader's `onUsage` callback.
/// Read after the stream completes; nil when the provider did not report usage, so the caller estimates.
private final class StreamUsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: TokenUsage?
    var value: TokenUsage? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

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
                    // Begin the span so EvaluationLogger-bridged events FK-link instead of
                    // being dropped, and the bot path appears in the trace tree (Gap #9).
                    await TraceRecorder.shared.beginSpan(context: traceSpan, name: "chat_call", kind: .llmCall)
                    var chatSucceeded = false
                    // The narrow model-call duration (call start to response), declared in the span's metadata.
                    // The Run Report's Model lane counts declared measurements; this span's own duration also covers assembly and retries.
                    var modelCallMs: Int? = nil
                    defer {
                        // End time captured HERE, before the fire-and-forget hop — the real end
                        // survives losing the race against endTrace's clamp (earliest-wins).
                        let endedAt = Date()
                        let s: SpanStatus = chatSucceeded ? .completed : .error
                        // nil when the call never reached the model (assembly threw or the consumer was torn down),
                        // so the lane counts nothing rather than charging teardown time to the model.
                        let meta = modelCallMs.map {
                            ["model": model.modelName, "duration_ms": "\($0)"]
                        }
                        Task { await TraceRecorder.shared.endSpan(spanID: traceSpan.spanID, status: s, at: endedAt, metadata: meta) }
                    }

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
                    let assemblyStart = Date()
                    let messages = self.buildMessages(input: input)
                    // Input-lane clock: the bot path's assembly is one synchronous build, measured rather than guessed.
                    await TraceRecorder.shared.emitMetric(
                        span: traceSpan, key: "input_assembly",
                        valueMs: Int(Date().timeIntervalSince(assemblyStart) * 1000))
                    await TraceRecorder.shared.emitLLMRequest(span: traceSpan, model: model.modelName, messageCount: messages.count)
                    // The model-time clock starts after message assembly, so prompt building is not charged to the Model lane.
                    let callStart = Date()

                    logger.info("--- 🤖 CHAT EXECUTOR START 🤖 ---")
                    logger.info("Model: \(model.modelName)")
                    if let instructions = input.instructions {
                        logger.info("Instructions: \(instructions.count) chars") // instructions are content
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

                    // Transport resilience: bounded backoff and classified fatal messages, same classifier as the agent path.
                    // Retries happen only before the first token; afterwards a re-attempt would double-render.
                    var retrier = TransportRetrier(transport: input.resiliencePolicy.transport)

                    // Throws on cancellation: swallowing a `CancellationError` during a long Retry-After backoff would make Stop fire
                    // another request.
                    let applyRetryStep: @Sendable (TransportRetrier.RetryStep) async throws -> Void = { step in
                        if let penalty = step.drainPenalty {
                            await GlobalRateLimiter.shared.drainAndPenalize(
                                key: input.rateLimitKey, category: input.rateLimitCategory, penaltySeconds: penalty
                            )
                        }
                        continuation.yield(.warning(category: step.category, message: step.message))
                        if step.delay > 0 {
                            try await Task.sleep(nanoseconds: UInt64(step.delay * 1_000_000_000))
                        }
                    }

                    // Multimodal branch: image blocks route through non-streaming `generate(payload:)` so vision providers see them.
                    // Text-only providers drop the image; a failed image resolve throws rather than dropping silently.
                    let currentImageBlocks: [MessageBlock] = (input.userPayload ?? []).filter {
                        if case .image = $0 { return true } else { return false }
                    }
                    // Vision bots also re-attach prior-turn images so the picture stays in view across follow-ups; non-vision adds nothing.
                    // Tradeoff: any image in the conversation makes every later turn non-streaming.
                    let (historyImageBlocks, historyImagesOmitted, historyImagesTranscoded) = input.botHistoryImagesEnabled
                        ? Self.buildHistoryImageBlocks(from: input.chatHistory, correlation: "trace:\(traceSpan.traceID)")
                        : ([], 0, 0)
                    let imageBlocks: [MessageBlock] = historyImageBlocks + currentImageBlocks

                    // Captures the provider's real token usage from the stream's terminal usage event; nil for the image path or
                    // non-reporting providers.
                    let usageBox = StreamUsageBox()

                    if !imageBlocks.isEmpty {
                        // The bot-path counterpart to the native 'Seeded' and legacy '[MULTIMODAL]' lines, confirming the request carries
                        // images via `generate(payload:)`.
                        logger.info("[VISION] trace:\(traceSpan.traceID) bot request carrying \(currentImageBlocks.count) current-turn + \(historyImageBlocks.count) prior-turn image(s)\(historyImagesOmitted > 0 ? ", \(historyImagesOmitted) history omitted (unsupported format)" : "")\(historyImagesTranscoded > 0 ? ", \(historyImagesTranscoded) history transcoded → jpeg" : "") → \(String(describing: type(of: model))) via generate(payload:) (atomic, non-streaming)")
                        // Atomic call — safe to retry the whole request.
                        let providerMessages = Self.appendImages(to: messages, imageBlocks: imageBlocks)
                        var result = ""
                        atomicLoop: while true {
                            try Task.checkCancellation()
                            do {
                                result = try await model.generate(payload: providerMessages, tools: nil, responseSchema: nil)
                                break atomicLoop
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                // A user cancel surfaces as `URLError(.cancelled)`, not `CancellationError`; normalize it so we exit instead of
                                // retrying.
                                if Task.isCancelled { throw CancellationError() }
                                // Throws `TransportFatalError` when the budget is spent or the failure is deterministic; rethrows non-transport errors
                                // unchanged.
                                let step = try retrier.nextStep(for: error)
                                try await applyRetryStep(step)
                            }
                        }
                        fullResponse = result
                        onTraceUpdate(AgentTraceLog(
                            traceID: traceSpan.traceID, spanID: traceSpan.spanID, parentSpanID: traceSpan.parentSpanID,
                            stepNumber: 2, state: .thinking(.finalizing), content: "Generating final answer..."
                        ))
                        continuation.yield(.content(result))
                    } else {
                        // Streams thoughts and content: pre-first-token failures retry, but once a chunk was yielded the error surfaces.
                        // Uses the base `LLMProvider.stream` until `streamChat` is added to the protocol.
                        streamLoop: while true {
                            try Task.checkCancellation()
                            var emittedThisAttempt = false
                            do {
                                // The conversation names the MLX prompt cache, so a Bot conversation's next message reuses the shared prompt prefix.
                                // Set around this call only and never for a workflow node; non-MLX providers ignore it.
                                let promptCacheKey = Self.promptCacheKey(for: input)
                                let stream = MLXPromptCacheScope.$key.withValue(promptCacheKey) {
                                    model.streamWithUsage(messages: messages, tools: nil, onUsage: { usageBox.value = $0 })
                                }
                                for try await chunk in stream {
                                    try Task.checkCancellation()
                                    emittedThisAttempt = true
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
                                break streamLoop
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                // User cancel surfaces as URLError(.cancelled) (not a Swift
                                // CancellationError) — exit cleanly rather than retry.
                                if Task.isCancelled { throw CancellationError() }
                                // Once content has been emitted (this attempt or a
                                // prior one), retrying would re-render — surface it.
                                if emittedThisAttempt || !fullResponse.isEmpty { throw error }
                                let step = try retrier.nextStep(for: error)
                                try await applyRetryStep(step)
                            }
                        }
                    }

                    // A torn-down consumer ends the provider stream quietly, so this path also runs when the task was cancelled mid-stream;
                    // log it as discarded, not as a complete response.
                    if Task.isCancelled {
                        logger.notice("--- 🚫 CHAT EXECUTOR TORN DOWN (cancelled mid-stream) 🚫 — \(fullResponse.count) chars of partial output DISCARDED; the consumer is gone (Stop, node timeout, or per-node skip). CONSEQUENCE: nothing below reaches the run — its outcome was decided by whoever cancelled this task, and the events yielded from here land in a dead stream.")
                    } else {
                        logger.info("--- 🏁 CHAT EXECUTOR COMPLETE 🏁 ---")
                        logger.info("Final Response: \(fullResponse.count) chars") // the reply is content; full text at debug only
                        logger.debug("Final Response: \(fullResponse)")
                        logger.info("-----------------------------------")
                    }
                    let callMs = Int(Date().timeIntervalSince(callStart) * 1000)
                    modelCallMs = callMs
                    await TraceRecorder.shared.emitLLMResponse(span: traceSpan, durationMs: callMs, preview: fullResponse)
                    chatSucceeded = true

                    // Emit token usage: prefer the provider's real counts from the terminal usage event, else a chars/4 estimate (e.g.
                    // MLX, image path).
                    let inputChars = messages.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
                    continuation.yield(.tokenUsage(
                        usageBox.value ?? .estimated(inputChars: inputChars, outputChars: fullResponse.count)
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

                    // Authoritative terminal signal, matching every other executor; the ActiveStreamManager safety nets remain as backstops.
                    continuation.yield(.executionFinished(outcome: .completed))
                    continuation.finish()

                } catch is CancellationError {
                    logger.info("ChatExecutor stream cancelled.")
                    // Best-effort terminal signal; if the consumer was already torn down, ActiveStreamManager's cancellation net stamps
                    // `.cancelled`.
                    continuation.yield(.executionFinished(outcome: .cancelled, reason: "User stopped the run"))
                    continuation.finish()
                } catch let fatal as TransportFatalError {
                    // A bounded-transport give-up or deterministic provider failure carries a category; record classified telemetry as the
                    // agent path does.
                    let classified = ClassifiedAgentError.synthetic(
                        category: fatal.category,
                        origin: "ChatExecutor.transport",
                        message: fatal.reason
                    )
                    await TraceRecorder.shared.emitAgentError(span: input.traceContext, error: classified)
                    logger.error("ChatExecutor transport-fatal (\(fatal.category.rawValue)): \(fatal.reason)")
                    continuation.yield(.error(.init(fatal.reason)))
                    continuation.yield(.executionFinished(outcome: .failed, reason: fatal.reason))
                    continuation.finish(throwing: fatal)
                } catch {
                    logger.error("ChatExecutor Error: \(error.localizedDescription)")
                    continuation.yield(.error(.init(error.localizedDescription)))
                    continuation.yield(.executionFinished(outcome: .failed, reason: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }

            // [CRITICAL FIX] Ensure stream termination kills the inner task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Multimodal

    /// Recent window of prior-turn messages scanned for re-attachable images: 20 messages is ~10 turn pairs,
    /// matching `NativeHistoryConverter`'s default window (a recency bound, not a per-image tier).
    private static let historyImageWindow = 20

    /// Collects prior-turn images from a vision bot's history for re-attachment, plus the count omitted for bad format.
    /// Bounded to `historyImageWindow` messages, user turns only; HEIC/GIF/TIFF/BMP are omitted via `VisionImageFormat`.
    /// `internal` so the pure collection logic is unit-testable.
    nonisolated static func buildHistoryImageBlocks(
        from history: [ChatMessage],
        window: Int = historyImageWindow,
        correlation: String = ""
    ) -> (blocks: [MessageBlock], omitted: Int, transcoded: Int) {
        var blocks: [MessageBlock] = []
        var omitted = 0
        var transcoded = 0
        for message in history.suffix(window) where message.sender == .user {
            guard let files = message.attachedImageFiles, !files.isEmpty else { continue }
            for file in files {
                // Bytes-first and byte-truthful: resolve from the persisted blob by its real container, passing jpeg/png/webp through,
                // transcoding HEIC and similar to JPEG, and omitting only the undecodable.
                if !file.binaryData.isEmpty {
                    if let sendable = VisionImageFormat.resolveSendable(data: file.binaryData) {
                        blocks.append(.image(ImagePayload(reference: .ephemeralData(sendable.data), mimeType: sendable.mimeType, alt: file.name)))
                        if sendable.wasTranscoded { transcoded += 1 }
                    } else {
                        omitted += 1
                        logger.warning("[VISION] \(correlation) omitted prior-turn image '\(file.name)' — persisted bytes are not a decodable image; the model won't re-see it (it stays in the transcript).")
                    }
                    continue
                }
                // Rare disk-path-only state (no persisted bytes): cannot sniff without a read, so use the extension and omit an
                // unsupported format.
                if let mime = VisionImageFormat.mimeType(forExtension: file.fileExtension) {
                    blocks.append(.image(ImagePayload(reference: .diskPath(file.url), mimeType: mime, alt: file.name)))
                } else {
                    omitted += 1
                    logger.warning("[VISION] \(correlation) omitted prior-turn image '\(file.name)' (.\(file.fileExtension)) — unsupported format and no persisted bytes to transcode; the model won't re-see it (it stays in the transcript).")
                }
            }
        }
        return (blocks, omitted, transcoded)
    }

    nonisolated private static func appendImages(to messages: [[String: String]], imageBlocks: [MessageBlock]) -> [ProviderMessage] {
        var providerMessages = messages.map { ProviderMessage(legacy: $0) }
        if let lastUser = providerMessages.lastIndex(where: { $0.role == "user" }) {
            var content = providerMessages[lastUser].content
            content.append(contentsOf: imageBlocks)
            providerMessages[lastUser] = ProviderMessage(role: "user", content: content, toolCallId: providerMessages[lastUser].toolCallId)
        } else {
            providerMessages.append(ProviderMessage(role: "user", content: imageBlocks))
        }
        return providerMessages
    }

    // MARK: - Message Construction

    /// The MLX prompt-cache key a Bot call runs under: its conversation, or nil for a workflow node.
    nonisolated static func promptCacheKey(for input: AgentInput) -> String? {
        input.workflowContext == nil ? input.conversationID.uuidString : nil
    }

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

    /// Builds workflow bot messages with `PromptBuilder` and the `.workflow` config.
    /// The per-node user-message prefix is derived from `workflowContext` inside `buildStandardMessages`.
    nonisolated private func buildWorkflowMessages(
        input: AgentInput,
        workflowContext: WorkflowExecutionContext
    ) -> [[String: String]] {
        logger.info("[Workflow] Building workflow messages for bot node '\(workflowContext.nodeName)'")

        let context = buildSemanticContext(
            from: input,
            workflowContext: workflowContext
        )

        return PromptBuilder.buildStandardMessages(
            context: context,
            layerConfig: .workflow
        )
    }

    // MARK: - SemanticContext Construction

    /// Builds a lightweight `SemanticContext` from `AgentInput` for Bot/Workflow-Bot use; bot-irrelevant fields are empty
    /// or nil.
    /// When `workflowContext` is non-nil, `buildStandardMessages` derives the per-node user-message prefix from it.
    nonisolated private func buildSemanticContext(
        from input: AgentInput,
        workflowContext: WorkflowExecutionContext? = nil
    ) -> SemanticContext {
        let envFacts = EnvironmentFacts(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            shellType: "Zsh (Non-Interactive Mode)",
            userName: NSUserName(),
            homeDirectory: NSHomeDirectory(),
            currentDate: EnvironmentFacts.clock().date,
            currentTime: EnvironmentFacts.clock().time
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
            promptLayerConfig: workflowContext != nil ? .workflow : .bot,
            workflowContext: workflowContext,
            attachmentContext: input.attachmentContext,
            knowledgeBaseContext: input.knowledgeBaseContext,
            toolGuidanceContext: input.toolGuidanceContext
        )
    }
}
