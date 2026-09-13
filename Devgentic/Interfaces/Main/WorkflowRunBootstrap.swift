// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowRunBootstrap.swift
//  Devgentic
//
//  The workflow-run bookkeeping every `startMessageStream` caller must perform when the profile
//  is a workflow: create the live `WorkflowExecutionState`, insert the `.running` stub record so
//  the run is discoverable from frame 1, and freeze + persist the finalized record when the
//  stream ends.
//
//  ⚠️ THIS EXISTS BECAUSE IT WAS INLINE IN EXACTLY ONE CALL SITE.
//
//  `MessagingCoordinator.sendMessage` did all of it; the other six `startMessageStream` callers —
//  scheduled runs, ChatOps, regenerate, QuickAccess, Jarvis, resume — did none of it. Those runs
//  EXECUTED correctly (the engine neither knows nor cares about this state), but everything
//  downstream of `workflowExecutionState == nil` broke:
//
//    1. No run record at all — no stub, no freeze, no store write. The workflow's history list,
//       run picker and "N of M" badge showed nothing, and per-node detail (timelines, inputs,
//       durations, statuses) lives ONLY in the live state, so it was never captured rather than
//       merely unpersisted. Worst on SCHEDULED runs, which are unattended and whose only review
//       surface is run history. A crash mid-run also left no `.running` row for
//       `reconcileOrphans` to settle.
//    2. HITL misattributed — `ActiveStreamManager.enqueueHITL` computes
//       `isWorkflow = workflowState != nil && sourceNodeID != nil`, so banners lost the node-name
//       title and the pending-interaction chip navigated to the CHAT interface.
//    3. The wrong renderer — `capabilityCardsEnabled = (workflowExecutionState == nil)`, so these
//       runs got the ordering-based capability-card router that is deliberately disabled for
//       workflows because parallel nodes interleave segments it cannot separate.
//
//  Passing a state is therefore not cosmetic: it is what makes a workflow run reviewable,
//  correctly attributed, and correctly rendered.
//

import Foundation

private let logger = DGLogger(category: "WorkflowRunBootstrap")

/// The pieces of app state this bootstrap touches.
///
/// Narrower than `MainApplicationViewModel` on purpose: the bookkeeping needs the live-state slot
/// and the in-memory history mirror and nothing else, and depending on the whole view model would
/// have made this untestable (constructing one claims `HITLPresenter` globally and loads
/// settings).
@MainActor
protocol WorkflowRunRegistry: AnyObject {
    var workflowExecutionStates: [UUID: WorkflowExecutionState] { get set }
    var workflowRunHistory: [UUID: [WorkflowRunRecord]] { get set }

    /// [WF-CS4] Workflow profiles whose cached canvas holds edits that are not on disk.
    ///
    /// ⚠️ READ-ONLY, and deliberately the narrowest possible shape — a plain list of ids, not the
    /// canvas states and not a save entry point. Widening this protocol to something that could
    /// PERSIST a canvas would drag `BackendProfileService` in and defeat the testability rationale
    /// above; disclosure needs to know only whether to speak.
    var unsavedWorkflowCanvasProfileIDs: [UUID] { get }
}

extension MainApplicationViewModel: WorkflowRunRegistry {}

/// Which surface started a run. Correlation only — carried into every `[WF_RUN]` log line so a
/// support log can answer "what started this?" without inferring it from timing.
enum WorkflowRunOrigin: String, Sendable {
    case chat
    case scheduled
    case chatOps
    case regenerate
    case quickAccess
    case jarvis
    case resume
}

/// A started workflow run's bookkeeping handle. `nil` is returned for non-workflow profiles, so
/// call sites can adopt this unconditionally and pass `ticket?.state` / call `ticket?.finalize()`.
@MainActor
final class WorkflowRunTicket {

    /// Hand to `startMessageStream(workflowExecutionState:)`.
    let state: WorkflowExecutionState

    private let conversationID: UUID
    private let workflowProfileID: UUID
    private let workflowName: String
    private let userInput: String
    private let origin: WorkflowRunOrigin

    /// The graph as it stood when this run STARTED.
    ///
    /// ⚠️ Captured at `begin`, not re-read at `finalize`. The record is supposed to describe the
    /// graph that RAN, and re-loading from the store at the end described whatever was on disk by
    /// then instead — so editing the canvas mid-run and pressing Save silently rewrote the
    /// finished run's input attribution, permanently. The executor itself loads the layout exactly
    /// once at run start, so this snapshot is the same graph it actually executed.
    private let layoutSnapshot: WorkflowLayout
    private weak var registry: (any WorkflowRunRegistry)?
    /// Guards against a double-finalize. `onComplete` fires exactly once per stream today, but a
    /// second freeze would re-run the whole persist path against already-settled state.
    private var didFinalize = false

    fileprivate init(
        state: WorkflowExecutionState,
        conversationID: UUID,
        workflowProfileID: UUID,
        workflowName: String,
        userInput: String,
        origin: WorkflowRunOrigin,
        layoutSnapshot: WorkflowLayout,
        registry: any WorkflowRunRegistry
    ) {
        self.layoutSnapshot = layoutSnapshot
        self.state = state
        self.conversationID = conversationID
        self.workflowProfileID = workflowProfileID
        self.workflowName = workflowName
        self.userInput = userInput
        self.origin = origin
        self.registry = registry

        // [WF-LC2] Self-register as ACTIVE (not yet finalized) — see `activeTickets` below.
        // `begin()` always sets `state.runRecordID` before constructing a ticket; the guard is
        // defensive, not expected to fire.
        if let recordID = state.runRecordID {
            Self.activeTickets[recordID] = self
        } else {
            logger.error("[WF_RUN] WorkflowRunTicket constructed for '\(workflowName)' (origin \(origin.rawValue), conv \(conversationID)) with no runRecordID. CONSEQUENCE: this run is invisible to the quit-time in-flight guard — a ⌘Q during it will lose its completed node output exactly as WF-LC2 describes.")
        }
    }

    /// Freeze the live state into the persisted record. Call from the stream's `onComplete`, on
    /// the main actor.
    ///
    /// Reuses the stub's `id` so the upsert REWRITES that row rather than creating a duplicate —
    /// the stub and the finalized record are the same run.
    ///
    /// Returns the persist task (nil when nothing was written). Production call sites ignore it —
    /// the write is deliberately fire-and-forget so completing a big run doesn't block the UI —
    /// but returning it means "has this actually reached disk?" is answerable by anyone who needs
    /// to know, including tests.
    @discardableResult
    func finalize() -> Task<Void, Never>? {
        guard !didFinalize else {
            logger.error("[WF_RUN] finalize() called twice for run \(self.state.runRecordID?.uuidString ?? "<no id>") (origin \(self.origin.rawValue), conv \(self.conversationID)). CONSEQUENCE: the second call is ignored; the record already on disk is the one from the first freeze.")
            return nil
        }
        didFinalize = true
        // [WF-LC2] Deregister the instant finalize genuinely proceeds — whether reached naturally
        // (stream completed) or forced (quit while still running). `activeTickets` must mean
        // exactly "not yet finalized", or a run already finalized here would ALSO be walked by the
        // quit-time force-finalize and hit the (harmless, but noisy) double-finalize log above.
        if let recordID = state.runRecordID {
            Self.activeTickets[recordID] = nil
        }

        guard let vm = registry else {
            logger.error("[WF_RUN] Run \(self.state.runRecordID?.uuidString ?? "<no id>") (origin \(self.origin.rawValue), conv \(self.conversationID)) NOT finalized — the run registry was deallocated before the stream ended. CONSEQUENCE: the record stays `.running` on disk and will be reconciled to `cancelled`/`Interrupted` at the next launch; its node results are lost.")
            return nil
        }

        let layout = layoutSnapshot
        let frozen = WorkflowRunRecord.freeze(
            from: state,
            conversationID: conversationID,
            workflowProfileID: workflowProfileID,
            workflowName: workflowName,
            userInput: userInput,
            timestamp: state.startedAt,
            layout: layout
        )
        // [CF-28] The live timelines are now COPIED into `frozen`; from this instant the state's
        // own copy is redundant and the conversation-switch sweep (`releaseSettledTraces`) may
        // drop it. Marked HERE rather than when the persist lands because `frozen` — a value —
        // is what the persist task below encodes; the live copy plays no further part. Both
        // finalize paths (natural, and `forceFinalizeActiveRuns` at quit) pass through this line;
        // the registry-deallocated return above does NOT, and must not: nothing was captured.
        state.markRecordFrozen()

        // Stamp the finalized record with the in-flight id so the upsert targets the existing row.
        let record: WorkflowRunRecord
        if let existingID = state.runRecordID {
            record = WorkflowRunRecord(
                id: existingID,
                conversationID: frozen.conversationID,
                workflowProfileID: frozen.workflowProfileID,
                workflowName: frozen.workflowName,
                timestamp: frozen.timestamp,
                userInput: frozen.userInput,
                nodeResults: frozen.nodeResults,
                finalOutput: frozen.finalOutput,
                variables: frozen.variables,
                status: frozen.status,
                duration: frozen.duration,
                error: frozen.error,
                traceID: frozen.traceID
            )
        } else {
            // Should not happen — `begin` always sets it — but a missing id means the upsert would
            // INSERT a duplicate beside the stub rather than rewrite it, so say so rather than
            // letting the history list quietly grow a twin.
            logger.error("[WF_RUN] Run for '\(self.workflowName)' (origin \(self.origin.rawValue), conv \(self.conversationID)) has no runRecordID at finalize. CONSEQUENCE: the finalized record is persisted under a NEW id, so the `.running` stub row remains beside it until the sliding window evicts it.")
            record = frozen
        }

        // In-memory mirror: replace the matching row if present, else insert at the front.
        //
        // ⚠️ [XUI-11] THE MIRROR IS TRACE-LESS; `record` IS NOT. The persist below writes `record`,
        // so stripping the wrong one would mean the traces never reach disk — the run's whole
        // debugging record, silently, for exactly the failed runs it exists for. The mirror only
        // ever feeds the history LIST (counts and failure flags) and, for the run on screen,
        // `displayData` — which reads live timelines from `WorkflowExecutionState` while this run
        // is still the current one, and re-reads from the store afterwards.
        let mirrored = record.strippingNodeTimelines()
        if let idx = vm.workflowRunHistory[conversationID]?.firstIndex(where: { $0.id == record.id }) {
            vm.workflowRunHistory[conversationID]?[idx] = mirrored.record
        } else {
            vm.workflowRunHistory[conversationID, default: []].insert(mirrored.record, at: 0)
            Self.trimInMemoryHistory(vm: vm, conversationID: conversationID)
        }

        logger.info("[WF_RUN] Finalizing run \(record.id) '\(self.workflowName)' (origin \(self.origin.rawValue), conv \(self.conversationID)): status=\(record.status.rawValue), \(record.nodeResults.count) node result(s), \(Int(record.duration))s, finalOutput \(record.finalOutput.count) chars; \(mirrored.droppedEvents) node timeline event(s) held on disk only. CONSEQUENCE: reopening this run after its live state is cleared re-reads the trace (one off-main decode); the persisted record below keeps every event.")

        // Finalized blobs are large (up to 400 timeline events per node); `upsertFinalized`
        // encodes off-main and hops back for the SwiftData write so completing a big run does not
        // hitch the UI at the "completed" transition.
        //
        // [WF-PE7] Fire-and-forget is the right policy for the UI and the wrong one for quit:
        // the window is not a scheduling hop — `upsertFinalized` AWAITS a detached encode before
        // its write — and exiting inside it left only the `.running` stub, which the next launch
        // relabelled "Interrupted" with zero node results. So every persist task registers itself
        // in `pendingPersists` and `drainPendingPersists()` (quit teardown) awaits the stragglers.
        // Registration happens before the body can run (both are MainActor-serialized), so the
        // task cannot finish unregistered.
        let recordID = record.id
        let persistTask = Task { @MainActor in
            await WorkflowRunHistoryStore.shared.upsertFinalized(record, forConversation: conversationID)
            logger.info("[WF_RUN] Run \(record.id) persisted — status=\(record.status.rawValue).")
            Self.pendingPersists[recordID] = nil
        }
        Self.pendingPersists[recordID] = persistTask
        return persistTask
    }

    // MARK: - [WF-PE7] Quit-time drain of in-flight persists

    /// Persist tasks that have not yet reached disk, keyed by run-record id. MainActor-confined,
    /// like everything else on the ticket. Entries remove themselves on completion.
    private(set) static var pendingPersists: [UUID: Task<Void, Never>] = [:]

    /// Awaits every in-flight run persist. Called from `AppDelegate.performAsyncTeardown()` under
    /// its existing 3s quit watchdog — a hung SwiftData write can therefore still lose the record,
    /// but the common case (quit racing a just-finished run's encode) now completes instead of
    /// stranding the `.running` stub. Force-quit and crash remain uncovered by design; that gap
    /// needs incremental persistence during the run, not a drain.
    static func drainPendingPersists() async {
        let pending = pendingPersists
        guard !pending.isEmpty else { return }
        logger.info("[WF_RUN] Quit teardown: draining \(pending.count) in-flight run persist(s) — \(pending.keys.map(\.uuidString).sorted().joined(separator: ", ")). CONSEQUENCE: without this, quitting inside the encode+write window discards the finished run's record and the next launch reports it 'Interrupted' with no node results.")
        for task in pending.values {
            await task.value
        }
        logger.info("[WF_RUN] Quit teardown: run persist drain complete.")
    }

    // MARK: - [WF-LC2] Quit-time capture of RUNS STILL IN FLIGHT

    /// Every started run that has not yet had `finalize()` called on it — i.e. genuinely still
    /// executing. Self-registered at construction (see `init`), self-removed the instant
    /// `finalize()` proceeds, whether reached naturally or forced. MainActor-confined, like
    /// `pendingPersists`.
    ///
    /// ⚠️ Keyed by `state.runRecordID`, never by conversation. `workflowExecutionStates` (the
    /// registry every `begin()` caller also updates) is conversation-keyed and DISPLACEMENT-LOSSY —
    /// two runs sharing one conversation slot means the older one's UI handle is gone the moment the
    /// second starts (`begin`'s own displaced-run log above). This registry is the run's OWN handle,
    /// unaffected by anything else that starts later in the same conversation.
    ///
    /// ⚠️ Reachable regardless of which object called `begin()`. None of the six call sites
    /// (`MessagingCoordinator` ×3, `SchedulerCoordinator`, `QuickAccessSessionViewModel`,
    /// `JarvisSessionController`) register their ticket anywhere else — each keeps it only in a
    /// local `let` inside its own running `Task`. A type-level registry is what lets `AppDelegate`
    /// find a Jarvis or QuickAccess run at quit without caring whether the session that started it
    /// is still alive; the ticket's own presence in this dictionary is what keeps it (and the
    /// `WorkflowExecutionState` it wraps) retained.
    private(set) static var activeTickets: [UUID: WorkflowRunTicket] = [:]

    /// Count only — for the quit-time alert to decide whether to ask, and how many to name, without
    /// mutating anything. Read this BEFORE the user has answered; only `forceFinalizeActiveRuns`
    /// below may act on the runs themselves.
    static var activeRunCount: Int { activeTickets.count }

    /// Display names of every still-active run, for the quit-time alert to name what it is about
    /// to end — a bare count leaves a QuickAccess or Jarvis run (no visible window of its own)
    /// impossible to identify. No ordering guarantee beyond dictionary iteration; the alert caps
    /// how many it actually lists.
    static var activeRunNames: [String] { activeTickets.values.map(\.workflowName) }

    /// Marks every still-running run CANCELLED and freezes it — called ONLY from the irrevocable
    /// "quit anyway" branch of the AppDelegate prompt this backs, never speculatively.
    ///
    /// ⚠️ ORDER IS THE WHOLE FIX. `didFinalize` is a PERMANENT one-shot guard (see `finalize()`) —
    /// calling this before the user has committed would freeze the run's PARTIAL progress and then
    /// permanently block its own real completion from ever being persisted if the user goes on to
    /// press Cancel and the run keeps going and finishes normally seconds later. So: the alert must
    /// show `activeRunCount` (read-only) first, and only a confirmed "Quit Anyway" may call this.
    ///
    /// Each still-`isRunning` ticket is settled via `state.handleError(reason, cancelled: true)` —
    /// the same call `Stop` makes — before `finalize()`, so `freeze()` records `.cancelled` at the
    /// run level and force-settles any node still `.running` to `.cancelled` too (never `.failed`):
    /// the run did not break, the app quit under it. `finalize()`'s own persist task registers into
    /// `pendingPersists`, which the EXISTING `drainPendingPersists()` call in
    /// `AppDelegate.performAsyncTeardown()` already awaits — this function does not need to await
    /// anything itself, only to run before that call.
    ///
    /// ⚠️ `isRunning` GATES the forced cancel — adversarial review of this exact fix caught the gap.
    /// A ticket stays in `activeTickets` until `finalize()` runs, but `finalize()` is only REACHED
    /// from each call site's deferred `onComplete` — which fires AFTER `handleStreamEnd`/`handleError`
    /// have already settled `state` to its TRUE outcome (`isRunning = false`) and AFTER real
    /// suspending work (`finalizeMessage`'s persistence write, `TraceRecorder.endTrace`). A run that
    /// finished successfully — or genuinely failed — a moment before quit sits in exactly that gap:
    /// active, but already settled. Unconditionally calling `handleError(cancelled: true)` on it
    /// would overwrite a real `.completed` outcome with a fabricated `.cancelled` one, and
    /// `didFinalize` being a PERMANENT guard means the run's true result could never be recovered.
    /// So: only a ticket still ACTUALLY running is force-cancelled; one already settled is simply
    /// finalized as-is, freezing whatever real outcome it already reached.
    @discardableResult
    static func forceFinalizeActiveRuns(reason: String) -> Int {
        // Snapshot first: `finalize()` mutates `activeTickets` (removes itself) as it runs, and
        // iterating a dictionary while mutating it is undefined.
        let running = activeTickets
        guard !running.isEmpty else { return 0 }
        logger.warning("[WF_RUN] Quit while \(running.count) workflow run(s) still in flight — \(running.keys.map(\.uuidString).sorted().joined(separator: ", ")). CONSEQUENCE: each still genuinely running is marked Cancelled; one already settled (mid-way to its own natural finalize) is persisted with its real outcome instead. The app then exits, so nothing further can run.")
        for ticket in running.values {
            // [WF-LC2 hardening, post-audit] `isRunning` is `false` in TWO different situations
            // this gate must not conflate: (a) the run genuinely reached its true outcome — the
            // case this gate exists to protect — and (b) the ticket was just constructed by
            // `begin()` and registered here, but `WorkflowExecutor` hasn't dispatched to its first
            // node yet, so `handleNodeStarted` (the only setter of `isRunning = true`) has never
            // fired. A quit landing in that pristine window used to skip `handleError` entirely,
            // then `finalize()` froze a run with empty `nodeResults`, no `workflowError`, and
            // `wasCancelled == false` — `WorkflowRunRecord.freeze`'s status derivation falls
            // through to `.completed` for exactly that shape, so an interrupted run that never
            // even started was permanently recorded as a successful empty answer. Strictly WORSE
            // than having no gate at all: without this fix, quitting here left an on-disk
            // `.running` stub that `WorkflowRunHistoryStore.reconcileOrphans()` would truthfully
            // relabel "Cancelled — Interrupted" at next launch.
            //
            // `completedAt` is the correct discriminator: it is set ONLY by `handleFinalOutput`/
            // `handleError` — i.e. only once the run has genuinely settled — and stays `nil` for
            // BOTH "still running" and "registered but never started." Gating on it (rather than
            // `isRunning`) force-cancels both non-settled shapes and leaves a truly-settled run
            // untouched, exactly matching this function's own stated contract above.
            if ticket.state.completedAt == nil {
                ticket.state.handleError(reason, cancelled: true)
            }
            ticket.finalize()
        }
        return running.count
    }

    /// Trims the VM's in-memory mirror to the store's window so the list can't outgrow what disk
    /// keeps. Uses the store's own constant — these were two duplicated `20` literals.
    fileprivate static func trimInMemoryHistory(vm: any WorkflowRunRegistry, conversationID: UUID) {
        let cap = WorkflowRunHistoryStore.maxRecordsPerConversation
        if let count = vm.workflowRunHistory[conversationID]?.count, count > cap {
            vm.workflowRunHistory[conversationID] = Array(vm.workflowRunHistory[conversationID]!.prefix(cap))
        }
    }
}

@MainActor
enum WorkflowRunBootstrap {

    /// Starts workflow bookkeeping for a run that is about to begin.
    ///
    /// Returns `nil` for every non-workflow profile, so callers can invoke this unconditionally.
    /// The `.running` stub is inserted BEFORE the stream starts so the run is visible in history
    /// and the run picker from the first frame — including the very first run in a fresh
    /// conversation, where there is otherwise no on-disk handle on the in-flight execution.
    static func begin(
        config: BackendRequestConfig,
        conversationID: UUID,
        userInput: String,
        registry: any WorkflowRunRegistry,
        origin: WorkflowRunOrigin
    ) -> WorkflowRunTicket? {
        guard config.profile.profileType == .workflow else { return nil }

        let state = WorkflowExecutionState()
        state.userInput = userInput
        state.workflowProfileID = config.profile.id
        // [cv-3] The run's settle paths post live-write completions to settle Code Viewer tabs,
        // and a completion cannot be addressed without this. Stamped here because `begin` is the
        // one choke point every run origin passes through — chat, scheduled, ChatOps, regenerate.
        state.conversationID = conversationID
        state.startedAt = Date()

        // [WF-CS4] Decided HERE, once, at the single choke point every run origin passes through —
        // chat, scheduled, ChatOps and regenerate all reach `begin`, so none of them can acquire the
        // silence independently.
        //
        // ⚠️ ONE load, reused for BOTH the disclosure and `layoutSnapshot` below, so the flag and the
        // snapshot provably describe the same graph at the same instant. Two reads could straddle a
        // save and disagree.
        let rootLayout = WorkflowLayoutStore.shared.load(for: config.profile.id)
        // Sub-workflow children never reach `begin` (the executor builds a child executor directly),
        // so their dirt is only visible from here — see `shouldDisclose`. Bounded work: nesting is
        // capped at `WorkflowDepth.maxDepth` and the resolver carries its own visited-set against
        // cycles.
        let runProfileIDs = Set([config.profile.id])
            .union(WorkflowLayoutStore.shared.resolveNestedLayouts(from: rootLayout).keys)
        let ranWithUnsavedCanvasEdits = WorkflowRunEditDisclosure.shouldDisclose(
            runProfileIDs: runProfileIDs,
            unsavedCanvasProfileIDs: registry.unsavedWorkflowCanvasProfileIDs
        )
        state.ranWithUnsavedCanvasEdits = ranWithUnsavedCanvasEdits

        let initialRecord = WorkflowRunRecord(
            id: UUID(),
            conversationID: conversationID,
            workflowProfileID: config.profile.id,
            workflowName: config.profile.displayName,
            timestamp: state.startedAt,
            userInput: userInput,
            nodeResults: [],
            finalOutput: "",
            variables: [:],
            status: .running,
            duration: 0,
            error: nil
        )
        state.runRecordID = initialRecord.id

        // ⚠️ Keyed by CONVERSATION, matching `workflowExecutionStates`' existing shape. Two runs
        // in one conversation therefore share one slot — pre-existing behaviour, but now
        // reachable from more surfaces (a scheduled run firing while a manual run is live), so
        // the overwrite is reported rather than silent.
        if let displaced = registry.workflowExecutionStates[conversationID], displaced.isRunning {
            logger.error("[WF_RUN] Starting a \(origin.rawValue) run in conversation \(conversationID) while another workflow run is STILL RUNNING (record \(displaced.runRecordID?.uuidString ?? "<no id>")). CONSEQUENCE: the live state slot is keyed by conversation, so the older run loses its UI handle — its events stop reaching the timeline and its record will be settled by the launch reconcile rather than by its own finalize.")
        }

        registry.workflowExecutionStates[conversationID] = state
        registry.workflowRunHistory[conversationID, default: []].insert(initialRecord, at: 0)
        WorkflowRunTicket.trimInMemoryHistory(vm: registry, conversationID: conversationID)

        // Cheap: the stub's `nodeResults` is empty, so the inline encode has nothing to move
        // off-main (unlike `upsertFinalized`).
        WorkflowRunHistoryStore.shared.upsert(initialRecord, forConversation: conversationID)

        logger.info("[WF_RUN] Started run \(initialRecord.id) '\(config.profile.displayName)' (origin \(origin.rawValue), profile \(config.profile.id), conv \(conversationID)) — `.running` stub persisted; the run is now visible in history and the run picker.")

        if ranWithUnsavedCanvasEdits {
            logger.warning("\(WorkflowRunEditDisclosure.logReason(runRecordID: initialRecord.id, workflowProfileID: config.profile.id, conversationID: conversationID, origin: origin.rawValue))")
        }

        return WorkflowRunTicket(
            state: state,
            conversationID: conversationID,
            workflowProfileID: config.profile.id,
            workflowName: config.profile.displayName,
            userInput: userInput,
            origin: origin,
            // ⚠️ Read at run start — see `layoutSnapshot`. One disk read fewer at finalize, and the
            // record now describes the graph that actually ran. [WF-CS4] Reuses the single load
            // taken above so the disclosure and this snapshot cannot describe different graphs.
            layoutSnapshot: rootLayout,
            registry: registry
        )
    }
}
