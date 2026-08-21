//
//  WorkflowNodeSkipStore.swift
//  Devgentic
//
//  The UI→engine channel for per-node SKIP requests — Phase A of the per-node skip design
//  (`LLM_Execution_Concurrency_Design.md` §0.6 D2.1, owner-ratified 2026-08-21).
//
//  A request means: when dispatch reaches this node, do not execute it — record it as
//  `.skipped(.byUser)` and forward its INPUT downstream unchanged. Requests target PENDING nodes
//  only in Phase A; the timeline row's button toggles them freely until dispatch consumes them,
//  which is why no confirmation dialog exists — an un-consumed request is always undoable.
//
//  KEYED ON conversationID + nodeID, and conversation keying is sound ONLY because of the
//  one-root-run-per-conversation invariant (§0.5): at most one root run is live per conversation,
//  so "the run this request belongs to" is unambiguous. If that invariant ever falls, this store
//  must move to run-ID keying in the same change.
//
//  `@MainActor @Observable` rather than an actor (the `ExecutionSuspensionService` shape) because
//  this store has a UI half the suspension service does not: the timeline button's label derives
//  from `isRequested`, and Observation gives that re-render for free when the view reads it in
//  `body`. The executor pays one MainActor hop per profile-node dispatch, which is noise against
//  the model call that follows.
//
import Foundation
import Observation

private let logger = DGLogger(category: "WorkflowNodeSkipStore")

@MainActor
@Observable
final class WorkflowNodeSkipStore {

    static let shared = WorkflowNodeSkipStore()

    /// conversationID → the node IDs whose next dispatch should skip.
    private(set) var requested: [UUID: Set<UUID>] = [:]

    /// Toggle from the timeline row's button ("Skip" ↔ "Undo skip").
    func toggle(nodeID: UUID, conversationID: UUID) {
        if requested[conversationID, default: []].contains(nodeID) {
            requested[conversationID]?.remove(nodeID)
            logger.info("[NODE-SKIP] Undo skip request for node \(nodeID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: the node will execute normally when dispatch reaches it.")
        } else {
            requested[conversationID, default: []].insert(nodeID)
            logger.notice("[NODE-SKIP] Skip requested for node \(nodeID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: when dispatch reaches this node it will be recorded as skipped-by-user and its INPUT forwarded downstream unchanged; undoable until then.")
        }
    }

    /// Whether a request is pending — drives the button label. Reading this in a SwiftUI `body`
    /// registers observation, so consume/clear from the engine re-renders the row.
    func isRequested(nodeID: UUID, conversationID: UUID) -> Bool {
        requested[conversationID]?.contains(nodeID) ?? false
    }

    /// Engine-side check-and-remove, called once per profile node at dispatch. Consuming (rather
    /// than reading) is what makes the request single-shot: it cannot linger and silently skip
    /// the same node in a later run.
    func consume(nodeID: UUID, conversationID: UUID) -> Bool {
        guard requested[conversationID]?.remove(nodeID) != nil else { return false }
        if requested[conversationID]?.isEmpty == true { requested[conversationID] = nil }
        return true
    }

    /// Called by the executor at ROOT-run start and end (never for nested sub-workflow runs, which
    /// share the conversationID and would wipe the outer run's pending requests). Start-clear is
    /// the correctness guard — a request left over from a previous run must not skip anything in
    /// a fresh one; end-clear is hygiene for requests dispatch never reached.
    func clear(conversationID: UUID, reason: StaticString) {
        guard let dropped = requested.removeValue(forKey: conversationID), !dropped.isEmpty else { return }
        logger.info("[NODE-SKIP] Cleared \(dropped.count) unconsumed skip request(s) for conv \(conversationID.uuidString.prefix(8)) (\(reason)). CONSEQUENCE: they apply to no run; the nodes execute normally next time.")
    }
}
