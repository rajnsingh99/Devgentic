//
//  BackendOrchestrationService.swift
//  Devgentic
//
//  Created by Raj Singh
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

    // RAG Services
    private let embeddingService = EmbeddingService.shared
    private let vectorStoreService = VectorStoreService.shared

    // MARK: - Initialization
    init(
        fileProcessorService: FileProcessorService
    ) {
        self.fileProcessorService = fileProcessorService
        self.ollamaService = OllamaService.shared
        self.agentConnect = AgentConnect()

        logger.info("BackendOrchestrationService initialized with AgentConnect.")
    }
    
    // MARK: - Streaming Message Logic
    
    /// Streams a response from the appropriate backend profile (Bot or Agent).
    /// Handles history sanitization, file context assembly, and RAG retrieval before routing.
    func streamMessage(
        withConfig config: BackendRequestConfig,
        conversationID: UUID,
        userQuery: String,
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
        
        return AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            // [CRITICAL FIX] Capture the task to allow cancellation propagation
            let task = Task {
                logger.info("ORCHESTRATION START (Stream): Routing with profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue)). TraceID: \(context.traceID)")
                
                // Resource Management: Unload local MLX models if they are not required for this request.
                if !self.isMLXProfile(config.profile) {
                    await MLXService.shared.unloadModel()
                }
                
                // 1. Sanitize History
                // Filter out error messages to prevents confusing the model with previous system failures.
                var conversationHistory = history.filter { message in
                    if case .error = message.content { return false }
                    return true
                }
                
                // Retrieval dedup must exclude the CURRENT user message too — its
                // fire-and-forget indexing (MessagingCoordinator) can land before
                // Section 3 runs, and the duplicate-removal below strips it from
                // `conversationHistory`, so a history-derived dedup set can't see it.
                // Without this the query literally retrieves itself (observed: the
                // "executionDefaultsCard" question consumed a doc slot as its own echo).
                // Captured from the ORIGINAL history, before any trimming.
                let retrievalExcludedIDs = Set(history.map { $0.id })

                // Prevent duplicate current query in history (User UX vs LLM Context)
                if let lastMsg = conversationHistory.last,
                   lastMsg.sender == .user,
                   let lastContent = lastMsg.content.textContent,
                   lastContent.trimmingCharacters(in: .whitespacesAndNewlines) == userQuery.trimmingCharacters(in: .whitespacesAndNewlines) {

                    logger.debug("Removing duplicated current message from history to prevent double-prompting. (Trace: \(context.traceID))")
                    conversationHistory.removeLast()
                }
                
                // The typed query is the ONLY thing that rides `userInput` → the system
                // <task> block. File and knowledge payloads travel as separate context
                // fields below (2026-07 redesign: no more prompt-prepending).
                let queryForRequest = userQuery
                let fileContextStrategy = config.profile.resolvedFileContextStrategy

                // 2. File Context Handling — the strategy shapes HOW current-turn
                // attachments are DELIVERED (extracted content vs read_file path note);
                // delivery is always deterministic, never dependent on retrieval. The
                // payload lands at the top of the USER message (executors render it
                // ahead of the query) — never in the system <task>.
                // Input-lane clock (Run-Report Phase 3): attachments + RAG retrieval +
                // knowledge assembly below are the request's real pre-flight cost.
                let preRequestAssemblyStart = Date()
                var attachmentContext: String? = nil
                if !files.isEmpty {
                    logger.info("Processing \(files.count) attached files with strategy: \(fileContextStrategy.rawValue). (Trace: \(context.traceID))")

                    switch fileContextStrategy {
                    case .contextualRAG, .directInjection:
                        // .contextualRAG is deprecated and never returned by resolve() —
                        // the arm stays only for switch exhaustiveness until Phase 4
                        // deletes the case, and maps to directInjection behavior.
                        // Write-capable profiles need the path, not just the name.
                        let disclosePaths = config.profile.profileType == .agent
                            || config.profile.profileType == .code
                        let (fileContext, docFailures) = await self.assembleTextFileContent(
                            for: files, includeAbsolutePaths: disclosePaths
                        )
                        if disclosePaths {
                            logger.info("[ATTACH] Direct injection for \(config.profile.profileType.rawValue) discloses absolute paths so the model can write back to the right file.")
                        }
                        if !fileContext.isEmpty {
                            attachmentContext = fileContext
                        }
                        // D3: report (traced + structured notice), keep answering.
                        await self.reportFileFailures(docFailures, span: context, continuation: continuation)

                    case .stateless:
                        // The manifest is a promise that `read_file` exists. If the profile
                        // has it switched off, the paths point at nothing and the attachment
                        // vanishes without a trace — so fall back to injecting the content
                        // rather than silently dropping what the user attached.
                        let paths = files.map { $0.url.path }.joined(separator: "\n")
                        if config.profile.enabledToolNames.contains("read_file") {
                            attachmentContext = "The user has attached the following files. Use the read_file tool to access them when needed:\n\(paths)"
                            logger.info("[ATTACH] Stateless: handed \(files.count) path(s) to the agent to read on demand.")
                        } else {
                            logger.warning("[ATTACH] Profile '\(config.profile.displayName)' uses the stateless file strategy but has NO read_file tool enabled — the path manifest would reference a tool it cannot call. Falling back to direct injection so the \(files.count) attachment(s) still reach the model; enable read_file to get on-demand reads.")
                            let (fileContext, docFailures) = await self.assembleTextFileContent(
                                for: files, includeAbsolutePaths: true
                            )
                            if !fileContext.isEmpty { attachmentContext = fileContext }
                            await self.reportFileFailures(docFailures, span: context, continuation: continuation)
                        }
                    }
                }

                // 3. RAG Retrieval — standard per-conversation memory (2026-07 redesign).
                // Strategy-independent: retrieval only SUPPLEMENTS what the sections above
                // delivered; it is never a delivery path. Skipped on the first message
                // (nothing indexed for this conversation yet — no placeholder is emitted)
                // and for flows that can't consume it (workflow/code suppress the
                // semantic_context layer; imageGen never dispatches through AgentConnect).
                // Resolve the EFFECTIVE context window once — the retrieval budget
                // (Section 3) and the pre-flight fit check (Section 5) both key off it.
                // Ollama: num_ctx is the allocation, not the trained max — the user's
                // configured value wins, else the auto-default the request factory now
                // sends, else Ollama's ~4K server default. Resolved through the same
                // policy the factory uses, so budget and request can never disagree.
                // MLX: trained metadata (the app owns the prompt). Cloud: catalog
                // windows; overflow errors loudly there anyway.
                // `resolvedLLMConfig`, NOT `primaryLLMConfig`: the latter returns nil for
                // `.code`, so a Code session resolved the 128K cloud default as its window and
                // priced every term against a number unrelated to its model. Only the fit
                // check reads this variable, so widening it cannot affect the request path.
                let primaryConfig = config.profile.resolvedLLMConfig
                let trainedWindow = EffectiveContextWindow.trainedWindow(for: primaryConfig)
                let contextWindowTokens = EffectiveContextWindow.resolve(for: primaryConfig)

                var ragContextString: String? = nil
                let profileUsesConversationRAG = config.profile.profileType == .bot
                    || config.profile.profileType == .agent

                /// The fit check runs for every CHAT-SHAPED profile, matching the composer
                /// gauge's own gate. It used to be nested inside `profileUsesConversationRAG`,
                /// which excludes `.code` — so a Code session had a ring and a pre-send hint
                /// with NO send-time authority behind them, and no self-heal clear of a stale
                /// overflow banner. Retrieval and fit are separate questions; only retrieval
                /// is bot/agent-only.
                let profileHasSingleContextWindow = config.profile.profileType == .bot
                    || config.profile.profileType == .agent
                    || config.profile.profileType == .code
                // ⚠️ Availability is checked BEFORE the progress line below, and with an `if/else`
                // rather than a `guard … else { return }`: this sits deep inside the streaming
                // closure, so an early `return` would abort the ENTIRE turn instead of skipping
                // retrieval — the user would get no answer at all because their search index was down.
                //
                // Why it must be checked at all: the progress line is a durable CLAIM, not a spinner.
                // `ActiveStreamManager` turns `.thought` into a `TimelineEvent` that is APPENDED to
                // the message and saved, so yielding it unconditionally wrote "Searching conversation
                // memory…" into the permanent transcript of a run where the vector store never opened.
                //
                // Gated strictly on `isAvailable`. NOT on "0 results": `retrieveRAGContext` returns
                // nil for four reasons and three of them are healthy (no embedding, nothing above
                // threshold, all hits were history duplicates) — the normal case early in a
                // conversation. Bannering on those would train the user to dismiss, and a dismissal
                // suppresses the key for the whole session, disarming the real signal.
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

                if profileUsesConversationRAG && !conversationHistory.isEmpty && knowledgeStoreIsAvailable {

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
                    if isICEnabled && hasICModel && isRAGRewritingEnabled {
                        queryForRAG = await QueryRewritingService.shared.rewriteQuery(userQuery, history: conversationHistory)
                    } else {
                        queryForRAG = userQuery
                    }

                    ragContextString = await self.retrieveRAGContext(for: queryForRAG, lexicalQuery: userQuery, contextWindowTokens: contextWindowTokens, conversationID: conversationID, excludedMessageIDs: retrievalExcludedIDs)
                }

                // 3b. Conversation-memory indexing of current-turn attachments — AFTER
                // retrieval, so a file can never re-surface in the same turn it was
                // injected; later turns can recall it, including the >50K tail the
                // injection budget cut off. Fire-and-forget: dispatch shouldn't wait on
                // chunking/embedding. Stateless attachments are paths-only by design and
                // are never indexed (the model never received their content).
                if !files.isEmpty,
                   profileUsesConversationRAG,
                   fileContextStrategy == .directInjection {
                    let filesToIndex = files
                    Task.detached(priority: .background) {
                        await RAGIndexingService.shared.indexAttachedFiles(
                            files: filesToIndex,
                            conversationID: conversationID,
                            messageID: UUID()
                        )
                    }
                }

                // 4. Knowledge Sources — static profile reference material, delivered as
                // the dedicated system `<knowledge_base>` layer (byte-stable per profile,
                // so the system prefix stays cache-friendly). The strategy shapes the
                // payload: extracted content vs a read_file path manifest. It never
                // rides the user query.
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
                            // Manifest only — the agent reads sources on demand. Built through
                            // the shared owner so the fit gauges price the exact string that
                            // ships, preamble included.
                            knowledgeBaseContext = StatelessKnowledgeManifest.text(
                                paths: localSources.map { $0.location },
                                canReadFiles: StatelessKnowledgeManifest.canReadFiles(config.profile)
                            )
                        }
                    }
                }

                // 4.5 MCP server instructions — the server author's own guidance on how to
                // drive their tools correctly, returned in the `initialize` handshake.
                //
                // The SDK stores `instructions` privately with no accessor, so the connect
                // return value is the only chance to read it; we capture it on `MCPSession`
                // and surface it here. It rides the `<knowledge_base>` layer rather than a
                // layer of its own: this is exactly what that layer is for — static
                // reference material the model should have before it acts — and adding a
                // parallel layer would mean threading a new field through five call sites
                // for the same result. The heading keeps it distinguishable from profile
                // knowledge sources in the rendered prompt.
                // ⚠️ TWO FIXES HERE (2026-08-20), both from the same field report: a single-node
                // workflow failed where the identical agent profile succeeded in chat.
                //
                //   1. GATED PER SERVER. This used to ask "is any MCP server connected?" and inject
                //      every one of them. The failing profile held `[final_answer, ask_user,
                //      execute_shell]` — ZERO MCP tools — and still received ~2,000 chars telling it
                //      how to drive 41 tools from two servers it could not call.
                //   2. ITS OWN LAYER. It used to be appended to `knowledgeBaseContext`. Knowledge is
                //      the USER's reference material; this is operating instructions for TOOLS. On
                //      the workflow path that conflation was fatal: nodes get no knowledge layer, so
                //      `AgentConnect` prepended the whole thing onto `userInput`, and it became the
                //      node's `<task>` — pushing the real question to char ~2,160 of 2,224.
                //
                // The gate keys on the profile's CONFIGURED tools (the user's choice), which is
                // known here; resolution happens later in `AgentConnect` and can only ever narrow
                // this set, never widen it.
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

                // Close the Input-lane bracket opened above the attachment block: this
                // covers attachment extraction, RAG retrieval, knowledge assembly and MCP
                // guidance — the run's pre-flight cost, attributed to the root span.
                await TraceRecorder.shared.emitMetric(
                    span: context, key: "input_assembly",
                    valueMs: Int(Date().timeIntervalSince(preRequestAssemblyStart) * 1000))

                // 5. Pre-flight context-fit check — every piece of the prompt is known
                // here, BEFORE any tokens stream. Oversize prompts on local models don't
                // fail loudly: Ollama HEAD-truncates silently (system prompt first), so
                // the model quietly loses the knowledge/retrieval layers and answers from
                // fragments. This is AMBIENT state (profile + content size), not a turn
                // event — it surfaces as an actionable advisory banner above the chat
                // input (AdvisoryBannerView), never as per-turn transcript clutter.
                if profileHasSingleContextWindow {
                    // Images cost real context but contribute ZERO chars: `attachmentChars`
                    // filters them out by extension and `historyChars` reads `textContent`,
                    // which is nil for media. Counted only when the model can actually see
                    // them — a non-vision model has its images dropped, so warning about
                    // them would be warning about payload that never ships.
                    let imageTokens: Int = {
                        guard config.profile.supportsVisionInput else { return 0 }
                        let current = PromptFitCheck.estimatedImageTokens(
                            forImageURLs: files.map(\.url).filter { fileProcessorService.isImageFile(mimeType: fileProcessorService.getFileMimeType(for: $0), url: $0) },
                            provider: primaryConfig?.apiProvider
                        )
                        // Prior-turn images are charged ONLY where they actually ship.
                        // On a bot, or a non-native/non-vision provider, they are
                        // dropped before the wire — billing for them would raise a
                        // banner the user has no way to clear.
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

                    // Episodic memory is charged for real now. `historyChars` reads
                    // `content.textContent`, which is nil for the tool params, outcomes and
                    // `<effect>` diffs the blob is mostly made of — so an edit-heavy
                    // conversation used to be billed ZERO for the biggest thing in its prompt
                    // and overflowed with no banner at all.
                    // Same fix as the ring: measure the native turns that actually ship
                    // rather than summing every message, which over-charged the turn limit,
                    // the char-budget trim, and non-native providers all at once.
                    let historyProseChars = PromptFitCheck.estimatedHistoryProseChars(
                        in: conversationHistory,
                        carriesProse: config.profile.carriesHistoryProse,
                        strategy: config.profile.resolvedHistoryStrategy,
                        contextWindow: contextWindowTokens
                    )
                    let episodicChars = PromptFitCheck.estimatedEpisodicChars(
                        in: conversationHistory,
                        strategy: config.profile.resolvedHistoryStrategy,
                        contextWindow: contextWindowTokens,
                        toolsAvailable: config.profile.profileType != .bot,
                        // The same flag `AgentConnect` hands the formatter when it builds the
                        // blob for real. Omitting it took the `false` default, so the
                        // `<attached_images>` lines a vision profile actually ships were
                        // measured as zero — the gauge under-read the payload on exactly the
                        // conversations whose images already crowd the window.
                        includeImageNames: config.profile.supportsVisionInput
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
                        // Condition-aware advice: raising num_ctx only helps when the
                        // model is trained for more than the current allocation —
                        // telling a gemma-at-trained-max user to raise it is a dead end.
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

                // ⚠️ register B14 — the missing-instructions advisory finally has a surface.
                // `ProfileValidator` has computed it correctly since A35, and nothing could show
                // it: the editors hard-block before saving (so they never see it) and every
                // out-of-band writer discards `saveProfile`'s return value. Chat is the right
                // place — it is where an agent with no guidance actually answers the user.
                //
                // ⚠️ Advisory, never a gate. G92 holds: this must not stop the send. A profile
                // with no instructions still runs; the user is simply told why it may behave oddly
                // and given one click to fix it.
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
                    // Native image input: turn the message's attached images into an
                    // image payload so vision-capable bot/agent profiles see them
                    // natively. D3: any unreadable image is reported (traced + notice),
                    // and the turn still answers (degrade).
                    let (rawImagePayload, imageFailures) = await self.buildImagePayload(from: files, traceID: context.traceID)
                    await self.reportFileFailures(imageFailures, span: context, continuation: continuation)

                    // [VISION] Single source of truth that the app SAW current-turn image
                    // attachments (covers bot + agent + code, before any routing). Absence
                    // of this line for an image-bearing turn means the attach pipeline
                    // dropped them upstream. Correlates to the request via traceID.
                    if let raw = rawImagePayload, !raw.isEmpty {
                        logger.info("[VISION] trace:\(context.traceID) current-turn: \(raw.count) image block(s) built from \(files.count) attached file(s), profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue)), vision-capable=\(config.profile.supportsVisionInput)")
                    }

                    // Vision capability gate (LOCAL providers only — cloud keeps its
                    // existing no-gate behavior). If the selected local model can't see
                    // images, drop them and tell the user, but still answer from text
                    // (degrade, per the chosen "degrade + tell user" policy). This covers
                    // both the MLXVLM gap families (mllama/llava-1.5/phi3_v/…) and any
                    // plain text-only local model the user attached an image to.
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

                    // [VISION] Explain the INTENTIONAL skip when a conversation already
                    // has prior-turn images but this profile won't re-send them — most
                    // commonly because the selected model isn't vision-capable (e.g. the
                    // user swapped a vision model out), and otherwise an agent path that
                    // carries episodic TEXT history only (MLX / chat-only Ollama). Without
                    // this line, the absence of a "carrying N image(s)" line on a follow-up
                    // turn is ambiguous — you can't tell an intentional skip from a dropped
                    // image. `historyImageSkipReason` names the ACTUAL cause (do not hard-code
                    // it here — the reason differs per profile/model and must stay accurate).
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
                            let imageFiles = files.filter { file in
                                let mimeType = self.fileProcessorService.getFileMimeType(for: file.url)
                                return self.fileProcessorService.isImageFile(mimeType: mimeType, url: file.url)
                            }
                            // #24: read the image bytes OFF the main actor — same sync-`Data(contentsOf:)`
                            // hitch as `buildImagePayload`, here on the image-gen intent path.
                            // Normalize each source image to JPEG: the image-to-image providers
                            // stamp the source with a FIXED mime (OpenAI/Gemini hardcode image/png),
                            // so an attached HEIC (the macOS default) / TIFF / etc. would otherwise
                            // ship raw under a false label and 400 — the same bypass the vision path
                            // closes. `ensureJPEG` passes real JPEGs through and transcodes the rest;
                            // an undecodable source is dropped + logged (the turn degrades to
                            // text-to-image rather than 400-ing the whole edit).
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
                        // Code mode routes through the agent pipeline (AgentConnect) but the
                        // profile IS .code end-to-end — CodeSessionManager builds it with
                        // `details: .code(agentConfig)` and ExecutorFactory has a dedicated
                        // .code arm. (An earlier comment here claimed the profile was built
                        // as .agent internally; that was never true and masked a factory
                        // fallthrough that capped Code runs at 15 iterations.)
                        let codeProjectPath: String
                        if case .code(let codeConfig) = currentConfig.profile.details {
                            codeProjectPath = codeConfig.projectPath ?? "unknown"
                        } else {
                            codeProjectPath = "unknown"
                        }
                        logger.info("[CODE] Routing to AgentConnect (agent pipeline) — traceID: \(context.traceID), project: \(codeProjectPath), RAG: \(ragContextString != nil), history: \(conversationHistory.count) msgs")

                        // [G1 Piece 2] resumeState threads into Code runs the same as agents —
                        // Code IS the plain ReAct loop, so the executor's resume preamble
                        // (replay completed steps, re-raise the parked tool) applies as-is.
                        // Without this, a resumed parked Code run silently re-ran from scratch.
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

                    // .warning, not .error: this is a benign one-shot self-heal (the
                    // retry below almost always succeeds and the profile is already
                    // patched). An .error here rendered a red failure card for a run
                    // that recovered. A SECOND thinkingUnsupported is not caught
                    // (thinkingRetryDone guard) and still surfaces as a real error.
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

    private func isMLXProfile(_ profile: BackendProfileModel) -> Bool {
        switch profile.details {
        case .bot(let config): return config.llmConfig.apiProvider == .mlx
        case .agent(let config): return config.llmConfig.apiProvider == .mlx
        case .imageGen(let config): return config.llmConfig.apiProvider == .mlx
        case .code(let config): return config.llmConfig.apiProvider == .mlx
        case .workflow: return false
        }
    }
    
    /// - Parameters:
    ///   - userQuery: The (possibly rewritten) query used for the EMBEDDING search.
    ///   - lexicalQuery: The user's RAW typed query, used for exact-match token
    ///     boosting — the raw text is the ground truth for symbol names, and it
    ///     can't be corrupted by a hallucinated rewrite.
    ///   - excludedMessageIDs: Message IDs whose indexed parents must not be
    ///     re-injected — everything already visible in history PLUS the current
    ///     user message (whose fire-and-forget indexing can beat retrieval, making
    ///     the query retrieve its own echo).
    private func retrieveRAGContext(for userQuery: String, lexicalQuery: String, contextWindowTokens: Int, conversationID: UUID, excludedMessageIDs: Set<UUID>) async -> String? {
        logger.info("RAG: Attempting to retrieve context for conversation: \(conversationID.uuidString)")

        guard let queryEmbedding = await embeddingService.generateEmbedding(for: userQuery) else {
            logger.warning("RAG: Could not generate embedding for query.")
            return nil
        }

        // Retrieve relevant documents — history/self exclusion happens INSIDE the
        // ranker so excluded parents can't occupy limit slots (post-filtering here
        // starved turns to 0 injected docs while injectable chunks sat at rank 4).
        let hits = vectorStoreService.findNearest(to: queryEmbedding, queryText: lexicalQuery, limit: 3, conversationID: conversationID, excludedParentMessageIDs: excludedMessageIDs)

        guard !hits.isEmpty else {
            logger.info("RAG: Vector store returned 0 documents.")
            return nil
        }

        // Belt-and-braces: the ranker already skips excluded parents during
        // collection — anything caught here indicates an exclusion leak upstream,
        // so the log doubles as a tripwire.
        let filteredHits = hits.filter { hit in
            !excludedMessageIDs.contains(hit.parent.sourceMessageID)
        }

        let removedCount = hits.count - filteredHits.count
        if removedCount > 0 {
            logger.warning("RAG: Dedup tripwire removed \(removedCount)/\(hits.count) documents the ranker should have excluded.")
        }

        guard !filteredHits.isEmpty else {
            logger.info("RAG: No relevant context found (all \(hits.count) documents were duplicates of history).")
            return nil
        }

        // Window each document around its matched chunk — never the blind head —
        // and size the injection to the model's window so retrieval can't evict
        // the system prompt on small local models.
        let budgets = RAGRetrievalBudget.budgets(forContextWindowTokens: contextWindowTokens)
        // Name each injected document (file name, or message-id prefix for chat
        // turns) + its match distance — without this, a wrong answer can't be
        // triaged to "retrieved the wrong doc" vs "model missed it".
        let hitsSummary = filteredHits.map { hit -> String in
            let identifier = hit.parent.sourceIdentifier
            let name = identifier.contains("/")
                ? (identifier as NSString).lastPathComponent
                : "msg:\(hit.parent.sourceMessageID.uuidString.prefix(8))"
            return "\(name) d=\(String(format: "%.3f", hit.distance))"
        }.joined(separator: ", ")
        logger.info("RAG: Injecting \(filteredHits.count) document(s) [\(hitsSummary)] (budget: \(budgets.total) chars for \(contextWindowTokens)-token window).")
        return RAGRetrievalBudget.assemble(
            filteredHits.map { (text: $0.parent.fullTextContent, anchor: $0.bestChunkText) },
            perParent: budgets.perParent,
            total: budgets.total
        )
    }
    
    // MARK: - Direct Injection Budget

    /// Maximum characters to inject per file (~12.5K tokens)
    private var directInjectionBudgetPerFile: Int { DirectInjectionBudget.perFile }
    /// Maximum total characters to inject across all files (~50K tokens)
    private var directInjectionTotalBudget: Int { DirectInjectionBudget.total }

    /// Builds an image `Payload` from the current message's attachments so
    /// vision-capable bot/agent profiles receive them natively (separate from the
    /// document text-extraction path). Reads bytes now under security-scoped access
    /// into ephemeral references; the provider resolves+encodes at send time.
    /// Returns nil when no images are attached. A file that can't be read is logged
    /// and skipped (it still appears in the document path's skipped-files notice).
    private func buildImagePayload(from files: [FileSystemItem], traceID: String) async -> (payload: Payload?, failures: [FileRetrievalError]) {
        // Determine which files are images + their mime types on the main actor — these are
        // cheap UTType lookups. Capture only Sendable values for the off-actor read below.
        var items: [(url: URL, mime: String, name: String)] = []
        for file in files {
            let mime = fileProcessorService.getFileMimeType(for: file.url)
            guard fileProcessorService.isImageFile(mimeType: mime, url: file.url) else { continue }
            items.append((file.url, mime, file.name))
        }
        guard !items.isEmpty else { return (nil, []) }

        // #24: read the bytes OFF the main actor. `Data(contentsOf:)` is synchronous disk I/O
        // that would hitch the UI for large image attachments (this service is `@MainActor`).
        // Security-scoped access brackets the read inside the detached work so it stays valid
        // for the read's duration.
        return await Task.detached(priority: .userInitiated) {
            var blocks: [MessageBlock] = []
            var failures: [FileRetrievalError] = []
            for item in items {
                let didAccess = item.url.startAccessingSecurityScopedResource()
                defer { if didAccess { item.url.stopAccessingSecurityScopedResource() } }
                // [M7] Reject an oversized image at egress too — redo/re-send re-reads from the URL
                // and bypasses the ingestion cap, and a pre-existing message may carry an
                // over-limit image. Stat first so a huge file is never read into memory. Reported
                // (not silent), so the turn still answers, just without this image.
                let byteSize = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                if byteSize > ImageConstraints.maxAttachmentImageBytes {
                    failures.append(.imageResolutionFailed(path: item.url.path, underlying: "Image exceeds the \(ImageConstraints.maxAttachmentImageBytes / (1024 * 1024)) MB limit."))
                    continue
                }
                do {
                    let data = try Data(contentsOf: item.url)
                    // Not every container the OS hands us is loadable by every provider —
                    // HEIC (the macOS/iOS default) is rejected by Ollama/Anthropic/OpenAI
                    // and previously reached the wire raw, 400-ing the whole request with an
                    // opaque "Failed to load image" error. Resolve to a sendable form:
                    // jpeg/png/webp pass through untouched, anything else decodable is
                    // transcoded to JPEG, and the truly-undecodable is omitted (reported,
                    // not silent) so the turn still answers.
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

    /// Extracts text from attached documents for direct injection. Returns the
    /// assembled content plus a typed list of files that couldn't be read (via the
    /// throwing `readFileContentOrThrow`, so the real cause is preserved). Images
    /// are skipped here — they flow through `buildImagePayload`.
    /// - Parameter includeAbsolutePaths: emit each file's resolved path alongside its
    ///   name. Set for profiles that can WRITE (agent/code): the name alone is not enough
    ///   to write back to — the model reproduces it verbatim as a relative path, which
    ///   `FilePathResolver` anchors to HOME, silently creating a stray file instead of
    ///   editing the user's. Bots stay name-only; they have no tools to act on a path and
    ///   the extra characters would just cost context.
    private func assembleTextFileContent(for files: [FileSystemItem], includeAbsolutePaths: Bool = false) async -> (content: String, failures: [FileRetrievalError]) {
        var assembledContent = ""
        var failures: [FileRetrievalError] = []

        for file in files {
            let mime = fileProcessorService.getFileMimeType(for: file.url)
            if fileProcessorService.isImageFile(mimeType: mime, url: file.url) { continue }

            guard assembledContent.count < directInjectionTotalBudget else {
                failures.append(.tooLarge(path: file.url.path))
                continue
            }

            let remainingBudget = min(
                directInjectionBudgetPerFile,
                directInjectionTotalBudget - assembledContent.count
            )

            do {
                let content = try await fileProcessorService.readFileContentOrThrow(for: file.url, maxSize: remainingBudget)
                let label = includeAbsolutePaths ? "\(file.name) (\(file.url.path))" : file.name
                assembledContent += "\n\n--- Start of file: \(label) ---\n\(content)\n--- End of file: \(file.name) ---"
                // ATT-1 visibility: this is the authoritative "the model saw it"
                // record — pair it against MessageAttachmentBuilder's persistence
                // logs to trace any transcript/model-input divergence.
                logger.debug("Direct-injected '\(file.name)' (\(content.count) chars) into the model context.")
            } catch let retrievalError as FileRetrievalError {
                failures.append(retrievalError)
            } catch {
                failures.append(.readFailed(path: file.url.path, underlying: error.localizedDescription))
            }
        }

        if !files.isEmpty {
            logger.log("Direct injection assembled: \(files.count) attachment(s) scanned, \(assembledContent.count) chars injected, \(failures.count) failure(s).")
        }

        return (assembledContent, failures)
    }

    /// D3 (chat = degrade): trace each retrieval failure (kills the observability
    /// dark zone) and surface a structured, actionable notice — the turn still
    /// answers with whatever loaded. (Phase 4 renders this as a card; for now it's
    /// a clear prepended notice, replacing the old buried `[System]` string.)
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

    /// Extracts text from knowledge source files for the system `<knowledge_base>`
    /// layer. Returns the assembled content plus a typed list of sources that
    /// couldn't be read — previously silent skips, now reported like attachments.
    private func assembleKnowledgeSourceContent(sources: [KnowledgeSource]) async -> (content: String, failures: [FileRetrievalError]) {
        var assembled = ""
        var failures: [FileRetrievalError] = []
        for source in sources {
            guard assembled.count < directInjectionTotalBudget else {
                failures.append(.tooLarge(path: source.location))
                continue
            }
            let remainingBudget = min(
                directInjectionBudgetPerFile,
                directInjectionTotalBudget - assembled.count
            )
            do {
                let content = try await fileProcessorService.readFileContentOrThrow(for: source.url, maxSize: remainingBudget)
                assembled += "\n\n--- Knowledge: \(source.fileName) ---\n\(content)"
            } catch let retrievalError as FileRetrievalError {
                failures.append(retrievalError)
            } catch {
                failures.append(.readFailed(path: source.location, underlying: error.localizedDescription))
            }
        }
        return (assembled, failures)
    }
}

// MARK: - RAG Retrieval Budget

/// Budgets for retrieved conversation-memory context (Section 3). Retrieval
/// SUPPLEMENTS the prompt — an un-capped parent (an entire indexed file) could
/// otherwise blow the context for a single chunk match, unlike the injection
/// path which has always been budgeted (50K/file, 200K total).
enum RAGRetrievalBudget {
    /// Per-parent CEILING on retrieved document text (~2K tokens) — cloud-scale.
    static let perParent = 8_000
    /// Total CEILING across all retrieved parents (~6K tokens) — cloud-scale.
    static let total = 24_000
    /// Floors so retrieval stays useful even against tiny local windows.
    static let minPerParent = 600
    static let minTotal = 1_200

    /// Scales the injection budget to the target model's context window. The
    /// fixed ceilings suit cloud models, but 24K chars injected into a local
    /// model whose ENTIRE window is ~4-8K tokens evicts the system prompt — the
    /// provider head-truncates, and the retrieved context (plus everything else
    /// in the system message) silently vanishes. Observed on-device: deep-symbol
    /// queries succeeded early in a conversation and failed once history +
    /// retrieval volume exceeded gemma:7b's num_ctx.
    /// Target ≈15% of the window at a conservative 3 chars/token (code-dense).
    static func budgets(forContextWindowTokens tokens: Int) -> (perParent: Int, total: Int) {
        let scaledTotal = Int(Double(tokens) * 3.0 * 0.15)
        let clampedTotal = max(minTotal, min(total, scaledTotal))
        let clampedPerParent = max(minPerParent, min(perParent, clampedTotal / 2))
        return (clampedPerParent, clampedTotal)
    }

    /// Assembles retrieved documents into the injected context string, windowing
    /// each oversize document AROUND its matched chunk (`anchor`) rather than
    /// taking the head — a head-clamped whole-file parent loses any match past
    /// the first 8K chars (manual testing: symbols early in a file answered,
    /// later ones "not found"). Falls back to the head window when the anchor
    /// can't be located in the text (e.g. markdown-normalized message chunks).
    static func assemble(
        _ docs: [(text: String, anchor: String?)],
        perParent perParentBudget: Int = perParent,
        total totalBudget: Int = total
    ) -> String {
        var assembled: [String] = []
        var used = 0
        for doc in docs {
            guard used < totalBudget else { break }
            let budget = min(perParentBudget, totalBudget - used)
            let windowed = window(for: doc.text, anchor: doc.anchor, budget: budget)
            assembled.append(windowed)
            used += windowed.count
        }
        return assembled.joined(separator: "\n\n")
    }

    /// A `budget`-sized excerpt of `text` centered on `anchor` (the matched chunk).
    /// Keeps the document's identity line (`[File: …]`) when the head is cut, and
    /// marks trimmed edges so the model knows the text is partial.
    static func window(for text: String, anchor: String?, budget: Int) -> String {
        guard text.count > budget else { return text }

        // Code chunks carry a "[lang Context]:\n" retrieval prefix that is not part
        // of the stored document text — strip it or the anchor never matches and
        // every code chunk silently falls back to the head window.
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
            return String(text.prefix(budget)) + "\n… [truncated]"
        }

        let matchStart = text.distance(from: text.startIndex, to: matched.lowerBound)
        let matchLength = text.distance(from: matched.lowerBound, to: matched.upperBound)
        let center = matchStart + matchLength / 2

        var start = max(0, center - budget / 2)
        let end = min(text.count, start + budget)
        start = max(0, end - budget)

        let winStart = text.index(text.startIndex, offsetBy: start)
        let winEnd = text.index(text.startIndex, offsetBy: end)
        var excerpt = String(text[winStart..<winEnd])

        if start > 0 {
            // Preserve the "[File: name]" identity line so the model knows the
            // excerpt's source even when the head is trimmed away.
            let firstLine = text.prefix(while: { $0 != "\n" })
            let header = firstLine.hasPrefix("[File:") ? String(firstLine) + "\n" : ""
            excerpt = header + "… [\(start) earlier chars omitted]\n" + excerpt
        }
        if end < text.count {
            excerpt += "\n… [truncated]"
        }
        return excerpt
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
}

// MARK: - Stateless Knowledge Manifest

/// The `.stateless` knowledge payload — ONE owner for the string the orchestrator ships and
/// the gauges price.
///
/// These were built independently and disagreed twice over. The orchestrator emitted a
/// preamble sentence plus the paths; the estimator counted only the joined paths, so it
/// under-charged every stateless profile by a fixed 104 chars. It also gated the whole
/// manifest on `read_file` being enabled, which the orchestrator never checked — so a
/// stateless profile with `read_file` switched off was priced as a FULL content injection
/// (up to 200 KB) for a prompt that in fact carried a few hundred characters of paths. That
/// is the over-warning direction: a banner the user can only clear by removing knowledge
/// sources that were costing them almost nothing.
enum StatelessKnowledgeManifest {
    /// Whether the profile can actually open the paths it is about to be handed.
    ///
    /// Owned here rather than restated at each call site: the emitter and the estimator must
    /// never disagree about WHICH sentence ships, and a duplicated predicate is exactly how
    /// they came to disagree about the manifest in the first place. Returns false for every
    /// profile type with no tools at all (`enabledToolNames` is empty for bots and imageGen),
    /// which is the correct answer for them.
    static func canReadFiles(_ profile: BackendProfileModel) -> Bool {
        profile.enabledToolNames.contains("read_file")
    }

    /// The manifest itself. Emitted whenever the strategy is `.stateless` and at least one
    /// local source exists — the presence of `read_file` changes the WORDING, never whether
    /// the manifest ships, because the paths are true either way.
    ///
    /// Why two sentences: a stateless profile with `read_file` disabled was still being told
    /// "Read them with the read_file tool", naming an instrument it does not have. Listing
    /// file paths under the word "available" while offering no way to open them is an
    /// invitation to confabulate their contents, so the second variant says plainly that the
    /// contents cannot be retrieved and must not be guessed at.
    ///
    /// The `canReadFiles == true` string is byte-for-byte what it has always been. Knowledge
    /// context is a system-prompt layer chosen to be byte-stable per profile so the prefix
    /// stays prompt-cache friendly; rewording the common case would invalidate that cache for
    /// every existing profile to no benefit.
    static func text(paths: [String], canReadFiles: Bool) -> String {
        let preamble = canReadFiles
            ? "The following profile reference documents are available. Read them with the read_file tool when needed:\n"
            : "The following profile reference documents are configured, but no file-reading tool is available this turn, so their contents cannot be retrieved. Refer to them by path only — do not state or infer what they contain:\n"
        return preamble + paths.joined(separator: "\n")
    }
}

// MARK: - Prompt Fit Check

/// Pre-flight estimate of whether the assembled prompt fits the model's
/// effective context window. Char-based (~3 chars/token, conservative for
/// code-dense content) with a fixed allowance for prompt-builder layers —
/// ±15% accuracy is plenty for a warning that only gates a banner.
enum PromptFitCheck {
    /// Instructions and environment facts — the genuinely FIXED layers.
    ///
    /// It used to claim episodic memory and tool schemas too, both of which vary by orders of
    /// magnitude: a 40 KB episodic blob and a 20-tool agent were each charged as part of this
    /// flat 2 KB. Both are now measured for real (`estimatedEpisodicChars`,
    /// `estimatedToolSchemaChars`). Do not fold anything variable back in here.
    static let layerOverheadChars = 2_000

    /// The whole history-channel character allocation — 60% of the window, floor 4K — split
    /// between `NativeHistoryConverter`'s turn pairs and the episodic XML, which ride the
    /// same prompt.
    ///
    /// Lives here so `AgentConnect` (which spends it) and the fit gauges (which measure what
    /// was spent) cannot drift apart on the formula — and denominated at `charsPerToken` so
    /// spending the whole allowance prices back at 60% of the window, not 80%.
    static func historyCharBudget(forContextWindow window: Int) -> Int {
        max(4_000, Int(Double(window) * 0.6 * charsPerToken))
    }

    /// The native conversation payload's compaction ceiling — 75% of the window, floor 8K.
    /// Hoisted out of `AgentConnect`, where it was inlined at two call sites, for the same
    /// reason and denominated the same way.
    static func nativePayloadCharBudget(forContextWindow window: Int) -> Int {
        max(8_000, Int(Double(window) * 0.75 * charsPerToken))
    }

    /// Chars the profile's `<knowledge_base>` layer contributes.
    ///
    /// Walks the same loop `assembleKnowledgeSourceContent` walks. Two things that loop does
    /// which the old estimate did not:
    ///
    /// 1. **The per-file ceiling SHRINKS.** It is `min(perFile, total - assembled.count)`, and
    ///    `readFileContentOrThrow` throws `.tooLarge` rather than truncating — so a later file
    ///    that no longer fits the room its predecessors left contributes NOTHING. Pricing every
    ///    source against a flat 50K ceiling charged a third knowledge document in full for
    ///    content the request silently drops.
    /// 2. **Each included source carries its wrapper**, `\n\n--- Knowledge: <name> ---\n`. That
    ///    width is now taken from the assembler's own literal rather than the magic 60 that sat
    ///    here, so the two cannot drift if the banner text is ever reworded.
    ///
    /// This is an APPROXIMATION, not an exact mirror, because the estimator has stat'd BYTES
    /// where the assembler has decoded CHARACTERS, and it errs in both directions:
    ///  • UNDER-counts (fails to warn) whenever bytes overstate characters — multi-byte text,
    ///    and any PDF/DOCX/XLSX the extraction registry turns into far less text than the file
    ///    weighs on disk. Such a source is dropped here while the request happily ships it.
    ///  • OVER-counts a source it does include, since UTF-8 characters ≤ bytes, and charges in
    ///    full for sources the reader will fail on (permissions, bad encoding) and skip.
    ///
    /// A `.stateless` profile hands over a path manifest instead, so it is charged as one.
    /// ⚠️ Known divergence, left as-is: this branch also requires `read_file` to be enabled,
    /// which the orchestrator's `.stateless` knowledge arm does NOT check — it emits the
    /// manifest either way. A stateless profile with `read_file` off is therefore charged full
    /// injection here for a prompt that only ever carries paths.
    @MainActor
    static func estimatedKnowledgeSourceChars(for profile: BackendProfileModel) -> Int {
        let sources = profile.knowledgeSourceFiles
        guard !sources.isEmpty else { return 0 }

        // `read_file` selects the WORDING, it does not gate the branch. This side used to
        // require the tool before taking the manifest path at all, so a stateless profile with
        // it disabled fell through to the full-injection arithmetic below — pricing a few
        // hundred chars of paths as up to 200 KB of content.
        if profile.resolvedFileContextStrategy == .stateless {
            return StatelessKnowledgeManifest.text(
                paths: sources.map(\.location),
                canReadFiles: StatelessKnowledgeManifest.canReadFiles(profile)
            ).count
        }

        var assembled = 0
        for source in sources {
            // `assembled` only grows, so once the total budget is gone every remaining source
            // is a `.tooLarge` failure — the assembler keeps looping to record them, this stops.
            guard assembled < DirectInjectionBudget.total else { break }
            let remainingBudget = min(
                DirectInjectionBudget.perFile,
                DirectInjectionBudget.total - assembled
            )
            guard let bytes = (try? source.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  bytes <= remainingBudget else { continue }
            // The assembler's own wrapper literal, so its width is derived rather than guessed.
            // The wrapper lands on top of `remainingBudget`, exactly as it does there, which is
            // why the running total can end a hair above `total`.
            assembled += "\n\n--- Knowledge: \(source.fileName) ---\n".count + bytes
        }
        return assembled
    }

    /// Characters the tool schemas contribute to the prompt.
    ///
    /// Measures the real serializer over the real registry entries rather than guessing a
    /// per-tool average — same discipline as the history and episodic terms.
    ///
    /// Caveat worth knowing: this renders the MARKDOWN form (`<available_tools>`, used by
    /// non-native providers). Native providers send an equivalent JSON `tools:` array, which
    /// differs by punctuation, not by content — the same names, descriptions and argument
    /// schemas. Treat it as the right magnitude for both, exact for one.
    static func estimatedToolSchemaChars(for profile: BackendProfileModel) -> Int {
        ToolSchemaSizes.chars(for: profile.schemaBearingToolNames)
    }

    /// Characters of PROSE history the next request will actually carry.
    ///
    /// Measures the real native turns rather than summing every message's `textContent`,
    /// which over-counted three ways at once: it ignored the per-strategy turn limit, ignored
    /// the char budget's oldest-first trimming, and charged providers that receive no prose
    /// at all. Same discipline as `estimatedEpisodicChars` — build what ships and count it.
    ///
    /// - Parameter carriesProse: `BackendProfileModel.carriesHistoryProse`. Passed as a Bool
    ///   rather than a profile, matching `estimatedHistoryImageTokens(shipsHistoryImages:)`.
    static func estimatedHistoryProseChars(
        in history: [ChatMessage],
        carriesProse: Bool,
        strategy: HistoryStrategy?,
        contextWindow: Int
    ) -> Int {
        guard carriesProse, !history.isEmpty else { return 0 }
        return NativeHistoryConverter.build(
            strategy: strategy ?? .recentHistory,
            from: history,
            charBudget: historyCharBudget(forContextWindow: contextWindow),
            includeImages: false
        ).reduce(0) { $0 + $1.text.count }
    }

    /// Characters the episodic memory blob will occupy in the next prompt.
    ///
    /// Previously invisible to every gauge: `historyChars` reads `content.textContent`, and
    /// episodic payload — tool params, outcomes, and `<effect>` diffs — lives on timeline
    /// `ToolExecutionData`, so a conversation full of file edits was charged ZERO for the
    /// largest thing in its prompt.
    ///
    /// Renders the real blob rather than estimating it, which is affordable because the
    /// gauge recomputes on turn boundaries, not keystrokes — and it guarantees the gauge and
    /// the request agree by construction.
    ///
    /// - Parameter history: ASCENDING (oldest first), which is what `BackendHistoryResolver`
    ///   returns — it sorts the merged stored + in-memory set by timestamp, and it is where
    ///   both production callers get their history. Nothing reverses on the way in, and
    ///   nothing should: `pairTurns` walks forward matching each user message to the agent
    ///   reply that follows it, so a descending array pairs every reply with the wrong
    ///   question. (The chat view's own `currentChatMessages` is descending AND a pagination
    ///   window — the resolver exists so neither gauge has to touch it.)
    /// - Parameter strategy: nil (bot / code profiles) resolves to `.recentHistory`, matching
    ///   `AgentConnect`'s own fallback for non-agent profiles.
    /// - Parameter includeImageNames: `BackendProfileModel.supportsVisionInput` — the exact
    ///   value `AgentConnect` passes when it builds the blob for real. On a vision profile
    ///   the formatter emits an `<attached_images>` line for every turn that carried images;
    ///   taking the `false` default here made the gauge cheaper than the payload precisely on
    ///   the profiles whose images already push them closest to the window. That is an
    ///   UNDER-count, i.e. the direction that fails to raise a banner. Defaulted to `false`
    ///   only so call sites not yet updated keep their current arithmetic.
    static func estimatedEpisodicChars(
        in history: [ChatMessage],
        strategy: HistoryStrategy?,
        contextWindow: Int,
        toolsAvailable: Bool = true,
        includeImageNames: Bool = false
    ) -> Int {
        guard !history.isEmpty else { return 0 }
        let budget = ActionEffect.diffBudget(forHistoryCharBudget: historyCharBudget(forContextWindow: contextWindow))
        return EpisodicHistoryFormatter.build(
            strategy: strategy ?? .recentHistory,
            from: history,
            includeImageNames: includeImageNames,
            effectBudget: budget,
            toolsAvailable: toolsAvailable
        ).count
    }
    /// The chars↔tokens ratio for FIT CHECKING and every char-denominated BUDGET, in both
    /// directions. Conservative because code burns tokens fast — a 4.0 assumption under-counts
    /// symbol-dense payloads, and under-counting is the dangerous direction when the question
    /// is "will this fit".
    ///
    /// ⚠️ NOT the app's only chars-per-token constant, and deliberately so.
    /// `TokenUsage.estimated` uses 4.0 because it answers a different question — how many
    /// tokens a call ACTUALLY consumed, for cost and usage display, where accuracy beats
    /// conservatism and over-reporting would inflate a spend figure. Two questions, two
    /// constants; see that function for the other side of the split.
    ///
    /// It used to be one of two. Char-denominated BUDGETS were built at 4.0 while this gauge
    /// priced their output at 3.0, so a history filled to exactly its 60%-of-window allowance
    /// read back as 80% — above the 75% overflow threshold. That posted an advisory the user
    /// could not clear, because the phantom cost came from history the composer cannot edit.
    /// One ratio in both directions makes that arithmetic impossible.
    static let charsPerToken = 3.0
    /// Fraction of the window reserved for the model's own output.
    static let responseHeadroom = 0.25

    /// - Parameter imageTokens: image cost, already in TOKENS (not chars) because
    ///   image cost has no relationship to any character count — see
    ///   `ImageTokenHeuristic`. Kept as a separate term from `attachmentChars`,
    ///   which excludes images by extension, so the two can never double-count.
    ///   Defaults to 0 so existing callers and their pinned arithmetic are unaffected.
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
    ///
    /// Images were invisible to this gauge until now — `estimatedAttachmentChars`
    /// filters them out by extension, so attaching a 6 MB screenshot to an 8K-window
    /// local model produced no warning whatsoever. Dimensions are read from each
    /// file's header (cheap, no decode); an unreadable header falls back to the flat
    /// per-image estimate rather than dropping the image from the tally.
    static func estimatedImageTokens(forImageURLs urls: [URL], provider: ApiProvider?) -> Int {
        urls.reduce(0) { total, url in
            total + ImageTokenHeuristic.tokens(pixels: ImageTokenHeuristic.pixelCount(of: url), provider: provider)
        }
    }

    /// Token cost of images already in the conversation. Prior-turn images ride the
    /// native history payload (see `HistoryTurn`), so they consume real context on
    /// every subsequent turn — `historyChars` cannot see them because it reads
    /// `content.textContent`, which is nil for media.
    /// - Parameter maxMessages: how far back to look. The converter only ever ships
    ///   the most recent turns (`.recentHistory` uses `limit: 10` PAIRS, and the char
    ///   budget trims further), so summing the whole fetched history — up to 300
    ///   messages — would over-state a 40-image conversation by ~36,000 tokens and
    ///   post a permanent overflow banner on a prompt that comfortably fits.
    /// - Parameter shipsHistoryImages: whether the profile's history strategy actually
    ///   carries prior-turn images. The `.pointer` strategy emits skeletons only and
    ///   ships ZERO images (`NativeHistoryConverter.buildPointerTurns` ignores them),
    ///   so counting them would post a permanent, un-clearable overflow banner for cost
    ///   that never ships. Pass `false` there. (`.hybrid` still over-counts images on
    ///   turns older than its inline window — accepted as a coarse-gauge upper bound.)
    static func estimatedHistoryImageTokens(in history: [ChatMessage], provider: ApiProvider?, shipsHistoryImages: Bool = true, maxMessages: Int = historyImageLookback) -> Int {
        guard shipsHistoryImages else { return 0 }
        let recent = history.suffix(max(0, maxMessages))
        // Count every image that will ACTUALLY reach the wire. The history splice now
        // TRANSCODES unsupported-but-decodable formats (HEIC/HEIF/TIFF/BMP/GIF) to JPEG
        // rather than dropping them, so the gauge must count those too — counting only
        // the already-loadable set would UNDER-state a HEIC-heavy conversation (HEIC is
        // the macOS default) and fail to warn on a prompt that really is over budget.
        // `isVisionEligible` is the cheap extension proxy for "will ship"; the wire
        // decision stays byte-truthful in `resolveSendable`.
        let count = recent.reduce(0) { total, message in
            total + (message.attachedImageFiles?.filter {
                VisionImageFormat.isVisionEligible(fileExtension: $0.fileExtension)
            }.count ?? 0)
        }
        return ImageTokenHeuristic.tokens(imageCount: count, provider: provider)
    }

    /// 10 turn PAIRS = 20 messages, matching `NativeHistoryConverter`'s default
    /// `limit:`. An upper bound, not an exact figure — the char budget and any
    /// checkpoint can trim further, so this errs toward under-warning, which is the
    /// safe direction for an advisory the user cannot act on.
    static let historyImageLookback = 20

    static func exceeds(estimatedTokens: Int, windowTokens: Int) -> Bool {
        Double(estimatedTokens) > Double(windowTokens) * (1.0 - responseHeadroom)
    }

    /// "8192" → "8K", "200000" → "200K"; sub-thousand values print as-is.
    static func roundedK(_ tokens: Int) -> String {
        tokens >= 1_000 ? "\(Int((Double(tokens) / 1_000).rounded()))K" : "\(tokens)"
    }

    /// Chars the attachments contribute once the reader has had its way with them.
    ///
    /// Two behaviours the old clamp got wrong, both now exact:
    ///
    /// 1. **A file over the per-file budget contributes ZERO, not the budget.**
    ///    `readFileContentOrThrow` THROWS `.tooLarge` when `content.count > maxSize` — it
    ///    does not truncate — and `assembleTextFileContent` records the failure and moves on.
    ///    Clamping to 50,000 charged the full budget for a file the model never sees.
    /// 2. **Each included file carries wrapper text.** `--- Start of file: <label> ---` …
    ///    `--- End of file: <name> ---`, where the label gains the absolute path on
    ///    write-capable profiles. Small per file, real across many.
    ///
    /// Sizes are STAT'd bytes while the reader's limit is decoded CHARS. For UTF-8 text
    /// chars ≤ bytes, so a file under the budget in bytes is certainly under it in chars;
    /// above the budget it is dropped in the common single-byte case. That is the direction
    /// this errs, and it errs toward the truth far more often than the old clamp did.
    static func attachmentInjectionChars(forFileSizes sizes: [Int], wrapperCharsPerFile: Int) -> Int {
        var total = 0
        for size in sizes {
            guard total < DirectInjectionBudget.total else { break }
            let bytes = max(size, 0)
            guard bytes <= DirectInjectionBudget.perFile else { continue }  // dropped, not clipped
            total += bytes + wrapperCharsPerFile
        }
        return min(total, DirectInjectionBudget.total)
    }

    /// Chars the attachments contribute for THIS profile, honouring its file strategy.
    ///
    /// `.stateless` sends a short path manifest and lets the agent `read_file` on demand, so
    /// charging the full file sizes over-warned enormously — a 5 MB attachment on a stateless
    /// profile costs a single line of text. The fallback matters too: with `read_file`
    /// disabled the manifest would point at a tool the profile cannot call, so the orchestrator
    /// falls back to direct injection, and so must this.
    @MainActor
    static func estimatedAttachmentChars(
        for files: [FileSystemItem],
        profile: BackendProfileModel
    ) -> Int {
        guard !files.isEmpty else { return 0 }

        let injectable = PreSendFitHint.estimatableSizes(of: files)
        let disclosesPaths = profile.profileType == .agent || profile.profileType == .code

        if profile.resolvedFileContextStrategy == .stateless,
           profile.enabledToolNames.contains("read_file") {
            // Mirrors the manifest the orchestrator builds: one preamble line plus one
            // absolute path per file. Measured, not guessed.
            let preamble = "The user has attached the following files. Use the read_file tool to access them when needed:\n"
            return preamble.count + files.map { $0.url.path }.joined(separator: "\n").count
        }

        // `--- Start of file: <name> (<path>) ---\n` + `\n--- End of file: <name> ---` plus
        // the leading blank line. Path only on write-capable profiles, matching
        // `assembleTextFileContent(includeAbsolutePaths:)`.
        let wrapper = files.reduce(0) { running, file in
            let label = disclosesPaths ? "\(file.name) (\(file.url.path))" : file.name
            return running + 55 + label.count + file.name.count
        }
        let averageWrapper = files.isEmpty ? 0 : wrapper / files.count

        return attachmentInjectionChars(forFileSizes: injectable, wrapperCharsPerFile: averageWrapper)
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

    /// Whether PRIOR-TURN images will actually reach the model on this profile.
    ///
    /// Mirrors — and must stay in step with — the gates `AgentConnect` applies when
    /// building `nativeHistoryTurns`. The fit gauge exists to tell the truth about
    /// what a request will cost, so charging for images the pipeline is going to
    /// drop is worse than not charging at all: the resulting banner cannot be
    /// dismissed by removing files, because the phantom cost comes from history the
    /// composer cannot edit.
    ///
    /// Two carriers, plus a universal VISION gate on top of both:
    ///   • BOT profile → `ChatExecutor.buildHistoryImageBlocks` re-attaches prior-turn
    ///     images on the atomic `generate(payload:)`/vision route, on ANY provider
    ///     (cloud, Ollama, or MLX) — tool capability is irrelevant to that path.
    ///   • AGENT profile → `nativeHistoryTurns` (cloud always; Ollama both capability
    ///     tiers) or the legacy multimodal path; MLX agents never build history turns.
    ///   • VISION model — required in every case (the first `guard` below). A non-vision
    ///     model, e.g. after the user swaps models mid-conversation, drops ALL prior-turn
    ///     media; this is the most common real-world skip. (Was once "bots are text-only
    ///     for history by design" — no longer true: vision bots carry history images.)
    ///
    /// Ollama ships prior-turn images on BOTH agent generators, by two routes:
    ///   • `.parallelActions` → `NativeStructuredGenerator` → the native turn splice.
    ///   • `.singleAction`     → Markdown/XMLStructuredGenerator → the legacy
    ///     `buildMultimodalMessages` path (2026-07-21).
    /// So the gate matches `AgentConnect.isNativeProvider`'s Ollama arm (`!= .none`) —
    /// an earlier version restricted this to `.parallelActions`, which under-counted
    /// history-image tokens for single-action Ollama vision agents and let their
    /// conversations overflow `num_ctx` with no pre-flight banner. `.none` is
    /// chat-only (agents reject it), and MLX never gets `nativeHistoryTurns` at all.
    var carriesHistoryImages: Bool {
        guard supportsVisionInput else { return false }
        switch profileType {
        case .bot:
            // Vision BOTS re-attach prior-turn images (ChatExecutor reads chatHistory)
            // on ANY provider — cloud, Ollama, or MLX — since the atomic
            // generate(payload:)/vision path handles them regardless of tool capability.
            return true
        case .agent:
            // Agent path carries history via nativeHistoryTurns: cloud always; Ollama
            // for both capability tiers (parallel = native splice, single = legacy);
            // MLX never builds nativeHistoryTurns.
            switch primaryLLMConfig?.apiProvider {
            case .anthropic, .openAI, .google, .openRouter, .openAICompatible: return true
            case .ollama: return primaryLLMConfig?.cognitiveCapability != ModelCognitiveCapability.none
            case .mlx, .none: return false
            }
        case .workflow, .imageGen, .code:
            return false
        }
    }

    /// Static reference material this profile injects as `<knowledge_base>` on EVERY request.
    ///
    /// Mirrors `BackendOrchestrationService.resolveKnowledgeSources` (bot and agent only) plus
    /// its `isLocalFile && exists` filter. Invisible to the composer until now, so a profile
    /// carrying a large reference document read as costing nothing right up until the
    /// send-time banner appeared.
    var knowledgeSourceFiles: [KnowledgeSource] {
        switch details {
        case .bot(let config):   return (config.knowledgeSources ?? []).filter { $0.isLocalFile && $0.exists }
        case .agent(let config): return (config.knowledgeSources ?? []).filter { $0.isLocalFile && $0.exists }
        default:                 return []
        }
    }

    /// Names of the tools this profile sends SCHEMAS for.
    ///
    /// Empty for bots — `AgentConnect` sets `rawTools = []` on the bot flow and `ChatExecutor`
    /// passes `tools: nil` to the provider, so a bot carries no tool payload at all. That is
    /// the single largest fixed difference between a bot and an agent on the same model, and
    /// the flat `layerOverheadChars` charged them identically.
    ///
    /// Known under-count: `AgentConnect` also appends `ask_user`, the long-term-memory
    /// capabilities, `final_answer` (non-bot) and — when the history has pointers —
    /// `get_conversation_history`. Those are request-time additions this can't see.
    var schemaBearingToolNames: [String] {
        switch details {
        case .agent(let config), .code(let config):
            return config.tools.filter(\.isEnabled).map(\.name)
        case .bot, .workflow, .imageGen:
            return []
        }
    }

    /// Whether PRIOR-TURN PROSE actually reaches the model on this profile.
    ///
    /// Only native providers receive `nativeHistoryTurns`. On MLX — and Ollama at the `.none`
    /// capability tier — prior turns reach the model ONLY through the episodic XML's 80-char
    /// `goal` and 200-char `<outcome>`, both of which `estimatedEpisodicChars` already counts.
    ///
    /// Charging the full transcript on top of that was ~90% phantom on a long MLX
    /// conversation: 248% of an 8K window displayed where the truth was 24% — and unclearable,
    /// because the phantom cost is history the composer cannot edit. Exactly the failure mode
    /// `carriesHistoryImages` exists to prevent for images; the text term simply never got the
    /// same gate.
    ///
    /// Mirrors `AgentConnect.isNativeProvider`, which gates every `nativeHistoryTurns` build.
    /// Applies to bots too — `ChatExecutor` infers `isNativeFlow` from whether that array
    /// exists. Reads `resolvedLLMConfig` (not `primaryLLMConfig`, which is nil for `.code`).
    var carriesHistoryProse: Bool {
        switch resolvedLLMConfig?.apiProvider {
        case .anthropic, .openAI, .google, .openRouter, .openAICompatible: return true
        case .ollama: return resolvedLLMConfig?.cognitiveCapability != ModelCognitiveCapability.none
        case .mlx, .none: return false
        }
    }

    /// Human-readable reason `carriesHistoryImages` returned false, for the intentional
    /// prior-turn-image skip log. Lives next to that gate and mirrors it branch-for-branch
    /// so the two never drift. The dominant real case is a non-vision model (the user
    /// swapped one in) — NOT any "by design" profile limit — and the log must say which,
    /// so a reader validating the swap-to-non-vision safety path sees the true cause.
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

    /// The agent's resolved history strategy (default `.recentHistory` when unset,
    /// matching `AgentConnect`). Profiles with no `AgentConfig` → nil. Used by the fit
    /// gauge to avoid charging history-image tokens under `.pointer`, which ships none.
    ///
    /// ⚠️ register B44 (twin, outside the filed file) — this was `if case .agent(let c) = details`,
    /// so `.code` returned nil. `CodeSessionManager` configures `.pointer` precisely because Code
    /// sessions must not resend history images, and nil meant the gauge charged for images the run
    /// never sends — over-reporting context pressure on exactly the profile type that avoids it.
    /// The nil-for-non-agent contract is preserved via `agentConfig`, which is the one place that
    /// decides which profile types are agent-shaped.
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
