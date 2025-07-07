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

/// This class is the central dispatcher for all LLM-related communications.
/// It now reactively determines the active backend by observing the data stores.
@MainActor
class BackendOrchestrationService: ObservableObject {

    // MARK: - Dependencies
    private let agentService: AgentService
    private let ollamaService: OllamaService // Using singleton
    private let remoteOrchestrationService: RemoteOrchestrationService
    private let agentStore: AgentStore
    private let llmIntegrationStore: LLMIntegrationStore
    
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Derived State
    /// The active backend, derived reactively from the stores. This is the single source of truth for this service.
    @Published private(set) var activeBackend: BackendType = .none

    // MARK: - Initialization
    init(agentStore: AgentStore, llmIntegrationStore: LLMIntegrationStore) {
        self.agentStore = agentStore
        self.llmIntegrationStore = llmIntegrationStore
        
        self.agentService = AgentService()
        self.ollamaService = OllamaService.shared
        self.remoteOrchestrationService = RemoteOrchestrationService()
        
        setupBindings()
        logger.info("BackendOrchestrationService initialized and bindings are set up.")
    }
    
    /// Sets up Combine pipelines to react to changes in the data stores and update the active backend.
    private func setupBindings() {
        agentStore.$selectedAgentID
            .combineLatest(llmIntegrationStore.$selectedIntegrationID, llmIntegrationStore.$integrations)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agentID, integrationID, integrations in
                guard let self = self else { return }

                if agentID != nil {
                    // If an agent is selected, it's the active backend.
                    if self.activeBackend != .agent {
                        self.activeBackend = .agent
                        logger.info("BackendOrchestrationService: Detected backend switch to Agent.")
                    }
                } else if let intID = integrationID {
                    // If an integration is selected, find it to determine the backend type.
                    if let integration = integrations.first(where: { $0.id == intID }) {
                        // FIXED: Explicitly define the type of newBackend to help the compiler infer the enum cases.
                        let newBackend: BackendType = (integration.providerType == .ollama) ? .ollama : .remote
                        if self.activeBackend != newBackend {
                            self.activeBackend = newBackend
                            logger.info("BackendOrchestrationService: Detected backend switch to \(self.activeBackend.rawValue).")
                        }
                    } else {
                        // The selected ID doesn't exist in the store, so no backend is active.
                        if self.activeBackend != .none {
                            self.activeBackend = .none
                            logger.warning("BackendOrchestrationService: Selected integration ID \(intID.uuidString) not found in store. No backend active.")
                        }
                    }
                } else {
                    // If neither an agent nor an integration is selected, there's no active backend.
                    if self.activeBackend != .none {
                        self.activeBackend = .none
                        logger.info("BackendOrchestrationService: No backend selected.")
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Main Sending Logic
    /// The primary method for sending a user's query to the appropriate backend.
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        files: [FileSystemItem]
    ) async -> ([ChatMessage], String?) {
        
        logger.debug("Sending message with detected backend: \(self.activeBackend.rawValue)")
        
        do {
            switch activeBackend {
            case .agent:
                guard let agentID = agentStore.selectedAgentID else {
                    return ([], "No agent selected for the Agent backend.")
                }
                let (messages, error) = try await sendToAgent(conversationID: conversationID, userQuery: userQuery, files: files, agentID: agentID)
                return (messages, error?.localizedDescription)
                
            case .ollama:
                guard let integrationID = llmIntegrationStore.selectedIntegrationID else {
                    return ([], "No Ollama integration selected.")
                }
                let (messages, error) = try await sendToOllama(conversationID: conversationID, userQuery: userQuery, files: files, integrationID: integrationID)
                return (messages, error?.localizedDescription)

            case .remote:
                 guard let integrationID = llmIntegrationStore.selectedIntegrationID else {
                    return ([], "No remote integration selected.")
                }
                let (messages, error) = try await sendToRemote(conversationID: conversationID, userQuery: userQuery, files: files, integrationID: integrationID)
                return (messages, error?.localizedDescription)

            case .none:
                return ([], "No backend has been selected. Please select a backend from the input area.")
            }
        } catch {
            let userFriendlyError = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: self.activeBackend)
            return ([], userFriendlyError)
        }
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
        
        let errorMessage = "Sending messages directly to the Ollama backend is not yet implemented in this service."
//        logger.warning(errorMessage)
        let errorContent = MessageContent.error(title: "Not Implemented", details: errorMessage)
        let chatMessage = ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)
        return ([chatMessage], nil)
    }

    private func sendToRemote(conversationID: UUID, userQuery: String, files: [FileSystemItem], integrationID: UUID) async throws -> ([ChatMessage], Error?) {
         guard let integration = llmIntegrationStore.integrations.first(where: { $0.id == integrationID && $0.providerType == .remote }) else {
             throw NSError(domain: "RemoteConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Selected remote integration not found."])
        }
        
        return try await remoteOrchestrationService.sendMessage(conversationID: conversationID, userQuery: userQuery, files: files, integration: integration)
    }
}
