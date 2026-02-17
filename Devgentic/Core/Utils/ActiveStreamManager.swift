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
        
        // Ensure "Thinking" UI is visible at start
        agentMessage.agentState = .thinking
        agentMessage.thinkingHeadline = "Processing..."
        
        let streamTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                // Now that BackendOrchestrationService returns AgentStreamEvent, this assignment is valid.
                let stream = self.backendOrchestrationService.streamMessage(
                    withConfig: config,
                    conversationID: conversationID,
                    userQuery: userQuery,
                    history: history,
                    files: files,
                    context: TraceContext(profile: config.profile),
                    onTraceUpdate: { _ in } // Trace logs are handled by events now
                )
                
                logger.info("👂 [STREAM_LISTEN] Now listening for events for message \(agentMessage.id.uuidString)...")
                
                var tokenBuffer = ""
                var lastUpdateTime = Date()
                let updateInterval: TimeInterval = 0.1

                for try await event in stream {
                    try Task.checkCancellation()
                    
                    switch event {
                    case .thought(let thought):
                        // 1. Handle Thoughts (Update Headline + Append to History)
                        agentMessage.thinkingHeadline = thought
                        agentMessage.agentState = .thinking
                        agentMessage.thoughts.append(thought)
                        
                    case .toolCall(let name, _):
                        agentMessage.thinkingHeadline = "Using tool: \(name)"
                        agentMessage.agentState = .acting
                        
                    // [HITL] Phase 3: Handle Permission Requests
                    case .requestConfirmation(let toolName, let params):
                        agentMessage.thinkingHeadline = "Waiting for approval: \(toolName)"
                        agentMessage.agentState = .requestingPermission
                        
                        // Populate the Pending Confirmation Data for the UI
                        agentMessage.pendingToolConfirmation = PendingToolConfirmation(
                            toolName: toolName,
                            params: params
                        )
                        
                    case .toolOutput(let output):
                        // 2. Handle Artifacts (File lists, etc.)
                        agentMessage.agentState = .observing
                        agentMessage.artifacts.append(output)
                        agentMessage.thinkingHeadline = "Processed \(output.toolName)"
                        
                        // Clear pending confirmation if any (it's done now)
                        agentMessage.pendingToolConfirmation = nil
                        
                    case .content(let textChunk):
                        // 3. Handle Final Text (Buffered)
                        agentMessage.agentState = .finalizing
                        tokenBuffer += textChunk
                        
                        if -lastUpdateTime.timeIntervalSinceNow >= updateInterval || tokenBuffer.count > 50 {
                            self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)
                            tokenBuffer = ""
                            lastUpdateTime = Date()
                        }
                        
                    case .error(let errorMsg):
                        logger.error("Stream Error Event: \(errorMsg)")
                    }
                }
                
                // Flush remaining text tokens
                if !tokenBuffer.isEmpty {
                    self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)
                }
                
                logger.info("🏁 [STREAM_LOOP_END] Finished processing stream for message \(agentMessage.id.uuidString).")
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
                
            } catch is CancellationError {
                logger.info("🛑 [STREAM_CANCELLED] Stream for message \(agentMessage.id.uuidString) was cancelled.")
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: nil)
            } catch {
                logger.error("❌ [STREAM_ERROR] Streaming failed for message \(agentMessage.id.uuidString): \(error.localizedDescription)")
                await self.finalizeMessage(agentMessage, conversationID: conversationID, error: error)
            }
            
            await self.removeTask(for: agentMessage.id)
            onComplete()
        }
        
        activeTasks[agentMessage.id] = streamTask
        
        return agentMessage
    }
    
    private func updateMessageContent(_ agentMessage: ChatMessage, with newTextChunk: String, isRegeneration: Bool) {
        if isRegeneration {
            guard let agentResponse = agentMessage.agentResponse,
                  agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) else {
                return
            }
            var targetVariant = agentResponse.variants[agentResponse.selectedVariantIndex]
            if var currentText = targetVariant.content.textContent {
                currentText += newTextChunk
                targetVariant.content = .markdownText(currentText)
                agentMessage.agentResponse?.variants[agentResponse.selectedVariantIndex] = targetVariant
            }
        } else {
            if var currentText = agentMessage.content.textContent {
                currentText += newTextChunk
                let newContent = MessageContent.markdownText(currentText)
                agentMessage.content = newContent
                agentMessage.agentResponse?.variants[0].content = newContent
            }
        }
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
        message.thinkingHeadline = nil // Clear the headline
        message.agentState = .idle
        message.pendingToolConfirmation = nil // Clear any pending UI state
        
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
        
        // Persist final message
        if let targetEntity = persistenceService.getConversation(withId: conversationID) {
            await persistenceService.addMessage(message, to: targetEntity)
        }
        
        activeStreams.removeValue(forKey: message.id)
    }
    
    
    private func removeTask(for messageId: UUID) {
        if activeTasks.removeValue(forKey: messageId) != nil {
            logger.debug("Cleaned up and removed completed task for message ID: \(messageId.uuidString)")
        }
    }
}
