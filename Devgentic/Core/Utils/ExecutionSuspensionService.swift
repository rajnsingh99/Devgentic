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
    /// Reverse lookup: operationID -> workflow NODE, for `cancelNode`. Absent for every park with
    /// no node dimension — chat and code runs, and both MCP brokers, which build their HITLOrigin
    /// with `nodeID: nil`. Those are drained only by the conversation-wide `cancel(for:)`.
    ///
    /// ⚠️ Written and removed in LOCKSTEP with `operationToConversation`. This actor is a
    /// process-wide singleton with no reset, so a removal missed at any one of the five sites leaks
    /// for the life of the process.
    private var operationToNode: [UUID: UUID] = [:]

    // MARK: - Park accounting (for compute-only node timeouts)

    /// How many operations in this conversation are parked right now.
    private var parkDepth: [UUID: Int] = [:]
    /// When the current "someone is waiting" period began (set when depth goes 0 → 1).
    private var parkBegan: [UUID: Date] = [:]
    /// Completed parked time, as a UNION of overlapping parks — not a sum.
    private var parkedTotal: [UUID: TimeInterval] = [:]

    /// Cumulative wall-clock during which AT LEAST ONE operation in this conversation was parked
    /// awaiting a human, including any park still open.
    ///
    /// ⚠️ This exists so a workflow node timeout can bound COMPUTE rather than wall-clock. A node
    /// that sat for ten minutes because nobody clicked the confirmation button has not misbehaved,
    /// and killing it is the wrong answer — that was a live defect on the profile path before
    /// 2026-08-13 (a slow tool confirmation killed the node at 120s) and would have killed the
    /// Router's deliberately-indefinite ambiguity arbitration outright.
    ///
    /// ⚠️ Reference-counted, so two simultaneous parks count once. Callers snapshot this at node
    /// start and diff later; there is no history, only a running total.
    ///
    /// ⚠️ Scoped per CONVERSATION, not per node — parallel sibling nodes in one run share the
    /// credit, so a node can over-run its limit if a sibling parked. That direction is deliberate:
    /// over-crediting wastes some time, under-crediting kills work that was only ever waiting.
    func cumulativeParkedTime(for conversationID: UUID) -> TimeInterval {
        let completed = parkedTotal[conversationID] ?? 0
        guard let began = parkBegan[conversationID] else { return completed }
        return completed + Date().timeIntervalSince(began)
    }

    /// Called when an operation begins waiting on a human.
    private func beginPark(_ conversationID: UUID) {
        let depth = (parkDepth[conversationID] ?? 0) + 1
        parkDepth[conversationID] = depth
        if depth == 1 { parkBegan[conversationID] = Date() }
    }

    /// Called when an operation stops waiting — resolved, cancelled or timed out, all the same here.
    private func endPark(_ conversationID: UUID) {
        guard let depth = parkDepth[conversationID], depth > 0 else { return }
        let next = depth - 1
        parkDepth[conversationID] = next
        guard next == 0, let began = parkBegan.removeValue(forKey: conversationID) else { return }
        parkedTotal[conversationID, default: 0] += Date().timeIntervalSince(began)
    }
    // [HITL/A3] operationID -> user-edited tool arguments to apply on approval.
    private var editedArgs: [UUID: [String: JSONValue]] = [:]

    // [HITL/P5] No internal HITL watchdog. A pause waits INDEFINITELY; the execution CONTAINER
    // owns the deadline — chat = none (drained by Stop / conversation close), workflow = node
    // timeout, scheduled = a 10-minute max-run deadline. Every deadline arrives as Task
    // cancellation, which the `withTaskCancellationHandler` blocks below resolve safely (deny / nil).

    private init() {}

    // MARK: - Queries

    /// Whether ANY operation (approval / clarification / plan review / gate) is
    /// currently parked. Used by MLXService's idle timer to distinguish
    /// "parked mid-run" from "genuinely idle" in its unload log — behavior is
    /// identical either way (unload + lazy reload on resume).
    func hasPendingSuspensions() -> Bool {
        !activeContinuations.isEmpty
            || !clarificationContinuations.isEmpty
            || !planReviewContinuations.isEmpty
            || !gateContinuations.isEmpty
    }

    /// How many operations are parked right now, across every kind and conversation.
    ///
    /// ⚠️ Read-only, and NOT redundant with the boolean above. A park is only observable once its
    /// continuation is INSTALLED: `suspendForGate` writes `operationToConversation` and calls
    /// `beginPark` before it `await`s to install the continuation, so `isSuspended(for:)` goes true
    /// while a `resumeGate` would still find nothing to resume. Anything that must wait for a
    /// SECOND park to land cannot use `hasPendingSuspensions()` as its barrier — it is already
    /// true from the first. This count is that barrier.
    func pendingSuspensionCount() -> Int {
        activeContinuations.count + clarificationContinuations.count
            + planReviewContinuations.count + gateContinuations.count
    }

    // MARK: - Permission Suspension (Tool Confirmation)

    /// Pauses execution for the specific operation until `resume` is called or timeout occurs.
    /// - Parameters:
    ///   - operationID: Unique identifier for this HITL operation.
    ///   - conversationID: The conversation this operation belongs to (for cancel-by-conversation).
    /// - Returns: `true` if the user approved the action, `false` if denied or timed out.
    func suspend(for operationID: UUID, conversationID: UUID, nodeID: UUID? = nil) async -> Bool {
        // Safety: If we somehow suspend twice with the same operationID, auto-deny previous.
        if let existing = activeContinuations[operationID] {
            logger.warning("[Suspension] Overwriting existing suspension for operation \(operationID). Auto-denying previous.")
            existing.resume(returning: false)
            activeContinuations.removeValue(forKey: operationID)
        }

        operationToConversation[operationID] = conversationID
        if let nodeID { operationToNode[operationID] = nodeID }
        beginPark(conversationID)

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
        operationToNode.removeValue(forKey: operationID)
        if let conversationID { endPark(conversationID) }

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
    func suspendForClarification(for operationID: UUID, conversationID: UUID, nodeID: UUID? = nil) async -> String? {
        // Safety: prevent double-suspension leaks
        if let existing = clarificationContinuations[operationID] {
            logger.warning("[Clarification] Overwriting existing clarification for operation \(operationID). Auto-cancelling previous.")
            existing.resume(returning: nil)
            clarificationContinuations.removeValue(forKey: operationID)
        }

        operationToConversation[operationID] = conversationID
        if let nodeID { operationToNode[operationID] = nodeID }
        beginPark(conversationID)

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
        operationToNode.removeValue(forKey: operationID)
        if let conversationID { endPark(conversationID) }

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
    func suspendForPlanReview(for operationID: UUID, conversationID: UUID, nodeID: UUID? = nil) async -> [SubTask]? {
        // Safety: prevent double-suspension leaks
        if let existing = planReviewContinuations[operationID] {
            logger.warning("[PlanReview] Overwriting existing plan review for operation \(operationID). Auto-cancelling previous.")
            existing.resume(returning: nil)
            planReviewContinuations.removeValue(forKey: operationID)
        }

        operationToConversation[operationID] = conversationID
        if let nodeID { operationToNode[operationID] = nodeID }
        beginPark(conversationID)

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
        operationToNode.removeValue(forKey: operationID)
        if let conversationID { endPark(conversationID) }

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
    func suspendForGate(for operationID: UUID, conversationID: UUID, nodeID: UUID? = nil) async -> String? {
        if let existing = gateContinuations[operationID] {
            logger.warning("[Gate] Overwriting existing gate suspension for operation \(operationID). Auto-cancelling previous.")
            existing.resume(returning: nil)
            gateContinuations.removeValue(forKey: operationID)
        }

        operationToConversation[operationID] = conversationID
        if let nodeID { operationToNode[operationID] = nodeID }
        beginPark(conversationID)
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
        operationToNode.removeValue(forKey: operationID)
        if let conversationID { endPark(conversationID) }

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
            drainOperation(opID, conversationID: conversationID, outcome: "cancelled")
        }
    }

    /// Force-resolves every park belonging to ONE workflow node, leaving its siblings alone.
    ///
    /// ⚠️ THE N3 FIX, and the narrower sibling of `cancel(for:)` — NOT a replacement for it. A
    /// conversation legitimately holds parks with no node dimension at all (chat and code runs, and
    /// both MCP brokers, which build their origin with `nodeID: nil`), and a node-partitioned
    /// reimplementation of the conversation-wide drain would silently stop draining those. That is
    /// a HANG, not a warning, so the two stay separate.
    ///
    /// The `conversationID` term is not redundant with `nodeID`: it keeps the drain inside the
    /// one-root-run-per-conversation boundary and guards against a stale node id from an earlier
    /// run of the same graph.
    ///
    /// Returns the operations it resolved, so a caller can log what it actually did.
    @discardableResult
    func cancelNode(_ nodeID: UUID, in conversationID: UUID, outcome: String = "cancelled") -> [UUID] {
        let ops = operationToConversation
            .filter { $0.value == conversationID && operationToNode[$0.key] == nodeID }
            .map(\.key)

        guard !ops.isEmpty else { return [] }
        for opID in ops {
            drainOperation(opID, conversationID: conversationID, outcome: outcome)
        }
        logger.info("[Suspension] Node-scoped drain resolved \(ops.count) park(s) for node \(nodeID.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)). CONSEQUENCE: only this node's banners clear; a sibling node's parked request is untouched and still awaiting the user.")
        return ops
    }

    /// Resolves ONE parked operation: drops its indexes, closes its park, resumes whichever
    /// continuation kind it holds, and posts the matching resolved notification.
    ///
    /// ⚠️ SHARED BY BOTH DRAINS ON PURPOSE. This was the body of `cancel(for:)`; `cancelNode`
    /// needs byte-identical semantics, and two copies of park accounting would be two chances to
    /// unbalance it.
    ///
    /// ⚠️ Exactly ONE `endPark` per drained operation — `beginPark`/`endPark` are a reference count
    /// over a UNION window keyed by CONVERSATION, so draining a subset correctly leaves the window
    /// OPEN while a sibling is still parked. An extra `endPark` here would drive the depth to zero
    /// early, close the window, and every later node in that conversation would stop crediting
    /// parked time — its timeout would then fire on wall-clock, killing work that was only waiting.
    ///
    /// ⚠️ `outcome` is free-form and reaches the trace row and the remote mirror. "cancelled" is the
    /// teardown value; a caller resolving a park for a different reason should say so, because
    /// downstream surfaces render it verbatim.
    private func drainOperation(_ opID: UUID, conversationID: UUID, outcome: String) {
        operationToConversation.removeValue(forKey: opID)
        operationToNode.removeValue(forKey: opID)
        // ⚠️ Force-cancel closes the park too. Without this the depth never returns to zero and
        // `cumulativeParkedTime` grows forever, so every later node in the conversation would
        // believe it had been waiting on a human and its timeout would never fire.
        endPark(conversationID)
        editedArgs.removeValue(forKey: opID)

        // Post the matching resolved notification (mirrors resume*/timeout) so every surface —
        // the legacy banners, the unified InteractionCenter, and the ChatOps remote mirror —
        // clears immediately on cancel rather than relying on a downstream finalize backstop.
        // This is what makes remote-Stop (no Mac task to tear down) dismiss the banner too.
        if let continuation = activeContinuations.removeValue(forKey: opID) {
            logger.info("[Suspension] Force-resolving permission for operation: \(opID) (\(outcome))")
            continuation.resume(returning: false)
            postResolved(name: .hitlPermissionResolved, operationID: opID, conversationID: conversationID, extraInfo: [HITLResolvedKey.approved: false, HITLResolvedKey.outcome: outcome])
        }

        if let continuation = clarificationContinuations.removeValue(forKey: opID) {
            logger.info("[Suspension] Force-resolving clarification for operation: \(opID) (\(outcome))")
            continuation.resume(returning: nil)
            postResolved(name: .hitlClarificationResolved, operationID: opID, conversationID: conversationID, extraInfo: [HITLResolvedKey.outcome: outcome])
        }

        if let continuation = planReviewContinuations.removeValue(forKey: opID) {
            logger.info("[Suspension] Force-resolving plan review for operation: \(opID) (\(outcome))")
            continuation.resume(returning: nil)
            postResolved(name: .hitlPlanReviewResolved, operationID: opID, conversationID: conversationID, extraInfo: [HITLResolvedKey.outcome: outcome])
        }

        if let continuation = gateContinuations.removeValue(forKey: opID) {
            logger.info("[Suspension] Force-resolving gate for operation: \(opID) (\(outcome))")
            continuation.resume(returning: nil)
            postResolved(name: .hitlGateResolved, operationID: opID, conversationID: conversationID, extraInfo: [HITLResolvedKey.outcome: outcome])
        }
    }

    /// Checks if a conversation has any pending suspension.
    func isSuspended(for conversationID: UUID) -> Bool {
        return operationToConversation.values.contains(conversationID)
    }

    /// Whether a specific workflow NODE has a park awaiting the user. Drives per-node affordances
    /// (the timeline's "Needs your input" state, and Phase B's skip button on a parked row).
    ///
    /// ⚠️ Answers only for parks that CARRY a node dimension. A chat park, or an MCP broker park
    /// (`nodeID: nil` by construction), is invisible here however true `isSuspended(for:)` is.
    func isSuspended(node nodeID: UUID, in conversationID: UUID) -> Bool {
        operationToConversation.contains { $0.value == conversationID && operationToNode[$0.key] == nodeID }
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
