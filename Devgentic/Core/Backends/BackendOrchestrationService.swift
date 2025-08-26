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
    private let llmIntegrationStore: LLMIntegrationStore
    private let persistenceService: CoreDataServiceProtocol
    private let fileProcessorService: FileProcessorService
    
    // RAG Services
    private let embeddingService = EmbeddingService.shared
    private let vectorStoreService = VectorStoreService.shared
    
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    init(
        llmIntegrationStore: LLMIntegrationStore,
        fileProcessorService: FileProcessorService
    ) {
        self.llmIntegrationStore = llmIntegrationStore
        self.fileProcessorService = fileProcessorService
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

                    case .ollama:
                        guard let integrationID = config.integrationID,
                              let integration = self.llmIntegrationStore.integrations.first(where: { $0.id == integrationID }),
                              let ollamaConfig = integration.ollamaConfig else {
                            throw NSError(domain: "OllamaConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Selected Ollama integration not found or is misconfigured."])
                        }

                        var ollamaHistory = conversationHistory.map { message -> OllamaChatMessage in
                            let role: String
                            switch message.sender {
                            case .user: role = "user"
                            case .agent: role = "assistant"
                            }
                            return OllamaChatMessage(role: role, content: message.content.textContent ?? "")
                        }
                        ollamaHistory.append(OllamaChatMessage(role: "user", content: finalUserQuery))
                        
                        logger.info("Initiating stream to Ollama with model \(ollamaConfig.modelName). History count: \(ollamaHistory.count).")

                        let stream = OllamaConnect.streamChatRequest(
                            baseURL: ollamaConfig.baseURL,
                            model: ollamaConfig.modelName,
                            history: ollamaHistory
                        )
                        
                        for try await token in stream {
                            continuation.yield(token)
                        }
                        continuation.finish()
                        
                    case .agent:
                        throw NSError(domain: "StreamingError", code: 501, userInfo: [NSLocalizedDescriptionKey: "Streaming is not yet supported for the Agent backend."])
                        
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
    
//    func sendMessage(
//        withConfig config: BackendRequestConfig,
//        conversationID: UUID,
//        userQuery: String,
//        files: [FileSystemItem]
//    ) async -> ([ChatMessage], String?) {
//        
//        logger.info("ORCHESTRATION START (One-shot): Routing with config - Backend: \(config.backendType.rawValue), AgentID: \(config.agentID?.uuidString ?? "nil"), IntegrationID: \(config.integrationID?.uuidString ?? "nil")")
//        
//        let augmentedQuery = await augmentQueryWithContext(userQuery: userQuery, conversationID: conversationID)
//        
//        let conversationEntity = persistenceService.getConversation(withId: conversationID)
//        let conversation = conversationEntity?.toConversationStruct()
//        
//        let conversationHistory = (conversation?.messages ?? []).filter { message in
//            if case .error = message.content { return false }
//            return true
//        }
//        
//        var finalUserQuery = augmentedQuery
//        
//        if !files.isEmpty {
//            logger.info("Assembling content for \(files.count) attached files.")
//            let fileContext = assembleTextFileContent(for: files)
//            if !fileContext.isEmpty {
//                finalUserQuery = fileContext + "\n\n" + finalUserQuery
//            }
//        }
//        
//        do {
//            switch config.backendType {
//            case .agent:
//                guard let agentID = config.agentID else {
//                    return ([], "No agent selected for the Agent backend.")
//                }
//                let (messages, error) = try await sendToAgent(conversationID: conversationID, userQuery: finalUserQuery, files: files, agentID: agentID)
//                return (messages, error?.localizedDescription)
//                
//            case .ollama:
//                guard let integrationID = config.integrationID else {
//                    return ([], "No Ollama integration selected.")
//                }
//                let (messages, error) = try await sendToOllama(
//                    conversationID: conversationID,
//                    userQuery: finalUserQuery,
//                    history: conversationHistory,
//                    files: files,
//                    integrationID: integrationID
//                )
//                return (messages, error?.localizedDescription)
//
//            case .remote:
//                 guard let integrationID = config.integrationID else {
//                    return ([], "No remote integration selected.")
//                }
//                
//                let (messages, newThreadID, error) = try await sendToRemote(
//                    conversationID: conversationID,
//                    userQuery: finalUserQuery,
//                    history: conversationHistory,
//                    openAIThreadID: conversation?.openAIThreadID,
//                    integrationID: integrationID
//                )
//                
//                if let newThreadID = newThreadID {
//                    persistenceService.updateOpenAIThreadID(for: conversationID, with: newThreadID)
//                }
//                
//                return (messages, error?.localizedDescription)
//
//            case .none:
//                return ([], "No backend has been selected. Please select a backend from the input area.")
//            }
//        } catch {
//            let userFriendlyError = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: config.backendType)
//            return ([], userFriendlyError)
//        }
//    }
    
    // MARK: - RAG Context Retrieval
    
    /// **STEP 2.1: RAG RETRIEVAL**
    /// This function uses the VectorStoreService to find relevant context from the current conversation
    /// and prepends it to the user's query before sending it to the AI.
    private func augmentQueryWithContext(userQuery: String, conversationID: UUID) async -> String {
        logger.info("RAG: Attempting to augment query with context for conversation: \(conversationID.uuidString)")
        
        // 1. Generate a vector embedding for the user's query.
        guard let queryEmbedding = await embeddingService.generateEmbedding(for: userQuery) else {
            logger.warning("RAG: Could not generate embedding for query. Proceeding without context.")
            return userQuery
        }
        
        // 2. Find the most relevant chunks from the vector store for this specific conversation.
        let relevantChunks = vectorStoreService.findNearest(to: queryEmbedding, limit: 3, conversationID: conversationID)
        
        guard !relevantChunks.isEmpty else {
            logger.info("RAG: No relevant context found for this conversation.")
            return userQuery
        }
        
        // 3. Assemble the retrieved context into a string to prepend to the user's query.
        logger.info("RAG: Found and prepended \(relevantChunks.count) relevant chunks for context.")
        let contextHeader = "--- Relevant Context ---\n"
        let contextString = relevantChunks.map { $0.content }.joined(separator: "\n\n")
        let contextFooter = "\n--- End of Context ---"
        let assembledContext = contextHeader + contextString + contextFooter
        
        return "\(assembledContext)\n\nQuestion: \(userQuery)"
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

    // MARK: - Backend-Specific Logic
//    private func sendToAgent(conversationID: UUID, userQuery: String, files: [FileSystemItem], agentID: UUID) async throws -> ([ChatMessage], Error?) {
//        guard let selectedAgent = agentStore.agents.first(where: { $0.id == agentID }) else {
//            throw NSError(domain: "AgentConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "The selected agent profile could not be found."])
//        }
//        
//        guard let linkedIntegration = llmIntegrationStore.integrations.first(where: { $0.id == selectedAgent.linkedIntegrationID }) else {
//            throw NSError(domain: "AgentConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "The selected agent's LLM integration is not found."])
//        }
//
//        guard linkedIntegration.providerType == .ollama, let ollamaConfig = linkedIntegration.ollamaConfig else {
//            throw NSError(domain: "AgentConfigError", code: 400, userInfo: [NSLocalizedDescriptionKey: "The agent's linked LLM must be a configured Ollama provider."])
//        }
//
//        let llmSettings = OllamaLLMSettings(
//            baseUrl: ollamaConfig.baseURL,
//            modelName: ollamaConfig.modelName,
//            contextWindowSize: ollamaConfig.contextWindowSize ?? 4096
//        )
//
//        let rootAgentConfig = AgentConfig(
//            agentId: selectedAgent.id.uuidString,
//            parentId: nil,
//            roleObjective: userQuery,
//            tools: selectedAgent.tools.map { $0.id },
//            llmSettings: .ollama(llmSettings)
//        )
//
//        let payload = AgentOrchestrationRequest(
//            conversationId: conversationID.uuidString,
//            files: files.map { FileObject(uri: $0.url.absoluteString, name: $0.name) },
//            agentConfigs: [rootAgentConfig]
//        )
//        
//        let (messageContents, error) = try await self.agentService.sendMessage(payload: payload)
//        
//        if let error = error {
//            let chatError = ChatMessage(conversationId: conversationID, sender: .agent, content: .error(title: "Agent Error", details: error.localizedDescription))
//            return ([chatError], error)
//        }
//    
//        let messages = messageContents.map { ChatMessage(conversationId: conversationID, sender: .agent, content: $0) }
//        return (messages, nil)
//    }

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
        
        var ollamaHistory = history.map { message -> OllamaChatMessage in
            let role: String
            switch message.sender {
            case .user: role = "user"
            case .agent: role = "assistant"
            }
            return OllamaChatMessage(role: role, content: message.content.textContent ?? "")
        }
        
        ollamaHistory.append(OllamaChatMessage(role: "user", content: userQuery))

        do {
            let response = try await OllamaConnect.sendChatRequest(
                baseURL: ollamaConfig.baseURL,
                model: ollamaConfig.modelName,
                history: ollamaHistory
            )

            let agentMessageContent = MessageContent.markdownText(response.message.content)
            let agentMessage = ChatMessage(
                conversationId: conversationID,
                sender: .agent,
                content: agentMessageContent
            )

            return ([agentMessage], nil)

        } catch {
            logger.error("Error sending message to Ollama: \(error.localizedDescription)")
            return ([], error)
        }
    }

    /// **UPDATED for Step 2.2**
    /// This function now receives raw data from the `RemoteOrchestrationService` and is responsible
    /// for creating the final `ChatMessage` objects.
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
        
        // 1. Call the refactored service method that returns raw data instead of ChatMessage objects.
        let (responseText, responseImageData, newThreadID, error) = try await remoteOrchestrationService.sendMessage(
            conversationID: conversationID,
            userQuery: userQuery,
            history: history,
            openAIThreadID: openAIThreadID,
            integration: integration
        )

        // 2. Handle any errors returned by the service.
        if let error = error {
            let errorMessage = ChatMessage(conversationId: conversationID, sender: .agent, content: .error(title: "Remote API Error", details: error.localizedDescription))
            return ([errorMessage], newThreadID, error)
        }

        var responseMessages: [ChatMessage] = []

        // 3. Create a ChatMessage from the response text, if it exists.
        if let text = responseText {
            let agentMessage = ChatMessage(
                conversationId: conversationID,
                sender: .agent,
                content: .markdownText(text)
            )
            responseMessages.append(agentMessage)
        }

        // 4. Create a ChatMessage from the response image data, if it exists.
        if let imageData = responseImageData {
            let agentMessage = ChatMessage(
                conversationId: conversationID,
                sender: .agent,
                content: .image(url: nil, alt: userQuery, imageData: imageData)
            )
            responseMessages.append(agentMessage)
        }
        
        // 5. Handle the case where there is no content but also no error.
        if responseMessages.isEmpty && error == nil {
             let errorMessage = ChatMessage(conversationId: conversationID, sender: .agent, content: .error(title: "Empty Response", details: "The remote API returned an empty response."))
             responseMessages.append(errorMessage)
        }

        return (messages: responseMessages, newThreadID: newThreadID, error: nil)
    }
}
