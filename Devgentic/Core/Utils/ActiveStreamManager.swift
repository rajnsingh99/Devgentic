//
//  ActiveStreamManager.swift
//  Devgentic
//
//  Created by Raj Singh on 19/08/25.
//

import Foundation
import Combine
import os


private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ActiveStreamManager")

@MainActor
class ActiveStreamManager: ObservableObject {

    @Published private(set) var activeStreams: [UUID: ChatMessage] = [:]
    
    // MARK: - Dependencies
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    
    private let persistenceService: CoreDataServiceProtocol
    private let fileProcessorService: FileProcessorService
    private let backendOrchestrationService: BackendOrchestrationService

    init(
        persistenceService: CoreDataServiceProtocol,
        fileProcessorService: FileProcessorService
    ) {
        self.persistenceService = persistenceService
        self.fileProcessorService = fileProcessorService
        self.backendOrchestrationService = BackendOrchestrationService(
            fileProcessorService: fileProcessorService
        )
        logger.info("ActiveStreamManager initialized.")
    }

    
    func startMessageStream(
        withConfig config: BackendRequestConfig,
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        files: [FileSystemItem],
        updating existingMessage: ChatMessage? = nil,
        onComplete: @escaping () -> Void
    ) -> ChatMessage {
        
        let agentMessage: ChatMessage
        let isRegeneration = existingMessage != nil

        if let messageToUpdate = existingMessage {
            agentMessage = messageToUpdate
            logger.notice("🚀 [STREAM_REGENERATE] Updating message \(agentMessage.id.uuidString) in conversation \(conversationID.uuidString).")
        } else {
            agentMessage = ChatMessage(
                conversationId: conversationID,
                sender: .agent,
                content: .markdownText(""),
                isStreaming: true,
                backendEntityId: config.profile.id
            )
            logger.notice("🚀 [STREAM_START] Created message \(agentMessage.id.uuidString) for conversation \(conversationID.uuidString).")
        }
        
        activeStreams[agentMessage.id] = agentMessage
        
        let streamTask = Task { [weak self] in
            do {
                let stream = self?.backendOrchestrationService.streamMessage(
                    withConfig: config,
                    conversationID: conversationID,
                    userQuery: userQuery,
                    history: history,
                    files: files,
                    context: TraceContext(profile: config.profile)
                )
                
                logger.info("👂 [STREAM_LISTEN] Now listening for tokens for message \(agentMessage.id.uuidString)...")
                var tokenCount = 0

                if let stream = stream {
                    for try await token in stream {
                        try Task.checkCancellation()
                        
                        tokenCount += 1
                        
                        if isRegeneration {
                            guard let agentResponse = agentMessage.agentResponse,
                                  agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) else {
                                logger.error("Logic error: Could not find variant to update during regeneration for message \(agentMessage.id.uuidString).")
                                break
                            }
                            var targetVariant = agentResponse.variants[agentResponse.selectedVariantIndex]
                            if var currentText = targetVariant.content.textContent {
                                currentText += token
                                targetVariant.content = .markdownText(currentText)
                                agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex] = targetVariant
                            }
                        } else {
                            // For new messages, update the legacy `content` and the first variant simultaneously.
                            if var currentText = agentMessage.content.textContent {
                                currentText += token
                                let newContent = MessageContent.markdownText(currentText)
                                agentMessage.content = newContent
                                agentMessage.agentResponse?.variants[0].content = newContent
                            }
                        }
                    }
                }
                
                logger.info("🏁 [STREAM_LOOP_END] Finished processing stream for message \(agentMessage.id.uuidString). Total tokens: \(tokenCount).")
                await self?.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
                
            } catch is CancellationError {
                logger.info("🛑 [STREAM_CANCELLED] Stream for message \(agentMessage.id.uuidString) was cancelled by the user.")
                await self?.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
            } catch {
                logger.error("❌ [STREAM_ERROR] Streaming failed for message \(agentMessage.id.uuidString): \(error.localizedDescription)")
                await self?.finalizeMessage(agentMessage, conversationID: conversationID, error: error)
            }
            
            await self?.removeTask(for: agentMessage.id)
            onComplete()
        }
        
        activeTasks[agentMessage.id] = streamTask
        
        return agentMessage
    }
    
    
    public func cancelStream(for messageId: UUID) {
        guard let taskToCancel = activeTasks[messageId] else {
            logger.warning("Attempted to cancel a stream for message ID \(messageId.uuidString), but no active task was found.")
            return
        }
        
        logger.info("Cancelling stream task for message ID: \(messageId.uuidString)")
        taskToCancel.cancel()
    }
    
    
    private func finalizeMessage(_ message: ChatMessage, conversationID: UUID, error: Error?) async {
        message.isStreaming = false
        
        if let error = error {
            let errorContent = MessageContent.error(title: "Response Error", details: error.localizedDescription)
            message.content = errorContent
            
            if let agentResponse = message.agentResponse,
               agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                message.agentResponse?.variants[agentResponse.selectedVariantIndex].content = errorContent
            }
        } else {
            if let currentAgentContent = message.currentAgentContent {
                message.content = currentAgentContent
            }
        }
        
        let finalContent = message.content.textContent ?? "[EMPTY]"
        logger.notice("💾 [STREAM_FINALIZE] Finalizing message \(message.id.uuidString). Final content length: \(finalContent.count).")
        
        if let targetEntity = persistenceService.getConversation(withId: conversationID) {
            await persistenceService.addMessage(message, to: targetEntity)
            logger.info("...Persistence successful for message \(message.id.uuidString).")
        } else {
            logger.error("...Could not find conversation entity \(conversationID.uuidString) to persist final message.")
        }
        
        activeStreams.removeValue(forKey: message.id)
        logger.info("...Stream for message \(message.id.uuidString) has finished. Removing from active manager.")
    }
    
    
    private func removeTask(for messageId: UUID) {
        if activeTasks.removeValue(forKey: messageId) != nil {
            logger.debug("Cleaned up and removed completed task for message ID: \(messageId.uuidString)")
        }
    }
}

