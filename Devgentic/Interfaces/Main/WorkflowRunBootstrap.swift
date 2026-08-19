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

/// The two pieces of app state this bootstrap touches.
///
/// Narrower than `MainApplicationViewModel` on purpose: the bookkeeping needs the live-state slot
/// and the in-memory history mirror and nothing else, and depending on the whole view model would
/// have made this untestable (constructing one claims `HITLPresenter` globally and loads
/// settings).
@MainActor
protocol WorkflowRunRegistry: AnyObject {
    var workflowExecutionStates: [UUID: WorkflowExecutionState] { get set }
    var workflowRunHistory: [UUID: [WorkflowRunRecord]] { get set }
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
                error: frozen.error
            )
        } else {
            // Should not happen — `begin` always sets it — but a missing id means the upsert would
            // INSERT a duplicate beside the stub rather than rewrite it, so say so rather than
            // letting the history list quietly grow a twin.
            logger.error("[WF_RUN] Run for '\(self.workflowName)' (origin \(self.origin.rawValue), conv \(self.conversationID)) has no runRecordID at finalize. CONSEQUENCE: the finalized record is persisted under a NEW id, so the `.running` stub row remains beside it until the sliding window evicts it.")
            record = frozen
        }

        // In-memory mirror: replace the matching row if present, else insert at the front.
        if let idx = vm.workflowRunHistory[conversationID]?.firstIndex(where: { $0.id == record.id }) {
            vm.workflowRunHistory[conversationID]?[idx] = record
        } else {
            vm.workflowRunHistory[conversationID, default: []].insert(record, at: 0)
            Self.trimInMemoryHistory(vm: vm, conversationID: conversationID)
        }

        logger.info("[WF_RUN] Finalizing run \(record.id) '\(self.workflowName)' (origin \(self.origin.rawValue), conv \(self.conversationID)): status=\(record.status.rawValue), \(record.nodeResults.count) node result(s), \(Int(record.duration))s, finalOutput \(record.finalOutput.count) chars.")

        // Finalized blobs are large (up to 400 timeline events per node); `upsertFinalized`
        // encodes off-main and hops back for the SwiftData write so completing a big run does not
        // hitch the UI at the "completed" transition.
        return Task { @MainActor in
            await WorkflowRunHistoryStore.shared.upsertFinalized(record, forConversation: conversationID)
            logger.info("[WF_RUN] Run \(record.id) persisted — status=\(record.status.rawValue).")
        }
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
        state.startedAt = Date()

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

        return WorkflowRunTicket(
            state: state,
            conversationID: conversationID,
            workflowProfileID: config.profile.id,
            workflowName: config.profile.displayName,
            userInput: userInput,
            origin: origin,
            // ⚠️ Read HERE, at run start — see `layoutSnapshot`. One disk read fewer at finalize,
            // and the record now describes the graph that actually ran.
            layoutSnapshot: WorkflowLayoutStore.shared.load(for: config.profile.id),
            registry: registry
        )
    }
}
