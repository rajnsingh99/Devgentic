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
    private let agentService: AgentService
    private let ollamaService: OllamaService
    private let remoteOrchestrationService: RemoteOrchestrationService
    private let agentStore: AgentStore
    private let llmIntegrationStore: LLMIntegrationStore
    private let persistenceService: CoreDataServiceProtocol
    private let fileProcessorService: FileProcessorService
    
    // RAG Services
    private let embeddingService = EmbeddingService.shared
    private let vectorStoreService = VectorStoreService.shared
    
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    init(
        agentStore: AgentStore,
        llmIntegrationStore: LLMIntegrationStore,
        fileProcessorService: FileProcessorService
    ) {
        self.agentStore = agentStore
        self.llmIntegrationStore = llmIntegrationStore
        self.fileProcessorService = fileProcessorService
        
        self.agentService = AgentService()
        self.ollamaService = OllamaService.shared
        self.remoteOrchestrationService = RemoteOrchestrationService()
        self.persistenceService = CoreDataPersistenceService.shared
        
        logger.info("BackendOrchestrationService initialized.")
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
                logger.info("ORCHESTRATION START (Stream): Routing with config - Backend: \(config.backendType.rawValue), AgentID: \(config.agentID?.uuidString ?? "nil"), IntegrationID: \(config.integrationID?.uuidString ?? "nil"). TraceID: \(context.traceID)")
                
                // --- UPDATED: Pass conversationID to augmentQueryWithContext ---
                let augmentedQuery = await self.augmentQueryWithContext(userQuery: userQuery, conversationID: conversationID)
                
                let conversationHistory = history.filter { message in
                    if case .error = message.content { return false }
                    return true
                }

                var finalUserQuery = augmentedQuery
                if !files.isEmpty {
                    logger.info("Assembling content for \(files.count) attached files.")
                    let fileContext = self.assembleTextFileContent(for: files)
                    if !fileContext.isEmpty {
                        finalUserQuery = fileContext + "\n\n" + finalUserQuery
                    }
                }
                
                do {
                    switch config.backendType {
                    case .remote:
                        guard let integrationID = config.integrationID,
                              let integration = self.llmIntegrationStore.integrations.first(where: { $0.id == integrationID }) else {
                            throw NSError(domain: "RemoteConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Selected remote integration not found."])
                        }
                        
                        let stream = self.remoteOrchestrationService.streamMessage(
                            conversationID: conversationID,
                            userQuery: finalUserQuery,
                            history: conversationHistory,
                            openAIThreadID: nil,
                            integration: integration,
                            context: context
                        )
                        
                        for try await token in stream {
                            continuation.yield(token)
                        }
                        continuation.finish()

                    case .agent, .ollama:
                        throw NSError(domain: "StreamingError", code: 501, userInfo: [NSLocalizedDescriptionKey: "Streaming is not yet supported for the \(config.backendType.rawValue) backend."])
                        
                    case .none:
                        throw NSError(domain: "BackendError", code: 404, userInfo: [NSLocalizedDescriptionKey: "No backend has been selected."])
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Main Sending Logic (Non-Streaming)
    
    func sendMessage(
        withConfig config: BackendRequestConfig,
        conversationID: UUID,
        userQuery: String,
        files: [FileSystemItem]
    ) async -> ([ChatMessage], String?) {
        
        logger.info("ORCHESTRATION START (One-shot): Routing with config - Backend: \(config.backendType.rawValue), AgentID: \(config.agentID?.uuidString ?? "nil"), IntegrationID: \(config.integrationID?.uuidString ?? "nil")")
        
        // --- UPDATED: Pass conversationID to augmentQueryWithContext ---
        let augmentedQuery = await augmentQueryWithContext(userQuery: userQuery, conversationID: conversationID)
        
        let conversationEntity = persistenceService.getConversation(withId: conversationID)
        let conversation = conversationEntity?.toConversationStruct()
        
        let conversationHistory = (conversation?.messages ?? []).filter { message in
            if case .error = message.content { return false }
            return true
        }
        
        var finalUserQuery = augmentedQuery
        
        // Combine file content with the user query for remote backends
        if !files.isEmpty {
            logger.info("Assembling content for \(files.count) attached files.")
            let fileContext = assembleTextFileContent(for: files)
            if !fileContext.isEmpty {
                // Prepend file context to the (potentially already augmented) query
                finalUserQuery = fileContext + "\n\n" + finalUserQuery
            }
        }
        
        do {
            switch config.backendType {
            case .agent:
                guard let agentID = config.agentID else {
                    return ([], "No agent selected for the Agent backend.")
                }
                let (messages, error) = try await sendToAgent(conversationID: conversationID, userQuery: finalUserQuery, files: files, agentID: agentID)
                return (messages, error?.localizedDescription)
                
            case .ollama:
                guard let integrationID = config.integrationID else {
                    return ([], "No Ollama integration selected.")
                }
                // *** MODIFIED: Pass conversationHistory to sendToOllama ***
                let (messages, error) = try await sendToOllama(
                    conversationID: conversationID,
                    userQuery: finalUserQuery,
                    history: conversationHistory, // Pass the history
                    files: files,
                    integrationID: integrationID
                )
                return (messages, error?.localizedDescription)

            case .remote:
                 guard let integrationID = config.integrationID else {
                    return ([], "No remote integration selected.")
                }
                
                let (messages, newThreadID, error) = try await sendToRemote(
                    conversationID: conversationID,
                    userQuery: finalUserQuery,
                    history: conversationHistory,
                    openAIThreadID: conversation?.openAIThreadID,
                    integrationID: integrationID
                )
                
                if let newThreadID = newThreadID {
                    persistenceService.updateOpenAIThreadID(for: conversationID, with: newThreadID)
                }
                
                return (messages, error?.localizedDescription)

            case .none:
                return ([], "No backend has been selected. Please select a backend from the input area.")
            }
        } catch {
            let userFriendlyError = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: config.backendType)
            return ([], userFriendlyError)
        }
    }
    
    // MARK: - RAG Context Retrieval
    
    // --- UPDATED: Function signature now accepts a conversationID ---
    private func augmentQueryWithContext(userQuery: String, conversationID: UUID) async -> String {
        logger.info("Attempting to augment query with RAG context for conversation: \(conversationID.uuidString)")
        guard let queryEmbedding = await embeddingService.generateEmbedding(for: userQuery) else {
            logger.warning("Could not generate embedding for query. Proceeding without RAG context.")
            return userQuery
        }
        
        // --- UPDATED: Pass the conversationID to the vector store search ---
        let relevantChunks = vectorStoreService.findNearest(to: queryEmbedding, limit: 3, conversationID: conversationID)
        
        guard !relevantChunks.isEmpty else {
            logger.info("No relevant RAG context found for this conversation.")
            return userQuery
        }
        
        logger.info("Found and prepended \(relevantChunks.count) relevant chunks for RAG context.")
        
        let contextHeader = "--- Relevant Context ---\n"
        let contextString = relevantChunks.map { $0.content }.joined(separator: "\n\n")
        let contextFooter = "\n--- End of Context ---"
        
        let assembledContext = contextHeader + contextString + contextFooter
        
        // Combine the context with the original user query.
        return "\(assembledContext)\n\nQuestion: \(userQuery)"
    }
    
    // MARK: - File Content Assembly
    
    private func assembleTextFileContent(for files: [FileSystemItem]) -> String {
        var assembledContent = ""
        
        for file in files {
            // We only process text files here. Image files are handled differently by multi-modal models.
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

    // MARK: - Backend-Specific Logic
    private func sendToAgent(conversationID: UUID, userQuery: String, files: [FileSystemItem], agentID: UUID) async throws -> ([ChatMessage], Error?) {
        guard let selectedAgent = agentStore.agents.first(where: { $0.id == agentID }) else {
            throw NSError(domain: "AgentConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "The selected agent profile could not be found."])
        }
        
        guard let linkedIntegration = llmIntegrationStore.integrations.first(where: { $0.id == selectedAgent.linkedIntegrationID }) else {
            throw NSError(domain: "AgentConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "The selected agent's LLM integration is not found."])
        }

        guard linkedIntegration.providerType == .ollama, let ollamaConfig = linkedIntegration.ollamaConfig else {
            throw NSError(domain: "AgentConfigError", code: 400, userInfo: [NSLocalizedDescriptionKey: "The agent's linked LLM must be a configured Ollama provider."])
        }

        let llmSettings = OllamaLLMSettings(
            baseUrl: ollamaConfig.baseURL,
            modelName: ollamaConfig.modelName,
            contextWindowSize: ollamaConfig.contextWindowSize ?? 4096
        )

        let rootAgentConfig = AgentConfig(
            agentId: selectedAgent.id.uuidString,
            parentId: nil,
            roleObjective: userQuery,
            tools: selectedAgent.tools.map { $0.id },
            llmSettings: .ollama(llmSettings)
        )

        let payload = AgentOrchestrationRequest(
            conversationId: conversationID.uuidString,
            files: files.map { FileObject(uri: $0.url.absoluteString, name: $0.name) },
            agentConfigs: [rootAgentConfig]
        )
        
        let (messageContents, error) = try await self.agentService.sendMessage(payload: payload)
        
        if let error = error {
            let chatError = ChatMessage(conversationId: conversationID, sender: .agent, content: .error(title: "Agent Error", details: error.localizedDescription))
            return ([chatError], error)
        }
    
        let messages = messageContents.map { ChatMessage(conversationId: conversationID, sender: .agent, content: $0) }
        return (messages, nil)
    }

    // *** FULLY IMPLEMENTED OLLAMA ONE-SHOT LOGIC ***
    private func sendToOllama(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        files: [FileSystemItem],
        integrationID: UUID
    ) async throws -> ([ChatMessage], Error?) {
        guard let integration = llmIntegrationStore.integrations.first(where: { $0.id == integrationID && $0.providerType == .ollama }),
              let ollamaConfig = integration.ollamaConfig else {
             throw NSError(domain: "OllamaConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Selected Ollama integration not found or is misconfigured."])
        }
        
        // 1. Convert the passed-in history to Ollama's format
        var ollamaHistory = history.map { message -> OllamaChatMessage in
            let role: String
            switch message.sender {
            case .user:
                role = "user"
            case .agent:
                role = "assistant"
            }
            // This assumes textContent is sufficient.
            // For multi-modal, we'd need to handle attached images here.
            return OllamaChatMessage(role: role, content: message.content.textContent ?? "")
        }
        
        // 2. Add the current user query to the history.
        // The `userQuery` is the final augmented query with RAG/file context.
        ollamaHistory.append(OllamaChatMessage(role: "user", content: userQuery))

        do {
            // 3. Send the request via OllamaConnect
            let response = try await OllamaConnect.sendChatRequest(
                baseURL: ollamaConfig.baseURL,
                model: ollamaConfig.modelName,
                history: ollamaHistory
            )

            // 4. Convert the response back to a ChatMessage
            let agentMessageContent = MessageContent.markdownText(response.message.content)
            let agentMessage = ChatMessage(
                conversationId: conversationID,
                sender: .agent,
                content: agentMessageContent
            )

            return ([agentMessage], nil)

        } catch {
            logger.error("Error sending message to Ollama: \(error.localizedDescription)")
            // The calling function will generate the user-friendly error, so we just pass it up.
            return ([], error)
        }
    }

    private func sendToRemote(
            conversationID: UUID,
            userQuery: String,
            history: [ChatMessage],
            openAIThreadID: String?,
            integrationID: UUID
        ) async throws -> (messages: [ChatMessage], newThreadID: String?, error: Error?) {
             guard let integration = llmIntegrationStore.integrations.first(where: { $0.id == integrationID && $0.providerType == .remote }) else {
                 throw NSError(domain: "RemoteConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Selected remote integration not found."])
            }
            
            return try await remoteOrchestrationService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                openAIThreadID: openAIThreadID,
                integration: integration
            )
        }
}
