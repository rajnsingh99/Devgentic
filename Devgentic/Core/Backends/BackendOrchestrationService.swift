//
//  BackendOrchestrationService.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "BackendOrchestrationService")

/// The primary entry point for backend operations.
/// Orchestrates the flow between the UI, file processing, RAG retrieval, and the Agent/Bot pipelines.
@MainActor
class BackendOrchestrationService: ObservableObject {
    
    // MARK: - Dependencies
    private let ollamaService: OllamaService
    private let persistenceService: CoreDataServiceProtocol
    private let fileProcessorService: FileProcessorService
    private let agentConnect: AgentConnect
    
    // RAG Services
    private let embeddingService = EmbeddingService.shared
    private let vectorStoreService = VectorStoreService.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    init(
        fileProcessorService: FileProcessorService
    ) {
        self.fileProcessorService = fileProcessorService
        self.ollamaService = OllamaService.shared
        self.persistenceService = CoreDataPersistenceService.shared
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
        onTraceUpdate: ((AgentTraceLog) -> Void)? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        
        // Automatic Trace Aggregation for UI monitoring
        let aggregatedTraceUpdate: (AgentTraceLog) -> Void = { log in
            Task { await TraceLogAggregator.shared.append(log) }
            onTraceUpdate?(log)
        }
        
        return AsyncThrowingStream { continuation in
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
                
                // 2. File Context Assembly
                // Read and attach content from supported text files.
                if !files.isEmpty {
                    logger.info("Assembling content for \(files.count) attached files. (Trace: \(context.traceID))")
                    let fileContext = self.assembleTextFileContent(for: files)
                    if !fileContext.isEmpty {
                        queryForRequest = fileContext + "\n\n" + queryForRequest
                    }
                }
                
                // 3. RAG Retrieval
                // Fetch long-term memory context if applicable.
                var ragContextString: String? = nil
                if config.profile.profileType == .bot || config.profile.profileType == .agent {
                    ragContextString = await self.retrieveRAGContext(for: userQuery, conversationID: conversationID, history: conversationHistory)
                }
                
                // Check cancellation before heavy lifting
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                
                do {
                    switch config.profile.profileType {
                        
                    case .bot:
                        logger.info("Routing BOT profile '\(config.profile.displayName)' to Unified Pipeline.")
                        
                        let stream = agentConnect.streamAgentResponse(
                            for: config.profile,
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
                        logger.info("Routing AGENT profile '\(config.profile.displayName)' to AgentConnect. Trace: \(context.traceID)")
                        
                        // Direct routing to the Generalist Agent.
                        // Signals a "New User Request" to the downstream AgentConnect logic.
                        logger.notice("[ORCHESTRATOR] ⚠️ Starting Generalist Agent Execution (Direct Handoff).")
                        
                        let traceHandler: (AgentTraceLog) -> Void = { log in
                            logger.info("[AGENT-TRACE] Step \(log.stepNumber) (\(log.state.headline)): \(log.content) (span: \(log.spanID))")
                            aggregatedTraceUpdate(log)
                        }
                        
                        // AgentConnect handles the "New Request" flag internally for stream start
                        let stream = agentConnect.streamAgentResponse(
                            for: config.profile,
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
                            case .thought(_, let message):
                                logger.debug("[THOUGHT] \(message)")
                                continuation.yield(event)
                            case .toolOutput(let output):
                                logger.debug("[ARTIFACT] \(output.toolName) - \(output.output.prefix(50))...")
                                continuation.yield(event)
                            case .toolCall(let name, let params):
                                logger.debug("[TOOL_CALL] \(name) params: \(params)")
                                continuation.yield(event)
                            case .requestConfirmation(let toolName, _):
                                logger.debug("[HITL] Permission requested for \(toolName)")
                                continuation.yield(event)
                            case .requestClarification(let question):
                                logger.debug("[ASK_USER] Clarification requested: \(question)")
                                continuation.yield(event)
                            case .error(let err):
                                logger.debug("[ERROR] \(err)")
                                continuation.yield(event)
                            }
                        }
                        
                        if tokensReceived == 0 {
                            logger.warning("Stream finished without receiving tokens.")
                        }
                        
                        continuation.finish()
                        
                    case .workflow:
                        throw NSError(domain: "NotImplemented", code: 501, userInfo: [NSLocalizedDescriptionKey: "Streaming is not yet supported for Workflow profiles."])
                    }
                } catch is CancellationError {
                    logger.warning("Orchestration Stream Cancelled.")
                    continuation.finish()
                } catch {
                    logger.error("AGENT_CONNECT_ERROR: \(error.localizedDescription) (Trace: \(context.traceID))")
                    continuation.finish(throwing: error)
                }
            }
            
            // [CRITICAL FIX] Hook up cancellation
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func isMLXProfile(_ profile: BackendProfileModel) -> Bool {
        switch profile.details {
        case .bot(let config, _): return config.apiProvider == .mlx
        case .agent(let config, _, _, _, _, _): return config.apiProvider == .mlx
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
    
    private func assembleTextFileContent(for files: [FileSystemItem]) -> String {
        var assembledContent = ""
        for file in files {
            if fileProcessorService.isTextFile(mimeType: fileProcessorService.getFileMimeType(for: file.url), url: file.url) {
                if let content = fileProcessorService.readFileContent(for: file.url) {
                    assembledContent += "\n\n--- Start of file: \(file.name) ---\n\(content)\n--- End of file: \(file.name) ---"
                }
            }
        }
        return assembledContent
    }
}
