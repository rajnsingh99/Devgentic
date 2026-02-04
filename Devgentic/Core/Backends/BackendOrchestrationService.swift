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
    private let remoteOrchestrationService: RemoteOrchestrationService
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
        self.remoteOrchestrationService = RemoteOrchestrationService()
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
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                logger.info("ORCHESTRATION START (Stream): Routing with profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue)). TraceID: \(context.traceID)")
                
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
                    
                    logger.debug("Removing duplicated current message from history to prevent double-prompting.")
                    conversationHistory.removeLast()
                }

                var queryForRequest = userQuery
                
                // 2. File Context Assembly (Manual Attachments)
                if !files.isEmpty {
                    logger.info("Assembling content for \(files.count) attached files.")
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
                        // --- BOT PIPELINE (Passive Context Injection) ---
                        var effectiveQuery = queryForRequest
                        if let context = ragContextString, !context.isEmpty {
                             let contextHeader = "### CONTEXT FROM KNOWLEDGE BASE ###\n"
                             let contextFooter = "\n### END CONTEXT ###\n(Please use the context above if relevant to answer the following question)\n\n"
                             effectiveQuery = "\(contextHeader)\(context)\(contextFooter)\(queryForRequest)"
                        }
                        
                        guard case .bot(let llmConfig) = config.profile.details else {
                            throw NSError(domain: "ProfileError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not extract bot configuration from profile."])
                        }
                        
                        switch llmConfig.apiProvider {
                        case .ollama:
                            guard let baseURL = llmConfig.baseURL else {
                                throw NSError(domain: "OllamaConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Ollama base URL is missing in the profile."])
                            }
                            
                            var ollamaHistory = conversationHistory.map { message -> OllamaChatMessage in
                                let role = (message.sender == .user) ? "user" : "assistant"
                                return OllamaChatMessage(role: role, content: message.content.textContent ?? "")
                            }
                            ollamaHistory.append(OllamaChatMessage(role: "user", content: effectiveQuery))
                            
                            let stream = OllamaConnect.streamChatRequest(
                                baseURL: baseURL,
                                model: llmConfig.modelName,
                                history: ollamaHistory
                            )
                            
                            for try await token in stream {
                                continuation.yield(token)
                            }
                            continuation.finish()

                        case .openAI, .google, .anthropic:
                            let stream = self.remoteOrchestrationService.streamMessage(
                                conversationID: conversationID,
                                userQuery: effectiveQuery,
                                history: conversationHistory,
                                profile: config.profile,
                                context: context
                            )
                            for try await token in stream {
                                continuation.yield(token)
                            }
                            continuation.finish()
                        case .mlx:
                            guard let baseURL = llmConfig.baseURL else {
                                throw NSError(domain: "OllamaConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Ollama base URL is missing in the profile."])
                            }
                            
                            var ollamaHistory = conversationHistory.map { message -> OllamaChatMessage in
                                let role = (message.sender == .user) ? "user" : "assistant"
                                return OllamaChatMessage(role: role, content: message.content.textContent ?? "")
                            }
                            ollamaHistory.append(OllamaChatMessage(role: "user", content: effectiveQuery))
                            
                            let stream = OllamaConnect.streamChatRequest(
                                baseURL: baseURL,
                                model: llmConfig.modelName,
                                history: ollamaHistory
                            )
                            
                            for try await token in stream {
                                continuation.yield(token)
                            }
                            continuation.finish()
                        }

                    case .agent:
                        // --- AGENT PIPELINE (Active Tool Usage + Planning) ---
                        logger.info("Routing to AgentConnect for profile: \(config.profile.displayName).")
                        
                        guard case .agent(let llmConfig, _, _, _, _, _) = config.profile.details else {
                             throw NSError(domain: "AgentConnect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid profile type for agent execution."])
                        }
                        
                        // =========================================================================
                        // A. ARCHITECT PHASE: Create or Repair Plan
                        // =========================================================================
                        var approvedPlan: ExecutionPlan? = nil
                        
                        // We must initialize a model specifically for the ManagerAgent.
                        if let plannerModel = self.createModelInstance(from: llmConfig) {
                            let manager = ManagerAgent(model: plannerModel)
                            
                            // 1. CHECK FOR BLOCKED PLAN (Repair Phase)
                            if let blockedPlan = self.activePlans[conversationID] {
                                // REMOVED STATIC YIELD: "🔧 **Patching Previous Plan...**\n\n"
                                // Instead, send a status update for the UI to display in the "Thinking" header.
                                onTraceUpdate?(AgentTraceLog(stepNumber: 0, state: .thinking, content: "Patching Previous Plan..."))
                                
                                logger.info("[PLANNER] Found blocked plan. Attempting to PATCH with input: '\(userQuery)'")
                                
                                do {
                                    // Call the Patching API on Manager
                                    let patchedPlan = try await manager.patchPlan(currentPlan: blockedPlan, userCorrection: userQuery)
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
                                // REMOVED STATIC YIELD: "🧠 **Architecting Plan...**\n\n"
                                // Instead, send status update.
                                onTraceUpdate?(AgentTraceLog(stepNumber: 0, state: .thinking, content: "Architecting new plan..."))
                                
                                logger.info("[PLANNER] Creating FRESH plan for query.")
                                
                                do {
                                    let newPlan = try await manager.generatePlan(
                                        userRequest: queryForRequest,
                                        chatHistory: conversationHistory,
                                        conversationID: conversationID
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
                        
                        // =========================================================================
                        // B. EXECUTION PHASE (Only reached if Plan is Safe)
                        // =========================================================================
                        
                        if approvedPlan != nil {
                            logger.info("[ORCHESTRATOR] 🚀 Handoff: Passing Approved Plan to Executor.")
                        } else {
                            logger.info("[ORCHESTRATOR] ⚠️ Handoff: Starting Executor WITHOUT Plan (Generalist Mode).")
                        }
                        
                        let traceHandler: (AgentTraceLog) -> Void = { log in
                            logger.info("[AGENT-TRACE] Step \(log.stepNumber) (\(log.state.rawValue)): \(log.content)")
                            // Bridge the log to the ViewModel/UI
                            onTraceUpdate?(log)
                        }
                        
                        let stream = agentConnect.streamAgentResponse(
                            for: config.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
                            approvedPlan: approvedPlan, // <--- INJECTING THE PLAN
                            onTraceUpdate: traceHandler
                        )
                        
                        var tokensReceived = 0
                        for try await eventData in stream {
                            tokensReceived += 1
                            continuation.yield(eventData)
                        }
                        
                        if tokensReceived == 0 {
                            logger.warning("AGENT_CONNECT_DATA: Stream finished without receiving any tokens.")
                        }
                        
                        continuation.finish()
                        
                    case .workflow:
                        throw NSError(domain: "NotImplemented", code: 501, userInfo: [NSLocalizedDescriptionKey: "Streaming is not yet supported for Workflow profiles."])
                    }
                } catch {
                    logger.error("AGENT_CONNECT_ERROR: The stream failed with an error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func logPlanPayload(_ plan: ExecutionPlan, source: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(plan), let json = String(data: data, encoding: .utf8) {
            logger.info("\n========== [PLANNER] \(source) ==========\n\(json)\n=========================================")
        }
    }
    
    private func handleSafetyStop(plan: ExecutionPlan, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        logger.notice("[PLANNER] 🛡️ Safety Check: BLOCKED.")
        let ambiguousStep = plan.steps.first(where: { $0.isAmbiguous })
        let question = ambiguousStep?.clarificationQuestion ?? "This plan looks risky. Do you want to proceed?"
        
        logger.info("[PLANNER] Asking User: \(question)")
        continuation.yield("🛑 **Safety Stop**: \(question)\n")
        continuation.finish()
    }
    
    // MARK: - Helper: Model Factory
    
    /// Creates a LanguageModel instance for the Planner (ManagerAgent).
    private func createModelInstance(from config: ProviderConfig) -> (any OpenFoundationModels.LanguageModel)? {
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
