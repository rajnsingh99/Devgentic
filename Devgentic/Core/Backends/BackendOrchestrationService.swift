//
//  BackendOrchestrationService.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "BackendOrchestrationService")

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
                
                // Prevent duplicate current query in history (User UX vs LLM Context)
                if let lastMsg = conversationHistory.last,
                   lastMsg.sender == .user,
                   let lastContent = lastMsg.content.textContent,
                   lastContent.trimmingCharacters(in: .whitespacesAndNewlines) == userQuery.trimmingCharacters(in: .whitespacesAndNewlines) {
                    
                    logger.debug("Removing duplicated current message from history to prevent double-prompting. (Trace: \(context.traceID))")
                    conversationHistory.removeLast()
                }
                
                var queryForRequest = userQuery
                let fileContextStrategy = config.profile.resolvedFileContextStrategy

                // 2. File Context Handling — strategy-based routing
                if !files.isEmpty {
                    logger.info("Processing \(files.count) attached files with strategy: \(fileContextStrategy.rawValue). (Trace: \(context.traceID))")

                    switch fileContextStrategy {
                    case .contextualRAG:
                        // Chunk, embed, and store for vector retrieval
                        await RAGIndexingService.shared.indexAttachedFiles(
                            files: files,
                            conversationID: conversationID,
                            messageID: UUID()
                        )

                    case .directInjection:
                        // Extract full text and inject into prompt context
                        let (fileContext, skippedFiles) = await self.assembleTextFileContent(for: files)
                        if !fileContext.isEmpty {
                            queryForRequest = fileContext + "\n\n" + queryForRequest
                        }
                        if !skippedFiles.isEmpty {
                            let warning = "[System] Could not extract text from: \(skippedFiles.joined(separator: ", ")). These files were not included in the context."
                            continuation.yield(.content(warning + "\n\n"))
                        }

                    case .stateless:
                        // No extraction — note file paths for agent tool access
                        let paths = files.map { $0.url.path }.joined(separator: "\n")
                        let fileNote = "The user has attached the following files. Use the read_file tool to access them when needed:\n\(paths)"
                        queryForRequest = fileNote + "\n\n" + queryForRequest
                    }
                }

                // 3. RAG Retrieval
                // Fetch long-term memory context when using contextualRAG strategy.
                var ragContextString: String? = nil
                if fileContextStrategy == .contextualRAG {

                    // --- UI Progress: RAG preparation ---
                    continuation.yield(.thought("Searching knowledge base…"))

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

                    ragContextString = await self.retrieveRAGContext(for: queryForRAG, conversationID: conversationID, history: conversationHistory)
                }

                // 4. Knowledge Sources — strategy-aware handling of pre-configured reference documents
                if let knowledgeSources = self.resolveKnowledgeSources(from: config.profile),
                   !knowledgeSources.isEmpty {
                    let localSources = knowledgeSources.filter { $0.isLocalFile && $0.exists }
                    if !localSources.isEmpty {
                        switch fileContextStrategy {
                        case .contextualRAG:
                            // Freshness check + indexing handled by KnowledgeSourceMonitor
                            await KnowledgeSourceMonitor.shared.ensureFreshness(
                                sources: localSources,
                                conversationID: conversationID
                            )

                        case .directInjection:
                            // Extract text from knowledge sources and inject into prompt
                            let knowledgeText = await self.assembleKnowledgeSourceContent(sources: localSources)
                            if !knowledgeText.isEmpty {
                                queryForRequest = knowledgeText + "\n\n" + queryForRequest
                            }

                        case .stateless:
                            // Note paths for agent tool access
                            let paths = localSources.map { $0.location }.joined(separator: "\n")
                            let note = "Knowledge sources available via read_file:\n\(paths)"
                            queryForRequest = note + "\n\n" + queryForRequest
                        }
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
                    switch currentConfig.profile.profileType {
                        
                    case .bot:
                        logger.info("Routing BOT profile '\(currentConfig.profile.displayName)' to Unified Pipeline.")

                        let stream = agentConnect.streamAgentResponse(
                            for: currentConfig.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
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
                        
                        // AgentConnect handles the "New Request" flag internally for stream start
                        let stream = agentConnect.streamAgentResponse(
                            for: currentConfig.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
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
                            case .toolSucceeded(let output, _, _), .toolFailed(let output, _, _, _):
                                logger.debug("[ARTIFACT] \(output.toolName) - \(output.output.prefix(50))...")
                                continuation.yield(event)
                            case .toolCall(let name, let params, _):
                                logger.debug("[TOOL_CALL] \(name) params: \(params)")
                                continuation.yield(event)
                            case .requestConfirmation(let toolName, _, _, _):
                                logger.debug("[HITL] Permission requested for \(toolName)")
                                continuation.yield(event)
                            case .requestClarification(let question, _, _):
                                logger.debug("[ASK_USER] Clarification requested: \(question)")
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
                            case .planGenerated, .subtaskStarted, .subtaskCompleted,
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
                            let attachedImages: [Data]? = imageFiles.isEmpty ? nil : imageFiles.compactMap { file in
                                try? Data(contentsOf: file.url)
                            }

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
                                options: options
                            )

                            // 6. Forward stream events
                            for try await event in stream {
                                continuation.yield(event)
                            }
                            continuation.finish()
                        } catch {
                            logger.error("ImageGen setup error: \(error.localizedDescription)")
                            continuation.yield(.error(error.localizedDescription))
                            continuation.finish()
                        }

                    case .code:
                        // Code mode routes through the agent pipeline using an ephemeral profile.
                        // The ephemeral profile is built with .agent profileType internally,
                        // so this case handles the rare scenario where profileType is explicitly .code.
                        let codeProjectPath: String
                        if case .code(let codeConfig) = currentConfig.profile.details {
                            codeProjectPath = codeConfig.projectPath ?? "unknown"
                        } else {
                            codeProjectPath = "unknown"
                        }
                        logger.info("[CODE] Routing to AgentConnect (agent pipeline) — traceID: \(context.traceID), project: \(codeProjectPath), RAG: \(ragContextString != nil), history: \(conversationHistory.count) msgs")

                        let stream = agentConnect.streamAgentResponse(
                            for: currentConfig.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
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

                    continuation.yield(.error("Extended thinking disabled — '\(modelName)' reported it isn't supported. Retrying without it…"))
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
    
    private func retrieveRAGContext(for userQuery: String, conversationID: UUID, history: [ChatMessage] = []) async -> String? {
        logger.info("RAG: Attempting to retrieve context for conversation: \(conversationID.uuidString)")
        
        guard let queryEmbedding = await embeddingService.generateEmbedding(for: userQuery) else {
            logger.warning("RAG: Could not generate embedding for query.")
            return nil
        }
        
        // Retrieve relevant parent documents based on child chunk embeddings
        let relevantParents = vectorStoreService.findNearest(to: queryEmbedding, limit: 3, conversationID: conversationID)

        guard !relevantParents.isEmpty else {
            logger.info("RAG: Vector store returned 0 documents.")
            return nil
        }

        // Phase 5: O(1) ID-based Deduplication instead of heavy string matching.
        // We simply check if the parent document's source message is already in the current chat history.
        let historyIDs = Set(history.map { $0.id })
        
        let filteredParents = relevantParents.filter { parent in
            !historyIDs.contains(parent.sourceMessageID)
        }

        let removedCount = relevantParents.count - filteredParents.count
        if removedCount > 0 {
            logger.info("RAG: Dedup filter removed \(removedCount)/\(relevantParents.count) documents already present in history.")
        }

        guard !filteredParents.isEmpty else {
            logger.info("RAG: No relevant context found (all \(relevantParents.count) documents were duplicates of history).")
            return nil
        }

        logger.info("RAG: Found \(filteredParents.count) relevant documents after dedup.")
        return filteredParents.map { $0.fullTextContent }.joined(separator: "\n\n")
    }
    
    // MARK: - Direct Injection Budget

    /// Maximum characters to inject per file (~12.5K tokens)
    private let directInjectionBudgetPerFile: Int = 50_000
    /// Maximum total characters to inject across all files (~50K tokens)
    private let directInjectionTotalBudget: Int = 200_000

    private func assembleTextFileContent(for files: [FileSystemItem]) async -> (content: String, skippedFiles: [String]) {
        var assembledContent = ""
        var skippedFiles: [String] = []

        for file in files {
            // Check total budget
            guard assembledContent.count < directInjectionTotalBudget else {
                skippedFiles.append("\(file.name) (context budget exceeded)")
                continue
            }

            let info = fileProcessorService.extractionInfo(for: file.url)
            guard info.canExtract else {
                skippedFiles.append(file.name)
                continue
            }

            let remainingBudget = min(
                directInjectionBudgetPerFile,
                directInjectionTotalBudget - assembledContent.count
            )

            if let content = await fileProcessorService.readFileContent(
                for: file.url,
                maxSize: remainingBudget
            ) {
                assembledContent += "\n\n--- Start of file: \(file.name) ---\n\(content)\n--- End of file: \(file.name) ---"
            } else {
                skippedFiles.append(file.name)
            }
        }

        return (assembledContent, skippedFiles)
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

    /// Extracts text from knowledge source files for direct injection.
    private func assembleKnowledgeSourceContent(sources: [KnowledgeSource]) async -> String {
        var assembled = ""
        for source in sources {
            guard assembled.count < directInjectionTotalBudget else { break }
            let remainingBudget = min(
                directInjectionBudgetPerFile,
                directInjectionTotalBudget - assembled.count
            )
            if let content = await fileProcessorService.readFileContent(
                for: source.url,
                maxSize: remainingBudget
            ) {
                assembled += "\n\n--- Knowledge: \(source.fileName) ---\n\(content)"
            }
        }
        return assembled
    }
}
