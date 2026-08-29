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
//  KEYED ON THE RUN TOKEN (`WorkflowRunScope.token`), not the conversation. [WF-CC14] This file
//  used to be conversation-keyed on the one-root-run-per-conversation invariant (§0.5) with its
//  own header warning "If that invariant ever falls, this store must move to run-ID keying in the
//  same change" — and the invariant was never enforced on the inbound start paths (chat, ChatOps,
//  scheduler, Jarvis carry no admission check; `RunAdmissionPolicy` is deliberately Redo/Resume-
//  only until increment 4). A scheduled re-run of the SAME workflow into the same conversation
//  has IDENTICAL node IDs, so under conversation keying run 2's start-clear silently discarded
//  the user's requests for run 1, run 2 could consume a request aimed at run 1 (skipping a node
//  in an unattended run the user never touched), and run 2's racer registration COLLIDED with
//  run 1's live waiter for the same node — leaking the continuation. Token keying makes each
//  run's namespace disjoint by construction:
//
//    • The ENGINE passes its `runToken` explicitly — a superseded run keeps consuming its OWN
//      requests, and can never see a successor's.
//    • The UI stays conversation-keyed (it acts on "the run this conversation currently shows")
//      and the store resolves conversation → `activeRun` token at write time. Writes landing
//      before any run is live go to a STAGED per-conversation set that the next `beginRun`
//      adopts — the integration shape "request already present when dispatch reaches the node".
//      The live UI cannot actually write pre-run (every Skip surface is gated on a state that
//      only the first `workflowNodeStarted` sets, which the executor emits after `beginRun`),
//      so staging is a defensive seam, not a user path.
//    • A previous run's namespace is NOT swept at `beginRun` — it dies at that run's own
//      `endRun`, which every terminal exit of the executor now calls (success, cancel, and both
//      failure arms — the missing cancel/error releases were WF-OB15) and which is token-guarded
//      so a superseded run's late end cannot wipe its successor's requests.
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

    // MARK: - Run scoping [WF-CC14]

    /// conversationID → the token of the run that currently OWNS the conversation's skip UI.
    /// Written by `beginRun`/`endRun`; read by every conversation-keyed (UI) entry point.
    private(set) var activeRun: [UUID: UUID] = [:]

    /// conversationID → node IDs toggled while NO run owned the conversation. Adopted wholesale
    /// by the next `beginRun`. See the header for why this is a defensive seam.
    private(set) var staged: [UUID: Set<UUID>] = [:]

    /// runToken → the node IDs whose next dispatch should skip.
    private(set) var requested: [UUID: Set<UUID>] = [:]

    /// Root run start: claim the conversation's skip UI and adopt anything staged for it.
    /// Replaces the old start-CLEAR — a fresh token has no leftovers by construction, and a
    /// concurrent run's namespace is deliberately left alone (it dies at that run's `endRun`).
    func beginRun(conversationID: UUID, runToken: UUID) {
        if let previous = activeRun[conversationID], previous != runToken {
            let previousPending = requested[previous]?.count ?? 0
            logger.notice("[NODE-SKIP] Run \(runToken.uuidString.prefix(8)) claimed conv \(conversationID.uuidString.prefix(8))'s skip UI from run \(previous.uuidString.prefix(8)) (\(previousPending) pending request(s) in the superseded run's namespace). CONSEQUENCE: new Skip clicks target the NEW run; the superseded run keeps consuming only its own existing requests and releases them at its own end. Two live runs in one conversation means the admission invariant (§0.5) was bypassed — see the [WF_RUN] displacement error at bootstrap.")
        }
        activeRun[conversationID] = runToken
        if let adopted = staged.removeValue(forKey: conversationID), !adopted.isEmpty {
            requested[runToken, default: []].formUnion(adopted)
            logger.notice("[NODE-SKIP] Run \(runToken.uuidString.prefix(8)) adopted \(adopted.count) staged skip request(s) for conv \(conversationID.uuidString.prefix(8)). CONSEQUENCE: they behave as if clicked during this run — consumed at dispatch, or released logged at run end.")
        }
    }

    /// Terminal exit of a root run (every arm: success, cancel, failure): release this run's
    /// namespace. Token-scoped, so a superseded run's late end touches nothing of its successor's.
    func endRun(conversationID: UUID, runToken: UUID, reason: StaticString) {
        if let dropped = requested.removeValue(forKey: runToken), !dropped.isEmpty {
            logger.info("[NODE-SKIP] Released \(dropped.count) unconsumed skip request(s) of run \(runToken.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8)), \(reason)). CONSEQUENCE: they apply to no run; the nodes execute normally next time.")
        }
        let staleRequests = pendingRunningRequests.filter { $0.runToken == runToken }
        if !staleRequests.isEmpty {
            pendingRunningRequests.subtract(staleRequests)
            logger.info("[NODE-SKIP] Released \(staleRequests.count) unconsumed RUNNING-skip request(s) of run \(runToken.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8)), \(reason)). CONSEQUENCE: they apply to no run; the nodes execute normally next time.")
        }
        firedRunningSkips.removeValue(forKey: runToken)
        for key in waiterOutcomes.keys.filter({ $0.runToken == runToken }) {
            waiterOutcomes.removeValue(forKey: key)
        }
        // A waiter surviving to its OWN run's end is an invariant violation (every waiter lives
        // inside a node's racer group, which the run awaits before reaching any terminal arm) —
        // resume it so the continuation cannot leak, and log the violation rather than hiding it.
        let staleWaiters = runningWaiters.keys.filter { $0.runToken == runToken }
        for key in staleWaiters {
            if let cont = runningWaiters.removeValue(forKey: key) {
                logger.error("[NODE-SKIP] Running-skip WAITER for node \(key.nodeID.uuidString.prefix(8)) survived to its run's \(reason) release — invariant violation (waiters must die with their node's racer group). CONSEQUENCE: it is resumed un-fired so the continuation cannot leak; its awaiter sees a plain cancellation.")
                waiterOutcomes[key] = false
                cont.resume()
            }
        }
        // Release ownership only if this run still holds it — a superseded run's late end must
        // not evict the successor's claim.
        if activeRun[conversationID] == runToken {
            activeRun[conversationID] = nil
        }
    }

    // MARK: - Pending-skip channel (UI half — conversation-keyed, resolved to the active run)

    /// Toggle from the timeline row's button ("Skip" ↔ "Undo skip").
    func toggle(nodeID: UUID, conversationID: UUID) {
        guard let token = activeRun[conversationID] else {
            // No live run owns this conversation — stage for the next one (defensive; the Skip
            // surfaces are gated on a running state that only exists after `beginRun`).
            if staged[conversationID, default: []].contains(nodeID) {
                staged[conversationID]?.remove(nodeID)
                logger.info("[NODE-SKIP] Undo STAGED skip request for node \(nodeID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8)), no run live). CONSEQUENCE: the next run will not adopt it.")
            } else {
                staged[conversationID, default: []].insert(nodeID)
                logger.notice("[NODE-SKIP] Skip requested for node \(nodeID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))) with NO run live — STAGED. CONSEQUENCE: the next run to start in this conversation adopts it at beginRun; undoable until then.")
            }
            return
        }
        if requested[token, default: []].contains(nodeID) {
            requested[token]?.remove(nodeID)
            logger.info("[NODE-SKIP] Undo skip request for node \(nodeID.uuidString.prefix(8)) (run \(token.uuidString.prefix(8))). CONSEQUENCE: the node will execute normally when dispatch reaches it.")
        } else {
            requested[token, default: []].insert(nodeID)
            logger.notice("[NODE-SKIP] Skip requested for node \(nodeID.uuidString.prefix(8)) (run \(token.uuidString.prefix(8))). CONSEQUENCE: when dispatch reaches this node it will be recorded as skipped-by-user and its INPUT forwarded downstream unchanged; undoable until then.")
        }
    }

    /// Whether a request is pending — drives the button label. Reading this in a SwiftUI `body`
    /// registers observation, so consume/release from the engine re-renders the row.
    func isRequested(nodeID: UUID, conversationID: UUID) -> Bool {
        if let token = activeRun[conversationID] {
            return requested[token]?.contains(nodeID) ?? false
        }
        return staged[conversationID]?.contains(nodeID) ?? false
    }

    // MARK: - Pending-skip channel (engine half — token-keyed)

    /// Engine-side check-and-remove, called once per profile node at dispatch. Consuming (rather
    /// than reading) is what makes the request single-shot: it cannot linger and silently skip
    /// the same node in a later run. Reads ONLY the caller's own namespace — a concurrent run's
    /// requests are invisible by construction [WF-CC14].
    func consume(nodeID: UUID, conversationID: UUID, runToken: UUID?) -> Bool {
        guard let runToken else { return false }
        guard requested[runToken]?.remove(nodeID) != nil else { return false }
        if requested[runToken]?.isEmpty == true { requested[runToken] = nil }
        return true
    }

    /// Test/teardown hygiene (and the future conversation-deletion hook): release the active
    /// run's namespace and drop anything staged. Not called by the executor — runs release their
    /// own namespaces via `endRun` on every terminal arm.
    func clear(conversationID: UUID, reason: StaticString) {
        if let dropped = staged.removeValue(forKey: conversationID), !dropped.isEmpty {
            logger.info("[NODE-SKIP] Cleared \(dropped.count) STAGED skip request(s) for conv \(conversationID.uuidString.prefix(8)) (\(reason)). CONSEQUENCE: no future run adopts them.")
        }
        if let token = activeRun[conversationID] {
            endRun(conversationID: conversationID, runToken: token, reason: reason)
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

    /// One running-skip key. Token-scoped [WF-CC14]: two runs of the same workflow have IDENTICAL
    /// node IDs, so a conversation-scoped key let run 2's racer registration overwrite run 1's
    /// LIVE continuation — a leak that parked run 1's node forever.
    struct RunningSkipKey: Hashable {
        let runToken: UUID
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
    /// runToken → nodes whose running-skip has FIRED. Observable — drives the UI's
    /// "Skipping…" state — and consulted by the executor's cancellation verdict repair.
    private(set) var firedRunningSkips: [UUID: Set<UUID>] = [:]

    /// UI entry point: skip this RUNNING node now. Not undoable — the racer child may already have
    /// observed it by the time this returns. Idempotent: a second click while the first is in
    /// flight is a logged no-op. Targets the ACTIVE run — the only one whose nodes the UI shows.
    func requestRunningSkip(nodeID: UUID, conversationID: UUID) {
        guard let token = activeRun[conversationID] else {
            logger.warning("[NODE-SKIP] RUNNING-skip requested for node \(nodeID.uuidString.prefix(8)) (conv \(conversationID.uuidString.prefix(8))) but NO run owns this conversation. CONSEQUENCE: dropped — a running-skip targets in-flight work, and there is none to target.")
            return
        }
        let key = RunningSkipKey(runToken: token, nodeID: nodeID)
        if firedRunningSkips[token]?.contains(nodeID) == true || pendingRunningRequests.contains(key) {
            logger.info("[NODE-SKIP] Duplicate RUNNING-skip request for node \(nodeID.uuidString.prefix(8)) (run \(token.uuidString.prefix(8))) ignored — already \(self.pendingRunningRequests.contains(key) ? "buffered" : "fired"). CONSEQUENCE: nothing changes; the first request stands.")
            return
        }
        if let waiter = runningWaiters.removeValue(forKey: key) {
            firedRunningSkips[token, default: []].insert(nodeID)
            waiterOutcomes[key] = true
            logger.notice("[NODE-SKIP] RUNNING-skip fired for node \(nodeID.uuidString.prefix(8)) (run \(token.uuidString.prefix(8))). CONSEQUENCE: the node's in-flight work is being torn down NOW (not undoable); its INPUT will be forwarded downstream unchanged and partial output is discarded.")
            waiter.resume()
        } else {
            pendingRunningRequests.insert(key)
            logger.notice("[NODE-SKIP] RUNNING-skip requested for node \(nodeID.uuidString.prefix(8)) (run \(token.uuidString.prefix(8))) with no waiter registered — buffered. CONSEQUENCE: the node's next racer registration (dispatch or retry attempt) consumes it immediately; if the node finishes first, the request dies at the run-end release and is logged there.")
        }
    }

    /// Whether a running-skip fired for this node — the executor's verdict repair reads this to
    /// classify a raced teardown honestly. Token-keyed: a concurrent run's firing is not ours.
    func runningSkipFired(nodeID: UUID, conversationID: UUID, runToken: UUID?) -> Bool {
        guard let runToken else { return false }
        return firedRunningSkips[runToken]?.contains(nodeID) == true
    }

    /// Whether a running-skip is buffered or fired — the UI's "Skipping…" covers both (a buffered
    /// request is already irrevocable from the user's side; it fires the instant a waiter appears).
    func runningSkipInFlight(nodeID: UUID, conversationID: UUID) -> Bool {
        guard let token = activeRun[conversationID] else { return false }
        return pendingRunningRequests.contains(RunningSkipKey(runToken: token, nodeID: nodeID))
            || firedRunningSkips[token]?.contains(nodeID) == true
    }

    /// The racer child's wait. Returns when a running-skip fires for this node; throws
    /// `CancellationError` when the node finishes first (the group cancels the child).
    ///
    /// Also the PENDING-request bridge: a Phase A toggle that landed after dispatch's pre-flight
    /// consult (the row still said "Waiting" when the user clicked, but the node had started) would
    /// otherwise sit inert until run end while the row misleadingly shows "Undo skip". Consuming it
    /// here converts that near-miss into the running-skip the user visibly asked for.
    ///
    /// A `nil` token registers under a fresh unfireable key: no `requestRunningSkip` can ever
    /// resolve it, so the await parks until the racer group cancels it — exactly the semantics of
    /// "this run has no skip channel" with none of the special-casing.
    func awaitRunningSkip(nodeID: UUID, conversationID: UUID, runToken: UUID?) async throws {
        let key = RunningSkipKey(runToken: runToken ?? UUID(), nodeID: nodeID)

        if consume(nodeID: nodeID, conversationID: conversationID, runToken: runToken) {
            logger.notice("[NODE-SKIP] Stale PENDING-skip request for node \(nodeID.uuidString.prefix(8)) (run \(key.runToken.uuidString.prefix(8))) found by the racer child — the toggle landed after dispatch. Bridged to a RUNNING-skip. CONSEQUENCE: the node tears down now instead of the request dying unconsumed at run end.")
            firedRunningSkips[key.runToken, default: []].insert(nodeID)
            return
        }
        if pendingRunningRequests.remove(key) != nil {
            firedRunningSkips[key.runToken, default: []].insert(nodeID)
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
