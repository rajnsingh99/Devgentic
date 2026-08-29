//
//  ChatExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 07/02/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ChatExecutor")

/// Thread-safe one-slot holder for a stream's real token usage. Written once from the SSE
/// reader task's `onUsage` callback, read by `ChatExecutor` after the stream completes (the
/// stream's clean finish synchronizes the two). `nil` when the provider didn't report usage,
/// in which case the caller falls back to an estimate (#10b).
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
                    // The NARROW model-call duration (callStart → response), declared in the
                    // span's metadata because the Run Report's Model lane counts declared
                    // measurements, not span wall-clock: this span brackets message assembly and
                    // the whole retry loop, so its own duration over-reads. Without this the bot
                    // path contributed NOTHING to the Model lane and its real model time landed
                    // in "Unattributed" — 12.0s of a 14.0s run, observed on-device 2026-08-23.
                    var modelCallMs: Int? = nil
                    defer {
                        // End time captured HERE, before the fire-and-forget hop — the real end
                        // survives losing the race against endTrace's clamp (earliest-wins).
                        let endedAt = Date()
                        let s: SpanStatus = chatSucceeded ? .completed : .error
                        // nil when the call never reached the model (assembly threw, or the
                        // consumer was torn down first) — the lane then honestly counts nothing
                        // rather than charging teardown time to the model.
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
                    // Input-lane clock (Run-Report Phase 3): the bot path's assembly is one
                    // synchronous build — small, but measured rather than guessed.
                    await TraceRecorder.shared.emitMetric(
                        span: traceSpan, key: "input_assembly",
                        valueMs: Int(Date().timeIntervalSince(assemblyStart) * 1000))
                    await TraceRecorder.shared.emitLLMRequest(span: traceSpan, model: model.modelName, messageCount: messages.count)
                    // The model-time clock starts AFTER message assembly — it used to start
                    // before buildMessages, so the bot lane charged prompt-building (history
                    // render, RAG splice) to the model and the Model lane over-read.
                    let callStart = Date()

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

                    // Transport resilience (audit gap #9): the bot path previously had
                    // NO retry/throttle handling — a single 429 or network blip surfaced
                    // a raw error card. We now bound transport failures with backoff and
                    // emit honest, classified fatal messages, reusing the SAME classifier
                    // as the agent path (`TransportRetrier` ↔ `LLMRetryStrategy`). Retries
                    // only happen BEFORE the first token is emitted — once streaming has
                    // started we can't cleanly re-attempt without double-rendering.
                    var retrier = TransportRetrier(transport: input.resiliencePolicy.transport)

                    // Throws on cancellation: a swallowed CancellationError during a long
                    // Retry-After backoff made Stop fire another provider request instead
                    // of aborting — propagating reaches the CancellationError catch below.
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

                    // Multimodal branch (Phase 3 — native image input): when the
                    // message carries image blocks, route through the non-streaming
                    // `generate(payload:)` so vision-capable providers (Claude/OpenAI/
                    // Gemini) receive the image natively. Text-only providers downgrade
                    // gracefully (image dropped, text kept). Token streaming is traded
                    // for image support on these turns. A failed image resolve throws
                    // here and is surfaced as an error (never a silent drop).
                    let currentImageBlocks: [MessageBlock] = (input.userPayload ?? []).filter {
                        if case .image = $0 { return true } else { return false }
                    }
                    // Vision bots also re-attach PRIOR-turn images so the picture stays
                    // "in view" across follow-ups (agents do this via nativeHistoryTurns;
                    // a .none-capability bot's history is episodic XML with no per-turn
                    // structure, so these ride the current user turn instead). Gated on
                    // vision + format; non-vision → flag is false → nothing added.
                    // TRADEOFF (accepted): any image in the conversation makes every
                    // subsequent turn non-streaming (the multimodal API is atomic).
                    let (historyImageBlocks, historyImagesOmitted, historyImagesTranscoded) = input.botHistoryImagesEnabled
                        ? Self.buildHistoryImageBlocks(from: input.chatHistory, correlation: "trace:\(traceSpan.traceID)")
                        : ([], 0, 0)
                    let imageBlocks: [MessageBlock] = historyImageBlocks + currentImageBlocks

                    // Captures the provider's real token usage from the stream's terminal
                    // usage event (#10b); stays nil for the atomic image path and for
                    // providers that don't report usage (then we estimate below).
                    let usageBox = StreamUsageBox()

                    if !imageBlocks.isEmpty {
                        // [VISION] The bot-path counterpart to the native "Seeded" and the
                        // legacy "[MULTIMODAL]" lines — the confirmation that THIS bot
                        // request carries images and via the atomic (non-streaming)
                        // generate(payload:) route. Without it the bot flow's only success
                        // evidence was absence-of-error.
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
                                // A user cancel surfaces as URLError(.cancelled), which is
                                // NOT a Swift CancellationError — normalize it so we exit
                                // cleanly instead of treating it as a retryable transient.
                                if Task.isCancelled { throw CancellationError() }
                                // Throws TransportFatalError (→ outer catch) when the
                                // budget is spent or the failure is deterministic;
                                // rethrows non-transport errors unchanged.
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
                        // Stream thoughts & content. Pre-first-token failures retry;
                        // once any chunk has been yielded we surface the error rather
                        // than re-stream and double-render.
                        // IMPORTANT: ChatExecutor currently uses the base LLMProvider.stream method
                        // until streamChat is formally added to the protocol.
                        streamLoop: while true {
                            try Task.checkCancellation()
                            var emittedThisAttempt = false
                            do {
                                for try await chunk in model.streamWithUsage(messages: messages, tools: nil, onUsage: { usageBox.value = $0 }) {
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

                    // Honest completion logging: a torn-down consumer ends the provider stream
                    // QUIETLY (no throw), so this path also runs when the task was cancelled
                    // mid-stream — Stop, a node timeout, or a per-node skip. Logging that as
                    // "COMPLETE" with a Final Response dump narrated a discarded partial answer
                    // as a success, seconds before the engine logged the same text as
                    // "PARTIAL OUTPUT DISCARDED" (observed on-device, 2026-08-22).
                    if Task.isCancelled {
                        logger.notice("--- 🚫 CHAT EXECUTOR TORN DOWN (cancelled mid-stream) 🚫 — \(fullResponse.count) chars of partial output DISCARDED; the consumer is gone (Stop, node timeout, or per-node skip). CONSEQUENCE: nothing below reaches the run — its outcome was decided by whoever cancelled this task, and the events yielded from here land in a dead stream.")
                    } else {
                        logger.info("--- 🏁 CHAT EXECUTOR COMPLETE 🏁 ---")
                        logger.info("Final Response: \(fullResponse)")
                        logger.info("-----------------------------------")
                    }
                    let callMs = Int(Date().timeIntervalSince(callStart) * 1000)
                    modelCallMs = callMs
                    await TraceRecorder.shared.emitLLMResponse(span: traceSpan, durationMs: callMs, preview: fullResponse)
                    chatSucceeded = true

                    // Emit token usage — prefer the provider's real counts captured from the
                    // stream's terminal usage event (#10b); fall back to a chars÷4 estimate for
                    // providers that don't report usage (e.g. MLX) or the atomic image path.
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

                    // Authoritative terminal signal — parity with every other executor (#9b).
                    // The ActiveStreamManager safety nets remain as backstops, but the bot path
                    // now reports its own outcome explicitly instead of relying on inference.
                    continuation.yield(.executionFinished(outcome: .completed))
                    continuation.finish()

                } catch is CancellationError {
                    logger.info("ChatExecutor stream cancelled.")
                    // Best-effort terminal signal; if the consumer was already torn down by the
                    // stop-button race, ActiveStreamManager's Task.isCancelled net stamps
                    // `.cancelled` instead (#9b parity).
                    continuation.yield(.executionFinished(outcome: .cancelled, reason: "User stopped the run"))
                    continuation.finish()
                } catch let fatal as TransportFatalError {
                    // A bounded-transport give-up / deterministic provider failure carries
                    // an honest category — record classified telemetry so the bot path is
                    // observable identically to the agent path (which emits the same on its
                    // `.fatal` arm). Without this the category was dropped and bot fatals
                    // appeared uncategorized in traces.
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

    /// Builds provider messages from the legacy text messages and appends image
    /// blocks to the final user turn (the user's text already lives in `messages`).
    /// Image bytes stay reference-backed here — the provider resolves+encodes them.
    /// Recent window of prior-turn messages scanned for re-attachable images. 20
    /// messages ≈ 10 turn pairs, matching `NativeHistoryConverter`'s default agent
    /// history window — the image window tracks the text window rather than dumping
    /// every image from a long conversation (a recency bound, not a per-image tier).
    private static let historyImageWindow = 20

    /// Collects prior-turn images from a vision bot's chat history for re-attachment.
    /// Keeps the picture "in view" across follow-up turns.
    ///
    /// - Bounded to the most recent `historyImageWindow` messages.
    /// - Format-validated via `VisionImageFormat` — HEIC/GIF/TIFF/BMP are OMITTED, never
    ///   guessed, so a bad format can't 400 the conversation on every subsequent turn.
    /// - Bytes-first (`.ephemeralData` over `.diskPath`) — survives relaunch; no stale URL.
    ///
    /// Images attach to USER turns only. `chatHistory` already excludes the current
    /// message (deduped upstream), so there is no overlap with the current-turn payload.
    /// Returns the blocks in chronological order and the count omitted for bad format.
    /// `internal` (not `private`) so the pure collection logic is directly unit-testable.
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
                // Bytes-first + byte-TRUTHFUL: resolve from the persisted blob by its real
                // container — pass jpeg/png/webp through, transcode HEIC/etc → JPEG (so a
                // prior-turn HEIC keeps working across follow-ups instead of vanishing the
                // turn after the current-turn path showed it), omit only the undecodable.
                // Byte-based, so a mislabeled .jpg-that-is-HEIC can't replay a 400 here.
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
                // Rare .diskPath-only state (no persisted bytes): can't sniff or transcode
                // without a read here, so fall back to the extension for the passthrough
                // decision and omit an unsupported format.
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
    /// The per-node user-message prefix is auto-derived from `workflowContext` inside
    /// `buildStandardMessages` via `SemanticContext.workflowContext` — no per-call
    /// duplication of the first-node / no-input / `<input>` branching logic.
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

    /// Builds a lightweight SemanticContext from AgentInput for Bot/Workflow-Bot usage.
    /// Bot-irrelevant fields (tools, working memory, guardrails, skills) are empty/nil.
    /// When `workflowContext` is non-nil, `buildStandardMessages` auto-derives the
    /// per-node user-message prefix from it — no per-call-site duplication.
    nonisolated private func buildSemanticContext(
        from input: AgentInput,
        workflowContext: WorkflowExecutionContext? = nil
    ) -> SemanticContext {
        let envFacts = EnvironmentFacts(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            shellType: "Zsh (Non-Interactive Mode)",
            userName: NSUserName(),
            homeDirectory: NSHomeDirectory(),
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
            promptLayerConfig: workflowContext != nil ? .workflow : .bot,
            workflowContext: workflowContext,
            attachmentContext: input.attachmentContext,
            knowledgeBaseContext: input.knowledgeBaseContext,
            toolGuidanceContext: input.toolGuidanceContext
        )
    }
}
