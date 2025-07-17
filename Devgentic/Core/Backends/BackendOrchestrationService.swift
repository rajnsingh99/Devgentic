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

    // MARK: - Derived State
    /// The active backend, derived reactively from the stores.
    @Published private(set) var activeBackend: BackendType = .none

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
        
        setupBindings()
        logger.info("BackendOrchestrationService initialized and bindings are set up.")
    }
    
    private func setupBindings() {
        agentStore.$selectedAgentID
            .combineLatest(llmIntegrationStore.$selectedIntegrationID, llmIntegrationStore.$integrations)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agentID, integrationID, integrations in
                guard let self = self else { return }

                if agentID != nil {
                    if self.activeBackend != .agent {
                        self.activeBackend = .agent
                        logger.info("BackendOrchestrationService: Detected backend switch to Agent.")
                    }
                } else if let intID = integrationID {
                    if let integration = integrations.first(where: { $0.id == intID }) {
                        let newBackend: BackendType = (integration.providerType == .ollama) ? .ollama : .remote
                        if self.activeBackend != newBackend {
                            self.activeBackend = newBackend
                            logger.info("BackendOrchestrationService: Detected backend switch to \(self.activeBackend.rawValue).")
                        }
                    } else {
                        if self.activeBackend != .none {
                            self.activeBackend = .none
                            logger.warning("BackendOrchestrationService: Selected integration ID \(intID.uuidString) not found in store. No backend active.")
                        }
                    }
                } else {
                    if self.activeBackend != .none {
                        self.activeBackend = .none
                        logger.info("BackendOrchestrationService: No backend selected.")
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Streaming Message Logic (NEW)
    
    /// The primary method for streaming a response from the appropriate backend.
    func streamMessage(
        conversationID: UUID,
        userQuery: String,
        files: [FileSystemItem],
        context: TraceContext // <-- Add context parameter
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                logger.debug("Backend Orchestration: Routing to \(self.activeBackend.rawValue). traceID: \(context.traceID)")
                
                // --- RAG Instrumentation (Re-enabled) ---
                let ragContext = context.newSpan()
                logger.info("RAG: Augmentation Started. traceID: \(ragContext.traceID), spanID: \(ragContext.spanID)")
                let ragStartTime = Date()
                
                let augmentedQuery = await self.augmentQueryWithContext(userQuery: userQuery)
                
                let ragDuration = Date().timeIntervalSince(ragStartTime)
                await MetricsManager.shared.record(duration: ragDuration, for: "rag_duration", context: ragContext)
                logger.info("RAG: Augmentation Finished. traceID: \(ragContext.traceID), spanID: \(ragContext.spanID)")
                // --- End RAG Instrumentation ---

                let conversationEntity = self.persistenceService.getConversation(withId: conversationID)
                let conversation = conversationEntity?.toConversationStruct()
                
                let conversationHistory = (conversation?.messages ?? []).filter { message in
                    if case .error = message.content { return false }
                    return true
                }
                
                var finalUserQuery = augmentedQuery
                if self.activeBackend == .remote, !files.isEmpty {
                    let fileContext = self.assembleTextFileContent(for: files)
                    if !fileContext.isEmpty {
                        finalUserQuery = fileContext + "\n\n" + finalUserQuery
                    }
                }
                
                do {
                    switch self.activeBackend {
                    case .remote:
                        guard let integrationID = self.llmIntegrationStore.selectedIntegrationID,
                              let integration = self.llmIntegrationStore.integrations.first(where: { $0.id == integrationID }) else {
                            throw NSError(domain: "RemoteConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Selected remote integration not found."])
                        }
                        
                        let stream = self.remoteOrchestrationService.streamMessage(
                            conversationID: conversationID,
                            userQuery: finalUserQuery,
                            history: conversationHistory,
                            openAIThreadID: conversation?.openAIThreadID,
                            integration: integration,
                            context: context // <-- Pass context down
                        )
                        
                        for try await token in stream {
                            continuation.yield(token)
                        }
                        continuation.finish()

                    case .agent, .ollama:
                        throw NSError(domain: "StreamingError", code: 501, userInfo: [NSLocalizedDescriptionKey: "Streaming is not yet supported for the \(self.activeBackend.rawValue) backend."])
                        
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
    
    /// The primary method for sending a user's query to the appropriate backend, augmented with RAG context.
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        files: [FileSystemItem]
    ) async -> ([ChatMessage], String?) {
        
        logger.debug("Sending message with detected backend: \(self.activeBackend.rawValue)")
        
        let augmentedQuery = await augmentQueryWithContext(userQuery: userQuery)
        
        let conversationEntity = persistenceService.getConversation(withId: conversationID)
        let conversation = conversationEntity?.toConversationStruct()
        
        let conversationHistory = (conversation?.messages ?? []).filter { message in
            if case .error = message.content { return false }
            return true
        }
        
        var finalUserQuery = augmentedQuery
        
        if activeBackend == .remote, !files.isEmpty {
            let fileContext = assembleTextFileContent(for: files)
            if !fileContext.isEmpty {
                finalUserQuery = fileContext + "\n\n" + finalUserQuery
                logger.info("Assembled text file content and prepended to the user query for remote backend.")
            }
        }
        
        do {
            switch activeBackend {
            case .agent:
                guard let agentID = agentStore.selectedAgentID else {
                    return ([], "No agent selected for the Agent backend.")
                }
                let (messages, error) = try await sendToAgent(conversationID: conversationID, userQuery: finalUserQuery, files: files, agentID: agentID)
                return (messages, error?.localizedDescription)
                
            case .ollama:
                guard let integrationID = llmIntegrationStore.selectedIntegrationID else {
                    return ([], "No Ollama integration selected.")
                }
                let (messages, error) = try await sendToOllama(conversationID: conversationID, userQuery: finalUserQuery, files: files, integrationID: integrationID)
                return (messages, error?.localizedDescription)

            case .remote:
                 guard let integrationID = llmIntegrationStore.selectedIntegrationID else {
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
                    logger.info("Saved new OpenAI thread ID \(newThreadID) to conversation \(conversationID.uuidString).")
                }
                
                return (messages, error?.localizedDescription)

            case .none:
                return ([], "No backend has been selected. Please select a backend from the input area.")
            }
        } catch {
            let userFriendlyError = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: self.activeBackend)
            return ([], userFriendlyError)
        }
    }
    
    // MARK: - RAG Context Retrieval
    
    private func augmentQueryWithContext(userQuery: String) async -> String {
        guard let queryEmbedding = await embeddingService.generateEmbedding(for: userQuery) else {
            logger.warning("Could not generate embedding for query. Proceeding without RAG context.")
            return userQuery
        }
        
        let relevantChunks = vectorStoreService.findNearest(to: queryEmbedding, limit: 3)
        
        guard !relevantChunks.isEmpty else {
            logger.info("No relevant context found in vector store for the query.")
            return userQuery
        }
        
        let contextHeader = "--- Relevant Context ---\n"
        let contextString = relevantChunks.map { $0.content }.joined(separator: "\n\n")
        let contextFooter = "\n--- End of Context ---"
        
        let assembledContext = contextHeader + contextString + contextFooter
        
        logger.info("Augmenting query with \(relevantChunks.count) chunks of context.")
        
        return "\(assembledContext)\n\nQuestion: \(userQuery)"
    }
    
    // MARK: - File Content Assembly
    
    private func assembleTextFileContent(for files: [FileSystemItem]) -> String {
        var assembledContent = ""
        
        for file in files {
            let mimeType = fileProcessorService.getFileMimeType(for: file.url)
            
            if fileProcessorService.isTextFile(mimeType: mimeType, url: file.url) {
                if let content = fileProcessorService.readFileContent(for: file.url) {
                    logger.debug("Reading content for file: \(file.name)")
                    assembledContent += "\n\n--- Start of file: \(file.name) ---\n"
                    assembledContent += content
                    assembledContent += "\n--- End of file: \(file.name) ---"
                } else {
                    logger.warning("Could not read content for text file: \(file.name)")
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

    private func sendToOllama(conversationID: UUID, userQuery: String, files: [FileSystemItem], integrationID: UUID) async throws -> ([ChatMessage], Error?) {
        guard let integration = llmIntegrationStore.integrations.first(where: { $0.id == integrationID && $0.providerType == .ollama }) else {
             throw NSError(domain: "OllamaConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Selected Ollama integration not found."])
        }
        
        let errorMessage = "Sending messages directly to the Ollama backend is not yet fully implemented in this service."
        let errorContent = MessageContent.error(title: "Not Implemented", details: errorMessage)
        let chatMessage = ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)
        return ([chatMessage], nil)
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
