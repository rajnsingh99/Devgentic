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
        if let dropped = requested.removeValue(forKey: conversationID), !dropped.isEmpty {
            logger.info("[NODE-SKIP] Cleared \(dropped.count) unconsumed skip request(s) for conv \(conversationID.uuidString.prefix(8)) (\(reason)). CONSEQUENCE: they apply to no run; the nodes execute normally next time.")
        }
        // Running-skip channel hygiene (Phase B). Buffered requests and fired markers die with the
        // run; a leftover WAITER is an invariant violation (every waiter lives inside a node's racer
        // group, which the run awaits before reaching either clear) — resume it so the continuation
        // cannot leak, and log the violation rather than hiding it.
        let staleRequests = pendingRunningRequests.filter { $0.conversationID == conversationID }
        if !staleRequests.isEmpty {
            pendingRunningRequests.subtract(staleRequests)
            logger.info("[NODE-SKIP] Cleared \(staleRequests.count) unconsumed RUNNING-skip request(s) for conv \(conversationID.uuidString.prefix(8)) (\(reason)). CONSEQUENCE: they apply to no run; the nodes execute normally next time.")
        }
        firedRunningSkips.removeValue(forKey: conversationID)
        for key in waiterOutcomes.keys.filter({ $0.conversationID == conversationID }) {
            waiterOutcomes.removeValue(forKey: key)
        }
        let staleWaiters = runningWaiters.keys.filter { $0.conversationID == conversationID }
        for key in staleWaiters {
            if let cont = runningWaiters.removeValue(forKey: key) {
                logger.error("[NODE-SKIP] Running-skip WAITER for node \(key.nodeID.uuidString.prefix(8)) survived to the \(reason) clear — invariant violation (waiters must die with their node's racer group). CONSEQUENCE: it is resumed un-fired so the continuation cannot leak; its awaiter sees a plain cancellation.")
                waiterOutcomes[key] = false
                cont.resume()
            }
        }
    }

    // MARK: - Running-skip channel (Phase B increment 5, D2.1)
    //
    // The SECOND channel, deliberately separate from `requested`. A pending-skip is freely
    // undoable until dispatch consumes it — that undoability is the whole no-confirmation-dialog
    // rationale in the header. A RUNNING-skip is not undoable: it interrupts work in flight the
    // moment the node's racer child observes it. Overloading `requested`/`consume` would blur the
    // two contracts; two channels keep each one's semantics honest.
    //
    // Signal path: the UI calls `requestRunningSkip`; the node's racer child awaits
    // `awaitRunningSkip`. Requests BUFFER (a request landing between retry attempts, or in the
    // instants before the racer child registers, is honoured by the next registration) and fire
    // exactly once. `firedRunningSkips` records consumption for the executor's verdict repair —
    // "did a skip fire for this node?" — and for the UI's non-undoable "Skipping…" state.

    /// One running-skip key. Conversation-scoped for the same §0.5 reason as `requested`.
    struct RunningSkipKey: Hashable {
        let conversationID: UUID
        let nodeID: UUID
    }

    /// Requests that arrived while no waiter was registered (node between retry attempts, or the
    /// register race). Consumed by the next `awaitRunningSkip` for the key.
    private var pendingRunningRequests: Set<RunningSkipKey> = []
    /// Continuations of racer children currently awaiting a signal.
    private var runningWaiters: [RunningSkipKey: CheckedContinuation<Void, Never>] = [:]
    /// Why THIS await's continuation was resumed: `true` = a request fired it, `false` = the
    /// group cancelled it. Written by the resumer (both run on MainActor, before resuming),
    /// consumed by the awaiter after its continuation returns.
    ///
    /// ⚠️ Per-AWAIT, deliberately not `firedRunningSkips`: that marker is per-NODE and persists
    /// for the run (the verdict repair needs it), so a later stray registration for an
    /// already-fired node would read it and report a firing that never touched this waiter —
    /// a cancelled await claiming success.
    private var waiterOutcomes: [RunningSkipKey: Bool] = [:]
    /// conversationID → nodes whose running-skip has FIRED. Observable — drives the UI's
    /// "Skipping…" state — and consulted by the executor's cancellation verdict repair.
    private(set) var firedRunningSkips: [UUID: Set<UUID>] = [:]

    /// UI entry point: skip this RUNNING node now. Not undoable — the racer child may already have
    /// observed it by the time this returns. Idempotent: a second click while the first is in
    /// flight is a logged no-op.
    func requestRunningSkip(nodeID: UUID, conversationID: UUID) {
        let key = RunningSkipKey(conversationID: conversationID, nodeID: nodeID)
        if firedRunningSkips[conversationID]?.contains(nodeID) == true || pendingRunningRequests.contains(key) {
            logger.info("[NODE-SKIP] Duplicate RUNNING-skip request for node \(nodeID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))) ignored — already \(self.pendingRunningRequests.contains(key) ? "buffered" : "fired"). CONSEQUENCE: nothing changes; the first request stands.")
            return
        }
        if let waiter = runningWaiters.removeValue(forKey: key) {
            firedRunningSkips[conversationID, default: []].insert(nodeID)
            waiterOutcomes[key] = true
            logger.notice("[NODE-SKIP] RUNNING-skip fired for node \(nodeID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))). CONSEQUENCE: the node's in-flight work is being torn down NOW (not undoable); its INPUT will be forwarded downstream unchanged and partial output is discarded.")
            waiter.resume()
        } else {
            pendingRunningRequests.insert(key)
            logger.notice("[NODE-SKIP] RUNNING-skip requested for node \(nodeID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))) with no waiter registered — buffered. CONSEQUENCE: the node's next racer registration (dispatch or retry attempt) consumes it immediately; if the node finishes first, the request dies at the run-end clear and is logged there.")
        }
    }

    /// Whether a running-skip fired for this node — the executor's verdict repair reads this to
    /// classify a raced teardown honestly, and the UI reads it (observably) for "Skipping…".
    func runningSkipFired(nodeID: UUID, conversationID: UUID) -> Bool {
        firedRunningSkips[conversationID]?.contains(nodeID) == true
    }

    /// Whether a running-skip is buffered or fired — the UI's "Skipping…" covers both (a buffered
    /// request is already irrevocable from the user's side; it fires the instant a waiter appears).
    func runningSkipInFlight(nodeID: UUID, conversationID: UUID) -> Bool {
        pendingRunningRequests.contains(RunningSkipKey(conversationID: conversationID, nodeID: nodeID))
            || firedRunningSkips[conversationID]?.contains(nodeID) == true
    }

    /// The racer child's wait. Returns when a running-skip fires for this node; throws
    /// `CancellationError` when the node finishes first (the group cancels the child).
    ///
    /// Also the PENDING-request bridge: a Phase A toggle that landed after dispatch's pre-flight
    /// consult (the row still said "Waiting" when the user clicked, but the node had started) would
    /// otherwise sit inert until run end while the row misleadingly shows "Undo skip". Consuming it
    /// here converts that near-miss into the running-skip the user visibly asked for.
    func awaitRunningSkip(nodeID: UUID, conversationID: UUID) async throws {
        let key = RunningSkipKey(conversationID: conversationID, nodeID: nodeID)

        if consume(nodeID: nodeID, conversationID: conversationID) {
            logger.notice("[NODE-SKIP] Stale PENDING-skip request for node \(nodeID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))) found by the racer child — the toggle landed after dispatch. Bridged to a RUNNING-skip. CONSEQUENCE: the node tears down now instead of the request dying unconsumed at run end.")
            firedRunningSkips[conversationID, default: []].insert(nodeID)
            return
        }
        if pendingRunningRequests.remove(key) != nil {
            firedRunningSkips[conversationID, default: []].insert(nodeID)
            logger.notice("[NODE-SKIP] Buffered RUNNING-skip for node \(nodeID.uuidString.prefix(8)) consumed at racer registration. CONSEQUENCE: the node tears down now.")
            return
        }

        try Task.checkCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                runningWaiters[key] = continuation
                // Cancellation may have landed between the check above and this install — the
                // same pre-install race ExecutionSuspensionService's suspend* bodies guard.
                if Task.isCancelled { cancelRunningWaiter(key) }
            }
        } onCancel: {
            Task { @MainActor in WorkflowNodeSkipStore.shared.cancelRunningWaiter(key) }
        }
        // Both resumers run on MainActor and mutate `waiterOutcomes` BEFORE resuming, so this
        // read is deterministic: true ⇒ the request fired THIS waiter; anything else ⇒ the group
        // cancelled it.
        guard waiterOutcomes.removeValue(forKey: key) == true else {
            throw CancellationError()
        }
    }

    /// Resolves a waiter without firing it (node finished; group cancelled the racer child).
    private func cancelRunningWaiter(_ key: RunningSkipKey) {
        guard let cont = runningWaiters.removeValue(forKey: key) else { return }
        waiterOutcomes[key] = false
        cont.resume()
    }
}
