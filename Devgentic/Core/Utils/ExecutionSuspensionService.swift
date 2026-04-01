//
//  ExecutionSuspensionService.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ExecutionSuspensionService")

/// Notification names posted after HITL suspensions are resolved (by any surface).
/// Both the Mac UI and ChatOps bridge observe these to clear stale banners/buttons.
extension Notification.Name {
    static let hitlPermissionResolved = Notification.Name("hitlPermissionResolved")
    static let hitlClarificationResolved = Notification.Name("hitlClarificationResolved")
}

/// UserInfo keys for HITL resolved notifications.
enum HITLResolvedKey {
    static let conversationID = "conversationID"
    static let operationID = "operationID"
    static let approved = "approved"
}

/// Manages the "Pause/Resume" state of Agent execution.
/// Uses Swift Concurrency continuations to bridge the gap between
/// the synchronous-feeling Agent Loop and the asynchronous User Interaction.
///
/// Keyed by **operationID** (unique per HITL event) rather than conversationID,
/// which enables multiple concurrent HITL operations and multi-surface deduplication.
actor ExecutionSuspensionService {

    static let shared = ExecutionSuspensionService()

    // Maps operationID -> continuation (permission gates)
    private var activeContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    // Maps operationID -> continuation (clarification gates)
    private var clarificationContinuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    // Maps operationID -> timeout task
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    // Reverse lookup: operationID -> conversationID (for cancel-by-conversation)
    private var operationToConversation: [UUID: UUID] = [:]

    // Config: How long to wait before auto-denying (Seconds)
    private let suspensionTimeout: TimeInterval = 300 // 5 Minutes

    private init() {}

    // MARK: - Permission Suspension (Tool Confirmation)

    /// Pauses execution for the specific operation until `resume` is called or timeout occurs.
    /// - Parameters:
    ///   - operationID: Unique identifier for this HITL operation.
    ///   - conversationID: The conversation this operation belongs to (for cancel-by-conversation).
    /// - Returns: `true` if the user approved the action, `false` if denied or timed out.
    func suspend(for operationID: UUID, conversationID: UUID) async -> Bool {
        // Safety: If we somehow suspend twice with the same operationID, auto-deny previous.
        if let existing = activeContinuations[operationID] {
            logger.warning("[Suspension] Overwriting existing suspension for operation \(operationID). Auto-denying previous.")
            existing.resume(returning: false)
            activeContinuations.removeValue(forKey: operationID)
            timeoutTasks[operationID]?.cancel()
        }

        operationToConversation[operationID] = conversationID

        logger.info("[Suspension] Suspending operation \(operationID) for conversation: \(conversationID). Timeout: \(self.suspensionTimeout)s.")

        // Start the Watchdog Timer
        let timeoutTask = Task { [weak self] in
            let seconds = self?.suspensionTimeout ?? 300
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleTimeout(for: operationID)
        }
        timeoutTasks[operationID] = timeoutTask

        return await withCheckedContinuation { continuation in
            activeContinuations[operationID] = continuation
        }
    }

    /// Resumes execution for a suspended operation.
    /// - Parameters:
    ///   - operationID: The unique operation identifier.
    ///   - approved: Whether the user clicked "Allow" (true) or "Deny" (false).
    func resume(for operationID: UUID, approved: Bool) {
        // Cancel the watchdog since user responded
        timeoutTasks[operationID]?.cancel()
        timeoutTasks.removeValue(forKey: operationID)

        let conversationID = operationToConversation.removeValue(forKey: operationID)

        guard let continuation = activeContinuations.removeValue(forKey: operationID) else {
            logger.warning("[Suspension] Attempted to resume non-existent suspension for operation: \(operationID)")
            return
        }

        logger.info("[Suspension] Resuming operation \(operationID) with approval: \(approved)")
        continuation.resume(returning: approved)

        // Notify both surfaces (Mac UI + remote) so the non-responding surface clears its stale state.
        Task { @MainActor in
            var userInfo: [String: Any] = [
                HITLResolvedKey.operationID: operationID,
                HITLResolvedKey.approved: approved
            ]
            if let conversationID { userInfo[HITLResolvedKey.conversationID] = conversationID }
            NotificationCenter.default.post(name: .hitlPermissionResolved, object: nil, userInfo: userInfo)
        }
    }

    // MARK: - Clarification Suspension (ask_user)

    /// Pauses execution until the user provides a text answer or the timeout fires.
    /// - Parameters:
    ///   - operationID: Unique identifier for this HITL operation.
    ///   - conversationID: The conversation this operation belongs to.
    /// - Returns: The user's text response, or `nil` if timed out / cancelled.
    func suspendForClarification(for operationID: UUID, conversationID: UUID) async -> String? {
        // Safety: prevent double-suspension leaks
        if let existing = clarificationContinuations[operationID] {
            logger.warning("[Clarification] Overwriting existing clarification for operation \(operationID). Auto-cancelling previous.")
            existing.resume(returning: nil)
            clarificationContinuations.removeValue(forKey: operationID)
        }

        operationToConversation[operationID] = conversationID

        logger.info("[Clarification] Suspending operation \(operationID) for conversation: \(conversationID).")

        let timeoutTask = Task { [weak self] in
            let seconds = self?.suspensionTimeout ?? 300
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleClarificationTimeout(for: operationID)
        }
        timeoutTasks[operationID] = timeoutTask

        return await withCheckedContinuation { continuation in
            clarificationContinuations[operationID] = continuation
        }
    }

    /// Resumes a clarification suspension with the user's text input.
    func resumeClarification(for operationID: UUID, userInput: String?) {
        timeoutTasks[operationID]?.cancel()
        timeoutTasks.removeValue(forKey: operationID)

        let conversationID = operationToConversation.removeValue(forKey: operationID)

        guard let continuation = clarificationContinuations.removeValue(forKey: operationID) else {
            logger.warning("[Clarification] Attempted to resume non-existent clarification for operation: \(operationID)")
            return
        }

        logger.info("[Clarification] Resuming operation \(operationID) with user input.")
        continuation.resume(returning: userInput)

        // Notify both surfaces so the non-responding surface clears its stale state.
        Task { @MainActor in
            var userInfo: [String: Any] = [HITLResolvedKey.operationID: operationID]
            if let conversationID { userInfo[HITLResolvedKey.conversationID] = conversationID }
            NotificationCenter.default.post(name: .hitlClarificationResolved, object: nil, userInfo: userInfo)
        }
    }

    private func handleClarificationTimeout(for operationID: UUID) {
        logger.notice("[Clarification] ⏰ TIMEOUT for operation: \(operationID). Returning nil.")
        let conversationID = operationToConversation.removeValue(forKey: operationID)
        timeoutTasks.removeValue(forKey: operationID)
        guard let continuation = clarificationContinuations.removeValue(forKey: operationID) else { return }
        continuation.resume(returning: nil)

        Task { @MainActor in
            var userInfo: [String: Any] = [HITLResolvedKey.operationID: operationID]
            if let conversationID { userInfo[HITLResolvedKey.conversationID] = conversationID }
            NotificationCenter.default.post(name: .hitlClarificationResolved, object: nil, userInfo: userInfo)
        }
    }

    // MARK: - Cancellation & Status

    /// Force-cancels ALL suspensions for a conversation (e.g., user stops the stream).
    /// Resumes with `false` (Denied) for permissions, `nil` for clarifications.
    func cancel(for conversationID: UUID) {
        // Find all operations belonging to this conversation
        let permissionOps = operationToConversation.filter { $0.value == conversationID }.map(\.key)

        for opID in permissionOps {
            timeoutTasks[opID]?.cancel()
            timeoutTasks.removeValue(forKey: opID)
            operationToConversation.removeValue(forKey: opID)

            if let continuation = activeContinuations.removeValue(forKey: opID) {
                logger.info("[Suspension] Force-cancelling permission for operation: \(opID)")
                continuation.resume(returning: false)
            }

            if let continuation = clarificationContinuations.removeValue(forKey: opID) {
                logger.info("[Suspension] Force-cancelling clarification for operation: \(opID)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Internal handler for auto-denial
    private func handleTimeout(for operationID: UUID) {
        logger.notice("[Suspension] ⏰ TIMEOUT for operation: \(operationID). Auto-denying permission.")
        let conversationID = operationToConversation.removeValue(forKey: operationID)
        timeoutTasks.removeValue(forKey: operationID)

        guard let continuation = activeContinuations.removeValue(forKey: operationID) else { return }
        continuation.resume(returning: false)

        Task { @MainActor in
            var userInfo: [String: Any] = [
                HITLResolvedKey.operationID: operationID,
                HITLResolvedKey.approved: false
            ]
            if let conversationID { userInfo[HITLResolvedKey.conversationID] = conversationID }
            NotificationCenter.default.post(name: .hitlPermissionResolved, object: nil, userInfo: userInfo)
        }
    }

    /// Checks if a conversation has any pending suspension.
    func isSuspended(for conversationID: UUID) -> Bool {
        return operationToConversation.values.contains(conversationID)
    }
}
