// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunBootstrap.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "WorkflowRunBootstrap")

// Why: constructing the main view model claims HITLPresenter globally and loads settings.
/// The pieces of app state the run bootstrap touches.
/// Narrower than the main view model so the bookkeeping can be tested without constructing one.
@MainActor
protocol WorkflowRunRegistry: AnyObject {
    var workflowExecutionStates: [UUID: WorkflowExecutionState] { get set }
    var workflowRunHistory: [UUID: [WorkflowRunRecord]] { get set }

    /// Workflow profile ids whose cached canvas holds edits that are not on disk.
    /// Read-only by design: a plain list of ids with no save entry point.
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
    case orb
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

    // Why: captured at `begin`, not re-read at `finalize`; a mid-run canvas save would otherwise
    // rewrite the finished run's input attribution.
    /// The graph as it stood when this run started.
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

        // Self-registers as active (not yet finalized) in `activeTickets`.
        // The guard is defensive; `begin()` always sets `state.runRecordID` first.
        if let recordID = state.runRecordID {
            Self.activeTickets[recordID] = self
        } else {
            logger.error("[WF_RUN] WorkflowRunTicket constructed for '\(workflowName)' (origin \(origin.rawValue), conv \(conversationID)) with no runRecordID. CONSEQUENCE: this run is invisible to the quit-time in-flight guard — a ⌘Q during it will lose its completed node output exactly as WF-LC2 describes.")
        }
    }

    /// Freezes the live state into the persisted record; call on the main actor from the stream's `onComplete`.
    /// Reuses the stub's `id` so the upsert rewrites that row. Returns the persist task, or nil when nothing was written.
    /// The persist is fire-and-forget; the returned task lets callers and tests await the write.
    @discardableResult
    func finalize() -> Task<Void, Never>? {
        guard !didFinalize else {
            logger.error("[WF_RUN] finalize() called twice for run \(self.state.runRecordID?.uuidString ?? "<no id>") (origin \(self.origin.rawValue), conv \(self.conversationID)). CONSEQUENCE: the second call is ignored; the record already on disk is the one from the first freeze.")
            return nil
        }
        didFinalize = true
        // Deregisters as soon as finalize proceeds, so `activeTickets` means exactly "not yet finalized".
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
        // The live timelines are now copied into `frozen`, so the sweep may release the state's own copy.
        // Both finalize paths pass through here; the registry-gone early return must not, as nothing was captured.
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
            // A missing id would make the upsert insert a duplicate beside the stub instead of rewriting it.
            logger.error("[WF_RUN] Run for '\(self.workflowName)' (origin \(self.origin.rawValue), conv \(self.conversationID)) has no runRecordID at finalize. CONSEQUENCE: the finalized record is persisted under a NEW id, so the `.running` stub row remains beside it until the sliding window evicts it.")
            record = frozen
        }

        // In-memory mirror: replaces the matching row if present, else inserts at the front.
        // The mirror is trace-less but `record` is not; the persist below must write the full timelines.
        let mirrored = record.strippingNodeTimelines()
        if let idx = vm.workflowRunHistory[conversationID]?.firstIndex(where: { $0.id == record.id }) {
            vm.workflowRunHistory[conversationID]?[idx] = mirrored.record
        } else {
            vm.workflowRunHistory[conversationID, default: []].insert(mirrored.record, at: 0)
            Self.trimInMemoryHistory(vm: vm, conversationID: conversationID)
        }

        logger.info("[WF_RUN] Finalizing run \(record.id) '\(self.workflowName)' (origin \(self.origin.rawValue), conv \(self.conversationID)): status=\(record.status.rawValue), \(record.nodeResults.count) node result(s), \(Int(record.duration))s, finalOutput \(record.finalOutput.count) chars; \(mirrored.droppedEvents) node timeline event(s) held on disk only. CONSEQUENCE: reopening this run after its live state is cleared re-reads the trace (one off-main decode); the persisted record below keeps every event.")

        // Fire-and-forget keeps the UI responsive, but each persist registers in `pendingPersists` so quit can await it.
        // Registration precedes the body (both are MainActor-serialized), so the task cannot finish unregistered.
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

    /// Awaits every in-flight run persist; called from the quit teardown under its watchdog.
    /// A hung write can still lose the record; force-quit and crash are not covered.
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

    // Why: a type-level registry lets quit find Orb or QuickAccess runs whether or not the session that started them is alive.
    /// Every started run that has not yet been finalized, i.e. still executing; main-actor confined.
    /// Keyed by run record id, never by conversation, since one conversation slot can be shared by several runs.
    private(set) static var activeTickets: [UUID: WorkflowRunTicket] = [:]

    /// Count only — for the quit-time alert to decide whether to ask, and how many to name, without
    /// mutating anything. Read this BEFORE the user has answered; only `forceFinalizeActiveRuns`
    /// below may act on the runs themselves.
    static var activeRunCount: Int { activeTickets.count }

    /// Display names of every still-active run, for the quit-time alert.
    /// Order follows dictionary iteration; the alert caps how many it lists.
    static var activeRunNames: [String] { activeTickets.values.map(\.workflowName) }

    // Why: finalize is a permanent one-shot guard; calling this before the user commits would stop
    // a run that then completes normally from ever persisting its real result.
    /// Marks every unsettled run cancelled and freezes it; call only from the confirmed "Quit Anyway" branch.
    /// Runs that already settled are finalized as-is so their real outcome is kept.
    @discardableResult
    static func forceFinalizeActiveRuns(reason: String) -> Int {
        // Snapshot first: `finalize()` mutates `activeTickets` (removes itself) as it runs, and
        // iterating a dictionary while mutating it is undefined.
        let running = activeTickets
        guard !running.isEmpty else { return 0 }
        logger.warning("[WF_RUN] Quit while \(running.count) workflow run(s) still in flight — \(running.keys.map(\.uuidString).sorted().joined(separator: ", ")). CONSEQUENCE: each still genuinely running is marked Cancelled; one already settled (mid-way to its own natural finalize) is persisted with its real outcome instead. The app then exits, so nothing further can run.")
        for ticket in running.values {
            // Gate on `completedAt`, not `isRunning`: a run registered but not yet dispatched to its first node
            // has `isRunning == false` yet is unsettled, and must be cancelled or it freezes as an empty success.
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

    /// Starts workflow bookkeeping for a run about to begin; returns nil for non-workflow profiles.
    /// The `.running` stub is inserted before the stream starts so the run is visible in history from the first frame.
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
        // Stamps the conversation id so settle paths can post live-write completions to the Code Viewer tabs.
        // `begin` is the single choke point every run origin passes through.
        state.conversationID = conversationID
        state.startedAt = Date()

        // Loaded once at this choke point and reused for both the disclosure and `layoutSnapshot`,
        // so the flag and the snapshot describe the same graph.
        let rootLayout = WorkflowLayoutStore.shared.load(for: config.profile.id)
        // Sub-workflow children never reach `begin`, so their unsaved edits are only visible from here.
        // Work is bounded: nesting is capped at `WorkflowDepth.maxDepth` and the resolver tracks visited profiles.
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

        // Keyed by conversation, so two runs in one conversation share one slot; the overwrite is logged, not silent.
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
            // Captured at run start so the record describes the graph that actually ran (see `layoutSnapshot`).
            layoutSnapshot: rootLayout,
            registry: registry
        )
    }
}
