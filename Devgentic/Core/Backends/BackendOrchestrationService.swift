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
        context: TraceContext
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                logger.info("ORCHESTRATION START (Stream): Routing with profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue)). TraceID: \(context.traceID)")
                
                // 1. Sanitize History
                // Filter out error messages
                var conversationHistory = history.filter { message in
                    if case .error = message.content { return false }
                    return true
                }
                
                // BUG FIX: Prevent duplication of the current query.
                // If the UI has already appended the current message to 'history', we must remove it
                // because we are about to inject 'userQuery' as the fresh prompt/user-turn.
                // We check if the last message is from the user and matches the current query text.
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
                // We retrieve context *separately* from modifying the query string initially.
                var ragContextString: String? = nil
                
                if config.profile.profileType == .bot || config.profile.profileType == .agent {
                    // BUG FIX: Pass history to filter out self-referential context
                    ragContextString = await self.retrieveRAGContext(for: userQuery, conversationID: conversationID, history: conversationHistory)
                }
                
                do {
                    switch config.profile.profileType {
                    
                    case .bot:
                        // --- BOT PIPELINE (Passive Context Injection) ---
                        // For Bots, we inject the RAG context directly into the effective query string.
                        
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
                            
                            // For Ollama (Bot Mode), we construct the history manually here.
                            var ollamaHistory = conversationHistory.map { message -> OllamaChatMessage in
                                let role: String
                                switch message.sender {
                                case .user: role = "user"
                                case .agent: role = "assistant"
                                }
                                return OllamaChatMessage(role: role, content: message.content.textContent ?? "")
                            }
                            // Append the augmented query (with RAG context)
                            ollamaHistory.append(OllamaChatMessage(role: "user", content: effectiveQuery))
                            
                            logger.info("Initiating stream to Ollama (Bot Mode) with model \(llmConfig.modelName). History count: \(ollamaHistory.count).")

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
                            // Remote APIs usually handle larger contexts well.
                            let stream = self.remoteOrchestrationService.streamMessage(
                                conversationID: conversationID,
                                userQuery: effectiveQuery, // RAG is baked in here
                                history: conversationHistory,
                                profile: config.profile,
                                context: context
                            )
                            
                            for try await token in stream {
                                continuation.yield(token)
                            }
                            continuation.finish()
                        }

                    case .agent:
                        // --- AGENT PIPELINE (Active Tool Usage) ---
                        // We route to AgentConnect, passing the tools and context separately.
                        
                        logger.info("Routing to AgentConnect for profile: \(config.profile.displayName).")
                        
                        // Define a handler for Agent Thoughts/Actions
                        let traceHandler: (AgentTraceLog) -> Void = { log in
                            // Log the trace to the system console
                            logger.info("[AGENT-TRACE] Step \(log.stepNumber) (\(log.state.rawValue)): \(log.content)")
                            
                            // FUTURE INTEGRATION:
                            // context.appendAgentTrace(log)
                            // This will allow the UI to display "Thinking..." bubbles or a debug drawer.
                        }
                        
                        let stream = agentConnect.streamAgentResponse(
                            for: config.profile,
                            userInput: queryForRequest,
                            chatHistory: conversationHistory,
                            conversationID: conversationID,
                            ragContext: ragContextString,
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
        // This prevents the "Echo Chamber" where the agent reads its own history as new "Relevant Context"
        // and thinks it needs to re-execute previous commands.
        let filteredChunks = relevantChunks.filter { chunk in
            // Check if this chunk's content is present in the recent history
            !history.contains { message in
                guard let text = message.content.textContent else { return false }
                let chunkClean = chunk.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let msgClean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // If the chunk is identical to or substantially contained within a recent message, skip it.
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
