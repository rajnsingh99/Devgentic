//
//  RemoteMirrorService.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import Combine
import os

/// Mirrors agent stream events to remote ChatOps transports.
///
/// When a message originates from a remote source (Telegram, Discord, etc.),
/// this service observes the resulting `ChatMessage` stream and mirrors
/// events (responses, HITL prompts, completion) back to the transport.
///
/// **Architecture**: The main app is the source of truth. This service is
/// a lightweight observer — it never drives execution, only mirrors output.
@MainActor
final class RemoteMirrorService: ObservableObject {

    private let logger = Logger(subsystem: "com.devgentic", category: "RemoteMirrorService")

    // MARK: - State

    /// Active remote sessions keyed by conversationID.
    private var remoteSessions: [UUID: RemoteSessionInfo] = [:]

    /// Tracks which HITL operationIDs have been mirrored to transport (prevents duplicates).
    private var mirroredOperations: Set<UUID> = []

    /// Maps operationID → transport message_id (for editing HITL messages after resolution).
    private var hitlMessageIDs: [UUID: String] = [:]

    /// Combine subscriptions for observing ChatMessage changes.
    private var streamSubscriptions: [UUID: AnyCancellable] = [:]

    /// Reference to ActiveStreamManager for observing new streams.
    private weak var activeStreamManager: ActiveStreamManager?

    /// Combine subscription for observing activeStreams changes.
    private var activeStreamsSubscription: AnyCancellable?

    /// Observers for HITL resolution notifications.
    private var permissionResolvedObserver: NSObjectProtocol?
    private var clarificationResolvedObserver: NSObjectProtocol?

    // MARK: - Init

    init(activeStreamManager: ActiveStreamManager) {
        self.activeStreamManager = activeStreamManager
        setupActiveStreamsObserver()
        setupHITLResolvedObservers()
    }

    deinit {
        if let obs = permissionResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = clarificationResolvedObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Session Registration

    /// Register a remote session for a conversation. Called when a remote message is submitted.
    func registerSession(conversationID: UUID, info: RemoteSessionInfo) {
        remoteSessions[conversationID] = info
        logger.info("[Mirror] Registered remote session for conversation \(conversationID) via \(info.source.rawValue).")
    }

    /// Unregister a remote session. Called on disconnect or explicit cleanup.
    func unregisterSession(conversationID: UUID) {
        remoteSessions.removeValue(forKey: conversationID)
        streamSubscriptions.removeValue(forKey: conversationID)
        logger.info("[Mirror] Unregistered remote session for conversation \(conversationID).")
    }

    // MARK: - HITL Response Routing (Transport → Agent)

    /// Called when a remote transport receives a tool approval/denial.
    func handleApproval(operationID: UUID, approved: Bool) async {
        await ExecutionSuspensionService.shared.resume(for: operationID, approved: approved)
    }

    /// Called when a remote transport receives a clarification response.
    func handleClarification(operationID: UUID, text: String) async {
        let response: String? = text.isEmpty ? nil : text
        await ExecutionSuspensionService.shared.resumeClarification(for: operationID, userInput: response)
    }

    // MARK: - Active Stream Observation

    /// Watches for new streams in conversations with active remote sessions.
    private func setupActiveStreamsObserver() {
        guard let asm = activeStreamManager else { return }

        activeStreamsSubscription = asm.$activeStreams
            .receive(on: RunLoop.main)
            .sink { [weak self] streams in
                guard let self else { return }
                for (messageID, message) in streams {
                    guard self.remoteSessions[message.conversationId] != nil else { continue }
                    guard self.streamSubscriptions[messageID] == nil else { continue }

                    // New stream for a remote conversation — start observing
                    self.observeMessage(message)
                }
            }
    }

    /// Subscribe to a ChatMessage's changes and mirror relevant events to the transport.
    private func observeMessage(_ message: ChatMessage) {
        let messageID = message.id
        let conversationID = message.conversationId

        streamSubscriptions[messageID] = message.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak message] _ in
                guard let self, let message else { return }
                // Defer to next runloop tick so @Published values are updated
                DispatchQueue.main.async {
                    Task { @MainActor in
                        await self.evaluateMessageState(message, conversationID: conversationID)
                    }
                }
            }

        logger.info("[Mirror] Started observing message \(messageID) for conversation \(conversationID).")
    }

    /// Evaluates current message state and mirrors events to the remote transport.
    private func evaluateMessageState(_ message: ChatMessage, conversationID: UUID) async {
        guard let session = remoteSessions[conversationID] else { return }

        // Mirror HITL tool confirmation
        if let confirmation = message.pendingToolConfirmation,
           !mirroredOperations.contains(confirmation.id) {
            mirroredOperations.insert(confirmation.id)
            do {
                let msgID = try await session.transport.sendHITLPrompt(
                    chatID: session.chatID,
                    operationID: confirmation.id,
                    type: .toolConfirmation(toolName: confirmation.toolName, params: confirmation.params)
                )
                hitlMessageIDs[confirmation.id] = msgID
                logger.info("[Mirror] Sent tool confirmation to \(session.source.rawValue) for operation \(confirmation.id).")
            } catch {
                logger.error("[Mirror] Failed to send tool confirmation: \(error.localizedDescription)")
            }
        }

        // Mirror HITL clarification
        if let clarification = message.pendingClarification,
           !mirroredOperations.contains(clarification.id) {
            mirroredOperations.insert(clarification.id)
            do {
                let msgID = try await session.transport.sendHITLPrompt(
                    chatID: session.chatID,
                    operationID: clarification.id,
                    type: .clarification(question: clarification.question)
                )
                hitlMessageIDs[clarification.id] = msgID
                logger.info("[Mirror] Sent clarification to \(session.source.rawValue) for operation \(clarification.id).")
            } catch {
                logger.error("[Mirror] Failed to send clarification: \(error.localizedDescription)")
            }
        }

        // Mirror final response (stream complete)
        if !message.isStreaming && message.agentState == .idle && message.sender == .agent {
            // Only send once — check if we've already mirrored the final content
            let responseKey = message.id
            guard !mirroredOperations.contains(responseKey) else { return }
            mirroredOperations.insert(responseKey)

            let responseText: String
            switch message.content {
            case .plainText(let text), .markdownText(let text):
                responseText = text
            case .codeBlock(_, let code):
                responseText = code
            default:
                responseText = "Response complete."
            }

            guard !responseText.isEmpty else { return }

            do {
                try await session.transport.sendChunkedMessage(chatID: session.chatID, text: responseText)
                logger.info("[Mirror] Sent full response to \(session.source.rawValue) for conversation \(conversationID).")
            } catch {
                logger.error("[Mirror] Failed to send response: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cross-Surface HITL Resolution

    /// When Mac UI resolves an HITL event, update the Telegram message to show it was handled.
    private func setupHITLResolvedObservers() {
        permissionResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPermissionResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let approved = notification.userInfo?[HITLResolvedKey.approved] as? Bool
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let approved,
                      let messageID = self.hitlMessageIDs[operationID],
                      let convID = conversationID,
                      let session = self.remoteSessions[convID] else { return }

                let statusText = approved
                    ? "✅ Tool approved (from Mac)."
                    : "❌ Tool denied (from Mac)."

                try? await session.transport.editMessage(chatID: session.chatID, messageID: messageID, newText: statusText)
                self.hitlMessageIDs.removeValue(forKey: operationID)
            }
        }

        clarificationResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlClarificationResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let messageID = self.hitlMessageIDs[operationID],
                      let convID = conversationID,
                      let session = self.remoteSessions[convID] else { return }

                try? await session.transport.editMessage(
                    chatID: session.chatID,
                    messageID: messageID,
                    newText: "✅ Clarification handled (from Mac)."
                )
                self.hitlMessageIDs.removeValue(forKey: operationID)
            }
        }
    }
}
