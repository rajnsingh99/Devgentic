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
    private var gateResolvedObserver: NSObjectProtocol?

    // MARK: - Init

    init(activeStreamManager: ActiveStreamManager) {
        self.activeStreamManager = activeStreamManager
        activeStreamManager.addMirrorDelegate(self)   // [D2] multicast — all active transports mirror
        setupHITLResolvedObservers()
    }

    deinit {
        if let obs = permissionResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = clarificationResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = planReviewResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = gateResolvedObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - ActiveStreamMirrorDelegate

    func activeStreamManager(_ manager: ActiveStreamManager, didStartStream message: ChatMessage, for conversationID: UUID) {
        guard remoteSessions[conversationID] != nil else { return }
        guard !observedMessageIDs.contains(message.id) else { return }
        observeMessage(message)
    }

    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage) {
        observedMessageIDs.remove(message.id)
        // [HITL/P5] Drop the final-response send-once key so the dedup Set doesn't grow unbounded.
        mirroredOperations.remove(message.id)
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

    /// [D2] Detaches this service when its owning transport stops: removes it from the stream manager's
    /// multicast and drops all sessions, so a stopped transport no longer mirrors Mac-UI activity back
    /// out (the bridge then nils its strong ref, letting the service deallocate). Without this, a stopped
    /// transport with a lingering session kept pushing responses to the remote chat.
    func teardown() {
        activeStreamManager?.removeMirrorDelegate(self)
        remoteSessions.removeAll()
        logger.info("[Mirror] Torn down — detached from stream manager, sessions cleared.")
    }

    // MARK: - HITL Response Routing (Transport → Agent)

    /// Called when a remote transport receives an approve/deny button tap. [D1] KIND-AWARE: the same
    /// approve/deny affordance can resolve a tool confirmation OR a plan review (each parks in a
    /// different continuation), so dispatch by the pending HITL's kind. Without this, a remote approve
    /// of a plan review hit the (empty) permission continuation and the agent stayed parked forever.
    func handleApproval(operationID: UUID, approved: Bool) async {
        let kind = activeStreamManager?.interactionCenter?.item(withID: operationID)?.kind
        switch kind {
        case .planReview(let p):
            await ExecutionSuspensionService.shared.resumePlanReview(for: operationID, editedPlan: approved ? p.subtasks : nil)
        case .gate:
            // Gates resolve only via their per-option buttons (handleGate), never a bare approve/deny.
            // If one somehow arrives here, do NOT guess an option (picking options.first could route to a
            // destructive branch for orderings like ["Reject","Approve"]) — log and leave it.
            logger.warning("[Mirror] Ignoring approve/deny for gate \(operationID) — gates resolve via option buttons.")
        case .toolConfirmation, .clarification, .none:
            await ExecutionSuspensionService.shared.resume(for: operationID, approved: approved)
        }
    }

    /// Called when a remote transport receives a clarification response.
    func handleClarification(operationID: UUID, text: String) async {
        let response: String? = text.isEmpty ? nil : text
        await ExecutionSuspensionService.shared.resumeClarification(for: operationID, userInput: response)
    }

    // (handlePlanReview removed — D1's kind-aware `handleApproval` now routes a remote plan-review
    // approve/reject straight to resumePlanReview; this duplicate had no callers. H1 cleanup.)

    /// [D1] Called when a remote transport receives a workflow Gate option tap. Maps the button's option
    /// INDEX back to its label (via the InteractionCenter) and resolves the gate, matching the Mac UI's
    /// `resumeGate(chosenOption:)`. A stale/unknown index cancels the gate (nil) rather than leaving it parked.
    func handleGate(operationID: UUID, optionIndex: Int) async {
        guard case .gate(let g)? = activeStreamManager?.interactionCenter?.item(withID: operationID)?.kind,
              g.options.indices.contains(optionIndex) else {
            await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: nil)
            return
        }
        await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: g.options[optionIndex])
    }

    // MARK: - Message Observation

    /// Observe a ChatMessage using withObservationTracking and mirror relevant events.
    private func observeMessage(_ message: ChatMessage) {
        let messageID = message.id
        let conversationID = message.conversationId
        observedMessageIDs.insert(messageID)

        func observe() {
            withObservationTracking {
                // [HITL/P5] Track the unified InteractionCenter queue (single source of truth)
                // instead of the retired per-message pendingInteraction container.
                _ = self.activeStreamManager?.interactionCenter?.pending
                _ = message.isStreaming
                _ = message.agentState
                _ = message.content
            } onChange: {
                Task { @MainActor [weak self, weak message] in
                    guard let self, let message else { return }
                    guard self.observedMessageIDs.contains(messageID) else { return }
                    // [HITL/P5] Re-arm tracking BEFORE the async mirror send so a HITL enqueued
                    // during the send window (e.g. a second parallel workflow node parking for input)
                    // is still observed — withObservationTracking is one-shot, and the dedup in
                    // evaluateMessageState makes the extra pass harmless.
                    self.observeMessage(message)
                    await self.evaluateMessageState(message, conversationID: conversationID)
                }
            }
        }
        observe()

        logger.info("[Mirror] Started observing message \(messageID) for conversation \(conversationID).")
    }

    /// Evaluates current message state and mirrors events to the remote transport.
    private func evaluateMessageState(_ message: ChatMessage, conversationID: UUID) async {
        guard let session = remoteSessions[conversationID] else { return }

        // [HITL/P5] Mirror HITL request(s) from the unified InteractionCenter (single source of
        // truth). A workflow run can have several nodes awaiting at once, so mirror every
        // un-mirrored item — this also makes WORKFLOW HITL remotely actionable for the first time
        // (the legacy per-message container never carried workflow requests).
        let pendingHITLs = activeStreamManager?.interactionCenter?.items(for: conversationID) ?? []
        for pending in pendingHITLs where !mirroredOperations.contains(pending.id) {
            let hitlType: HITLType
            switch pending.kind {
            case .toolConfirmation(let c):
                hitlType = .toolConfirmation(toolName: c.toolName, params: c.params)
            case .clarification(let c):
                // A5: the remote channel is free-text, so append the suggested options to the prompt
                // body (the model's choices are otherwise invisible on Slack/Discord/Telegram).
                let question = (c.options?.isEmpty == false)
                    ? c.question + "\n\nReply with one of: " + (c.options ?? []).joined(separator: " / ")
                    : c.question
                hitlType = .clarification(question: question)
            case .planReview(let p):
                hitlType = .planReview(subtaskDescriptions: p.subtasks.map(\.description))
            case .gate(let g):
                // [D1] Real gate prompt — the transport renders one tappable button per option, and a
                // tap routes back through `hitl:gate:<opID>:<idx>` → resumeGate.
                hitlType = .gate(prompt: g.prompt, options: g.options)
            }

            do {
                let msgID = try await session.transport.sendHITLPrompt(
                    chatID: session.chatID,
                    operationID: pending.id,
                    type: hitlType
                )
                // Mark mirrored only AFTER a successful send — a transient transport failure then
                // self-heals on the next observation pass instead of permanently suppressing the prompt.
                mirroredOperations.insert(pending.id)
                hitlMessageIDs[pending.id] = msgID
                logger.info("[Mirror] Sent HITL prompt to \(session.source.rawValue) for operation \(pending.id).")
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
                self.mirroredOperations.remove(operationID)   // [HITL/P5] bound the dedup Set
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
                self.mirroredOperations.remove(operationID)   // [HITL/P5] bound the dedup Set
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
                self.mirroredOperations.remove(operationID)   // [HITL/P5] bound the dedup Set
            }
        }

        // [D1] Gate resolved (a choice was made on the Mac or remotely) → reflect the outcome and
        // drop the now-stale option buttons on the remote message.
        gateResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlGateResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let messageID = self.hitlMessageIDs[operationID],
                      let convID = conversationID,
                      let session = self.remoteSessions[convID] else { return }

                let chosen = (outcome == nil || outcome == "cancelled") ? "cancelled" : (outcome ?? "")
                try? await session.transport.editMessage(
                    chatID: session.chatID,
                    messageID: messageID,
                    newText: "✅ Gate decided: \(chosen)."
                )
                self.hitlMessageIDs.removeValue(forKey: operationID)
                self.mirroredOperations.remove(operationID)   // [HITL/P5] bound the dedup Set
            }
        }
    }
}
