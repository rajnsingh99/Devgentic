//
//  ActiveStreamManager.swift
//  Devgentic
//
//  Created by Raj Singh on 19/08/25.
//

import Foundation
import Combine
import AppKit
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

        // Defer initial state mutations to the next run loop tick.
        // This prevents "Modifying state during view update" warnings when the returned
        // ChatMessage is immediately assigned to SwiftUI state within a view update cycle.
        Task { @MainActor in
            agentMessage.agentState = .thinking(.reasoning)
            agentMessage.thinkingHeadline = "Processing..."
        }
        
        let streamTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                let traceContext = TraceContext(profile: config.profile, messageID: agentMessage.id)
                agentMessage.traceID = traceContext.traceID
                
                Task {
                    await TraceRecorder.shared.beginTrace(
                        context: traceContext,
                        conversationID: conversationID,
                        messageID: agentMessage.id,
                        modelName: nil
                    )
                }
                
                let stream = self.backendOrchestrationService.streamMessage(
                    withConfig: config,
                    conversationID: conversationID,
                    userQuery: userQuery,
                    history: history,
                    files: files,
                    context: traceContext,
                    onTraceUpdate: { _ in } // Trace logs are handled by events now
                )
                
                logger.info("👂 [STREAM_LISTEN] Now listening for events for message \(agentMessage.id.uuidString)...")
                
                var tokenBuffer = ""
                var lastUpdateTime = Date()
                var tokensReceivedInWindow = 0
                var adaptiveInterval: TimeInterval = 0.1 // Start with default

                for try await event in stream {
                    try Task.checkCancellation()

                    switch event {
                    case .thought(let thoughtText, let id):
                        // 1. Handle Thoughts (Update Headline + Append to History using structured ID)
                        agentMessage.thinkingHeadline = thoughtText
                        agentMessage.agentState = .thinking(.reasoning)
                        agentMessage.timelineEvents.append(.thought(id: id, text: thoughtText))
                        
                    case .toolCall(let name, let params):
                        agentMessage.thinkingHeadline = "Using tool: \(name)"
                        agentMessage.agentState = .acting(.tool(name: name))
                        let callId = UUID()
                        agentMessage.timelineEvents.append(.toolExecution(id: callId, name: name, params: params, output: nil, isSuccess: nil, isExecuting: true))
                        
                    // [HITL] Phase 3: Handle Permission Requests
                    case .requestConfirmation(let toolName, let params):
                        agentMessage.thinkingHeadline = "Waiting for approval: \(toolName)"
                        agentMessage.agentState = .interaction(.permission(toolName: toolName))
                        
                        // Populate the Pending Confirmation Data for the UI
                        agentMessage.pendingToolConfirmation = PendingToolConfirmation(
                            toolName: toolName,
                            params: params
                        )
                        
                    // [ASK_USER] Handle Clarification Requests
                    case .requestClarification(let question):
                        agentMessage.thinkingHeadline = "Asking you a question..."
                        agentMessage.agentState = .interaction(.clarification)

                        // Populate the Pending Clarification Data for the UI
                        agentMessage.pendingClarification = PendingClarification(
                            question: question
                        )

                    case .toolOutput(let output):
                        // 2. Handle Artifacts (File lists, etc.)
                        agentMessage.agentState = .thinking(.reflecting)
                        agentMessage.thinkingHeadline = "Processed \(output.toolName)"

                        // Update timeline event
                        if let index = agentMessage.timelineEvents.lastIndex(where: {
                            if case .toolExecution(_, let name, _, _, _, let isExecuting) = $0 {
                                return name == output.toolName && isExecuting
                            }
                            return false
                        }) {
                            if case .toolExecution(let id, let name, let params, _, _, _) = agentMessage.timelineEvents[index] {
                                agentMessage.timelineEvents[index] = .toolExecution(
                                    id: id,
                                    name: name,
                                    params: params,
                                    output: output.output,
                                    isSuccess: output.isSuccess,
                                    isExecuting: false
                                )
                            }
                        }

                        // Clear only the specific pending interaction that matches this tool output.
                        // Blanket clearing both flags caused a deadlock when interactive tools
                        // ran sequentially — completing one tool would erase the other's pending UI.
                        if output.toolName == "ask_user" {
                            agentMessage.pendingClarification = nil
                        }
                        if let pending = agentMessage.pendingToolConfirmation, pending.toolName == output.toolName {
                            agentMessage.pendingToolConfirmation = nil
                        }
                        
                    case .content(let textChunk):
                        // 3. Handle Final Text (Buffered)
                        if agentMessage.agentState != .thinking(.finalizing) {
                            agentMessage.agentState = .thinking(.finalizing)
                            agentMessage.thinkingHeadline = "Finalizing..."
                        }
                        
                        tokenBuffer += textChunk
                        tokensReceivedInWindow += textChunk.count

                        let elapsed = -lastUpdateTime.timeIntervalSinceNow
                        if elapsed >= adaptiveInterval || tokenBuffer.count > 50 {
                            self.updateMessageContent(agentMessage, with: tokenBuffer, isRegeneration: isRegeneration)

                            // Adapt interval based on token throughput:
                            // High throughput (fast local models) → shorter interval (0.05s) for smooth streaming
                            // Low throughput (slow remote APIs)  → longer interval (0.2s) to reduce UI churn
                            if elapsed > 0 {
                                let charsPerSecond = Double(tokensReceivedInWindow) / elapsed
                                if charsPerSecond > 500 {
                                    adaptiveInterval = 0.05   // Fast: flush frequently for smooth UX
                                } else if charsPerSecond > 100 {
                                    adaptiveInterval = 0.1    // Normal: balanced default
                                } else {
                                    adaptiveInterval = 0.2    // Slow: batch more to reduce rerenders
                                }
                            }

                            tokenBuffer = ""
                            tokensReceivedInWindow = 0
                            lastUpdateTime = Date()
                        }
                        
                    case .error(let errorMsg):
                        logger.error("Stream Error Event: \(errorMsg)")

                    // MARK: Workflow Orchestration Events
                    case .workflowNodeStarted(_, let profileName, let idx, let total):
                        agentMessage.thinkingHeadline = "Running \(profileName) (\(idx)/\(total))..."
                        agentMessage.agentState = .acting(.subtask(current: idx, total: total))

                    case .workflowNodeCompleted(_, let profileName, let summary):
                        agentMessage.thinkingHeadline = "\(profileName) completed"
                        let completedId = UUID()
                        agentMessage.timelineEvents.append(.thought(id: completedId, text: "✅ \(profileName): \(summary)"))

                    case .workflowNodeFailed(_, let profileName, let error):
                        agentMessage.thinkingHeadline = "\(profileName) failed"
                        let failedId = UUID()
                        agentMessage.timelineEvents.append(.thought(id: failedId, text: "❌ \(profileName): \(error)"))

                    case .workflowProgress(let completed, let total):
                        agentMessage.thinkingHeadline = "Workflow progress: \(completed)/\(total)"

                    // MARK: Multimodal Events
                    case .mediaProgress(let toolName, let percent, let status):
                        agentMessage.thinkingHeadline = "\(toolName): \(status) (\(Int(percent * 100))%)"

                    case .artifactProduced(let artifact):
                        agentMessage.timelineEvents.append(.mediaGeneration(
                            id: UUID(),
                            toolName: artifact.label ?? artifact.kind.rawValue,
                            artifact: artifact,
                            isComplete: true
                        ))
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
            
            self.removeTask(for: agentMessage.id)
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
        
        if let traceID = message.traceID {
            let traceStatus: TraceStatus = error != nil ? .error : .completed
            await TraceRecorder.shared.endTrace(traceID: traceID, status: traceStatus, error: error?.localizedDescription)
        }
        
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
        
        // [RAG UPGRADE] Event-Driven Vectorization
        // Fire-and-forget: Index the final message into the vector database without blocking the UI.
        Task.detached(priority: .background) {
            // Brief pause to ensure UI settles and CoreData write completes
            try? await Task.sleep(nanoseconds: 500_000_000)
            await RAGIndexingService.shared.indexSingleMessage(message)
        }
        
        activeStreams.removeValue(forKey: message.id)

        // Dispatch notification if app is in background
        let notifConversationID = conversationID
        let hasError = error != nil
        let summaryText: String = {
            switch message.content {
            case .plainText(let text), .markdownText(let text):
                return String(text.prefix(100))
            default:
                return hasError ? "An error occurred." : "Response complete."
            }
        }()

        Task.detached(priority: .utility) {
            let isAppActive = await MainActor.run { NSApp.isActive }
            guard !isAppActive else { return }

            let config = await NotificationConfiguration.shared
            guard await config.isNotificationEnabled(for: notifConversationID) else { return }

            let payload = AppNotificationPayload(
                title: hasError ? "Query Failed" : "Query Completed",
                body: summaryText,
                conversationID: notifConversationID
            )
            await NotificationDispatcher.shared.dispatch(payload)
        }
    }
    
    
    private func removeTask(for messageId: UUID) {
        if activeTasks.removeValue(forKey: messageId) != nil {
            logger.debug("Cleaned up and removed completed task for message ID: \(messageId.uuidString)")
        }
    }
}
