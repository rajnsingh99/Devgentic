//
//  ExecutionSuspensionService.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import os

private let logger = DGLogger(category: "ExecutionSuspensionService")

/// Notification names posted after HITL suspensions are resolved (by any surface).
/// Both the Mac UI and ChatOps bridge observe these to clear stale banners/buttons.
extension Notification.Name {
    static let hitlPermissionResolved = Notification.Name("hitlPermissionResolved")
    static let hitlClarificationResolved = Notification.Name("hitlClarificationResolved")
    static let hitlPlanReviewResolved = Notification.Name("hitlPlanReviewResolved")
    static let hitlGateResolved = Notification.Name("hitlGateResolved")
}

/// UserInfo keys for HITL resolved notifications.
enum HITLResolvedKey {
    static let conversationID = "conversationID"
    static let operationID = "operationID"
    static let approved = "approved"
    /// [HITL/C1] Precise, type-specific resolution outcome for the trace span:
    /// permission → approved/denied, clarification → answered/skipped,
    /// plan review → approved/rejected, any cancel/deadline → cancelled.
    static let outcome = "outcome"
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
    // Maps operationID -> continuation (plan review gates — no timeout)
    private var planReviewContinuations: [UUID: CheckedContinuation<[SubTask]?, Never>] = [:]
    // [E1] Maps operationID -> continuation (workflow Gate — resumes with the chosen option, nil = none)
    private var gateContinuations: [UUID: CheckedContinuation<String?, Never>] = [:]
    // Reverse lookup: operationID -> conversationID (for cancel-by-conversation)
    private var operationToConversation: [UUID: UUID] = [:]
    // [HITL/A3] operationID -> user-edited tool arguments to apply on approval.
    private var editedArgs: [UUID: [String: JSONValue]] = [:]

    // [HITL/P5] No internal HITL watchdog. A pause waits INDEFINITELY; the execution CONTAINER
    // owns the deadline — chat = none (drained by Stop / conversation close), workflow = node
    // timeout, scheduled = a 10-minute max-run deadline. Every deadline arrives as Task
    // cancellation, which the `withTaskCancellationHandler` blocks below resolve safely (deny / nil).

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
        }

        operationToConversation[operationID] = conversationID

        logger.info("[Suspension] Suspending operation \(operationID) for conversation: \(conversationID). Indefinite — container owns the deadline.")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                activeContinuations[operationID] = continuation
                // If cancellation already happened before we parked, deny right away.
                if Task.isCancelled {
                    resume(for: operationID, approved: false)
                }
            }
        } onCancel: {
            // Stop button / conversation close / container deadline must wake the parked
            // await immediately rather than leaving it to the watchdog. Resolve as denied.
            Task { await self.resume(for: operationID, approved: false) }
        }
    }

    /// Resumes execution for a suspended operation.
    /// - Parameters:
    ///   - operationID: The unique operation identifier.
    ///   - approved: Whether the user clicked "Allow" (true) or "Deny" (false).
    func resume(for operationID: UUID, approved: Bool, editedArguments: [String: JSONValue]? = nil) {
        let conversationID = operationToConversation.removeValue(forKey: operationID)

        // [HITL/A3] Stash user edits to apply on approval; drop them on denial.
        if approved, let editedArguments {
            editedArgs[operationID] = editedArguments
        } else {
            editedArgs.removeValue(forKey: operationID)
        }

        guard let continuation = activeContinuations.removeValue(forKey: operationID) else {
            logger.warning("[Suspension] Attempted to resume non-existent suspension for operation: \(operationID)")
            editedArgs.removeValue(forKey: operationID)
            return
        }

        logger.info("[Suspension] Resuming operation \(operationID) with approval: \(approved)")
        continuation.resume(returning: approved)

        postResolved(name: .hitlPermissionResolved, operationID: operationID, conversationID: conversationID, extraInfo: [HITLResolvedKey.approved: approved, HITLResolvedKey.outcome: approved ? "approved" : "denied"])
    }

    /// [HITL/A3] Returns and clears any user-edited arguments for an approved tool, so dispatch runs
    /// with the corrected values instead of the agent's originals. Nil if the user didn't edit.
    func consumeEditedArguments(for operationID: UUID) -> [String: JSONValue]? {
        editedArgs.removeValue(forKey: operationID)
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

        logger.info("[Clarification] Suspending operation \(operationID) for conversation: \(conversationID). Indefinite — container owns the deadline.")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                clarificationContinuations[operationID] = continuation
                if Task.isCancelled {
                    resumeClarification(for: operationID, userInput: nil)
                }
            }
        } onCancel: {
            Task { await self.resumeClarification(for: operationID, userInput: nil) }
        }
    }

    /// Resumes a clarification suspension with the user's text input.
    func resumeClarification(for operationID: UUID, userInput: String?) {
        let conversationID = operationToConversation.removeValue(forKey: operationID)

        guard let continuation = clarificationContinuations.removeValue(forKey: operationID) else {
            logger.warning("[Clarification] Attempted to resume non-existent clarification for operation: \(operationID)")
            return
        }

        logger.info("[Clarification] Resuming operation \(operationID) with user input.")
        continuation.resume(returning: userInput)

        postResolved(name: .hitlClarificationResolved, operationID: operationID, conversationID: conversationID, extraInfo: [HITLResolvedKey.outcome: userInput != nil ? "answered" : "skipped"])
    }

    // MARK: - Plan Review Suspension (indefinite — container owns the deadline)

    /// Pauses execution until the user reviews, edits, and approves the generated plan.
    /// Unlike tool confirmations, plan review has **no timeout** — it stays indefinitely.
    /// - Parameters:
    ///   - operationID: Unique identifier for this HITL operation.
    ///   - conversationID: The conversation this operation belongs to.
    /// - Returns: The user-edited subtask array, or `nil` if the user rejected the plan.
    func suspendForPlanReview(for operationID: UUID, conversationID: UUID) async -> [SubTask]? {
        // Safety: prevent double-suspension leaks
        if let existing = planReviewContinuations[operationID] {
            logger.warning("[PlanReview] Overwriting existing plan review for operation \(operationID). Auto-cancelling previous.")
            existing.resume(returning: nil)
            planReviewContinuations.removeValue(forKey: operationID)
        }

        operationToConversation[operationID] = conversationID

        logger.info("[PlanReview] Suspending operation \(operationID) for conversation: \(conversationID). No timeout — awaiting user action.")

        // NO timeout task — plan review stays indefinitely until user acts, the stream is
        // cancelled, or the execution container (workflow node / scheduled run) deadlines.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[SubTask]?, Never>) in
                planReviewContinuations[operationID] = continuation
                if Task.isCancelled {
                    resumePlanReview(for: operationID, editedPlan: nil)
                }
            }
        } onCancel: {
            Task { await self.resumePlanReview(for: operationID, editedPlan: nil) }
        }
    }

    /// Resumes a plan review suspension with the user-edited plan or nil for rejection.
    func resumePlanReview(for operationID: UUID, editedPlan: [SubTask]?) {
        let conversationID = operationToConversation.removeValue(forKey: operationID)

        guard let continuation = planReviewContinuations.removeValue(forKey: operationID) else {
            logger.warning("[PlanReview] Attempted to resume non-existent plan review for operation: \(operationID)")
            return
        }

        logger.info("[PlanReview] Resuming operation \(operationID) with \(editedPlan != nil ? "approved plan (\(editedPlan!.count) subtasks)" : "rejection").")
        continuation.resume(returning: editedPlan)

        postResolved(name: .hitlPlanReviewResolved, operationID: operationID, conversationID: conversationID, extraInfo: [HITLResolvedKey.outcome: editedPlan != nil ? "approved" : "rejected"])
    }

    // MARK: - Gate Suspension (workflow Gate — per-option routing, E1)

    /// Pauses a workflow Gate node until the user picks an option (routes to that option's port) or the
    /// gate is cancelled / times out. Returns the chosen option string, or `nil` if cancelled/timed out.
    func suspendForGate(for operationID: UUID, conversationID: UUID) async -> String? {
        if let existing = gateContinuations[operationID] {
            logger.warning("[Gate] Overwriting existing gate suspension for operation \(operationID). Auto-cancelling previous.")
            existing.resume(returning: nil)
            gateContinuations.removeValue(forKey: operationID)
        }

        operationToConversation[operationID] = conversationID
        logger.info("[Gate] Suspending operation \(operationID) for conversation: \(conversationID). Indefinite — container owns the deadline.")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                gateContinuations[operationID] = continuation
                if Task.isCancelled {
                    resumeGate(for: operationID, chosenOption: nil)
                }
            }
        } onCancel: {
            Task { await self.resumeGate(for: operationID, chosenOption: nil) }
        }
    }

    /// Resumes a gate suspension with the user's chosen option (nil = cancelled / timed out / rejected).
    func resumeGate(for operationID: UUID, chosenOption: String?) {
        let conversationID = operationToConversation.removeValue(forKey: operationID)

        guard let continuation = gateContinuations.removeValue(forKey: operationID) else {
            logger.warning("[Gate] Attempted to resume non-existent gate for operation: \(operationID)")
            return
        }

        logger.info("[Gate] Resuming operation \(operationID) with choice: \(chosenOption ?? "<none>")")
        continuation.resume(returning: chosenOption)

        postResolved(name: .hitlGateResolved, operationID: operationID, conversationID: conversationID, extraInfo: [HITLResolvedKey.outcome: chosenOption ?? "cancelled"])
    }

    // MARK: - Cancellation & Status

    /// Force-cancels ALL suspensions for a conversation (e.g., user stops the stream).
    /// Resumes with `false` (Denied) for permissions, `nil` for clarifications.
    func cancel(for conversationID: UUID) {
        // Find all operations belonging to this conversation
        let permissionOps = operationToConversation.filter { $0.value == conversationID }.map(\.key)

        for opID in permissionOps {
            operationToConversation.removeValue(forKey: opID)
            editedArgs.removeValue(forKey: opID)

            // Post the matching resolved notification (mirrors resume*/timeout) so every surface —
            // the legacy banners, the unified InteractionCenter, and the ChatOps remote mirror —
            // clears immediately on cancel rather than relying on a downstream finalize backstop.
            // This is what makes remote-Stop (no Mac task to tear down) dismiss the banner too.
            if let continuation = activeContinuations.removeValue(forKey: opID) {
                logger.info("[Suspension] Force-cancelling permission for operation: \(opID)")
                continuation.resume(returning: false)
                postResolved(name: .hitlPermissionResolved, operationID: opID, conversationID: conversationID, extraInfo: [HITLResolvedKey.approved: false, HITLResolvedKey.outcome: "cancelled"])
            }

            if let continuation = clarificationContinuations.removeValue(forKey: opID) {
                logger.info("[Suspension] Force-cancelling clarification for operation: \(opID)")
                continuation.resume(returning: nil)
                postResolved(name: .hitlClarificationResolved, operationID: opID, conversationID: conversationID, extraInfo: [HITLResolvedKey.outcome: "cancelled"])
            }

            if let continuation = planReviewContinuations.removeValue(forKey: opID) {
                logger.info("[Suspension] Force-cancelling plan review for operation: \(opID)")
                continuation.resume(returning: nil)
                postResolved(name: .hitlPlanReviewResolved, operationID: opID, conversationID: conversationID, extraInfo: [HITLResolvedKey.outcome: "cancelled"])
            }

            if let continuation = gateContinuations.removeValue(forKey: opID) {
                logger.info("[Suspension] Force-cancelling gate for operation: \(opID)")
                continuation.resume(returning: nil)
                postResolved(name: .hitlGateResolved, operationID: opID, conversationID: conversationID, extraInfo: [HITLResolvedKey.outcome: "cancelled"])
            }
        }
    }

    /// Checks if a conversation has any pending suspension.
    func isSuspended(for conversationID: UUID) -> Bool {
        return operationToConversation.values.contains(conversationID)
    }

    // MARK: - Notification Helper

    /// Posts an HITL resolved notification on the main actor for cross-surface deduplication.
    /// Centralizes the pattern used by all resume/timeout paths to prevent drift.
    private func postResolved(
        name: Notification.Name,
        operationID: UUID,
        conversationID: UUID?,
        extraInfo: sending [String: Any] = [:]
    ) {
        let wrappedExtra = UnsafeSendable(extraInfo)
        Task { @MainActor in
            var userInfo: [String: Any] = [HITLResolvedKey.operationID: operationID]
            if let conversationID { userInfo[HITLResolvedKey.conversationID] = conversationID }
            for (key, value) in wrappedExtra.value { userInfo[key] = value }
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        }
    }
}
