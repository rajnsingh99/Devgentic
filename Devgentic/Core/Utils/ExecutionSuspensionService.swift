// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExecutionSuspensionService.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    /// Who answered the prompt, as a `MessageSource.rawValue`; absent means no human answered (a timeout or force-cancel),
    /// which is why it is optional rather than defaulted to a surface.
    static let source = "source"
    /// [HITL/C1] Precise, type-specific resolution outcome for the trace span:
    /// permission → approved/denied, clarification → answered/skipped,
    /// plan review → approved/rejected, any cancel/deadline → cancelled.
    static let outcome = "outcome"
}

// Why: every resolution in this file passes `resolvedBy: nil`: double-suspension cleanup, cancellation and
// deadlines are machines, not people.
/// Manages the Pause/Resume state of agent execution, using Swift Concurrency continuations to bridge the
/// synchronous-feeling agent loop and asynchronous user interaction. Keyed by operationID (unique per HITL event), not
/// conversationID.
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
    // Why: written and removed in lockstep with `operationToConversation`; the actor is a singleton, so a missed
    // removal leaks for the process lifetime.
    /// Reverse lookup: operationID -> workflow node, for `cancelNode`. Absent for parks with no node dimension (chat and
    /// code runs, MCP brokers), which only the conversation-wide `cancel(for:)` drains.
    private var operationToNode: [UUID: UUID] = [:]
    // Why: same lockstep rule as `operationToNode`: removed at every removal site or it leaks for the process lifetime.
    /// Reverse lookup: operationID -> owning workflow run, for `cancelRun`. Stamped from the `WorkflowRunScope.token`
    /// TaskLocal inside each `suspend*` body; absent for parks raised outside any run's task tree (chat/code runs, MCP
    /// brokers).
    private var operationToRunToken: [UUID: UUID] = [:]

    // MARK: - Park accounting (for compute-only node timeouts)

    /// How many operations in this conversation are parked right now.
    private var parkDepth: [UUID: Int] = [:]
    /// When the current "someone is waiting" period began (set when depth goes 0 → 1).
    private var parkBegan: [UUID: Date] = [:]
    /// Completed parked time, as a UNION of overlapping parks — not a sum.
    private var parkedTotal: [UUID: TimeInterval] = [:]

    // Why: reference-counted and scoped per conversation, so a node may over-run if a sibling parked; over-crediting
    // wastes time, under-crediting kills waiting work.
    /// Cumulative wall-clock during which at least one operation in this conversation was parked awaiting a human, including
    /// any open park. Lets a workflow node timeout bound compute rather than wall-clock; callers snapshot it at node start
    /// and diff later.
    func cumulativeParkedTime(for conversationID: UUID) -> TimeInterval {
        let completed = parkedTotal[conversationID] ?? 0
        guard let began = parkBegan[conversationID] else { return completed }
        return completed + Date().timeIntervalSince(began)
    }

    /// Called when an operation begins waiting on a human. Credits the conversation total and, separately, each time bound
    /// in the park's owner chain, which is what the timeouts read (see `ParkScope`).
    private func beginPark(_ conversationID: UUID, operationID: UUID) {
        // A run waiting on a human gives the local lock up; the run is read off the caller's task, and the end is reported from
        // `endPark`, which every resolution path reaches.
        if let runID = LocalInferenceScope.runID {
            operationToLocalRun[operationID] = runID
            Task { @MainActor in LocalInferenceCoordinator.shared.parkBegan(runID: runID, operationID: operationID) }
        } else {
            logger.debug("[LOCAL-COORD] Park \(operationID.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)) is outside any run (no run id on its task). CONSEQUENCE: the local lock is not given up for it.")
        }
        let depth = (parkDepth[conversationID] ?? 0) + 1
        parkDepth[conversationID] = depth
        if depth == 1 { parkBegan[conversationID] = Date() }

        // An actor call runs on the CALLER's task, so this is the chain of the code that parked.
        let chain = ParkScope.chain
        let owners: [UUID]
        if chain.isEmpty {
            // Out of chain: an MCP elicitation/sampling request arrives on the transport's own task, so its owner cannot be known
            // and every bound open in this conversation is paused.
            owners = activeScopes.filter { $0.value == conversationID }.map(\.key)
        } else {
            owners = chain
        }
        operationToScopes[operationID] = owners
        for scope in owners {
            let scopeDepth = (scopeParkDepth[scope] ?? 0) + 1
            scopeParkDepth[scope] = scopeDepth
            if scopeDepth == 1 { scopeParkBegan[scope] = Date() }
        }
    }

    /// Called when an operation stops waiting — resolved, cancelled or timed out, all the same here.
    private func endPark(_ conversationID: UUID, operationID: UUID) {
        releaseScopeCredit(operationID)
        if let runID = operationToLocalRun.removeValue(forKey: operationID) {
            Task { @MainActor in LocalInferenceCoordinator.shared.parkEnded(runID: runID, operationID: operationID) }
        }

        guard let depth = parkDepth[conversationID], depth > 0 else { return }
        let next = depth - 1
        parkDepth[conversationID] = next
        guard next == 0, let began = parkBegan.removeValue(forKey: conversationID) else { return }
        parkedTotal[conversationID, default: 0] += Date().timeIntervalSince(began)
    }

    /// Ends the scope credit `operationID` was paying into.
    private func releaseScopeCredit(_ operationID: UUID) {
        for scope in operationToScopes.removeValue(forKey: operationID) ?? [] {
            guard let scopeDepth = scopeParkDepth[scope], scopeDepth > 0 else { continue }
            scopeParkDepth[scope] = scopeDepth - 1
            if scopeDepth == 1, let began = scopeParkBegan.removeValue(forKey: scope) {
                scopeParkedTotal[scope, default: 0] += Date().timeIntervalSince(began)
            }
        }
    }

    // MARK: - Local-model queue credit (local inference coordinator, phase 2)

    /// A run is waiting in line for the local model; its time bounds (the caller's `ParkScope` chain) pause as a HITL park
    /// pauses them. Scope credit only: not a park in the conversation, so `parkDepth` / `cumulativeParkedTime` are
    /// untouched, and a wait outside any chain credits nothing.
    func beginQueueWait(_ waitID: UUID) {
        let owners = ParkScope.chain
        guard !owners.isEmpty else {
            logger.debug("[LOCAL-COORD] Queue wait \(waitID.uuidString.prefix(8)) is outside any time bound. CONSEQUENCE: nothing to credit — no limit is running for it.")
            return
        }
        logger.debug("[LOCAL-COORD] Queue wait \(waitID.uuidString.prefix(8)) pauses \(owners.count) time bound(s) until it ends.")
        operationToScopes[waitID] = owners
        for scope in owners {
            let scopeDepth = (scopeParkDepth[scope] ?? 0) + 1
            scopeParkDepth[scope] = scopeDepth
            if scopeDepth == 1 { scopeParkBegan[scope] = Date() }
        }
    }

    /// The wait ended — admitted or withdrawn. Idempotent.
    func endQueueWait(_ waitID: UUID) {
        releaseScopeCredit(waitID)
    }

    // MARK: - Owner-chain park credit (HITL Waiting Contract, decision A)

    /// Parked operation → the run it parked (`LocalInferenceScope.runID` at park time). Removed in
    /// `endPark`, the one place every park ends.
    private var operationToLocalRun: [UUID: UUID] = [:]

    /// Open time bounds → their conversation, so an out-of-chain park can find them.
    private var activeScopes: [UUID: UUID] = [:]
    /// Which bounds each parked operation is paying into; read back by `endPark`.
    private var operationToScopes: [UUID: [UUID]] = [:]
    private var scopeParkDepth: [UUID: Int] = [:]
    private var scopeParkBegan: [UUID: Date] = [:]
    private var scopeParkedTotal: [UUID: TimeInterval] = [:]

    /// Bounds whose run nobody can answer (scheduled, background-task wake).
    private var unattendedScopes: Set<UUID> = []

    /// - Parameter attended: whether a human can answer this bound's run. Defaults to the CALLER's
    ///   `WorkflowRunAttendance` (a default argument is evaluated on the caller's task).
    func registerScope(_ scope: UUID, conversationID: UUID,
                       attended: Bool = WorkflowRunAttendance.canReachAHuman) {
        activeScopes[scope] = conversationID
        if !attended { unattendedScopes.insert(scope) }
    }

    /// Whether an out-of-chain ask in this conversation (an MCP question or sampling approval) has anyone to answer it.
    /// False while any open bound in the conversation belongs to an unattended run; one run per conversation makes that a
    /// fair proxy.
    func canReachAHuman(inConversation conversationID: UUID) -> Bool {
        !activeScopes.contains { $0.value == conversationID && unattendedScopes.contains($0.key) }
    }

    /// Registers a bound NESTED in `chain` (a tool call inside a turn or node) under its parent's
    /// conversation, so an out-of-chain park — an MCP question raised while that tool call is in
    /// flight — pauses the tool's clock too. Unregistered if the chain has no registered parent.
    func registerScope(_ scope: UUID, under chain: [UUID]) {
        guard let parent = chain.reversed().first(where: { self.activeScopes[$0] != nil }),
              let conversationID = activeScopes[parent] else { return }
        activeScopes[scope] = conversationID
        if unattendedScopes.contains(parent) { unattendedScopes.insert(scope) }
    }

    /// Drops a finished bound and its accounting. A park still open on it keeps its operation
    /// entry and closes harmlessly: `endPark` skips a scope with no depth.
    func unregisterScope(_ scope: UUID) {
        activeScopes.removeValue(forKey: scope)
        unattendedScopes.remove(scope)
        scopeParkDepth.removeValue(forKey: scope)
        scopeParkBegan.removeValue(forKey: scope)
        scopeParkedTotal.removeValue(forKey: scope)
    }

    /// Wall-clock during which at least one park in THIS bound's owner chain was open, including a
    /// park still open. This — not the conversation total — is what a timeout subtracts.
    func parkedTime(forScope scope: UUID) -> TimeInterval {
        let completed = scopeParkedTotal[scope] ?? 0
        guard let began = scopeParkBegan[scope] else { return completed }
        return completed + Date().timeIntervalSince(began)
    }

    /// Whether a park in this bound's chain is open right now.
    func isParked(scope: UUID) -> Bool {
        (scopeParkDepth[scope] ?? 0) > 0
    }
    // [HITL/A3] operationID -> user-edited tool arguments to apply on approval.
    private var editedArgs: [UUID: [String: JSONValue]] = [:]

    // No internal HITL watchdog: a pause waits indefinitely and the execution container owns the deadline, delivered as
    // Task cancellation, which the `withTaskCancellationHandler` blocks below resolve safely (deny / nil).

    private init() {}

    // MARK: - Queries

    /// Whether any operation (approval / clarification / plan review / gate) is currently parked; MLXService's idle timer
    /// uses it to tell 'parked mid-run' from 'genuinely idle' in its unload log.
    func hasPendingSuspensions() -> Bool {
        !activeContinuations.isEmpty
            || !clarificationContinuations.isEmpty
            || !planReviewContinuations.isEmpty
            || !gateContinuations.isEmpty
    }

    /// How many operations are parked right now, across every kind and conversation. Read-only; use it, not
    /// `hasPendingSuspensions()`, as a barrier for a second park, since a park is observable only once its continuation is
    /// installed.
    func pendingSuspensionCount() -> Int {
        activeContinuations.count + clarificationContinuations.count
            + planReviewContinuations.count + gateContinuations.count
    }

    /// Invariant probe: an orphaned park, whose continuation is installed but whose `operationToConversation` index is gone,
    /// so no resume-by-conversation or drain can find it. Reads two maps in one actor call; sampling them from outside races
    /// the install.
    func isOrphaned(operation operationID: UUID) -> Bool {
        guard operationToConversation[operationID] == nil else { return false }
        return activeContinuations[operationID] != nil
            || clarificationContinuations[operationID] != nil
            || planReviewContinuations[operationID] != nil
            || gateContinuations[operationID] != nil
    }

    // MARK: - Permission Suspension (Tool Confirmation)

    /// Pauses execution for the specific operation until `resume` is called or the task is cancelled. - Parameters:
    /// `operationID` identifies this HITL operation; `conversationID` enables cancel-by-conversation. - Returns: `true` if
    /// the user approved the action, `false` if denied or cancelled.
    func suspend(for operationID: UUID, conversationID: UUID, nodeID: UUID? = nil) async -> Bool {
        // Safety: a second suspend with the same operationID auto-denies the previous one, routed through `resume(for:)` so
        // `endPark` and the index removals balance the first suspend's `beginPark`.
        if activeContinuations[operationID] != nil {
            logger.warning("[Suspension] Overwriting existing suspension for operation \(operationID). Auto-denying previous. CONSEQUENCE: the earlier waiter resolves as denied and its park closes; this new suspension parks fresh.")
            resume(for: operationID, approved: false, resolvedBy: nil)
        }

        operationToConversation[operationID] = conversationID
        if let nodeID { operationToNode[operationID] = nodeID }
        // EXC-2: reads the caller's TaskLocal — see `operationToRunToken`'s doc for why this
        // stamps every workflow-run park with no signature change.
        if let runToken = WorkflowRunScope.token { operationToRunToken[operationID] = runToken }
        beginPark(conversationID, operationID: operationID)

        logger.info("[Suspension] Suspending operation \(operationID) for conversation: \(conversationID). Indefinite — container owns the deadline.")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                activeContinuations[operationID] = continuation
                // If cancellation already happened before we parked, deny right away.
                if Task.isCancelled {
                    resume(for: operationID, approved: false, resolvedBy: nil, outcome: "cancelled")
                }
            }
        } onCancel: {
            // Stop, conversation close and container deadlines wake the parked await immediately: the waiter resolves as denied
            // (the only safe Bool), while the audit outcome says 'cancelled' since teardown is not a user decision.
            Task { await self.resume(for: operationID, approved: false, resolvedBy: nil, outcome: "cancelled") }
        }
    }

    /// Resumes a suspended operation. `approved` is the user's Allow/Deny; `outcome` overrides the audit outcome, nil
    /// derives 'approved'/'denied' from `approved`, and teardown paths pass 'cancelled' because they are not a denial
    /// (`approved` stays false).
    func resume(for operationID: UUID, approved: Bool, resolvedBy: MessageSource?, editedArguments: [String: JSONValue]? = nil, outcome: String? = nil) {
        let conversationID = operationToConversation.removeValue(forKey: operationID)
        operationToNode.removeValue(forKey: operationID)
        operationToRunToken.removeValue(forKey: operationID)
        if let conversationID { endPark(conversationID, operationID: operationID) }

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

        var resolvedInfo: [String: Any] = [HITLResolvedKey.approved: approved, HITLResolvedKey.outcome: outcome ?? (approved ? "approved" : "denied")]
        if let resolvedBy { resolvedInfo[HITLResolvedKey.source] = resolvedBy.rawValue }
        postResolved(name: .hitlPermissionResolved, operationID: operationID, conversationID: conversationID, extraInfo: resolvedInfo)
    }

    /// [HITL/A3] Returns and clears any user-edited arguments for an approved tool, so dispatch runs
    /// with the corrected values instead of the agent's originals. Nil if the user didn't edit.
    func consumeEditedArguments(for operationID: UUID) -> [String: JSONValue]? {
        editedArgs.removeValue(forKey: operationID)
    }

    // MARK: - Clarification Suspension (ask_user)

    /// Pauses execution until the user provides a text answer. - Parameters: `operationID` identifies this HITL operation;
    /// `conversationID` is the conversation it belongs to. - Returns: The user's text response, or `nil` if cancelled.
    func suspendForClarification(for operationID: UUID, conversationID: UUID, nodeID: UUID? = nil) async -> String? {
        // Safety: prevent double-suspension leaks. Via `resumeClarification` so the previous
        // park's accounting balances — see the `suspend` twin for the parkDepth leak this avoids.
        if clarificationContinuations[operationID] != nil {
            logger.warning("[Clarification] Overwriting existing clarification for operation \(operationID). Auto-cancelling previous. CONSEQUENCE: the earlier waiter resolves nil and its park closes; this new suspension parks fresh.")
            resumeClarification(for: operationID, userInput: nil, resolvedBy: nil)
        }

        operationToConversation[operationID] = conversationID
        if let nodeID { operationToNode[operationID] = nodeID }
        // EXC-2: reads the caller's TaskLocal — see `operationToRunToken`'s doc for why this
        // stamps every workflow-run park with no signature change.
        if let runToken = WorkflowRunScope.token { operationToRunToken[operationID] = runToken }
        beginPark(conversationID, operationID: operationID)

        logger.info("[Clarification] Suspending operation \(operationID) for conversation: \(conversationID). Indefinite — container owns the deadline.")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                clarificationContinuations[operationID] = continuation
                if Task.isCancelled {
                    resumeClarification(for: operationID, userInput: nil, resolvedBy: nil, outcome: "cancelled")
                }
            }
        } onCancel: {
            Task { await self.resumeClarification(for: operationID, userInput: nil, resolvedBy: nil, outcome: "cancelled") }
        }
    }

    /// Resumes a clarification suspension with the user's text input.
    /// `outcome` override: nil derives "answered"/"skipped" from `userInput`; teardown paths pass
    /// "cancelled" — a torn-down question was not skipped by the user (see `resume(for:)`).
    func resumeClarification(for operationID: UUID, userInput: String?, resolvedBy: MessageSource?, outcome: String? = nil) {
        let conversationID = operationToConversation.removeValue(forKey: operationID)
        operationToNode.removeValue(forKey: operationID)
        operationToRunToken.removeValue(forKey: operationID)
        if let conversationID { endPark(conversationID, operationID: operationID) }

        guard let continuation = clarificationContinuations.removeValue(forKey: operationID) else {
            logger.warning("[Clarification] Attempted to resume non-existent clarification for operation: \(operationID)")
            return
        }

        logger.info("[Clarification] Resuming operation \(operationID) with user input.")
        continuation.resume(returning: userInput)

        var resolvedInfo: [String: Any] = [HITLResolvedKey.outcome: outcome ?? (userInput != nil ? "answered" : "skipped")]
        if let resolvedBy { resolvedInfo[HITLResolvedKey.source] = resolvedBy.rawValue }
        postResolved(name: .hitlClarificationResolved, operationID: operationID, conversationID: conversationID, extraInfo: resolvedInfo)
    }

    // MARK: - Plan Review Suspension (indefinite — container owns the deadline)

    /// Pauses execution until the user reviews, edits, and approves the generated plan; unlike tool confirmations it has no
    /// timeout. - Parameters: `operationID` identifies this HITL operation; `conversationID` is the conversation it belongs
    /// to. - Returns: The user-edited subtask array, or `nil` if the user rejected the plan.
    func suspendForPlanReview(for operationID: UUID, conversationID: UUID, nodeID: UUID? = nil) async -> [SubTask]? {
        // Safety: prevent double-suspension leaks. Via `resumePlanReview` so the previous
        // park's accounting balances — see the `suspend` twin for the parkDepth leak this avoids.
        if planReviewContinuations[operationID] != nil {
            logger.warning("[PlanReview] Overwriting existing plan review for operation \(operationID). Auto-cancelling previous. CONSEQUENCE: the earlier waiter resolves nil and its park closes; this new suspension parks fresh.")
            resumePlanReview(for: operationID, editedPlan: nil, resolvedBy: nil)
        }

        operationToConversation[operationID] = conversationID
        if let nodeID { operationToNode[operationID] = nodeID }
        // EXC-2: reads the caller's TaskLocal — see `operationToRunToken`'s doc for why this
        // stamps every workflow-run park with no signature change.
        if let runToken = WorkflowRunScope.token { operationToRunToken[operationID] = runToken }
        beginPark(conversationID, operationID: operationID)

        logger.info("[PlanReview] Suspending operation \(operationID) for conversation: \(conversationID). No timeout — awaiting user action.")

        // NO timeout task — plan review stays indefinitely until user acts, the stream is
        // cancelled, or the execution container (workflow node / scheduled run) deadlines.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[SubTask]?, Never>) in
                planReviewContinuations[operationID] = continuation
                if Task.isCancelled {
                    resumePlanReview(for: operationID, editedPlan: nil, resolvedBy: nil, outcome: "cancelled")
                }
            }
        } onCancel: {
            Task { await self.resumePlanReview(for: operationID, editedPlan: nil, resolvedBy: nil, outcome: "cancelled") }
        }
    }

    /// Resumes a plan review suspension with the user-edited plan or nil for rejection.
    /// `outcome` override: nil derives "approved"/"rejected" from `editedPlan`; teardown paths pass
    /// "cancelled" — a torn-down review was not rejected by the user (see `resume(for:)`).
    func resumePlanReview(for operationID: UUID, editedPlan: [SubTask]?, resolvedBy: MessageSource?, outcome: String? = nil) {
        let conversationID = operationToConversation.removeValue(forKey: operationID)
        operationToNode.removeValue(forKey: operationID)
        operationToRunToken.removeValue(forKey: operationID)
        if let conversationID { endPark(conversationID, operationID: operationID) }

        guard let continuation = planReviewContinuations.removeValue(forKey: operationID) else {
            logger.warning("[PlanReview] Attempted to resume non-existent plan review for operation: \(operationID)")
            return
        }

        logger.info("[PlanReview] Resuming operation \(operationID) with \(editedPlan != nil ? "approved plan (\(editedPlan!.count) subtasks)" : "rejection").")
        continuation.resume(returning: editedPlan)

        var resolvedInfo: [String: Any] = [HITLResolvedKey.outcome: outcome ?? (editedPlan != nil ? "approved" : "rejected")]
        if let resolvedBy { resolvedInfo[HITLResolvedKey.source] = resolvedBy.rawValue }
        postResolved(name: .hitlPlanReviewResolved, operationID: operationID, conversationID: conversationID, extraInfo: resolvedInfo)
    }

    // MARK: - Gate Suspension (workflow Gate — per-option routing, E1)

    /// Pauses a workflow Gate node until the user picks an option (routes to that option's port) or the
    /// gate is cancelled / times out. Returns the chosen option string, or `nil` if cancelled/timed out.
    func suspendForGate(for operationID: UUID, conversationID: UUID, nodeID: UUID? = nil) async -> String? {
        // Via `resumeGate` so the previous park's accounting balances — see the `suspend` twin
        // for the parkDepth leak this avoids.
        if gateContinuations[operationID] != nil {
            logger.warning("[Gate] Overwriting existing gate suspension for operation \(operationID). Auto-cancelling previous. CONSEQUENCE: the earlier waiter resolves nil and its park closes; this new suspension parks fresh.")
            resumeGate(for: operationID, chosenOption: nil, resolvedBy: nil)
        }

        operationToConversation[operationID] = conversationID
        if let nodeID { operationToNode[operationID] = nodeID }
        // EXC-2: reads the caller's TaskLocal — see `operationToRunToken`'s doc for why this
        // stamps every workflow-run park with no signature change.
        if let runToken = WorkflowRunScope.token { operationToRunToken[operationID] = runToken }
        beginPark(conversationID, operationID: operationID)
        logger.info("[Gate] Suspending operation \(operationID) for conversation: \(conversationID). Indefinite — container owns the deadline.")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                gateContinuations[operationID] = continuation
                if Task.isCancelled {
                    resumeGate(for: operationID, chosenOption: nil, resolvedBy: nil)
                }
            }
        } onCancel: {
            Task { await self.resumeGate(for: operationID, chosenOption: nil, resolvedBy: nil) }
        }
    }

    /// Resumes a gate suspension with the user's chosen option (nil = cancelled / expired / rejected). - Parameter outcome:
    /// what to report when there is no choice; nil means 'cancelled', a gate's own timer passes 'expired'.
    func resumeGate(for operationID: UUID, chosenOption: String?, resolvedBy: MessageSource?, outcome: String? = nil) {
        let conversationID = operationToConversation.removeValue(forKey: operationID)
        operationToNode.removeValue(forKey: operationID)
        operationToRunToken.removeValue(forKey: operationID)
        if let conversationID { endPark(conversationID, operationID: operationID) }

        guard let continuation = gateContinuations.removeValue(forKey: operationID) else {
            logger.warning("[Gate] Attempted to resume non-existent gate for operation: \(operationID)")
            return
        }

        logger.info("[Gate] Resuming operation \(operationID) with choice: \(chosenOption ?? "<none>")")
        continuation.resume(returning: chosenOption)

        var resolvedInfo: [String: Any] = [HITLResolvedKey.outcome: chosenOption ?? outcome ?? "cancelled"]
        if let resolvedBy { resolvedInfo[HITLResolvedKey.source] = resolvedBy.rawValue }
        postResolved(name: .hitlGateResolved, operationID: operationID, conversationID: conversationID, extraInfo: resolvedInfo)
    }

    // MARK: - Cancellation & Status

    /// Force-cancels all suspensions for a conversation (e.g. the user stops the stream): `false` for permissions, `nil` for
    /// clarifications. Conversation-scoped by design, including token-less parks; a workflow root run's own stop uses
    /// `cancelRun` instead.
    func cancel(for conversationID: UUID) {
        // Find all operations belonging to this conversation
        let permissionOps = operationToConversation.filter { $0.value == conversationID }.map(\.key)

        for opID in permissionOps {
            drainOperation(opID, conversationID: conversationID, outcome: "cancelled")
        }
    }

    /// Force-cancels the parks owned by one time bound (raised inside its chain, or out of chain while it was open in its
    /// conversation), for a container deadline such as the scheduler's per-run limit, so an attended run queued behind it is
    /// not denied.
    @discardableResult
    func cancel(scope: UUID) -> [UUID] {
        let owned = operationToScopes.filter { $0.value.contains(scope) }.map(\.key)
        for opID in owned {
            guard let conversationID = operationToConversation[opID] else { continue }
            drainOperation(opID, conversationID: conversationID, outcome: "cancelled")
        }
        if !owned.isEmpty {
            logger.info("[Suspension] Drained \(owned.count) park(s) owned by bound \(scope.uuidString.prefix(8)). CONSEQUENCE: each resolves as cancelled; parks owned by other runs in the conversation are untouched.")
        }
        return owned
    }

    /// Force-cancels one workflow run's suspensions, leaving a concurrent run's parks standing; returns the operations it
    /// resolved. Drains operations whose run token matches plus token-less ones (MCP consents carry none); the run-scoped
    /// sibling of `cancel(for:)`.
    @discardableResult
    func cancelRun(_ runToken: UUID, in conversationID: UUID) -> [UUID] {
        let conversationOps = operationToConversation.filter { $0.value == conversationID }.map(\.key)
        let drained = conversationOps.filter { operationToRunToken[$0] == nil || operationToRunToken[$0] == runToken }
        let survivors = conversationOps.count - drained.count
        // Counted before the drain loop: `drainOperation` removes the token entry, so counting after would report every op as
        // token-less.
        let tokenless = drained.filter { operationToRunToken[$0] == nil }.count

        for opID in drained {
            drainOperation(opID, conversationID: conversationID, outcome: "cancelled")
        }
        if !drained.isEmpty || survivors > 0 {
            logger.info("[Suspension] Run-scoped drain for run \(runToken.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)): resolved \(drained.count) park(s) (\(tokenless) token-less, swept by conversation). CONSEQUENCE: \(survivors) park(s) belonging to a DIFFERENT run survive THIS drain and stay awaiting the user. ⚠️ Scope honesty: the attended Stop surfaces (MessagingCoordinator, scheduler deadline, ChatOps /cancel) still run their own conversation-wide cancel(for:) BEFORE this arm — run-scoping those is the concurrency design's deferred increment 2, which this token machinery now unblocks.")
        }
        return drained
    }

    // Why: when the caller runs inside a workflow run, the park's token must also match: concurrent runs of the same
    // workflow share node IDs.
    /// Force-resolves every park belonging to one workflow node, leaving siblings alone; returns the operations it resolved.
    /// Separate from `cancel(for:)` because parks with no node dimension would otherwise never drain; the `conversationID`
    /// term guards against stale node ids.
    @discardableResult
    func cancelNode(_ nodeID: UUID, in conversationID: UUID, outcome: String = "cancelled") -> [UUID] {
        let callerToken = WorkflowRunScope.token
        let ops = operationToConversation
            .filter { $0.value == conversationID && operationToNode[$0.key] == nodeID }
            .filter { callerToken == nil || operationToRunToken[$0.key] == nil || operationToRunToken[$0.key] == callerToken }
            .map(\.key)

        guard !ops.isEmpty else { return [] }
        for opID in ops {
            drainOperation(opID, conversationID: conversationID, outcome: outcome)
        }
        logger.info("[Suspension] Node-scoped drain resolved \(ops.count) park(s) for node \(nodeID.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)). CONSEQUENCE: only this node's banners clear; a sibling node's parked request is untouched and still awaiting the user.")
        return ops
    }

    // Why: exactly one `endPark` per drained operation: an extra one closes the parked-time window early while a
    // sibling is still parked.
    /// Resolves one parked operation: drops its indexes, closes its park, resumes whichever continuation kind it holds, and
    /// posts the resolved notification. `outcome` is free-form and rendered verbatim downstream; 'cancelled' is the teardown
    /// value.
    private func drainOperation(_ opID: UUID, conversationID: UUID, outcome: String) {
        operationToConversation.removeValue(forKey: opID)
        operationToNode.removeValue(forKey: opID)
        operationToRunToken.removeValue(forKey: opID)
        // Force-cancel closes the park too; otherwise the depth never returns to zero and `cumulativeParkedTime` grows forever.
        endPark(conversationID, operationID: opID)
        editedArgs.removeValue(forKey: opID)

        // Posts the matching resolved notification so every surface (banners, InteractionCenter, ChatOps remote mirror) clears
        // at once. No `HITLResolvedKey.source` is set on purpose: a force-cancel or deadline is not a person answering.
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

    /// Whether a specific workflow node has a park awaiting the user; drives per-node affordances in the timeline. Answers
    /// only for parks that carry a node dimension; chat and MCP broker parks are invisible here.
    func isSuspended(node nodeID: UUID, in conversationID: UUID) -> Bool {
        operationToConversation.contains { $0.value == conversationID && operationToNode[$0.key] == nodeID }
    }

    // MARK: - Notification Helper

    /// Posts an HITL resolved notification on the main actor for cross-surface deduplication.
    /// Centralizes the pattern used by all resume/timeout paths to prevent drift.
    // MARK: - Resolution memory

    /// Operations resolved recently, oldest first. Bounded: it only has to outlive the gap between
    /// a request being raised and its banner being shown.
    private var recentlyResolved: [UUID] = []
    private var recentlyResolvedSet: Set<UUID> = []
    private static let recentlyResolvedLimit = 512

    /// Whether `operationID` has already been answered, denied, cancelled or drained. Only an operation actually resolved is
    /// reported, not 'not pending': a request is raised before its suspension registers, so a pending check could hide a
    /// live banner.
    func wasResolved(_ operationID: UUID) -> Bool {
        recentlyResolvedSet.contains(operationID)
    }

    private func rememberResolved(_ operationID: UUID) {
        guard recentlyResolvedSet.insert(operationID).inserted else { return }
        recentlyResolved.append(operationID)
        if recentlyResolved.count > Self.recentlyResolvedLimit {
            recentlyResolvedSet.remove(recentlyResolved.removeFirst())
        }
    }

    private func postResolved(
        name: Notification.Name,
        operationID: UUID,
        conversationID: UUID?,
        extraInfo: sending [String: Any] = [:]
    ) {
        rememberResolved(operationID)
        let wrappedExtra = UnsafeSendable(extraInfo)
        Task { @MainActor in
            var userInfo: [String: Any] = [HITLResolvedKey.operationID: operationID]
            if let conversationID { userInfo[HITLResolvedKey.conversationID] = conversationID }
            for (key, value) in wrappedExtra.value { userInfo[key] = value }
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
        }
    }
}
