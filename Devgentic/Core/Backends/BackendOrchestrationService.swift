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
                logger.info("ORCHESTRATION START (Stream): Routing with profile '\(config.profile.displayName)' (\(config.profile.profileType.rawValue)). TraceID: \(context.traceID)")
                
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
                    // New routing logic based on ProfileType
                    switch config.profile.profileType {
                    
                    case .bot:
                        guard case .bot(let llmConfig) = config.profile.details else {
                            throw NSError(domain: "ProfileError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not extract bot configuration from profile."])
                        }
                        
                        // Nested switch for the API provider
                        switch llmConfig.apiProvider {
                        
                        case .ollama:
                            guard let baseURL = llmConfig.baseURL else {
                                throw NSError(domain: "OllamaConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Ollama base URL is missing in the profile."])
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
                            
                            logger.info("Initiating stream to Ollama with model \(llmConfig.modelName). History count: \(ollamaHistory.count).")

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
                            // Defer to the remote orchestration service
                            let stream = self.remoteOrchestrationService.streamMessage(
                                conversationID: conversationID,
                                userQuery: finalUserQuery,
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
                        throw NSError(domain: "NotImplemented", code: 501, userInfo: [NSLocalizedDescriptionKey: "Streaming is not yet supported for Agent profiles."])
                        
                    case .workflow:
                        throw NSError(domain: "NotImplemented", code: 501, userInfo: [NSLocalizedDescriptionKey: "Streaming is not yet supported for Workflow profiles."])
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

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
}
