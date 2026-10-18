// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendOrchestrationService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "BackendOrchestrationService")

/// The primary entry point for backend operations.
/// Orchestrates the flow between the UI, file processing, RAG retrieval, and the Agent/Bot pipelines.
@MainActor
@Observable
class BackendOrchestrationService {
    
    // MARK: - Dependencies
    private let ollamaService: OllamaService
    private let fileProcessorService: FileProcessorService
    private let agentConnect: AgentConnect

    // No stored `EmbeddingService`/`VectorStoreService` here: first touch loads CoreML and opens ObjectBox,
    // which must not happen on main at launch; `init` warms both off-main.

    #if DEBUG
    /// Test hook called with `Thread.isMainThread` when the RAG warm-up runs.
    nonisolated(unsafe) static var ragWarmUpThreadObserver: (@Sendable (_ onMainThread: Bool) -> Void)?
    #endif

    // MARK: - Initialization
    init(
        fileProcessorService: FileProcessorService
    ) {
        self.fileProcessorService = fileProcessorService
        self.ollamaService = OllamaService.shared
        self.agentConnect = AgentConnect()

        // First touch happens off the main thread so neither load sits in launch; a main-thread reader
        // arriving mid-load waits only for the remainder (static `let` init is once-only).
        Task.detached(priority: .utility) {
            let started = ContinuousClock.now
            _ = EmbeddingService.shared
            _ = VectorStoreService.shared
            logger.info("[RAG] Embedding model and vector store warmed off the main thread in \(ContinuousClock.now - started).")
            #if DEBUG
            BackendOrchestrationService.ragWarmUpThreadObserver?(Thread.isMainThread)
            #endif
        }

        logger.info("BackendOrchestrationService initialized with AgentConnect.")
    }
    
    // MARK: - The duplicate-query strip

    /// What `strippingCurrentQuery` did, so the caller can log it and a test can assert it.
    enum CurrentQueryStripOutcome: Equatable {
        case strippedByID(index: Int, of: Int)
        case strippedByText
        /// An id WAS supplied and matched nothing. The run proceeds; the caller logs loudly.
        case idNotFound(id: UUID, rows: Int)
        case nothingToStrip
    }

    // Why: the text path is gated on the id being absent, not on the lookup failing; an unmatched id must not fall
    // through to `removeLast()`, which would delete an unrelated row.
    /// Removes the message currently being asked from the history that travels with it.
    /// Matches by `currentUserMessageID` (scanning, not `.last`); text equality applies only when no id is given.
    /// `nonisolated static` over plain values so the rule is testable without a service or backend.
    nonisolated static func strippingCurrentQuery(
        from history: [ChatMessage],
        userQuery: String,
        currentUserMessageID: UUID?
    ) -> (history: [ChatMessage], outcome: CurrentQueryStripOutcome) {
        var history = history

        if let currentUserMessageID {
            guard let index = history.firstIndex(where: { $0.id == currentUserMessageID }) else {
                return (history, .idNotFound(id: currentUserMessageID, rows: history.count))
            }
            let count = history.count
            history.remove(at: index)
            return (history, .strippedByID(index: index, of: count))
        }

        if let lastMsg = history.last,
           lastMsg.sender == .user,
           let lastContent = lastMsg.content.textContent,
           lastContent.trimmingCharacters(in: .whitespacesAndNewlines)
               == userQuery.trimmingCharacters(in: .whitespacesAndNewlines) {
            history.removeLast()
            return (history, .strippedByText)
        }

        return (history, .nothingToStrip)
    }

    // MARK: - Streaming Message Logic
    
    /// Streams a response from the appropriate backend profile (Bot or Agent).
    /// Handles history sanitization, file context assembly, and RAG retrieval before routing.
    func streamMessage(
        withConfig config: BackendRequestConfig,
        conversationID: UUID,
        userQuery: String,
        currentUserMessageID: UUID? = nil,
        retrievalQuery: String,
        regenerating: RegenerationBoundary?,
        history: [ChatMessage],
        files: [FileSystemItem],
        context: TraceContext,
        resumeState: TimelineReconstruction? = nil,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        // Forward trace updates to the caller (TraceLogAggregator is superseded by TraceRecorder)
        let aggregatedTraceUpdate: @Sendable (AgentTraceLog) -> Void = { log in
            onTraceUpdate?(log)
        }
        let requestedConfig = config

        return AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            // [CRITICAL FIX] Capture the task to allow cancellation propagation
            let task = Task {
                // Resolved first: the history shape, generator, trace snapshot and request log all read the capability,
                // and must see the one this run uses (see `LiveModelDetection`).
                let config = BackendRequestConfig(profile: await LiveModelDetection.resolving(requestedConfig.profile))
                logger.info("ORCHESTRATION START (Stream): Routing with profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue)). TraceID: \(context.traceID)")
                
                // No residency change here: which local models stay loaded is decided when a run takes the local lock
                // (unloading MLX for a non-MLX request would evict a running agent's model and prompt cache).
                
                // 1. Sanitize History
                // Filter out error messages to prevents confusing the model with previous system failures.
                var conversationHistory = history.filter { message in
                    if case .error = message.content { return false }
                    return true
                }
                
                // Drops the current query from history so it is not sent twice (user UX vs LLM context).
                // The rule lives in `strippingCurrentQuery`; this call site owns the logging.
                let strip = Self.strippingCurrentQuery(
                    from: conversationHistory,
                    userQuery: userQuery,
                    currentUserMessageID: currentUserMessageID
                )
                conversationHistory = strip.history
                switch strip.outcome {
                case .strippedByID(let index, let count):
                    logger.debug("[HISTORY] Current message stripped from history BY ID at index \(index) of \(count). (Trace: \(context.traceID))")
                case .strippedByText:
                    logger.notice("[HISTORY] Current message stripped by TEXT — no message id was supplied by the caller. Every production caller passes one via `startMessageStream`; a text strip means a NEW call site is bypassing that, and text equality silently fails whenever the model-facing query differs from the persisted row (the Orb decoration case). (Trace: \(context.traceID))")
                case .idNotFound(let id, let count):
                    // Id supplied but not found in history: loud because the run proceeds, asking the question twice
                    // (as the query and as the last history row), and `pairTurns` reports that row as unanswered.
                    logger.error("[HISTORY] ⚠️ Current message NOT FOUND in history — id \(id.uuidString.prefix(8)), \(count) row(s) after sanitising. CONSEQUENCE: the query is DOUBLE-PROMPTED (once as the request, once inside the history blob) and `EpisodicHistoryFormatter.pairTurns` will emit it as an orphan marked \"Agent never responded to this query\", telling the model its own question was abandoned. Expected only when history legitimately excludes it (a regenerate/resume cut). (Trace: \(context.traceID))")
                case .nothingToStrip:
                    break
                }

                // The typed query is the only thing that rides `userInput` into the system <task> block;
                // file and knowledge payloads travel as separate context fields below.
                let queryForRequest = userQuery
                let fileContextStrategy = config.profile.resolvedFileContextStrategy

                // Attachment delivery follows the file-context strategy (extracted content vs read_file path note), never
                // retrieval; the payload lands atop the user message, not the system <task>.
                let preRequestAssemblyStart = Date()
                var attachmentContext: String? = nil
                // Resolved ONCE: delivery (below) and conversation-memory indexing (3b) must agree.
                let attachmentDelivery = AttachmentDeliveryMode.resolve(for: config.profile)
                if !files.isEmpty {
                    logger.info("Processing \(files.count) attached files with strategy: \(fileContextStrategy.rawValue). (Trace: \(context.traceID))")

                    // The mode comes from `AttachmentDeliveryMode.resolve`, the same call the transcript and gauge make, so all
                    // three agree on manifest-vs-injection and wrapper width. Do not re-derive it here.
                    switch attachmentDelivery {
                    case .pathManifest:
                        // The manifest is a promise that `read_file` exists — `resolve` only
                        // returns this when it does.
                        let paths = files.map { $0.url.path }.joined(separator: "\n")
                        attachmentContext = "The user has attached the following files. Use the read_file tool to access them when needed:\n\(paths)"
                        logger.info("[ATTACH] Stateless: handed \(files.count) path(s) to the agent to read on demand.")

                    case .inject(let includeAbsolutePaths):
                        if fileContextStrategy == .stateless {
                            // The paths would point at a tool the profile cannot call, so the
                            // content is injected rather than silently dropping the attachment.
                            logger.warning("[ATTACH] Profile '\(config.profile.displayName)' uses the stateless file strategy but has NO read_file tool enabled — the path manifest would reference a tool it cannot call. Falling back to direct injection so the \(files.count) attachment(s) still reach the model; enable read_file to get on-demand reads.")
                        } else if includeAbsolutePaths {
                            // Write-capable profiles need the path, not just the name.
                            logger.info("[ATTACH] Direct injection for \(config.profile.profileType.rawValue) discloses absolute paths so the model can write back to the right file.")
                        }
                        let (fileContext, docFailures) = await self.assembleTextFileContent(
                            for: files, includeAbsolutePaths: includeAbsolutePaths
                        )
                        if !fileContext.isEmpty {
                            attachmentContext = fileContext
                        }
                        // D3: report (traced + structured notice), keep answering.
                        await self.reportFileFailures(docFailures, span: context, continuation: continuation)
                    }
                }

                // RAG retrieval only supplements the sections above; skipped on the first message and for flows that can't use it.
                // Window comes from `resolvedLLMConfig` (`primaryLLMConfig` is nil for `.code`) and feeds budget and fit check.
                let primaryConfig = config.profile.resolvedLLMConfig
                let trainedWindow = EffectiveContextWindow.trainedWindow(for: primaryConfig)
                let contextWindowTokens = EffectiveContextWindow.resolve(
                    for: primaryConfig,
                    flavour: .forProfileType(config.profile.profileType))

                var ragContextString: String? = nil
                let profileUsesConversationRAG = config.profile.profileType == .bot
                    || config.profile.profileType == .agent

                /// The fit check runs for every chat-shaped profile, matching the composer gauge's own gate.
                /// Retrieval and fit are separate questions; only retrieval is bot/agent-only.
                let profileHasSingleContextWindow = config.profile.profileType == .bot
                    || config.profile.profileType == .agent
                    || config.profile.profileType == .code
                // Check availability before yielding the progress line (a durable transcript event); use `if/else`, not an early
                // `return`, which would abort the whole turn. Gate on `isAvailable` only: an empty result is usually healthy.
                let knowledgeStoreIsAvailable = VectorStoreService.shared.isAvailable
                if profileUsesConversationRAG && !conversationHistory.isEmpty && !knowledgeStoreIsAvailable {
                    logger.error(
                        "[RAG] Retrieval SKIPPED — the vector store is unavailable (it failed to open "
                        + "at launch). CONSEQUENCE: this turn is answered with NO knowledge-base or "
                        + "conversation-memory context, the 'Searching conversation memory' progress "
                        + "line is suppressed so the saved transcript does not claim otherwise, and an "
                        + "advisory is shown. (conv: \(conversationID) trace: \(context.traceID))"
                    )
                    await MainActor.run {
                        AdvisoryCenter.shared.post(Advisory(
                            conversationID: conversationID,
                            category: .knowledgeUnavailable,
                            message: "Conversation memory and knowledge-base search are unavailable — "
                                + "the search index didn't open. Answers won't use your indexed "
                                + "documents or earlier conversations. Quit and reopen Devgentic to retry.",
                            actionLabel: "Show Index",
                            action: .revealInFinder(path: VectorStoreService.storeDirectoryPath),
                            // No volatile inputs: the condition is process-wide and cannot change
                            // without a relaunch, so one dismissal per conversation is the right dose.
                            dedupeKey: "\(conversationID.uuidString)|knowledgeUnavailable"
                        ))
                    }
                }

                // Nothing to search for in a query with no letter or digit (empty, emoji-only).
                let queryIsRetrievable = QueryRewritingService.isRetrievable(retrievalQuery)
                if profileUsesConversationRAG && !conversationHistory.isEmpty && knowledgeStoreIsAvailable && !queryIsRetrievable {
                    logger.info("[RAG] Retrieval skipped — the query has no letters or digits (\(retrievalQuery.count) chars). CONSEQUENCE: no conversation memory this turn; an empty or emoji-only query has nothing to embed or match, so retrieval would only inject noise. (conv: \(conversationID) trace: \(context.traceID))")
                }
                if profileUsesConversationRAG && !conversationHistory.isEmpty && knowledgeStoreIsAvailable && queryIsRetrievable {

                    // The store is up — self-heal any advisory left from an earlier state.
                    await MainActor.run {
                        AdvisoryCenter.shared.clear(category: .knowledgeUnavailable, conversationID: conversationID)
                    }

                    // --- UI Progress: RAG preparation ---
                    continuation.yield(.thought("Searching conversation memory…"))

                    aggregatedTraceUpdate(AgentTraceLog(
                        traceID: context.traceID,
                        spanID: context.newSpan().spanID,
                        parentSpanID: context.spanID,
                        stepNumber: 0,
                        state: .thinking(.preparing),
                        content: "Analyzing conversation history for context retrieval...",
                        metadata: nil
                    ))

                    // Use Intelligence Core query rewriting when enabled, feature toggled on, and a model is selected
                    let isICEnabled = UserDefaults.standard.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
                    let hasICModel = await IntelligenceCoreService.shared.hasModelSelected
                    // Default to true if the key hasn't been set yet (matches @AppStorage default in settings UI)
                    let isRAGRewritingEnabled = UserDefaults.standard.object(forKey: AppSettings.ciFeatureRAGRewritingKey) == nil
                        ? true
                        : UserDefaults.standard.bool(forKey: AppSettings.ciFeatureRAGRewritingKey)
                    let queryForRAG: String
                    // Use `retrievalQuery`, not `userQuery`: the model-facing query can carry a decoration (Orb's spoken-style hint)
                    // that would swamp the embedder's window and boost BM25 on the hint's own words.
                    if isICEnabled && hasICModel && isRAGRewritingEnabled {
                        queryForRAG = await QueryRewritingService.shared.rewriteQuery(retrievalQuery, history: conversationHistory)
                    } else {
                        queryForRAG = retrievalQuery
                    }

                    ragContextString = await Self.conversationMemoryContext(
                        query: queryForRAG,
                        lexicalQuery: retrievalQuery,
                        profile: config.profile,
                        conversationID: conversationID,
                        originalHistory: history,
                        shippedHistory: conversationHistory,
                        currentTurnFiles: files,
                        regenerating: regenerating,
                        contextWindowTokens: contextWindowTokens,
                        traceID: context.traceID
                    )
                }

                // Index current-turn attachments after retrieval so a file can't re-surface in the same turn; fire-and-forget.
                // A path manifest is never indexed (the model got paths, not content); every injecting path is.
                if !files.isEmpty,
                   profileUsesConversationRAG,
                   attachmentDelivery.deliversContent {
                    let filesToIndex = files
                    // Indexed under the message that CARRIED them, dated to its turn — a fresh
                    // UUID left the vectors untraceable to any turn and outside a Redo's cutoff.
                    let carrier = currentUserMessageID.flatMap { id in history.first { $0.id == id } }
                    if carrier == nil {
                        logger.warning("[RAG] Indexing \(filesToIndex.count) attachment(s) without their carrying message — id \(currentUserMessageID.map { String($0.uuidString.prefix(8)) } ?? "nil") is not in history. CONSEQUENCE: the file vectors get a synthetic message id and are dated to now, so a later Redo of this turn treats them as belonging to a later turn. (conv: \(conversationID) trace: \(context.traceID))")
                    }
                    let carrierID = carrier?.id ?? UUID()
                    let carrierTimestamp = carrier?.timestamp ?? Date()
                    Task.detached(priority: .background) {
                        await RAGIndexingService.shared.indexAttachedFiles(
                            files: filesToIndex,
                            conversationID: conversationID,
                            messageID: carrierID,
                            messageTimestamp: carrierTimestamp
                        )
                    }
                }

                // Knowledge sources: static profile reference material, delivered as the system `<knowledge_base>` layer
                // (byte-stable per profile); the strategy picks extracted content vs a path manifest. Never rides the user query.
                var knowledgeBaseContext: String? = nil
                var toolGuidanceContext: String? = nil
                if let knowledgeSources = self.resolveKnowledgeSources(from: config.profile),
                   !knowledgeSources.isEmpty {
                    let localSources = knowledgeSources.filter { $0.isLocalFile && $0.exists }
                    if !localSources.isEmpty {
                        switch fileContextStrategy {
                        case .contextualRAG, .directInjection:
                            // Deprecated arm maps to directInjection (see Section 2 note).
                            let (knowledgeText, kbFailures) = await self.assembleKnowledgeSourceContent(sources: localSources)
                            if !knowledgeText.isEmpty {
                                knowledgeBaseContext = knowledgeText
                            }
                            await self.reportFileFailures(kbFailures, span: context, continuation: continuation)

                        case .stateless:
                            // Manifest only: the agent reads sources on demand. Built through the shared owner so the fit gauges
                            // price the exact string that ships, preamble included.
                            knowledgeBaseContext = StatelessKnowledgeManifest.text(
                                paths: localSources.map { $0.location },
                                canReadFiles: StatelessKnowledgeManifest.canReadFiles(config.profile)
                            )
                        }
                    }
                }

                // MCP server instructions (from the `initialize` handshake) go in the `<tool_guidance>` layer, not knowledge,
                // and only for servers whose tools this profile has enabled; later resolution can only narrow that set.
                let enabledToolSourceIDs: Set<UUID> = {
                    switch config.profile.details {
                    case .agent(let c), .code(let c):
                        return Set(c.tools.filter(\.isEnabled).map(\.sourceId))
                    case .bot, .workflow, .imageGen:
                        return []
                    }
                }()
                let mcpInstructions = await MCPClientService.shared
                    .connectedServerInstructions(forSourceIDs: enabledToolSourceIDs)
                if !mcpInstructions.isEmpty {
                    toolGuidanceContext = mcpInstructions
                    logger.info("[MCP-INSTRUCTIONS] Injected \(mcpInstructions.count) chars of server guidance into <tool_guidance>, from the server(s) supplying this profile's \(enabledToolSourceIDs.count) tool source(s). CONSEQUENCE: servers whose tools this profile does not hold contribute nothing.")
                } else if !enabledToolSourceIDs.isEmpty {
                    logger.debug("[MCP-INSTRUCTIONS] No server guidance applies — this profile's \(enabledToolSourceIDs.count) tool source(s) supplied no instructions. CONSEQUENCE: <tool_guidance> is omitted entirely.")
                }

                // Closes the input-assembly bracket: attachment extraction, RAG retrieval, knowledge assembly and MCP guidance,
                // attributed to the root span as the run's pre-flight cost.
                await TraceRecorder.shared.emitMetric(
                    span: context, key: "input_assembly",
                    valueMs: Int(Date().timeIntervalSince(preRequestAssemblyStart) * 1000))

                // Pre-flight fit check before tokens stream: Ollama silently head-truncates oversize prompts (system prompt first).
                // Ambient state, so it surfaces as an advisory banner above the input, not as transcript clutter.
                if profileHasSingleContextWindow {
                    // Images cost real context but add zero chars (`attachmentChars` filters them, `historyChars` reads `textContent`,
                    // nil for media). Counted only when the model can see them; a non-vision model drops them.
                    let imageTokens: Int = {
                        guard config.profile.supportsVisionInput else { return 0 }
                        let current = PromptFitCheck.estimatedImageTokens(
                            forImageURLs: files.map(\.url).filter { AttachmentClassifier.classify($0) == .image },
                            provider: primaryConfig?.apiProvider
                        )
                        // Prior-turn images are charged only where they ship; on a bot or non-native/non-vision provider they are
                        // dropped before the wire, and charging them would raise a banner the user can't clear.
                        guard config.profile.carriesHistoryImages else { return current }
                        let prior = PromptFitCheck.estimatedHistoryImageTokens(
                            in: conversationHistory,
                            provider: primaryConfig?.apiProvider,
                            // `.pointer` ships skeletons only — zero history images —
                            // so counting them would raise an un-clearable banner.
                            shipsHistoryImages: config.profile.resolvedHistoryStrategy != .pointer
                        )
                        return current + prior
                    }()

                    // Episodic memory is charged: `historyChars` reads `textContent`, nil for tool params, outcomes and `<effect>` diffs,
                    // so measure the native turns that actually ship rather than summing every message.
                    let historyProseChars = PromptFitCheck.estimatedHistoryProseChars(
                        in: conversationHistory,
                        carriesProse: config.profile.carriesHistoryProse,
                        strategy: config.profile.resolvedHistoryStrategy,
                        contextWindow: contextWindowTokens,
                        toolsAvailable: config.profile.profileType != .bot
                    )
                    let episodicChars = PromptFitCheck.estimatedEpisodicChars(
                        in: conversationHistory,
                        strategy: config.profile.resolvedHistoryStrategy,
                        contextWindow: contextWindowTokens,
                        toolsAvailable: config.profile.profileType != .bot,
                        // Pass the same flag `AgentConnect` hands the formatter, so the `<attached_images>` lines a vision profile ships
                        // are measured rather than counted as zero.
                        includeImageNames: config.profile.supportsVisionInput,
                        carriesProse: config.profile.carriesHistoryProse
                    )
                    // Tool schemas ride EVERY request and scale with how many tools the user
                    // enabled; the flat layer overhead charged an agent the same as a bot.
                    let toolSchemaChars = PromptFitCheck.estimatedToolSchemaChars(for: config.profile)
                    let estimatedTokens = PromptFitCheck.estimatedTokens(
                        attachmentChars: attachmentContext?.count ?? 0,
                        knowledgeChars: (knowledgeBaseContext?.count ?? 0) + toolSchemaChars,
                        retrievalChars: ragContextString?.count ?? 0,
                        queryChars: queryForRequest.count,
                        historyChars: historyProseChars + episodicChars,
                        imageTokens: imageTokens
                    )
                    if PromptFitCheck.exceeds(estimatedTokens: estimatedTokens, windowTokens: contextWindowTokens) {
                        // Condition-aware advice: raising num_ctx helps only when the model is trained for more than the current
                        // allocation; a model already at its trained max has nothing to raise.
                        let canRaiseWindow = primaryConfig?.apiProvider == .ollama
                            && (trainedWindow ?? 0) > contextWindowTokens
                        let modelName = primaryConfig?.modelName ?? "this model"
                        let message: String
                        if canRaiseWindow {
                            message = "This prompt is ~\(PromptFitCheck.roundedK(estimatedTokens)) tokens but the context window is set to \(PromptFitCheck.roundedK(contextWindowTokens)) — content will be cut off. \(modelName) supports up to \(PromptFitCheck.roundedK(trainedWindow ?? 0)): raise Context Window in the profile's Advanced settings."
                        } else {
                            message = "This prompt is ~\(PromptFitCheck.roundedK(estimatedTokens)) tokens but \(modelName)'s context window is \(PromptFitCheck.roundedK(contextWindowTokens)) — the model will only see part of it. Use fewer or smaller files, or switch to a larger-context model."
                        }
                        AdvisoryCenter.shared.post(Advisory(
                            conversationID: conversationID,
                            category: .contextOverflow,
                            message: message,
                            actionLabel: canRaiseWindow ? "Open Settings" : "Profile Settings",
                            action: .openProfileSettings(profileID: config.profile.id),
                            dedupeKey: "\(conversationID.uuidString)|contextOverflow|\(config.profile.id.uuidString)|\(contextWindowTokens)"
                        ))
                        logger.warning("[FIT] Context-fit: ~\(estimatedTokens) tok vs \(contextWindowTokens)-token window — advisory posted, the model will see only part of this prompt. Breakdown: tools \(toolSchemaChars) chars, episodic \(episodicChars) chars (strategy=\(config.profile.resolvedHistoryStrategy?.rawValue ?? "recentHistory/non-agent default")), prose \(historyProseChars), attachments \(attachmentContext?.count ?? 0), knowledge \(knowledgeBaseContext?.count ?? 0), retrieval \(ragContextString?.count ?? 0), query \(queryForRequest.count), images \(imageTokens) tok. (Trace: \(context.traceID))")
                    } else {
                        // Condition resolved (files removed, model switched, window
                        // raised…) — the banner self-heals.
                        AdvisoryCenter.shared.clear(category: .contextOverflow, conversationID: conversationID)
                    }
                }

                // Surfaces `ProfileValidator`'s missing-instructions advisory in chat, where an agent with no guidance answers.
                // Advisory only, never a gate: the send proceeds and the user gets one click to fix it.
                await MainActor.run {
                    let details = config.profile.details
                    if details.supportsSystemInstructions,
                       ProfileValidator.instructionsAreMissing(details.systemInstructions) {
                        AdvisoryCenter.shared.post(Advisory(
                            conversationID: conversationID,
                            category: .profileMissingInstructions,
                            message: "'\(config.profile.displayName)' has no system instructions, so it "
                                + "has no guidance on how to behave or which tools to prefer. Add them "
                                + "in the profile's settings.",
                            actionLabel: "Profile Settings",
                            action: .openProfileSettings(profileID: config.profile.id),
                            dedupeKey: "\(conversationID.uuidString)|missingInstructions|\(config.profile.id.uuidString)"
                        ))
                    } else {
                        // Self-heals the moment instructions are added.
                        AdvisoryCenter.shared.clear(
                            category: .profileMissingInstructions, conversationID: conversationID)
                    }
                }

                // Check cancellation before heavy lifting
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }

                // Mutable config wrapper so we can swap in an updated profile after Option B auto-heal.
                var currentConfig = config
                var thinkingRetryDone = false

                dispatchLoop: while true {
                do {
                    // Native image input: turns the message's attached images into a payload so vision-capable bot/agent profiles
                    // see them natively. An unreadable image is reported (traced + notice) and the turn still answers.
                    let (rawImagePayload, imageFailures) = await self.buildImagePayload(from: files, traceID: context.traceID)
                    await self.reportFileFailures(imageFailures, span: context, continuation: continuation)

                    // [VISION] Records that the app saw current-turn image attachments (bot, agent, code, before routing); its
                    // absence for an image-bearing turn means the attach pipeline dropped them. Correlates by traceID.
                    if let raw = rawImagePayload, !raw.isEmpty {
                        logger.info("[VISION] trace:\(context.traceID) current-turn: \(raw.count) image block(s) built from \(files.count) attached file(s), profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue)), vision-capable=\(config.profile.supportsVisionInput)")
                    }

                    // Vision gate (local providers only; cloud has none): if the local model can't see images, drop them, tell the
                    // user and still answer from text. Covers MLXVLM gap families and plain text-only local models.
                    let attachedImagePayload: Payload?
                    if let raw = rawImagePayload,
                       currentConfig.profile.usesLocalProvider,
                       !currentConfig.profile.supportsVisionInput {
                        attachedImagePayload = nil
                        let modelName = currentConfig.profile.primaryLLMConfig?.modelName ?? "This model"
                        continuation.yield(.content("⚠️ \(modelName) can't analyze images — answering from text only. Pick a vision-capable model to inspect the image.\n\n"))
                        logger.info("[VISION] trace:\(context.traceID) gate: DROPPED \(raw.count) image block(s) for non-vision local model '\(modelName)' — answering from text only")
                    } else {
                        attachedImagePayload = rawImagePayload
                        if let raw = rawImagePayload, !raw.isEmpty {
                            logger.info("[VISION] trace:\(context.traceID) gate: PASSED \(raw.count) image block(s) → model will receive them natively")
                        }
                    }

                    // [VISION] Explains an intentional skip when prior-turn images exist but this profile won't re-send them;
                    // `historyImageSkipReason` names the actual cause, which differs per profile/model, so don't hard-code it.
                    let priorTurnImageCount = conversationHistory.reduce(0) { $0 + ($1.attachedImageFiles?.count ?? 0) }
                    if priorTurnImageCount > 0, !currentConfig.profile.carriesHistoryImages {
                        logger.info("[VISION] trace:\(context.traceID) \(priorTurnImageCount) prior-turn image(s) in history NOT re-sent to profile '\(currentConfig.profile.displayName)' (\(currentConfig.profile.profileType.rawValue)) — \(currentConfig.profile.historyImageSkipReason). It answers from the earlier text/episodic context, not the picture.")
                    }

                    switch currentConfig.profile.profileType {

                    case .bot:
                        logger.info("Routing BOT profile '\(currentConfig.profile.displayName)' to Unified Pipeline.")

                        let stream = agentConnect.streamAgentResponse(
                            for: currentConfig.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
                            attachmentContext: attachmentContext,
                            knowledgeBaseContext: knowledgeBaseContext,
                            toolGuidanceContext: toolGuidanceContext,
                            userPayload: attachedImagePayload,
                            traceContext: context,
                            onTraceUpdate: aggregatedTraceUpdate
                        )

                        for try await event in stream {
                            // Yield events as they come
                            continuation.yield(event)
                        }
                        continuation.finish()

                    case .agent:
                        logger.info("Routing AGENT profile '\(currentConfig.profile.displayName)' to AgentConnect. Trace: \(context.traceID)")
                        
                        // Direct routing to the Generalist Agent.
                        // Signals a "New User Request" to the downstream AgentConnect logic.
                        logger.notice("[ORCHESTRATOR] ⚠️ Starting Generalist Agent Execution (Direct Handoff).")
                        
                        let traceHandler: @Sendable (AgentTraceLog) -> Void = { log in
                            logger.info("[AGENT-TRACE] Step \(log.stepNumber) (\(log.state.headline)): \(log.content) (span: \(log.spanID))")
                            aggregatedTraceUpdate(log)
                        }
                        
                        // AgentConnect handles the "New Request" flag internally for stream start.
                        // [G1 Piece 2] resumeState is non-nil only for a resumed parked-HITL agent run.
                        let stream = agentConnect.streamAgentResponse(
                            for: currentConfig.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
                            attachmentContext: attachmentContext,
                            knowledgeBaseContext: knowledgeBaseContext,
                            toolGuidanceContext: toolGuidanceContext,
                            userPayload: attachedImagePayload,
                            resumeState: resumeState,
                            traceContext: context,
                            onTraceUpdate: traceHandler
                        )
                        
                        var tokensReceived = 0
                        for try await event in stream {
                            switch event {
                            case .content:
                                tokensReceived += 1
                                continuation.yield(event)
                            case .draftText:
                                // Provisional preview only: not counted in `tokensReceived`, since a run that streamed drafts and then
                                // produced no `.content` still produced no answer.
                                continuation.yield(event)
                            case .thought(_, let message, _):
                                logger.debug("[THOUGHT] \(message)")
                                continuation.yield(event)
                            case .reasoning(let message, _, _):
                                logger.debug("[REASONING] \(message)")
                                continuation.yield(event)
                            case .toolSucceeded(let output, _, _), .toolFailed(let output, _, _, _):
                                logger.debug("[ARTIFACT] \(output.toolName) - \(output.output.prefix(50))...")
                                continuation.yield(event)
                            case .toolCall(let name, let params, _, _):
                                logger.debug("[TOOL_CALL] \(name) params: \(params)")
                                continuation.yield(event)
                            case .requestConfirmation(let toolName, _, _, _, _):
                                logger.debug("[HITL] Permission requested for \(toolName)")
                                continuation.yield(event)
                            case .requestClarification(let question, _, _, _, _, _):
                                logger.debug("[ASK_USER] Clarification requested: \(question)")
                                continuation.yield(event)
                            case .requestGate(let prompt, _, _, _, _, _, _, _):
                                logger.debug("[GATE] Decision requested: \(prompt)")
                                continuation.yield(event)
                            case .error(let err):
                                logger.debug("[ERROR] \(err)")
                                continuation.yield(event)

                            case .warning(let cat, let msg, _, _):
                                logger.debug("[WARNING] [\(cat.rawValue)] \(msg)")
                                continuation.yield(event)

                            // Workflow orchestration events (not emitted by agent profiles, but needed for exhaustive switch)
                            case .workflowNodeStarted, .workflowNodeCompleted, .workflowNodeFailed,
                                 .workflowNodeSkipped, .workflowNodeCancelled,
                                 .workflowNodeRetryScheduled,
                                 .workflowProgress, .workflowRunFinished:
                                continuation.yield(event)

                            // Multimodal events
                            case .mediaProgress, .artifactProduced:
                                continuation.yield(event)

                            // Capability events (Planning, Self-Reflection, Delegation)
                            case .requestPlanReview:
                                logger.debug("[PLAN_REVIEW] Plan review requested")
                                continuation.yield(event)
                            case .planGenerated, .planApproved, .subtaskStarted, .subtaskCompleted,
                                 .reflectionTrialStarted, .reflectionEvaluating, .reflectionRetrying, .reflectionAccepted,
                                 .delegationStarted, .delegationCompleted,
                                 .compactionCompleted, .compactionFailed,
                                 .tokenUsage,
                                 .executionFinished:
                                continuation.yield(event)
                            }
                        }
                        
                        if tokensReceived == 0 {
                            logger.warning("Stream finished without receiving tokens.")
                        }
                        
                        continuation.finish()
                        
                    case .workflow:
                        logger.info("Routing WORKFLOW profile '\(currentConfig.profile.displayName)' to AgentConnect.")

                        let stream = agentConnect.streamAgentResponse(
                            for: currentConfig.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
                            attachmentContext: attachmentContext,
                            knowledgeBaseContext: knowledgeBaseContext,
                            toolGuidanceContext: toolGuidanceContext,
                            userPayload: attachedImagePayload,
                            traceContext: context,
                            onTraceUpdate: aggregatedTraceUpdate
                        )

                        for try await event in stream {
                            continuation.yield(event)
                        }
                        continuation.finish()

                    case .imageGen:
                        logger.info("Routing IMAGE GENERATOR profile '\(currentConfig.profile.displayName)' to ImageGenExecutor.")

                        guard case .imageGen(let imgConfig) = currentConfig.profile.details else {
                            continuation.yield(.error("Invalid ImageGen profile configuration."))
                            continuation.finish()
                            return
                        }

                        let llmConfig = imgConfig.llmConfig
                        let defaultAspectRatio = imgConfig.defaultAspectRatio
                        let advancedSettings = imgConfig.advancedSettings

                        do {
                            // 1. Create provider
                            let provider = try ImageGenProviderFactory.create(for: llmConfig)

                            // 2. Analyze capability
                            let capability = ImageCapabilityAnalyzer.analyze(
                                provider: llmConfig.apiProvider,
                                modelName: llmConfig.modelName,
                                modelMetadata: llmConfig.modelMetadata
                            )

                            // 3. Resolve intent
                            // Extract attached image data from files if any are images
                            let imageFiles = files.filter { AttachmentClassifier.classify($0) == .image }
                            // Reads image bytes off the main actor and normalizes to JPEG: providers stamp a fixed image/png mime, so raw
                            // HEIC/TIFF would 400. An undecodable source is dropped and logged (degrades to text-to-image).
                            let imageURLs = imageFiles.map(\.url)
                            let editTraceID = context.traceID
                            let attachedImages: [Data]? = imageURLs.isEmpty ? nil : await Task.detached(priority: .userInitiated) {
                                imageURLs.compactMap { url -> Data? in
                                    guard let raw = try? Data(contentsOf: url) else {
                                        logger.warning("[VISION] trace:\(editTraceID) imageGen source '\(url.lastPathComponent)' unreadable — skipped")
                                        return nil
                                    }
                                    guard let jpeg = ImageConstraints.ensureJPEG(raw) else {
                                        logger.warning("[VISION] trace:\(editTraceID) imageGen source '\(url.lastPathComponent)' is not a decodable image — skipped (cannot normalize to JPEG for the provider)")
                                        return nil
                                    }
                                    if jpeg.count != raw.count {
                                        logger.info("[VISION] trace:\(editTraceID) imageGen source '\(url.lastPathComponent)' normalized → image/jpeg (\(raw.count) → \(jpeg.count) bytes)")
                                    }
                                    return jpeg
                                }
                            }.value

                            let intent = await ImageIntentResolver.resolve(
                                userQuery: userQuery,
                                attachedImages: attachedImages,
                                chatHistory: conversationHistory
                            )

                            // 4. Build options from profile defaults + advanced config
                            let advConfig: ImageGenAdvancedConfig? = {
                                guard let dict = advancedSettings else { return nil }
                                let unwrapped = dict.mapValues { $0.rawValue }
                                guard let data = try? JSONSerialization.data(withJSONObject: unwrapped) else { return nil }
                                return try? JSONDecoder().decode(ImageGenAdvancedConfig.self, from: data)
                            }()

                            let options = ImageGenOptions(
                                aspectRatio: defaultAspectRatio ?? .square,
                                numberOfImages: 1,
                                quality: advConfig?.quality ?? .standard,
                                steps: advConfig?.steps,
                                guidance: advConfig?.guidance,
                                advancedSettings: advancedSettings
                            )

                            // 5. Execute
                            let executor = ImageGenExecutor()
                            let stream = executor.execute(
                                intent: intent,
                                provider: provider,
                                capability: capability,
                                profile: currentConfig.profile,
                                conversationID: conversationID,
                                traceContext: context,
                                options: options
                            )

                            // 6. Forward stream events
                            for try await event in stream {
                                continuation.yield(event)
                            }
                            continuation.finish()
                        } catch {
                            logger.error("ImageGen setup error: \(error.localizedDescription)")
                            continuation.yield(.error(.init(error.localizedDescription)))
                            continuation.finish()
                        }

                    case .code:
                        // Code mode routes through the agent pipeline (AgentConnect), but the profile is `.code` end-to-end:
                        // `CodeSessionManager` builds it with `details: .code(agentConfig)` and `ExecutorFactory` has a `.code` arm.
                        let codeProjectPath: String
                        if case .code(let codeConfig) = currentConfig.profile.details {
                            codeProjectPath = codeConfig.projectPath ?? "unknown"
                        } else {
                            codeProjectPath = "unknown"
                        }
                        logger.info("[CODE] Routing to AgentConnect (agent pipeline) — traceID: \(context.traceID), project: \(codeProjectPath), RAG: \(ragContextString != nil), history: \(conversationHistory.count) msgs")

                        // `resumeState` threads into Code runs as into agents: Code is the plain ReAct loop, so the executor's resume
                        // preamble (replay completed steps, re-raise the parked tool) applies as-is.
                        let stream = agentConnect.streamAgentResponse(
                            for: currentConfig.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
                            attachmentContext: attachmentContext,
                            knowledgeBaseContext: knowledgeBaseContext,
                            toolGuidanceContext: toolGuidanceContext,
                            userPayload: attachedImagePayload,
                            resumeState: resumeState,
                            traceContext: context,
                            onTraceUpdate: aggregatedTraceUpdate
                        )

                        for try await event in stream {
                            continuation.yield(event)
                        }
                        logger.info("[CODE] AgentConnect stream completed — traceID: \(context.traceID)")
                        continuation.finish()
                    }
                    break dispatchLoop  // success — exit retry loop
                } catch is CancellationError {
                    logger.warning("Orchestration Stream Cancelled.")
                    continuation.finish()
                    break dispatchLoop
                } catch LLMProviderError.thinkingUnsupported(let modelName) where !thinkingRetryDone {
                    // Option B: auto-heal — disable thinking on the profile and retry once.
                    thinkingRetryDone = true
                    logger.warning("[THINKING_AUTO_HEAL] Model '\(modelName)' rejected `think: true`. Disabling and retrying.")

                    if let updatedProfile = self.disableThinkingOnProfile(currentConfig.profile) {
                        currentConfig = BackendRequestConfig(profile: updatedProfile)
                    }

                    // .warning, not .error: a benign one-shot self-heal whose retry almost always succeeds; an .error would render
                    // a red failure card for a recovered run. A second thinkingUnsupported is not caught and surfaces as an error.
                    continuation.yield(.warning(
                        category: .retry,
                        message: "Extended thinking disabled — '\(modelName)' reported it isn't supported. Retrying without it…"
                    ))
                    // Loop back to retry dispatch with the updated config.
                    continue dispatchLoop
                } catch {
                    logger.error("AGENT_CONNECT_ERROR: \(error.localizedDescription) (Trace: \(context.traceID))")
                    continuation.finish(throwing: error)
                    break dispatchLoop
                }
                } // end dispatchLoop
            }
            
            // [CRITICAL FIX] Hook up cancellation
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Option B auto-heal: disables `thinkingEnabled` on the profile's llmConfig and persists.
    /// Called when a provider throws `LLMProviderError.thinkingUnsupported` at runtime.
    /// Returns the updated snapshot (or nil if the profile doesn't have an llmConfig with a thinking flag).
    private func disableThinkingOnProfile(_ profile: BackendProfileModel) -> BackendProfileModel? {
        var updated = profile

        switch updated.details {
        case .bot(var config):
            config.llmConfig.thinkingEnabled = false
            updated.details = .bot(config)
        case .agent(var config):
            config.llmConfig.thinkingEnabled = false
            updated.details = .agent(config)
        case .code(var config):
            config.llmConfig.thinkingEnabled = false
            updated.details = .code(config)
        case .imageGen, .workflow:
            // These types don't use Ollama's think parameter.
            return nil
        }

        do {
            try BackendProfileStore.shared.saveProfile(updated)
            logger.info("[THINKING_AUTO_HEAL] Profile '\(updated.displayName)' (\(updated.id.uuidString)) updated: thinkingEnabled=false")
            return updated
        } catch {
            logger.error("[THINKING_AUTO_HEAL] Failed to persist thinkingEnabled=false for profile \(updated.id.uuidString): \(error.localizedDescription)")
            return updated  // return the in-memory updated copy so retry still proceeds
        }
    }

    // MARK: - Conversation Memory (Section 3)

    // Why: exclude only what the request carries in full; excluding the whole fetched history leaves older turns
    // neither in the prompt nor retrievable.
    /// What conversation-memory retrieval must not return for this turn.
    /// Excludes what the request carries in full (native turns from `shippedHistory`), the current query and error rows,
    /// this turn's attachments by path, and on Redo/Resume the regenerated reply and everything indexed at or after it.
    static func retrievalExclusion(
        profile: BackendProfileModel,
        originalHistory: [ChatMessage],
        shippedHistory: [ChatMessage],
        currentTurnFiles: [FileSystemItem],
        regenerating: RegenerationBoundary?,
        contextWindowTokens: Int
    ) -> RetrievalExclusion {
        let carriedInFull: Set<UUID> = profile.carriesHistoryProse
            ? NativeHistoryConverter.buildCarryingProvenance(
                strategy: profile.resolvedHistoryStrategy ?? .recentHistory,
                from: shippedHistory,
                charBudget: PromptFitCheck.historyCharBudget(forContextWindow: contextWindowTokens),
                // `includeImages: false`, as the fit check sizes the same turns: with history images the request's trim can keep one
                // fewer pair, so at most one carried turn is excluded here that the request dropped.
                includeImages: false,
                toolsAvailable: profile.profileType != .bot
            ).messageIDsCarriedInFull
            : []
        let removedFromHistory = Set(originalHistory.map(\.id)).subtracting(shippedHistory.map(\.id))

        var exclusion = RetrievalExclusion(
            messageIDs: carriedInFull.union(removedFromHistory),
            sourceIdentifiers: Set(currentTurnFiles.map(\.url.path))
        )
        if let regenerating {
            exclusion.messageIDs.insert(regenerating.messageID)
            exclusion.indexedAtOrAfter = regenerating.timestamp
        }
        return exclusion
    }

    /// Section 3's retrieval: the exclusion for this turn, then the scoped search. Static and
    /// internal so tests drive the SAME composition the send path runs, against the test host's
    /// redirected store.
    static func conversationMemoryContext(
        query: String,
        lexicalQuery: String,
        profile: BackendProfileModel,
        conversationID: UUID,
        originalHistory: [ChatMessage],
        shippedHistory: [ChatMessage],
        currentTurnFiles: [FileSystemItem],
        regenerating: RegenerationBoundary?,
        contextWindowTokens: Int,
        traceID: String
    ) async -> String? {
        let exclusion = retrievalExclusion(
            profile: profile,
            originalHistory: originalHistory,
            shippedHistory: shippedHistory,
            currentTurnFiles: currentTurnFiles,
            regenerating: regenerating,
            contextWindowTokens: contextWindowTokens
        )
        logger.debug("[RAG] Exclusion for conv \(conversationID.uuidString.prefix(8)): \(exclusion.messageIDs.count) message(s) carried in full or removed, \(exclusion.sourceIdentifiers.count) current-turn file(s), redo cutoff: \(exclusion.indexedAtOrAfter != nil). (trace: \(traceID))")
        return await retrieveRAGContext(for: query, lexicalQuery: lexicalQuery,
                                        contextWindowTokens: contextWindowTokens,
                                        conversationID: conversationID, exclusion: exclusion)
    }

    // Why: `nonisolated`: the scoped scan is synchronous and heavy (dense + BM25 + RRF) and must not run on the
    // main actor; async here runs on the cooperative pool and inherits the caller's cancellation.
    /// Retrieves conversation-memory context. `userQuery` (possibly rewritten) drives the embedding search;
    /// `lexicalQuery` is the raw typed text used for exact-match token boosting; `exclusion` lists parents not to re-inject.
    nonisolated private static func retrieveRAGContext(for userQuery: String, lexicalQuery: String, contextWindowTokens: Int, conversationID: UUID, exclusion: RetrievalExclusion) async -> String? {
        let conv = conversationID.uuidString.prefix(8)
        logger.info("[RAG] Retrieving conversation memory (conv \(conv)).")

        guard let queryEmbedding = await EmbeddingService.shared.generateEmbedding(for: userQuery) else {
            logger.warning("[RAG] The query could not be embedded (conv \(conv)). CONSEQUENCE: no conversation memory this turn; the request goes out without it.")
            return nil
        }

        // History/self exclusion happens inside the ranker so excluded parents can't occupy limit slots;
        // post-filtering here would starve turns of injected docs.
        let hits = VectorStoreService.shared.findNearest(to: queryEmbedding, queryText: lexicalQuery, limit: 3, conversationID: conversationID, exclusion: exclusion)

        guard !hits.isEmpty else {
            logger.info("[RAG] Nothing in conversation memory passed the relevance threshold (conv \(conv)) — none injected.")
            return nil
        }

        // Belt-and-braces: the ranker already skips excluded parents, so anything caught here indicates an exclusion leak
        // upstream and the log acts as a tripwire.
        let filteredHits = hits.filter { hit in
            !exclusion.excludes(hit)
        }

        let removedCount = hits.count - filteredHits.count
        if removedCount > 0 {
            logger.warning("[RAG] Dedup tripwire removed \(removedCount)/\(hits.count) document(s) the ranker should have excluded (conv \(conv)). CONSEQUENCE: none for this turn (they are dropped here), but the ranker's exclusion has a leak — fewer than the limit may be injected.")
        }

        guard !filteredHits.isEmpty else {
            logger.info("[RAG] All \(hits.count) retrieved document(s) were already in the prompt (conv \(conv)) — none injected.")
            return nil
        }

        // Window each document around its matched chunk (never the blind head) and size the injection to the model's
        // window so retrieval can't evict the system prompt on small local models.
        let budgets = RAGRetrievalBudget.budgets(forContextWindowTokens: contextWindowTokens)
        // Name each injected document (file name, or message-id prefix) and its match distance, so a wrong answer can be
        // triaged to 'retrieved the wrong doc' vs 'model missed it'.
        let hitsSummary = filteredHits.map { hit -> String in
            let identifier = hit.sourceIdentifier
            let name = identifier.contains("/")
                ? (identifier as NSString).lastPathComponent
                : "msg:\(hit.sourceMessageID.uuidString.prefix(8))"
            return "\(name) d=\(String(format: "%.3f", hit.distance))"
        }.joined(separator: ", ")
        logger.info("[RAG] Injecting \(filteredHits.count) document(s) [\(hitsSummary)] (conv \(conv); budget \(budgets.total) chars for a \(contextWindowTokens)-token window).")
        return RAGRetrievalBudget.assemble(
            filteredHits.map { (text: $0.fullTextContent, anchor: $0.bestChunkText) },
            perParent: budgets.perParent,
            total: budgets.total
        )
    }
    
    // MARK: - Direct Injection Budget

    /// Maximum characters to inject per file (~12.5K tokens)
    private var directInjectionBudgetPerFile: Int { DirectInjectionBudget.perFile }
    /// Maximum total characters to inject across all files (~50K tokens)
    private var directInjectionTotalBudget: Int { DirectInjectionBudget.total }

    /// Builds an image `Payload` from the message's attached images so vision-capable profiles receive them natively.
    /// Bytes are read under security-scoped access into ephemeral references; the payload is nil when no images attach.
    /// A file that can't be read is logged and skipped (it still appears in the document path's skipped-files notice).
    private func buildImagePayload(from files: [FileSystemItem], traceID: String) async -> (payload: Payload?, failures: [FileRetrievalError]) {
        // Determine which files are images + their mime types on the main actor — these are
        // cheap UTType lookups. Capture only Sendable values for the off-actor read below.
        var items: [(url: URL, mime: String, name: String)] = []
        for file in files {
            // Classification is shared with the transcript (`MessageAttachmentBuilder`) via `AttachmentClassifier`.
            guard AttachmentClassifier.classify(file) == .image else { continue }
            items.append((file.url, fileProcessorService.getFileMimeType(for: file.url), file.name))
        }
        guard !items.isEmpty else { return (nil, []) }

        // Reads bytes off the main actor: `Data(contentsOf:)` is synchronous disk I/O that would hitch the UI (this service
        // is `@MainActor`). Security-scoped access brackets the read inside the detached work.
        return await Task.detached(priority: .userInitiated) {
            var blocks: [MessageBlock] = []
            var failures: [FileRetrievalError] = []
            for item in items {
                let didAccess = item.url.startAccessingSecurityScopedResource()
                defer { if didAccess { item.url.stopAccessingSecurityScopedResource() } }
                // Reject an oversized image at egress too (redo/re-send re-reads from the URL and bypasses the ingestion cap);
                // stat first so a huge file is never read into memory. Reported, so the turn still answers without it.
                let byteSize = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                if byteSize > ImageConstraints.maxAttachmentImageBytes {
                    failures.append(.imageResolutionFailed(path: item.url.path, underlying: "Image exceeds the \(ImageConstraints.maxAttachmentImageBytes / (1024 * 1024)) MB limit."))
                    continue
                }
                do {
                    let data = try Data(contentsOf: item.url)
                    // Not every provider can load every container (HEIC is rejected by Ollama/Anthropic/OpenAI): jpeg/png/webp pass
                    // through, other decodable formats are transcoded to JPEG, and undecodable ones are omitted and reported.
                    guard let sendable = VisionImageFormat.resolveSendable(data: data) else {
                        failures.append(.imageResolutionFailed(
                            path: item.url.path,
                            underlying: "'\(item.name)' could not be decoded as an image, so it was omitted from the request."
                        ))
                        logger.warning("[VISION] trace:\(traceID) omitted current-turn image '\(item.name)' (\(item.mime)) — bytes are not a decodable image, cannot transcode. The turn answers without it.")
                        continue
                    }
                    if sendable.wasTranscoded {
                        logger.info("[VISION] trace:\(traceID) transcoded current-turn image '\(item.name)' (\(item.mime)) → image/jpeg for provider compatibility (\(data.count) → \(sendable.data.count) bytes)")
                    }
                    blocks.append(.image(ImagePayload(reference: .ephemeralData(sendable.data), mimeType: sendable.mimeType, alt: item.name)))
                } catch {
                    // Never silent: report the image read failure (chat degrades — the
                    // turn still answers, just without this image).
                    failures.append(.imageResolutionFailed(path: item.url.path, underlying: error.localizedDescription))
                }
            }
            return (blocks.isEmpty ? nil : blocks, failures)
        }.value
    }

    // Why: a bare file name is reproduced as a relative path that `FilePathResolver` anchors to HOME, creating a stray
    // file instead of editing the user's.
    /// Extracts text from attached documents for direct injection, skipping images (see `buildImagePayload`).
    /// Returns the assembled content and a typed list of files that couldn't be read (via `readFileContentOrThrow`).
    /// `includeAbsolutePaths` adds each file's resolved path; set for profiles that can write.
    func assembleTextFileContent(for files: [FileSystemItem], includeAbsolutePaths: Bool = false) async -> (content: String, failures: [FileRetrievalError]) {
        var readable: [DirectInjectionPlan.File] = []
        var failures: [FileRetrievalError] = []

        for file in files {
            // Images ride `buildImagePayload`. Same classifier as the transcript, so a file is
            // never recorded as one kind and delivered as another (ATT-1).
            switch AttachmentClassifier.classify(file) {
            case .image:
                continue
            case .folder:
                // Injection sends contents and a folder has none: report `.isFolder` rather than attempting a read. Intake refuses
                // folders for injecting profiles; this catches one attached under a different profile.
                failures.append(.isFolder(path: file.url.path))
                continue
            case .document, .text, .video, .binary:
                break
            }

            do {
                // Read up to the transcript's cap, not the injection budget: the plan below cuts an over-budget file to what fits,
                // whereas reading at the budget would make the reader throw and the model receive nothing.
                let content = try await fileProcessorService.readFileContentOrThrow(for: file.url, maxSize: DirectInjectionBudget.readCap)
                readable.append(.init(name: file.name, path: file.url.path, content: content))
            } catch let retrievalError as FileRetrievalError {
                failures.append(retrievalError)
            } catch {
                failures.append(.readFailed(path: file.url.path, underlying: error.localizedDescription))
            }
        }

        // The one injection rule: `MessageAttachmentBuilder` runs the same plan to record each file's delivery on the
        // transcript, and the gauge prices it.
        let (assembledContent, deliveries) = DirectInjectionPlan.assemble(readable, includeAbsolutePaths: includeAbsolutePaths)
        for (file, delivery) in zip(readable, deliveries) {
            switch delivery {
            case .full:
                // ATT-1 visibility: the authoritative "the model saw it" record — pair it
                // against MessageAttachmentBuilder's persistence logs.
                logger.debug("Direct-injected '\(file.name)' (\(file.content.count) chars) into the model context.")
            case .truncated(let sent, let total):
                logger.notice("[ATTACH] '\(file.name)' CUT to its first \(sent) of \(total) chars to fit the injection budget. CONSEQUENCE: the model sees a truncation marker and only that part; the transcript chip says so.")
            case .omitted:
                failures.append(.tooLarge(path: file.path))
            case .pathOnly:
                break
            }
        }

        if !files.isEmpty {
            logger.log("Direct injection assembled: \(files.count) attachment(s) scanned, \(assembledContent.count) chars injected, \(failures.count) failure(s).")
        }

        return (assembledContent, failures)
    }

    /// Traces each retrieval failure and surfaces a structured, actionable notice; the turn answers with what loaded.
    private func reportFileFailures(
        _ failures: [FileRetrievalError],
        span: TraceContext,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async {
        guard !failures.isEmpty else { return }
        for failure in failures {
            let classified = ClassifiedAgentError.synthetic(
                category: failure.category,
                origin: "BackendOrchestrationService.fileRetrieval",
                message: failure.message,
                context: ["path": failure.path]
            )
            await TraceRecorder.shared.emitAgentError(span: span, error: classified)
        }
        let lines = failures.map { failure -> String in
            "• " + failure.message + (failure.suggestion.map { " — \($0)" } ?? "")
        }
        let notice = "⚠️ Some attachments couldn't be read:\n" + lines.joined(separator: "\n")
        continuation.yield(.content(notice + "\n\n"))
    }

    // MARK: - Knowledge Source Helpers

    /// Resolves knowledge sources from the profile, handling both bot and agent configs.
    private func resolveKnowledgeSources(from profile: BackendProfileModel) -> [KnowledgeSource]? {
        switch profile.details {
        case .bot(let config):   return config.knowledgeSources
        case .agent(let config): return config.knowledgeSources
        default:                 return nil
        }
    }

    /// Extracts text from knowledge source files for the system `<knowledge_base>` layer.
    /// Returns the assembled content and a typed list of sources that couldn't be read; uses the same
    /// `DirectInjectionPlan` as attachments, so an over-budget source is cut with a marker rather than dropped whole.
    func assembleKnowledgeSourceContent(sources: [KnowledgeSource]) async -> (content: String, failures: [FileRetrievalError]) {
        var readable: [DirectInjectionPlan.File] = []
        var failures: [FileRetrievalError] = []
        for source in sources {
            do {
                // Read to the cap, not the budget — the plan cuts. Reading at the budget made the
                // reader THROW for an over-budget source, so none of it reached the model.
                let content = try await fileProcessorService.readFileContentOrThrow(for: source.url, maxSize: DirectInjectionBudget.readCap)
                readable.append(.init(name: source.fileName, path: source.location, content: content))
            } catch let retrievalError as FileRetrievalError {
                failures.append(retrievalError)
            } catch {
                failures.append(.readFailed(path: source.location, underlying: error.localizedDescription))
            }
        }
        let (assembled, deliveries) = DirectInjectionPlan.assemble(readable, layout: .knowledge)
        for (file, delivery) in zip(readable, deliveries) {
            switch delivery {
            case .truncated(let sent, let total):
                logger.notice("[KNOWLEDGE] '\(file.name)' CUT to its first \(sent) of \(total) chars to fit the injection budget. CONSEQUENCE: the model sees a truncation marker and only that part; the profile editor warns about this source.")
            case .omitted:
                failures.append(.tooLarge(path: file.path))
            case .full, .pathOnly:
                break
            }
        }
        return (assembled, failures)
    }
}

// MARK: - RAG Retrieval Budget

/// Budgets for retrieved conversation-memory context. Retrieval supplements the prompt, so an un-capped parent (a whole
/// indexed file) could otherwise blow the context for a single chunk match.
enum RAGRetrievalBudget {
    /// Per-parent CEILING on retrieved document text (~2K tokens) — cloud-scale.
    static let perParent = 8_000
    /// Total CEILING across all retrieved parents (~6K tokens) — cloud-scale.
    static let total = 24_000
    /// Floors so retrieval stays useful even against tiny local windows.
    static let minPerParent = 600
    static let minTotal = 1_200

    /// Scales the injection budget to the target model's context window (~15% at a conservative 3 chars/token).
    /// Fixed cloud-sized ceilings would evict the system prompt on local models with a ~4-8K-token window.
    static func budgets(forContextWindowTokens tokens: Int) -> (perParent: Int, total: Int) {
        let scaledTotal = Int(Double(tokens) * 3.0 * 0.15)
        let clampedTotal = max(minTotal, min(total, scaledTotal))
        let clampedPerParent = max(minPerParent, min(perParent, clampedTotal / 2))
        return (clampedPerParent, clampedTotal)
    }

    /// Assembles retrieved documents into the injected context string, windowing each oversize document around its
    /// matched chunk (`anchor`) rather than the head; falls back to the head window if the anchor isn't found in the text.
    static func assemble(
        _ docs: [(text: String, anchor: String?)],
        perParent perParentBudget: Int = perParent,
        total totalBudget: Int = total
    ) -> String {
        // The budget covers everything emitted: the separators between documents and every marker `window` adds,
        // not only the excerpts.
        let separator = "\n\n"
        var assembled: [String] = []
        var used = 0
        for (index, doc) in docs.enumerated() {
            let overhead = assembled.isEmpty ? 0 : separator.count
            let remaining = totalBudget - used - overhead
            guard remaining >= minUsefulExcerpt else {
                let dropped = docs.count - index
                logger.info("[RAG] Retrieved-context budget (\(totalBudget) chars) spent after \(assembled.count) of \(docs.count) document(s) — \(dropped) lower-ranked document(s) NOT injected. CONSEQUENCE: the model does not see them this turn; they remain retrievable on later turns.")
                break
            }
            let windowed = window(for: doc.text, anchor: doc.anchor, budget: min(perParentBudget, remaining))
            assembled.append(windowed)
            used += overhead + windowed.count
        }
        return assembled.joined(separator: separator)
    }

    /// Smallest excerpt worth injecting: below this, the remaining budget would deliver a sliver
    /// of a document — markers and a few words — rather than anything the model can use.
    static let minUsefulExcerpt = 120

    /// A `budget`-sized excerpt of `text` centered on `anchor` (the matched chunk).
    /// Keeps the identity line (`[File: …]`) when the head is cut and marks trimmed edges so the model knows it is partial.
    /// The result is at most `budget` characters, markers and identity line included.
    static func window(for text: String, anchor: String?, budget: Int) -> String {
        guard text.count > budget else { return text }
        let tailMarker = "\n… [truncated]"

        // Code chunks carry a `[lang Context]:` retrieval prefix that isn't part of the stored text; strip it or the anchor
        // never matches and every code chunk falls back to the head window.
        var needle = anchor ?? ""
        if needle.hasPrefix("["),
           let newline = needle.firstIndex(of: "\n"),
           needle[..<newline].hasSuffix(" Context]:") {
            needle = String(needle[needle.index(after: newline)...])
        }

        // Locate the anchor: full chunk text first, then its head (chunk boundaries
        // can drift from the stored full text via sanitization/overlap).
        var anchorRange: Range<String.Index>?
        if !needle.isEmpty {
            anchorRange = text.range(of: needle)
            if anchorRange == nil, needle.count > 120 {
                anchorRange = text.range(of: String(needle.prefix(120)))
            }
        }

        guard let matched = anchorRange else {
            return String(text.prefix(max(0, budget - tailMarker.count))) + tailMarker
        }

        // Reserve the decorations first. The omitted-count marker is sized for the LARGEST count
        // this text could produce, so the reservation is an upper bound.
        let firstLine = text.prefix(while: { $0 != "\n" })
        let header = firstLine.hasPrefix("[File:") ? String(firstLine) + "\n" : ""
        let omittedMarkerMax = "… [\(text.count) earlier chars omitted]\n".count
        let reserved = header.count + omittedMarkerMax + tailMarker.count
        let inner = reserved < budget / 2 ? budget - reserved : budget / 2

        let matchStart = text.distance(from: text.startIndex, to: matched.lowerBound)
        let matchLength = text.distance(from: matched.lowerBound, to: matched.upperBound)
        let center = matchStart + matchLength / 2

        var start = max(0, center - inner / 2)
        let end = min(text.count, start + inner)
        start = max(0, end - inner)

        let winStart = text.index(text.startIndex, offsetBy: start)
        let winEnd = text.index(text.startIndex, offsetBy: end)
        var excerpt = String(text[winStart..<winEnd])

        if start > 0 {
            // Preserve the "[File: name]" identity line so the model knows the
            // excerpt's source even when the head is trimmed away.
            excerpt = header + "… [\(start) earlier chars omitted]\n" + excerpt
        }
        if end < text.count {
            excerpt += tailMarker
        }
        // Only an identity line longer than half the budget could break the bound — clip, never overshoot.
        return excerpt.count <= budget ? excerpt : String(excerpt.prefix(budget))
    }
}

// MARK: - Direct Injection Budget

/// Injection budgets for current-turn attachments and knowledge sources.
/// File-scope (not private orchestrator state) so the composer's PRE-SEND
/// estimate can mirror exactly what the orchestrator will inject.
enum DirectInjectionBudget {
    /// Maximum characters injected per file (~12.5K tokens).
    static let perFile = 50_000
    /// Maximum total characters injected across all files (~50K tokens).
    static let total = 200_000
    /// Most characters READ from one attachment. Past it the file isn't read at all (the
    /// reader throws `.tooLarge`); under it, `DirectInjectionPlan` cuts to the budget. Shared
    /// with the transcript, whose reader uses the same cap.
    static let readCap = 500_000
}

// MARK: - Stateless Knowledge Manifest

/// The `.stateless` knowledge payload: one owner for the string the orchestrator ships and the gauges price.
enum StatelessKnowledgeManifest {
    // Why: the emitter and the estimator must share this one predicate so they never disagree about which sentence ships.
    /// Whether the profile can actually open the paths it is about to be handed.
    /// False for every profile type with no tools (`enabledToolNames` is empty for bots and imageGen).
    static func canReadFiles(_ profile: BackendProfileModel) -> Bool {
        profile.enabledToolNames.contains("read_file")
    }

    // Why: the `canReadFiles` string must stay byte-stable: the knowledge layer is a per-profile cached prompt prefix,
    // and rewording the common case invalidates that cache.
    /// The manifest itself: emitted whenever the strategy is `.stateless` and at least one local source exists.
    /// `read_file` being enabled changes the wording, never whether the manifest ships.
    /// Without `read_file`, the text says plainly that contents cannot be retrieved and must not be guessed at.
    static func text(paths: [String], canReadFiles: Bool) -> String {
        let preamble = canReadFiles
            ? "The following profile reference documents are available. Read them with the read_file tool when needed:\n"
            : "The following profile reference documents are configured, but no file-reading tool is available this turn, so their contents cannot be retrieved. Refer to them by path only — do not state or infer what they contain:\n"
        return preamble + paths.joined(separator: "\n")
    }
}

// MARK: - Prompt Fit Check

/// Pre-flight estimate of whether the assembled prompt fits the model's effective context window.
/// Char-based (~3 chars/token, conservative for code) plus a fixed layer allowance; accurate enough to gate a banner.
enum PromptFitCheck {
    /// Instructions and environment facts, the genuinely fixed layers.
    /// Variable layers are measured separately (`estimatedEpisodicChars`, `estimatedToolSchemaChars`); don't fold them in.
    static let layerOverheadChars = 2_000

    /// The whole history-channel character allocation (60% of the window, floor 4K), split between `NativeHistoryConverter`'s
    /// turn pairs and the episodic XML. Shared by `AgentConnect` (which spends it) and the fit gauges (which measure it);
    /// denominated at `charsPerToken` so spending it all prices back at 60% of the window.
    static func historyCharBudget(forContextWindow window: Int) -> Int {
        max(4_000, Int(Double(window) * 0.6 * charsPerToken))
    }

    /// The native conversation payload's compaction ceiling — 75% of the window, floor 8K.
    /// Hoisted out of `AgentConnect`, where it was inlined at two call sites, for the same
    /// reason and denominated the same way.
    static func nativePayloadCharBudget(forContextWindow window: Int) -> Int {
        max(8_000, Int(Double(window) * 0.75 * charsPerToken))
    }

    /// Chars the profile's `<knowledge_base>` layer contributes; walks the same loop as `assembleKnowledgeSourceContent`.
    /// Approximate: it stats bytes where the assembler decodes characters, so it can under- or over-count.
    /// A `.stateless` profile hands over a path manifest instead and is charged as one.
    @MainActor
    static func estimatedKnowledgeSourceChars(for profile: BackendProfileModel) -> Int {
        let sources = profile.knowledgeSourceFiles
        guard !sources.isEmpty else { return 0 }

        // `read_file` selects the wording, it does not gate the branch: a stateless profile with it disabled still takes
        // the manifest path rather than the full-injection arithmetic below.
        if profile.resolvedFileContextStrategy == .stateless {
            return StatelessKnowledgeManifest.text(
                paths: sources.map(\.location),
                canReadFiles: StatelessKnowledgeManifest.canReadFiles(profile)
            ).count
        }

        // The backend's own plan over stat'd sizes, with the knowledge wrapper, so an over-budget source is priced as the
        // slice that ships (it is cut). A source that can't be stat'd (missing) is skipped, as the reader fails on it.
        var sizes: [Int] = []
        var wrappers: [Int] = []
        for source in sources {
            guard let bytes = (try? source.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            sizes.append(bytes)
            wrappers.append(DirectInjectionPlan.wrapperWidth(name: source.fileName, path: source.location, layout: .knowledge))
        }
        return attachmentInjectionChars(forFileSizes: sizes, wrapperWidths: wrappers)
    }

    /// Characters the tool schemas contribute to the prompt, via the real serializer over the real registry entries.
    /// Renders the markdown `<available_tools>` form; native JSON `tools:` arrays differ only by punctuation.
    static func estimatedToolSchemaChars(for profile: BackendProfileModel) -> Int {
        ToolSchemaSizes.chars(for: profile.schemaBearingToolNames)
    }

    /// Characters of prose history the next request will actually carry, measured from the real native turns.
    /// `carriesProse` is `BackendProfileModel.carriesHistoryProse`, passed as a Bool rather than a profile.
    /// `toolsAvailable` mirrors `estimatedEpisodicChars` and is defaulted so existing call sites keep their arithmetic.
    static func estimatedHistoryProseChars(
        in history: [ChatMessage],
        carriesProse: Bool,
        strategy: HistoryStrategy?,
        contextWindow: Int,
        toolsAvailable: Bool = true
    ) -> Int {
        guard carriesProse, !history.isEmpty else { return 0 }
        return NativeHistoryConverter.build(
            strategy: strategy ?? .recentHistory,
            from: history,
            charBudget: historyCharBudget(forContextWindow: contextWindow),
            includeImages: false,
            toolsAvailable: toolsAvailable
        ).reduce(0) { $0 + $1.text.count }
    }

    /// Characters the episodic memory blob will occupy in the next prompt, measured by rendering the real blob.
    /// `history` must be ascending (oldest first), as `BackendHistoryResolver` returns it; `pairTurns` walks forward.
    /// `strategy` nil resolves to `.recentHistory`; `includeImageNames` and `carriesProse` mirror what `AgentConnect` passes.
    static func estimatedEpisodicChars(
        in history: [ChatMessage],
        strategy: HistoryStrategy?,
        contextWindow: Int,
        toolsAvailable: Bool = true,
        includeImageNames: Bool = false,
        carriesProse: Bool = false
    ) -> Int {
        guard !history.isEmpty else { return 0 }
        let charBudget = historyCharBudget(forContextWindow: contextWindow)
        let budget = ActionEffect.diffBudget(forHistoryCharBudget: charBudget)
        // `includeImages: false`, as `estimatedHistoryProseChars` sizes the same turns: with history images the budget trim
        // can keep one fewer turn, so the gauge under-reads by at most one 200-char outcome clip.
        let carried = carriesProse
            ? NativeHistoryConverter.buildCarryingProvenance(
                strategy: strategy ?? .recentHistory, from: history, charBudget: charBudget,
                includeImages: false, toolsAvailable: toolsAvailable).fullAnswerMessageIDs
            : []
        return EpisodicHistoryFormatter.build(
            strategy: strategy ?? .recentHistory,
            from: history,
            includeImageNames: includeImageNames,
            effectBudget: budget,
            toolsAvailable: toolsAvailable,
            answersCarriedNatively: carried
        ).count
    }
    // Why: budgets and the gauge must share this one ratio; a budget built at 4.0 but priced at 3.0 reads back over the
    // overflow threshold and posts an advisory the user can't clear.
    /// The chars-to-tokens ratio for fit checking and every char-denominated budget, in both directions.
    /// Conservative (3.0) because code burns tokens fast; under-counting is the dangerous direction for 'will this fit'.
    /// Distinct from `TokenUsage.estimated` (4.0), which answers how many tokens a call actually consumed.
    static let charsPerToken = 3.0
    /// Fraction of the window reserved for the model's own output.
    static let responseHeadroom = 0.25

    /// - Parameter imageTokens: image cost in tokens (not chars), kept separate from `attachmentChars`, which excludes
    ///   images by extension, so the two never double-count. Defaults to 0.
    static func estimatedTokens(
        attachmentChars: Int,
        knowledgeChars: Int,
        retrievalChars: Int,
        queryChars: Int,
        historyChars: Int,
        imageTokens: Int = 0
    ) -> Int {
        let totalChars = attachmentChars + knowledgeChars + retrievalChars
            + queryChars + historyChars + layerOverheadChars
        return Int(Double(totalChars) / charsPerToken) + imageTokens
    }

    /// Token cost of the images in a set of composer attachments.
    /// Dimensions come from each file's header (no decode); an unreadable header falls back to the flat per-image
    /// estimate rather than dropping the image from the tally.
    static func estimatedImageTokens(forImageURLs urls: [URL], provider: ApiProvider?) -> Int {
        urls.reduce(0) { total, url in
            total + ImageTokenHeuristic.tokens(pixels: ImageTokenHeuristic.pixelCount(of: url), provider: provider)
        }
    }

    /// Token cost of images already in the conversation, which ride the native history payload on every later turn.
    /// `maxMessages` bounds how far back to look, matching what the converter ships rather than the whole fetched history.
    /// `shipsHistoryImages` is false for strategies that carry no prior-turn images (e.g. `.pointer`), which returns 0.
    static func estimatedHistoryImageTokens(in history: [ChatMessage], provider: ApiProvider?, shipsHistoryImages: Bool = true, maxMessages: Int = historyImageLookback) -> Int {
        guard shipsHistoryImages else { return 0 }
        let recent = history.suffix(max(0, maxMessages))
        // Count every image that will actually reach the wire, including unsupported-but-decodable formats that history
        // transcodes to JPEG; `isVisionEligible` is the cheap extension proxy, the wire decision stays in `resolveSendable`.
        let count = recent.reduce(0) { total, message in
            total + (message.attachedImageFiles?.filter {
                VisionImageFormat.isVisionEligible(fileExtension: $0.fileExtension)
            }.count ?? 0)
        }
        return ImageTokenHeuristic.tokens(imageCount: count, provider: provider)
    }

    /// 10 turn pairs = 20 messages, matching `NativeHistoryConverter`'s default `limit:`.
    /// An upper bound: the char budget and any checkpoint can trim further, which errs toward under-warning.
    static let historyImageLookback = 20

    static func exceeds(estimatedTokens: Int, windowTokens: Int) -> Bool {
        Double(estimatedTokens) > Double(windowTokens) * (1.0 - responseHeadroom)
    }

    /// "8192" → "8K", "200000" → "200K"; sub-thousand values print as-is.
    static func roundedK(_ tokens: Int) -> String {
        tokens >= 1_000 ? "\(Int((Double(tokens) / 1_000).rounded()))K" : "\(tokens)"
    }

    /// Chars the attachments contribute under `DirectInjectionPlan.allocate`, over stat'd sizes.
    /// In-budget files are charged in full plus wrapper, over-budget ones as the cut slice plus marker, and files with less
    /// than `minimumSlice` of room contribute nothing. Sizes are bytes while the plan counts chars, so it errs high.
    static func attachmentInjectionChars(forFileSizes allSizes: [Int], wrapperWidths allWrappers: [Int]) -> Int {
        // A file past the READ cap is never read (the reader throws `.tooLarge`), so it never
        // reaches the plan — drop it before allocating, exactly as the assembler never sees it.
        let kept = zip(allSizes, allWrappers).filter { $0.0 <= DirectInjectionBudget.readCap }
        let sizes = kept.map(\.0)
        let wrapperWidths = kept.map(\.1)
        let deliveries = DirectInjectionPlan.allocate(lengths: sizes, wrapperWidths: wrapperWidths)
        var total = 0
        for ((size, wrapper), delivery) in zip(zip(sizes, wrapperWidths), deliveries) {
            switch delivery {
            case .full:
                total += wrapper + max(size, 0)
            case .truncated(let sent, let fileTotal):
                total += wrapper + sent + DirectInjectionPlan.truncationMarker(sent: sent, total: fileTotal).count
            case .omitted, .pathOnly:
                continue
            }
        }
        return total
    }

    /// Convenience for callers pricing a uniform wrapper.
    static func attachmentInjectionChars(forFileSizes sizes: [Int], wrapperCharsPerFile: Int) -> Int {
        attachmentInjectionChars(forFileSizes: sizes, wrapperWidths: Array(repeating: wrapperCharsPerFile, count: sizes.count))
    }

    /// Chars the attachments contribute for this profile, honouring its file strategy.
    /// `.stateless` sends a short path manifest and is charged as one; with `read_file` disabled the orchestrator
    /// falls back to direct injection, and so does this.
    @MainActor
    static func estimatedAttachmentChars(
        for files: [FileSystemItem],
        profile: BackendProfileModel
    ) -> Int {
        guard !files.isEmpty else { return 0 }

        // Same mode resolution the orchestrator and the transcript use; the stateless-without-`read_file` fallback
        // injects with paths, which changes every wrapper's width.
        switch AttachmentDeliveryMode.resolve(for: profile) {
        case .pathManifest:
            // Mirrors the manifest the orchestrator builds: one preamble line plus one
            // absolute path per file. Measured, not guessed.
            let preamble = "The user has attached the following files. Use the read_file tool to access them when needed:\n"
            return preamble.count + files.map { $0.url.path }.joined(separator: "\n").count

        case .inject(let includeAbsolutePaths):
            // Per file, paired: the size (`PreSendFitHint.estimatableSizes`; images are priced in tokens elsewhere, binary documents
            // not at all) and the exact wrapper `DirectInjectionPlan.assemble` will emit.
            var sizes: [Int] = []
            var wrappers: [Int] = []
            for file in files {
                guard let size = PreSendFitHint.estimatableSizes(of: [file]).first else { continue }
                let label = DirectInjectionPlan.wrapperLabel(name: file.name, path: file.url.path, includeAbsolutePaths: includeAbsolutePaths)
                sizes.append(size)
                wrappers.append(DirectInjectionPlan.wrapperWidth(name: file.name, label: label))
            }
            return attachmentInjectionChars(forFileSizes: sizes, wrapperWidths: wrappers)
        }
    }
}

// MARK: - Vision Capability Gate Helpers

// Internal (not private): `primaryLLMConfig` is also the composer-side pre-send
// fit hint's window-resolution input (PreSendFitHint).
extension BackendProfileModel {
    /// The primary chat model's config (bot / agent profiles). Workflow / image-gen → nil.
    var primaryLLMConfig: ProviderConfig? {
        switch details {
        case .bot(let c):   return c.llmConfig
        case .agent(let c): return c.llmConfig
        default:            return nil
        }
    }

    /// Whether the primary model accepts image input — from its detected, persisted
    /// modality (`SupportedModalities.visionInput`).
    var supportsVisionInput: Bool {
        primaryLLMConfig?.supportedModalities.contains(.visionInput) ?? false
    }

    // Why: must stay in step with `AgentConnect`: charging for images the pipeline drops raises a banner the user can't
    // clear, since the phantom cost comes from history the composer cannot edit.
    /// Whether prior-turn images will actually reach the model on this profile.
    /// Mirrors the gates `AgentConnect` applies when building `nativeHistoryTurns`; a vision model is required in every case.
    /// Bots re-attach them on any provider; agents carry them on cloud and Ollama (not `.none`), never on MLX.
    var carriesHistoryImages: Bool {
        guard supportsVisionInput else { return false }
        switch profileType {
        case .bot:
            // Vision bots re-attach prior-turn images on any provider (cloud, Ollama, MLX): the atomic generate(payload:)/vision
            // path handles them regardless of tool capability.
            return true
        case .agent:
            // Agents carry history via nativeHistoryTurns: cloud always; Ollama for both capability tiers (parallel = native
            // splice, single = legacy path); MLX never builds them.
            switch primaryLLMConfig?.apiProvider {
            case .anthropic, .openAI, .google, .openRouter, .openAICompatible: return true
            case .ollama: return primaryLLMConfig?.cognitiveCapability != ModelCognitiveCapability.none
            case .mlx, .none: return false
            }
        case .workflow, .imageGen, .code:
            return false
        }
    }

    /// Static reference material this profile injects as `<knowledge_base>` on every request.
    /// Mirrors `BackendOrchestrationService.resolveKnowledgeSources` (bot and agent only) and its local-file filter.
    var knowledgeSourceFiles: [KnowledgeSource] {
        switch details {
        case .bot(let config):   return (config.knowledgeSources ?? []).filter { $0.isLocalFile && $0.exists }
        case .agent(let config): return (config.knowledgeSources ?? []).filter { $0.isLocalFile && $0.exists }
        default:                 return []
        }
    }

    // Why: an under-read costs the user a silently head-truncated system prompt, an over-read only a little headroom,
    // so any difference from the run's actual conditions must err high.
    /// Names of the tools this profile sends schemas for.
    /// Empty for bots (no tool payload); includes the control-plane tools `AgentConnect` appends at request time.
    /// Conditions are evaluated from what the profile knows, so the estimate errs high where it differs from the run.
    var schemaBearingToolNames: [String] {
        switch details {
        case .agent(let config), .code(let config):
            let configured = config.tools.filter(\.isEnabled).map(\.name)
            // An MCP server is free to publish a tool called `ask_user`; the injected one would
            // then lose the name clash at registration, so charging for both would double-count.
            let alreadyCounted = Set(configured)
            return configured + controlPlaneToolNames(for: config).filter { !alreadyCounted.contains($0) }
        case .bot, .workflow, .imageGen:
            return []
        }
    }

    // Why: every name must exist in `NativeToolCatalog.injectedTools` or it prices at 0 and the estimate silently
    // under-reads.
    /// The control-plane tools this profile's next request will carry.
    private func controlPlaneToolNames(for config: AgentConfig) -> [String] {
        // Unconditional on every tool-running flow: `final_answer` is the only clean exit from
        // the ReAct loop, and `ask_user` is always appended by `resolveExecutableTools`.
        var names = ["final_answer", "ask_user"]

        // Code profiles get the project-memory tools on every run.
        if case .code = details { names.append(contentsOf: ["remember", "forget", "recall"]) }

        // An upper bound: `AgentConnect` injects `load_skill` only once manifests resolve non-empty, and the profile can only
        // see that skills are referenced, so a profile whose skill folder is missing is over-charged.
        if !(config.skillSelections ?? []).isEmpty {
            names.append("load_skill")
        }

        // Injected only when the episodic skeleton contains `get_conversation_history(` pointers, which
        // `EpisodicHistoryFormatter.renderPointerTurn` emits; `.hybrid` renders older turns the same way, so it counts too.
        if resolvedHistoryStrategy == .pointer || resolvedHistoryStrategy == .hybrid {
            names.append("get_conversation_history")
        }

        return names
    }

    // Why: charging the full transcript on top of the episodic XML is phantom cost the user can't clear (the composer can't
    // edit history); mirrors `AgentConnect.isNativeProvider`, and applies to bots too.
    /// Whether prior-turn prose actually reaches the model on this profile.
    /// Only native providers receive `nativeHistoryTurns`; on MLX and Ollama at the `.none` tier prior turns reach the model
    /// only through the episodic XML. Reads `resolvedLLMConfig`, not `primaryLLMConfig` (nil for `.code`).
    var carriesHistoryProse: Bool {
        switch resolvedLLMConfig?.apiProvider {
        case .anthropic, .openAI, .google, .openRouter, .openAICompatible: return true
        case .ollama: return resolvedLLMConfig?.cognitiveCapability != ModelCognitiveCapability.none
        case .mlx, .none: return false
        }
    }

    /// Human-readable reason `carriesHistoryImages` returned false, for the prior-turn-image skip log.
    /// Mirrors that gate branch-for-branch so the two never drift; the dominant real case is a non-vision model.
    var historyImageSkipReason: String {
        if !supportsVisionInput {
            return "'\(primaryLLMConfig?.modelName ?? "the selected model")' is not vision-capable"
        }
        switch profileType {
        case .bot:
            // Defensive: a vision bot returns true above, so this is unreachable — but a
            // truthful fallback beats a misleading one if the gate ever changes.
            return "vision bot (unexpected — bots carry history images)"
        case .agent:
            switch primaryLLMConfig?.apiProvider {
            case .mlx: return "MLX agents carry episodic TEXT history only, not per-turn images"
            default:   return "this model's capability tier carries no per-turn history images"
            }
        case .workflow, .imageGen, .code:
            return "\(profileType.rawValue) profiles don't carry history images"
        }
    }

    /// The agent's resolved history strategy (default `.recentHistory` when unset, matching `AgentConnect`).
    /// Nil for profiles with no `AgentConfig`; the fit gauge uses it to skip history-image tokens under `.pointer`.
    /// Keyed off `agentConfig` so `.code` (which configures `.pointer`) is covered too.
    var resolvedHistoryStrategy: HistoryStrategy? {
        details.agentConfig == nil ? nil : details.historyStrategy
    }

    /// LOCAL provider (MLX / Ollama), where vision detection is authoritative and the
    /// degrade gate applies. Cloud keeps its existing no-gate behavior (send the image,
    /// let the API error), so cloud vision is unaffected by the gate.
    var usesLocalProvider: Bool {
        switch primaryLLMConfig?.apiProvider {
        case .mlx, .ollama: return true
        default:            return false
        }
    }
}
