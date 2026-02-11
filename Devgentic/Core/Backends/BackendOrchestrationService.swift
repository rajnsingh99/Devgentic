//
//  BackendOrchestrationService.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation
import Combine
import os
import OpenFoundationModels
import OpenFoundationModelsOllama
import OpenFoundationModelsOpenAI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "BackendOrchestrationService")


@MainActor
class BackendOrchestrationService: ObservableObject {

    // MARK: - Dependencies
    private let ollamaService: OllamaService
    // RemoteOrchestrationService removed in favor of AgentConnect Unified Pipeline
    private let persistenceService: CoreDataServiceProtocol
    private let fileProcessorService: FileProcessorService
    
    private let agentConnect: AgentConnect
    
    // RAG Services
    private let embeddingService = EmbeddingService.shared
    private let vectorStoreService = VectorStoreService.shared
    
    // MARK: - 🧠 Active Plan Memory (State Management)
    // Stores plans that are currently PAUSED/BLOCKED waiting for user clarification.
    // Key: ConversationID, Value: The blocked ExecutionPlan
    private var activePlans: [UUID: ExecutionPlan] = [:]
    
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    init(
        fileProcessorService: FileProcessorService
    ) {
        self.fileProcessorService = fileProcessorService
        self.ollamaService = OllamaService.shared
        self.persistenceService = CoreDataPersistenceService.shared
        
        // Initialize AgentConnect (Native implementation)
        self.agentConnect = AgentConnect()
        
        logger.info("BackendOrchestrationService initialized with AgentConnect.")
    }
    
    // MARK: - Streaming Message Logic
    
    func streamMessage(
        withConfig config: BackendRequestConfig,
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        files: [FileSystemItem],
        context: TraceContext,
        // --- NEW: Trace Callback for UI Updates ---
        onTraceUpdate: ((AgentTraceLog) -> Void)? = nil
        // ------------------------------------------
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        
        // BUG REPORT FEATURE:
        // Wrap the UI callback to automatically record every step into the Aggregator.
        let aggregatedTraceUpdate: (AgentTraceLog) -> Void = { log in
            Task { await TraceLogAggregator.shared.append(log) }
            onTraceUpdate?(log)
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                logger.info("ORCHESTRATION START (Stream): Routing with profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue)). TraceID: \(context.traceID)")
                
                // RAM OPTIMIZATION:
                // If the user is NOT using an MLX profile, unload any MLX models to free up Unified Memory.
                if !self.isMLXProfile(config.profile) {
                    await MLXService.shared.unloadModel()
                }
                
                // 1. Sanitize History
                var conversationHistory = history.filter { message in
                    if case .error = message.content { return false }
                    return true
                }
                
                // BUG FIX: Prevent duplication of the current query.
                if let lastMsg = conversationHistory.last,
                   lastMsg.sender == .user,
                   let lastContent = lastMsg.content.textContent,
                   lastContent.trimmingCharacters(in: .whitespacesAndNewlines) == userQuery.trimmingCharacters(in: .whitespacesAndNewlines) {
                    
                    logger.debug("Removing duplicated current message from history to prevent double-prompting. (Trace: \(context.traceID))")
                    conversationHistory.removeLast()
                }

                var queryForRequest = userQuery
                
                // 2. File Context Assembly (Manual Attachments)
                if !files.isEmpty {
                    logger.info("Assembling content for \(files.count) attached files. (Trace: \(context.traceID))")
                    let fileContext = self.assembleTextFileContent(for: files)
                    if !fileContext.isEmpty {
                        queryForRequest = fileContext + "\n\n" + queryForRequest
                    }
                }
                
                // 3. RAG Retrieval
                var ragContextString: String? = nil
                
                if config.profile.profileType == .bot || config.profile.profileType == .agent {
                    ragContextString = await self.retrieveRAGContext(for: userQuery, conversationID: conversationID, history: conversationHistory)
                }
                
                do {
                    switch config.profile.profileType {
                    
                    case .bot:
                        // --- BOT PIPELINE (Unified) ---
                        // Replaced manual routing with AgentConnect.
                        // ChatExecutor will handle the response streaming and trace logging.
                        
                        logger.info("Routing BOT profile '\(config.profile.displayName)' to Unified Pipeline.")
                        
                        let stream = agentConnect.streamAgentResponse(
                            for: config.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
                            approvedPlan: nil, // Bots don't plan
                            traceContext: context,
                            onTraceUpdate: aggregatedTraceUpdate
                        )
                        
                        // Passthrough all events to UI
                        for try await event in stream {
                            continuation.yield(event)
                        }
                        continuation.finish()

                    case .agent:
                        // --- AGENT PIPELINE (Active Tool Usage + Planning) ---
                        logger.info("Routing AGENT profile '\(config.profile.displayName)' to AgentConnect. Trace: \(context.traceID)")
                        
                        guard case .agent(let llmConfig, _, _, _, _, _) = config.profile.details else {
                             throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid profile type for agent execution."])
                        }
                        
                        // =========================================================================
                        // A. ARCHITECT PHASE: Create or Repair Plan
                        // =========================================================================
                        var approvedPlan: ExecutionPlan? = nil
                        
                        // [TEMPORARY MODIFICATION]
                        // The ManagerAgent (Planner) is disabled. User input flows directly to the Executor.
                        // This allows for faster testing of the Worker/Tools without the Architect overhead.
                        logger.notice("[ORCHESTRATOR] 🚧 ManagerAgent (Planner) is DISABLED. Routing directly to Worker.")

                        /*
                        // We must initialize a model specifically for the ManagerAgent.
                        if let plannerModel = await self.createModelInstance(from: llmConfig) {
                            let manager = ManagerAgent(model: plannerModel)
                            
                            // 1. CHECK FOR BLOCKED PLAN (Repair Phase)
                            if let blockedPlan = self.activePlans[conversationID] {
                                // Note: Plan Trace is not fully linked yet, using root ID for now
                                aggregatedTraceUpdate(AgentTraceLog(
                                    traceID: context.traceID,
                                    spanID: UUID().uuidString,
                                    parentSpanID: context.spanID,
                                    stepNumber: 0,
                                    state: .thinking,
                                    content: "Patching Previous Plan..."
                                ))
                                
                                logger.info("[PLANNER] Found blocked plan. Attempting to PATCH with input: '\(userQuery)'")
                                
                                do {
                                    // Call the Patching API on Manager
                                    let patchedPlan = try await manager.patchPlan(
                                        currentPlan: blockedPlan,
                                        userCorrection: userQuery,
                                        traceContext: context
                                    )
                                    self.logPlanPayload(patchedPlan, source: "PATCHED PLAN")
                                    
                                    if patchedPlan.requiresUserConfirmation {
                                        // Still broken? Update storage and ask again.
                                        self.activePlans[conversationID] = patchedPlan
                                        self.handleSafetyStop(plan: patchedPlan, continuation: continuation)
                                        return
                                    } else {
                                        // Fixed! Clear storage and proceed.
                                        self.activePlans.removeValue(forKey: conversationID)
                                        approvedPlan = patchedPlan
                                        logger.info("[PLANNER] Plan successfully repaired.")
                                    }
                                } catch {
                                    logger.error("[PLANNER] Patch failed: \(error.localizedDescription). Clearing memory and falling back to new plan.")
                                    self.activePlans.removeValue(forKey: conversationID)
                                }
                            }
                            
                            // 2. FRESH PLANNING (If no plan exists or patch failed)
                            if approvedPlan == nil {
                                aggregatedTraceUpdate(AgentTraceLog(
                                    traceID: context.traceID,
                                    spanID: UUID().uuidString,
                                    parentSpanID: context.spanID,
                                    stepNumber: 0,
                                    state: .thinking,
                                    content: "Architecting new plan..."
                                ))
                                
                                logger.info("[PLANNER] Creating FRESH plan for query.")
                                
                                do {
                                    let newPlan = try await manager.generatePlan(
                                        userRequest: queryForRequest,
                                        chatHistory: conversationHistory,
                                        conversationID: conversationID,
                                        traceContext: context
                                    )
                                    self.logPlanPayload(newPlan, source: "FRESH PLAN")
                                    
                                    if newPlan.requiresUserConfirmation {
                                        // Store for next turn
                                        self.activePlans[conversationID] = newPlan
                                        self.handleSafetyStop(plan: newPlan, continuation: continuation)
                                        return
                                    } else {
                                        approvedPlan = newPlan
                                        logger.info("[PLANNER] 🛡️ Safety Check: PASSED.")
                                    }
                                } catch {
                                    logger.warning("[PLANNER] ⚠️ Planning Failed. Falling back to ReAct. Error: \(error.localizedDescription)")
                                    // Removed static yield for failure notice to keep UI clean
                                }
                            }
                        }
                        */
                        
                        // =========================================================================
                        // B. EXECUTION PHASE (Only reached if Plan is Safe)
                        // =========================================================================
                        
                        if approvedPlan != nil {
                            logger.info("[ORCHESTRATOR] 🚀 Handoff: Passing Approved Plan to Executor.")
                        } else {
                            logger.info("[ORCHESTRATOR] ⚠️ Handoff: Starting Executor WITHOUT Plan (Generalist Mode).")
                        }
                        
                        // The 'aggregatedTraceUpdate' wrapper handles logging to Aggregator automatically
                        let traceHandler: (AgentTraceLog) -> Void = { log in
                            logger.info("[AGENT-TRACE] Step \(log.stepNumber) (\(log.state.rawValue)): \(log.content) (span: \(log.spanID))")
                            aggregatedTraceUpdate(log)
                        }
                        
                        let stream = agentConnect.streamAgentResponse(
                            for: config.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
                            approvedPlan: approvedPlan,
                            traceContext: context,
                            onTraceUpdate: traceHandler
                        )
                        
                        var tokensReceived = 0
                        // Bridge: Passthrough the Structured Stream
                        for try await event in stream {
                            switch event {
                            case .content:
                                tokensReceived += 1
                                continuation.yield(event)
                                
                            case .thought(let thought):
                                // Log thoughts for debug, but pass them through to UI
                                logger.debug("[THOUGHT] \(thought)")
                                continuation.yield(event)
                                
                            case .toolOutput(let output):
                                // Log artifacts
                                logger.debug("[ARTIFACT] \(output.toolName) - \(output.output.prefix(50))...")
                                continuation.yield(event)
                                
                            case .toolCall(let name, let params):
                                logger.debug("[TOOL_CALL] \(name) params: \(params)")
                                continuation.yield(event)
                                
                            case .error(let err):
                                logger.debug("[ERROR] \(err)")
                                continuation.yield(event)
                            }
                        }
                        
                        if tokensReceived == 0 {
                            logger.warning("AGENT_CONNECT_DATA: Stream finished without receiving any tokens. (Trace: \(context.traceID))")
                        }
                        
                        continuation.finish()
                        
                    case .workflow:
                        throw NSError(domain: "NotImplemented", code: 501, userInfo: [NSLocalizedDescriptionKey: "Streaming is not yet supported for Workflow profiles."])
                    }
                } catch {
                    logger.error("AGENT_CONNECT_ERROR: The stream failed with an error: \(error.localizedDescription) (Trace: \(context.traceID))")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Checks if the current profile is using MLX.
    private func isMLXProfile(_ profile: BackendProfileModel) -> Bool {
        switch profile.details {
        case .bot(let config):
            return config.apiProvider == .mlx
        case .agent(let config, _, _, _, _, _):
            return config.apiProvider == .mlx
        case .workflow:
            return false
        }
    }
    
    private func logPlanPayload(_ plan: ExecutionPlan, source: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(plan), let json = String(data: data, encoding: .utf8) {
            logger.info("\n========== [PLANNER] \(source) ==========\n\(json)\n=========================================")
        }
    }
    
    private func handleSafetyStop(plan: ExecutionPlan, continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation) {
        logger.notice("[PLANNER] 🛡️ Safety Check: BLOCKED.")
        let ambiguousStep = plan.steps.first(where: { $0.isAmbiguous })
        let question = ambiguousStep?.clarificationQuestion ?? "This plan looks risky. Do you want to proceed?"
        
        logger.info("[PLANNER] Asking User: \(question)")
        continuation.yield(.content("🛑 **Safety Stop**: \(question)\n"))
        continuation.finish()
    }
    
    // MARK: - Helper: Model Factory
    
    /// Creates a LanguageModel instance for the Planner (ManagerAgent).
    private func createModelInstance(from config: ProviderConfig) async -> (any OpenFoundationModels.LanguageModel)? {
        switch config.apiProvider {
        case .ollama:
            let baseURLString = config.baseURL ?? "http://127.0.0.1:11434"
            guard let baseURL = URL(string: baseURLString) else { return nil }
            // Use a shorter timeout for planning than full execution
            let conf = OllamaConfiguration(baseURL: baseURL, timeout: 60.0)
            return OllamaLanguageModel(configuration: conf, modelName: config.modelName)
            
        case .openAI:
            guard let apiKey = config.apiKey, !apiKey.isEmpty else { return nil }
            let baseURL = (config.baseURL != nil) ? URL(string: config.baseURL!)! : URL(string: "https://api.openai.com/v1")!
            let conf = OpenAIConfiguration(apiKey: apiKey, baseURL: baseURL)
            return OpenAILanguageModel(configuration: conf, model: config.modelName)
            
        case .google:
            guard let apiKey = config.apiKey, !apiKey.isEmpty else { return nil }
            let googleBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!
            let conf = OpenAIConfiguration(apiKey: apiKey, baseURL: googleBaseURL)
            return OpenAILanguageModel(configuration: conf, model: config.modelName)
            
        case .mlx:
            // For MLX, we must ensure the model is loaded first.
            let modelName = config.modelName
            let modelPath: URL? = await MainActor.run {
                if MLXModelService.shared.installedModels.isEmpty {
                    MLXModelService.shared.refreshInstalledModels()
                }
                return MLXModelService.shared.installedModels.first(where: { $0.displayName == modelName })?.localPath
            }
            
            if let path = modelPath {
                try? await MLXService.shared.loadModel(from: path)
                return MLXLanguageModel(modelName: modelName)
            }
            return nil
            
        default:
            return nil
        }
    }

   /// Retrieves relevant RAG context without modifying the user query directly.
   /// - Parameters:
   ///   - history: The current chat history. Used to filter out self-referential context (loops).
   private func retrieveRAGContext(for userQuery: String, conversationID: UUID, history: [ChatMessage] = []) async -> String? {
        logger.info("RAG: Attempting to retrieve context for conversation: \(conversationID.uuidString)")
        
        // 1. Generate a vector embedding for the user's query.
        guard let queryEmbedding = await embeddingService.generateEmbedding(for: userQuery) else {
            logger.warning("RAG: Could not generate embedding for query. Proceeding without context.")
            return nil
        }
        
        // 2. Find the most relevant chunks from the vector store for this specific conversation.
        let relevantChunks = vectorStoreService.findNearest(to: queryEmbedding, limit: 3, conversationID: conversationID)
        
        // 3. Filter Chunks
        // BUG FIX: Don't include chunks that are just the user's previous messages in this same session.
        let filteredChunks = relevantChunks.filter { chunk in
            // Check if this chunk's content is present in the recent history
            !history.contains { message in
                guard let text = message.content.textContent else { return false }
                let chunkClean = chunk.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let msgClean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                return msgClean.contains(chunkClean) || chunkClean.contains(msgClean)
            }
        }
        
        guard !filteredChunks.isEmpty else {
            logger.info("RAG: No relevant context found (or all matches were filtered due to history redundancy).")
            return nil
        }
        
        // 4. Assemble the retrieved context
        logger.info("RAG: Found \(filteredChunks.count) relevant chunks (after filtering).")
        let contextString = filteredChunks.map { $0.content }.joined(separator: "\n\n")
        
        return contextString
    }
    
    // MARK: - File Content Assembly
    
    private func assembleTextFileContent(for files: [FileSystemItem]) -> String {
        var assembledContent = ""
        
        for file in files {
            if fileProcessorService.isTextFile(mimeType: fileProcessorService.getFileMimeType(for: file.url), url: file.url) {
                if let content = fileProcessorService.readFileContent(for: file.url) {
                    logger.debug("Appending content from file: \(file.name)")
                    assembledContent += "\n\n--- Start of file: \(file.name) ---\n"
                    assembledContent += content
                    assembledContent += "\n--- End of file: \(file.name) ---"
                }
            }
        }
        
        return assembledContent
    }
}
