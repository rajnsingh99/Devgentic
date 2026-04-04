//
//  RemoteMirrorService.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
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
final class RemoteMirrorService: ActiveStreamMirrorDelegate {

    private let logger = Logger(subsystem: "com.devgentic", category: "RemoteMirrorService")

    // MARK: - State

    /// Active remote sessions keyed by conversationID.
    private var remoteSessions: [UUID: RemoteSessionInfo] = [:]

    /// Tracks which HITL operationIDs have been mirrored to transport (prevents duplicates).
    private var mirroredOperations: Set<UUID> = []

    /// Maps operationID → transport message_id (for editing HITL messages after resolution).
    private var hitlMessageIDs: [UUID: String] = [:]

    /// Messages currently being observed via withObservationTracking.
    private var observedMessageIDs: Set<UUID> = []

    /// Reference to ActiveStreamManager (set as delegate).
    private weak var activeStreamManager: ActiveStreamManager?

    /// Observers for HITL resolution notifications.
    private var permissionResolvedObserver: NSObjectProtocol?
    private var clarificationResolvedObserver: NSObjectProtocol?
    private var planReviewResolvedObserver: NSObjectProtocol?

    // MARK: - Init

    init(activeStreamManager: ActiveStreamManager) {
        self.activeStreamManager = activeStreamManager
        activeStreamManager.mirrorDelegate = self
        setupHITLResolvedObservers()
    }

    deinit {
        if let obs = permissionResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = clarificationResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = planReviewResolvedObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - ActiveStreamMirrorDelegate

    func activeStreamManager(_ manager: ActiveStreamManager, didStartStream message: ChatMessage, for conversationID: UUID) {
        guard remoteSessions[conversationID] != nil else { return }
        guard !observedMessageIDs.contains(message.id) else { return }
        observeMessage(message)
    }

    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage) {
        observedMessageIDs.remove(message.id)
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

    /// Called when a remote transport receives a plan review response.
    /// Plan review editing is only available on the Mac UI — remote transports
    /// can only approve the plan as-is or reject it.
    func handlePlanReview(operationID: UUID, approved: Bool, subtasks: [SubTask]?) async {
        let editedPlan = approved ? subtasks : nil
        await ExecutionSuspensionService.shared.resumePlanReview(for: operationID, editedPlan: editedPlan)
    }

    // MARK: - Message Observation

    /// Observe a ChatMessage using withObservationTracking and mirror relevant events.
    private func observeMessage(_ message: ChatMessage) {
        let messageID = message.id
        let conversationID = message.conversationId
        observedMessageIDs.insert(messageID)

        func observe() {
            withObservationTracking {
                // Touch observable properties to register tracking
                _ = message.pendingInteraction
                _ = message.isStreaming
                _ = message.agentState
                _ = message.content
            } onChange: {
                Task { @MainActor [weak self, weak message] in
                    guard let self, let message else { return }
                    guard self.observedMessageIDs.contains(messageID) else { return }
                    await self.evaluateMessageState(message, conversationID: conversationID)
                    observe()
                }
            }
        }
        observe()

        logger.info("[Mirror] Started observing message \(messageID) for conversation \(conversationID).")
    }

    /// Evaluates current message state and mirrors events to the remote transport.
    private func evaluateMessageState(_ message: ChatMessage, conversationID: UUID) async {
        guard let session = remoteSessions[conversationID] else { return }

        // Mirror HITL interaction (unified)
        if let interaction = message.pendingInteraction,
           !mirroredOperations.contains(interaction.id) {
            mirroredOperations.insert(interaction.id)

            let hitlType: HITLType
            switch interaction {
            case .toolConfirmation(let c):
                hitlType = .toolConfirmation(toolName: c.toolName, params: c.params)
            case .clarification(let c):
                hitlType = .clarification(question: c.question)
            case .planReview(let p):
                hitlType = .planReview(subtaskDescriptions: p.subtasks.map(\.description))
            }

            do {
                let msgID = try await session.transport.sendHITLPrompt(
                    chatID: session.chatID,
                    operationID: interaction.id,
                    type: hitlType
                )
                hitlMessageIDs[interaction.id] = msgID
                logger.info("[Mirror] Sent HITL prompt to \(session.source.rawValue) for operation \(interaction.id).")
            } catch {
                logger.error("[Mirror] Failed to send HITL prompt: \(error.localizedDescription)")
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

        planReviewResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPlanReviewResolved,
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
                    newText: "✅ Plan reviewed (from Mac)."
                )
                self.hitlMessageIDs.removeValue(forKey: operationID)
            }
        }
    }
}
