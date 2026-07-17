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
                var attachmentContext: String? = nil
                if !files.isEmpty {
                    logger.info("Processing \(files.count) attached files with strategy: \(fileContextStrategy.rawValue). (Trace: \(context.traceID))")

                    switch fileContextStrategy {
                    case .contextualRAG, .directInjection:
                        // .contextualRAG is deprecated and never returned by resolve() —
                        // the arm stays only for switch exhaustiveness until Phase 4
                        // deletes the case, and maps to directInjection behavior.
                        let (fileContext, docFailures) = await self.assembleTextFileContent(for: files)
                        if !fileContext.isEmpty {
                            attachmentContext = fileContext
                        }
                        // D3: report (traced + structured notice), keep answering.
                        await self.reportFileFailures(docFailures, span: context, continuation: continuation)

                    case .stateless:
                        // No extraction — note file paths for agent tool access
                        let paths = files.map { $0.url.path }.joined(separator: "\n")
                        attachmentContext = "The user has attached the following files. Use the read_file tool to access them when needed:\n\(paths)"
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
                let primaryConfig = config.profile.primaryLLMConfig
                let trainedWindow = EffectiveContextWindow.trainedWindow(for: primaryConfig)
                let contextWindowTokens = EffectiveContextWindow.resolve(for: primaryConfig)

                var ragContextString: String? = nil
                let profileUsesConversationRAG = config.profile.profileType == .bot
                    || config.profile.profileType == .agent
                if profileUsesConversationRAG && !conversationHistory.isEmpty {

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
                            // Manifest only — the agent reads sources on demand.
                            let paths = localSources.map { $0.location }.joined(separator: "\n")
                            knowledgeBaseContext = "The following profile reference documents are available. Read them with the read_file tool when needed:\n\(paths)"
                        }
                    }
                }

                // 5. Pre-flight context-fit check — every piece of the prompt is known
                // here, BEFORE any tokens stream. Oversize prompts on local models don't
                // fail loudly: Ollama HEAD-truncates silently (system prompt first), so
                // the model quietly loses the knowledge/retrieval layers and answers from
                // fragments. This is AMBIENT state (profile + content size), not a turn
                // event — it surfaces as an actionable advisory banner above the chat
                // input (AdvisoryBannerView), never as per-turn transcript clutter.
                if profileUsesConversationRAG {
                    let estimatedTokens = PromptFitCheck.estimatedTokens(
                        attachmentChars: attachmentContext?.count ?? 0,
                        knowledgeChars: knowledgeBaseContext?.count ?? 0,
                        retrievalChars: ragContextString?.count ?? 0,
                        queryChars: queryForRequest.count,
                        historyChars: conversationHistory.reduce(0) { $0 + ($1.content.textContent?.count ?? 0) }
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
                        logger.warning("Context-fit: ~\(estimatedTokens) tokens estimated vs \(contextWindowTokens)-token window — advisory posted. (Trace: \(context.traceID))")
                    } else {
                        // Condition resolved (files removed, model switched, window
                        // raised…) — the banner self-heals.
                        AdvisoryCenter.shared.clear(category: .contextOverflow, conversationID: conversationID)
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
                    let (rawImagePayload, imageFailures) = await self.buildImagePayload(from: files)
                    await self.reportFileFailures(imageFailures, span: context, continuation: continuation)

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
                        logger.info("Vision gate: dropped \(raw.count) image block(s) for non-vision local model '\(modelName)'")
                    } else {
                        attachedImagePayload = rawImagePayload
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
                            case .requestConfirmation(let toolName, _, _, _):
                                logger.debug("[HITL] Permission requested for \(toolName)")
                                continuation.yield(event)
                            case .requestClarification(let question, _, _, _, _):
                                logger.debug("[ASK_USER] Clarification requested: \(question)")
                                continuation.yield(event)
                            case .requestGate(let prompt, _, _, _, _):
                                logger.debug("[GATE] Decision requested: \(prompt)")
                                continuation.yield(event)
                            case .error(let err):
                                logger.debug("[ERROR] \(err)")
                                continuation.yield(event)

                            case .warning(let cat, let msg, _, _):
                                logger.debug("[WARNING] [\(cat.rawValue)] \(msg)")
                                continuation.yield(event)

                            // Workflow orchestration events (not emitted by agent profiles, but needed for exhaustive switch)
                            case .workflowNodeStarted, .workflowNodeCompleted, .workflowNodeFailed, .workflowProgress, .workflowLoopIteration:
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
                                 .compactionStarted, .compactionCompleted,
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
                            let imageURLs = imageFiles.map(\.url)
                            let attachedImages: [Data]? = imageURLs.isEmpty ? nil : await Task.detached(priority: .userInitiated) {
                                imageURLs.compactMap { try? Data(contentsOf: $0) }
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
    private func buildImagePayload(from files: [FileSystemItem]) async -> (payload: Payload?, failures: [FileRetrievalError]) {
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
                    blocks.append(.image(ImagePayload(reference: .ephemeralData(data), mimeType: item.mime, alt: item.name)))
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
    private func assembleTextFileContent(for files: [FileSystemItem]) async -> (content: String, failures: [FileRetrievalError]) {
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
                assembledContent += "\n\n--- Start of file: \(file.name) ---\n\(content)\n--- End of file: \(file.name) ---"
            } catch let retrievalError as FileRetrievalError {
                failures.append(retrievalError)
            } catch {
                failures.append(.readFailed(path: file.url.path, underlying: error.localizedDescription))
            }
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

// MARK: - Prompt Fit Check

/// Pre-flight estimate of whether the assembled prompt fits the model's
/// effective context window. Char-based (~3 chars/token, conservative for
/// code-dense content) with a fixed allowance for prompt-builder layers —
/// ±15% accuracy is plenty for a warning that only gates a banner.
enum PromptFitCheck {
    /// Instructions, environment facts, episodic wrappers, tool schemas, etc.
    static let layerOverheadChars = 2_000
    /// Conservative chars→tokens ratio (code burns tokens fast).
    static let charsPerToken = 3.0
    /// Fraction of the window reserved for the model's own output.
    static let responseHeadroom = 0.25

    static func estimatedTokens(
        attachmentChars: Int,
        knowledgeChars: Int,
        retrievalChars: Int,
        queryChars: Int,
        historyChars: Int
    ) -> Int {
        let totalChars = attachmentChars + knowledgeChars + retrievalChars
            + queryChars + historyChars + layerOverheadChars
        return Int(Double(totalChars) / charsPerToken)
    }

    static func exceeds(estimatedTokens: Int, windowTokens: Int) -> Bool {
        Double(estimatedTokens) > Double(windowTokens) * (1.0 - responseHeadroom)
    }

    /// "8192" → "8K", "200000" → "200K"; sub-thousand values print as-is.
    static func roundedK(_ tokens: Int) -> String {
        tokens >= 1_000 ? "\(Int((Double(tokens) / 1_000).rounded()))K" : "\(tokens)"
    }

    /// COMPOSER-SIDE attachment estimate from stat'd file sizes (content not yet
    /// read; bytes ≈ chars for text/code), clamped to the direct-injection budgets
    /// the orchestrator will actually apply — a 5 MB file injects at most 50K
    /// chars, so estimating its full size would wildly over-warn.
    static func estimatedAttachmentChars(forFileSizes sizes: [Int]) -> Int {
        var total = 0
        for size in sizes {
            guard total < DirectInjectionBudget.total else { break }
            total += min(max(size, 0), DirectInjectionBudget.perFile)
        }
        return min(total, DirectInjectionBudget.total)
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
