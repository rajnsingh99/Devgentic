// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowDedicatedView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Top-level dedicated view for workflow execution mode.
//  Replaces ChatHistoryView when a workflow profile is selected.
//  Provides three modes: execution (live), historical (past run), and canvas (builder).
//
//  Execution layout (build 2026-04-25 redesign):
//  - Title bar     : Back + "Workflow execution" | Historical badge | run "1/N" counter | History + Canvas
//  - Status strip  : ✓ Completed / Running / Failed | Total time X.Xs
//  - Card strip    : agent cards interleaved with status-aware connectors, terminating in the Final Outcome card
//  - Output area   : auto-routed Final Output panel — three states:
//                    pending   → "Waiting for execution" placeholder
//                    running   → AgentTimelineView at full chat fidelity
//                    completed → markdown content via the shared chat content pipeline
//

import SwiftUI
import os

private let logger = DGLogger(category: "WorkflowDedicated")

struct WorkflowDedicatedView: View {
    let workflowProfileID: UUID
    let conversationID: UUID?

    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(BackendProfileService.self) private var profileService
    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @State private var viewMode: ViewMode = .execution
    @State private var selectedHistoricalRunID: UUID?

    /// [XUI-11] The selected run's node traces, re-read from the store because the in-memory
    /// mirror drops them. Cached here because `displayData` is read during `body` and cannot await.
    ///
    /// ⚠️ TRACES ONLY, never the whole record, and that is not a detail. Preferring a re-read
    /// RECORD over the listed one lets a stale disk row replace an authoritative in-memory one: the
    /// mirror is written SYNCHRONOUSLY at finalize while the disk write is a fire-and-forget task
    /// that first awaits an off-main encode, so inside that window the row is still the `.running`
    /// stub — zero nodes, no output — and a completed run would render as running. `apply` also
    /// deliberately keeps the PREVIOUS blob when an encode is refused, which makes that shape
    /// permanent rather than transient. Grafting only the timelines removes the entire class.
    ///
    /// It rides the `liveTimelines` parameter `WorkflowRunDisplayData.from(record:)` already takes
    /// for exactly this job (`liveTimelines?[snapshot.nodeID] ?? snapshot.nodeTimeline ?? []`), so
    /// there is no second merge rule to keep in step with the first.
    @State private var hydratedTimelines: (runID: UUID, timelines: [UUID: [TimelineEvent]])?
    @State private var selectedNodeID: UUID?
    /// While true, the selection auto-follows the currently running node. A tap on any non-running
    /// node pins the selection (sets this false); each new run (or conversation switch) re-enables it.
    @State private var followRunningNode = true
    @State private var validationIssues: [WorkflowValidationIssue] = []
    @State private var isHoveringFix = false
    // The workflow surface renders no chat bubbles, so it needs its own Report entry
    // point — same panel, same developer-mode sizing memory as the chat one.
    @AppStorage(AppSettings.developerModeKey) private var isDeveloperMode: Bool = false

    /// Cached workflow layout.
    ///
    /// `displayData` is a computed property read during `body`, and `body`
    /// re-evaluates on every streamed workflow event (`executionState` is
    /// `@Observable`) — so loading the layout there ran an UNCACHED SwiftData fetch +
    /// JSON blob decode at streaming frequency, on the main thread, for the whole run.
    /// The layout only changes via the canvas builder, so it's loaded at the few
    /// moments it can actually change (appear / profile switch / return from canvas —
    /// the same points validation already refreshes) and read from here otherwise.
    /// `nil` until the first load; the display adapter treats a nil layout as
    /// "started nodes only", which is its documented fallback.
    @State private var cachedLayout: WorkflowLayout?

    /// Set when Re-run is refused because the selected profile is not this run's workflow.
    /// Named so the alert can say which two workflows were involved — "it didn't work" is not
    /// actionable when the whole point is that two workflows were confused.
    @State private var rerunMismatch: RerunMismatch?

    struct RerunMismatch: Identifiable {
        let id = UUID()
        let intended: String
        let actual: String
    }

    enum ViewMode {
        case canvas
        case execution
    }

    /// The live execution state for this conversation's workflow run.
    private var executionState: WorkflowExecutionState? {
        guard let cid = conversationID else { return nil }
        return viewModel.workflowExecutionStates[cid]
    }

    /// [HITL/P4] Node IDs with a pending HITL on a live run — drives the "awaiting input"
    /// badge on the run card (D2). Sourced from the unified InteractionCenter so it survives
    /// the P5 removal of the legacy `WorkflowExecutionState.pendingInteractions` container.
    private func awaitingNodeIDs(for data: WorkflowRunDisplayData) -> Set<UUID> {
        guard data.isLive, let cid = conversationID else { return [] }
        return Set(viewModel.interactionCenter.items(for: cid).compactMap { $0.origin.nodeID })
    }

    /// Validation errors only (blocks execution).
    private var validationErrors: [WorkflowValidationIssue] {
        validationIssues.filter { $0.severity == .error }
    }

    /// Loads the layout from the store ONCE and refreshes everything derived from it:
    /// the `cachedLayout` used by `displayData`, and the validation issues. Called at
    /// the only points the layout can change (see `cachedLayout`).
    private func refreshLayoutAndValidation() {
        let layout = WorkflowLayoutStore.shared.load(for: workflowProfileID)
        cachedLayout = layout
        let profileMap = Dictionary(
            profileService.profiles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // ⚠️ FULL context, matching what pre-flight will actually use to BLOCK the run. This used
        // to pass only layout+profileMap, so the nesting cycle/depth rules — error severity — went
        // dark on this screen: the panel said "Workflow Ready" for a graph the executor would
        // refuse at pre-flight with the very same summary. Safe to resolve here, unlike on the
        // canvas keystroke path: this method runs only on appear / mode switch / profile change.
        let nested = WorkflowLayoutStore.shared.resolveNestedLayouts(from: layout)
        validationIssues = WorkflowValidator.validate(
            layout: layout,
            profileMap: profileMap,
            subWorkflowLayouts: nested,
            rootProfileID: workflowProfileID
        )
    }

    /// Run history for THIS workflow in this conversation.
    ///
    /// ⚠️ Filtered by `workflowProfileID`, not just conversation. The store is keyed by
    /// conversation alone, so a conversation whose profile was switched accumulated several
    /// workflows' runs in one list — rendered identically, with no name on the card and no way to
    /// tell them apart. Opening one showed a different workflow's nodes under this workflow's
    /// header (every node-id lookup missing, logged only at `.info`), and the "N of M" badge
    /// counted runs this workflow never performed.
    ///
    /// Filtering rather than labelling: a run belonging to another workflow has nothing useful to
    /// say on this screen — its nodes cannot be resolved against this layout — and the Re-run
    /// button below would offer to replay it through the wrong pipeline.
    private var runHistory: [WorkflowRunRecord] {
        guard let cid = conversationID else { return [] }
        return (viewModel.workflowRunHistory[cid] ?? [])
            .filter { $0.workflowProfileID == workflowProfileID }
    }

    /// Unified display data — every visible run, live or historical, is
    /// addressed through `selectedHistoricalRunID`. There is no auto-fallback
    /// to `executionState`: that would re-pin the live view even after the
    /// user explicitly pressed back, preventing them from reaching the empty
    /// / history-list state while a run is streaming. Instead, live runs are
    /// auto-selected (by `runRecordID`) when they start or when the view
    /// re-appears with an in-flight run already in memory — see
    /// `autoSelectLiveRunIfNeeded` below.
    ///
    /// Special case: when the selected record IS the in-flight run (matched
    /// by `runRecordID`), we render the live state instead of the stale
    /// `.running` snapshot so the strip and output panels animate as events
    /// arrive.
    private var displayData: WorkflowRunDisplayData? {
        guard let historicalID = selectedHistoricalRunID,
              let record = runHistory.first(where: { $0.id == historicalID }) else {
            return nil
        }
        if record.status == .running,
           let state = executionState,
           state.runRecordID == historicalID {
            return .from(live: state, layout: cachedLayout)
        }
        // For finalized records that still match the in-memory execution state
        // (run just completed, executionState not yet cleared), pull per-node
        // timelines from memory so the Output/Timeline toggle on agent nodes
        // can render the agent's reasoning + tool calls. Once `executionState`
        // is cleared (back button, conversation switch, app restart), this
        // falls through to `nil` and only the static output remains.
        // [XUI-11/XUI-15] Live memory first, then the traces re-read from the store for this run,
        // then whatever the snapshot still carries. The listed record stays the source of truth for
        // every other field.
        let liveTimelines: [UUID: [TimelineEvent]]? =
            liveTimelines(forRun: record.id) ??
            (hydratedTimelines?.runID == record.id ? hydratedTimelines?.timelines : nil)
        // Pass the current layout so the adapter can resolve node kinds and hide
        // the Timeline tab for single-shot nodes (bots etc.).
        return .from(record: record, liveTimelines: liveTimelines, layout: cachedLayout)
    }

    /// The live state's traces for a run, or nil when it does not have them.
    ///
    /// ⚠️ ONE resolver, read by `displayData` AND by the hydration trigger, so the two cannot
    /// disagree about whether a re-read is needed. ⚠️ The `!isEmpty` test is load-bearing (register
    /// XUI-15): a settled run whose timelines were dropped still OWNS the live slot, and returning
    /// its empty map here would SHADOW the hydrated one — `from(record:)` reads
    /// `liveTimelines?[nodeID] ?? snapshot.nodeTimeline ?? []`, so an empty-but-non-nil map wins
    /// the `??` and every node renders with no trace.
    private func liveTimelines(forRun runID: UUID) -> [UUID: [TimelineEvent]]? {
        guard let state = executionState, state.runRecordID == runID,
              !state.nodeTimelines.isEmpty else { return nil }
        return state.nodeTimelines
    }

    /// [XUI-11] Re-reads the selected run's node traces when the mirror no longer has them.
    ///
    /// ⚠️ DRIVEN FROM TWO EDGES, and one of them is not obvious. The predicate depends on
    /// `executionState`, not only on the selection: a run selected WHILE it was the live one
    /// correctly skips hydration, because its traces are being served from
    /// `WorkflowExecutionState`. When the next run then takes that slot, the selection has not
    /// changed — so a selection-only trigger left the previous run's Timeline tabs permanently
    /// EMPTY, with no log and no retry, for a trace that rendered fine before this row's fix.
    /// `.onChange(of: executionState?.runRecordID)` closes it; the predicate is cheap and
    /// idempotent, so re-asking on that edge costs one comparison.
    ///
    /// ⚠️ The live-state slot is replaced by `WorkflowRunBootstrap.begin`, and the new state's
    /// `isRunning` stays false until its first node dispatches — so the existing
    /// `.onChange(of: executionState?.isRunning)` observer does NOT fire on that transition and
    /// cannot be reused for this.
    ///
    /// ⚠️ [CF-57] The read is attempted at most TWICE, and the loop below is deliberately inline
    /// rather than a recursive call: everything after the first `await` may touch only `@State`
    /// (`selectedHistoricalRunID`, `hydratedTimelines`). Re-entering this method would read
    /// `runHistory` and `executionState`, i.e. `@Environment`, from a continuation the view is no
    /// longer installed for.
    private func hydrateTracesIfNeeded(for runID: UUID?) {
        guard let runID, let listed = runHistory.first(where: { $0.id == runID }),
              WorkflowRunRecord.needsTraceHydration(
                  listed, liveTimelinesAvailable: liveTimelines(forRun: runID) != nil)
        else { return }

        Task { @MainActor in
            // 0 = the first read, 1 = the single retry for the write race described below. Bounded
            // at one on purpose: the race is narrow, while the many runs that legitimately hold no
            // trace (a bot-only workflow records none) must not re-read the store in a loop.
            for attempt in 0...1 {
                guard let full = await WorkflowRunHistoryStore.shared.loadRecord(id: runID) else {
                    logger.notice("[WORKFLOW] Trace re-read for run \(runID) found no stored row — evicted by the per-conversation window, or its conversation was deleted. CONSEQUENCE: this run's per-node Timeline tabs render empty, which looks identical to a run that never recorded one; its output, status and node list are unaffected.")
                    return
                }
                // The user may have moved on during the read; never show one run's trace against
                // another.
                guard selectedHistoricalRunID == runID else { return }
                let timelines = Dictionary(
                    full.nodeResults.compactMap { snapshot in
                        snapshot.nodeTimeline.map { (snapshot.nodeID, $0) }
                    },
                    uniquingKeysWith: { _, latest in latest }
                )
                if !timelines.isEmpty {
                    // Animated because hydration does not merely lengthen the panel:
                    // `bodyIsDuplicated` and the legacy `nodeRanBeforeSkip` both read timeline
                    // PRESENCE, so arriving events can retract an error paragraph or swap a
                    // "Not run" line for a full trace.
                    withAnimation(.easeInOut(duration: 0.15)) {
                        hydratedTimelines = (runID: runID, timelines: timelines)
                    }
                    return
                }

                // [CF-57] This used to `return` silently, and it is not the same failure as the
                // missing row above. `needsTraceHydration` has already established that the LISTED
                // record is finalized — it comes from the in-memory mirror, written SYNCHRONOUSLY
                // by `finalize` — while the disk row is written by a fire-and-forget task that
                // first awaits an off-main encode. Inside that window the re-read returns the
                // `.running` stub: zero nodes, no trace. Hydration is re-armed only by the two
                // `.onChange` triggers below, so losing that race left the run trace-less with
                // nothing in the log to say why.
                let runTag = runID.uuidString.prefix(8)
                if full.status == .running, attempt == 0 {
                    logger.notice("[WORKFLOW] Trace re-read for run \(runTag) came back as the .running stub (\(full.nodeResults.count) stored node(s) vs \(listed.nodeResults.count) in the finalized listed record) — the disk write for this run has not landed yet. Retrying once in 600ms. CONSEQUENCE if the retry also loses the race: this run's per-node Timeline tabs render empty until the run is selected again.")
                    try? await Task.sleep(for: .milliseconds(600))
                    guard selectedHistoricalRunID == runID else { return }
                    continue
                }
                logger.info("[WORKFLOW] Trace re-read for run \(runTag) (attempt \(attempt + 1), stored status '\(full.status.label)') returned \(full.nodeResults.count) node(s), none carrying a timeline. CONSEQUENCE: this run's per-node Timeline tabs render empty — on screen indistinguishable from a run that never recorded a trace, which for a bot-only workflow is exactly what it is; output, status and node list are unaffected.")
                return
            }
        }
    }

    /// Auto-selects the in-flight run's record when it exists but nothing is
    /// currently selected — covers three paths:
    ///   1. A run just started and we need to surface the live view.
    ///   2. The view appeared (mount or conversation switch) and there's
    ///      already a running execution from before this view mounted.
    ///   3. [CF-54] The workflow profile switched under this view and the
    ///      selection was just reset — the new workflow's own live run, if any,
    ///      should come up the same way.
    /// We deliberately skip auto-select when `selectedHistoricalRunID` is
    /// already non-nil so user choices (including an explicit back press
    /// followed by selecting a different historical row) are respected.
    ///
    /// ⚠️ THE PROFILE CONJUNCT IS LOAD-BEARING, exactly as in `runPickerMenu` (XUI-3):
    /// `executionState` is CONVERSATION-scoped while this view is PROFILE-scoped, so a run of
    /// workflow A live in this conversation must NOT be selected while the view shows B — its
    /// id cannot resolve in B's filtered `runHistory`, `displayData` goes nil, and the stale
    /// non-nil selection then blocks every later auto-select. The decision is a pure static so
    /// that rule can be pinned; the `@State` write here is the only part a test cannot reach.
    private func autoSelectLiveRunIfNeeded() {
        switch Self.liveRunAutoSelection(
            currentSelection: selectedHistoricalRunID,
            liveRunID: executionState?.runRecordID,
            liveRunIsRunning: executionState?.isRunning == true,
            liveRunProfileID: executionState?.workflowProfileID,
            viewProfileID: workflowProfileID
        ) {
        case .select(let recordID):
            selectedHistoricalRunID = recordID
        case .liveRunBelongsToAnotherWorkflow(let recordID):
            logger.notice("[WORKFLOW] Not auto-selecting live run \(recordID.uuidString.prefix(8)) — it belongs to workflow \((executionState?.workflowProfileID).map { String($0.uuidString.prefix(8)) } ?? "<none>") and this view shows \(workflowProfileID.uuidString.prefix(8)). CONSEQUENCE: this workflow's history list stays on screen; the live run is reachable by switching the profile picker back to its own workflow.")
        case .keep:
            break
        }
    }

    /// What `autoSelectLiveRunIfNeeded` should do (register CF-54). `nonisolated static` and
    /// pure — the `runBadge` / WF-UI5 shape — because the profile rule is the defect surface and
    /// the caller is a `@State` write no unit test can reach.
    enum LiveRunAutoSelection: Equatable {
        /// Nothing is selected and THIS workflow's own run is in flight — select it.
        case select(UUID)
        /// A run is in flight in this conversation but belongs to ANOTHER workflow. Selecting it
        /// would assign an id this view's profile-filtered `runHistory` cannot resolve.
        case liveRunBelongsToAnotherWorkflow(UUID)
        /// Respect what is there: a selection already exists, or nothing is running.
        case keep
    }

    nonisolated static func liveRunAutoSelection(
        currentSelection: UUID?,
        liveRunID: UUID?,
        liveRunIsRunning: Bool,
        liveRunProfileID: UUID?,
        viewProfileID: UUID
    ) -> LiveRunAutoSelection {
        guard currentSelection == nil, liveRunIsRunning, let liveRunID else { return .keep }
        // A nil profile on the live state never happens after `WorkflowRunBootstrap.begin`, which
        // always stamps it; treated as "not this workflow" so a malformed state cannot hijack
        // the selection — the same reading `runPickerMenu`'s conjunct gives it.
        guard liveRunProfileID == viewProfileID else {
            return .liveRunBelongsToAnotherWorkflow(liveRunID)
        }
        return .select(liveRunID)
    }

    /// Index of the currently selected run in `runHistory` (1-based, newest first), for the
    /// "1/N" badge; `nil` when nothing is selected or the id is not in this workflow's history.
    ///
    /// ⚠️ The LIVE run resolves too — its `.running` stub is inserted into `runHistory` at index
    /// 0 before the stream starts — so this alone cannot distinguish live from archive. The badge
    /// precedence that decides which wins lives in `Self.runBadge` (register XUI-3; the previous
    /// doc's "Returns 0 when viewing live" was false on both counts).
    private var historicalRunPosition: (index: Int, total: Int)? {
        guard let id = selectedHistoricalRunID,
              let idx = runHistory.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return (idx + 1, runHistory.count)
    }

    /// Currently running node's nodeID, if any. Drives the auto-select behaviour:
    /// the Final Output area follows whichever node is actively executing.
    private var currentRunningNodeID: UUID? {
        executionState?.nodeResults.first(where: { $0.status == .running })?.nodeID
    }

    /// Selection binding shared by both execution layouts: a tap on any non-running node
    /// (incl. Final Outcome) pins the selection; tapping the running node keeps auto-follow on.
    private var pinningSelectionBinding: Binding<UUID?> {
        Binding(
            get: { selectedNodeID },
            set: { newValue in
                selectedNodeID = newValue
                if newValue != currentRunningNodeID { followRunningNode = false }
            }
        )
    }

    /// Resolved profile binding for canvas view.
    ///
    /// ⚠️ Keyed on the profile ID, resolved on every access — NEVER on a captured array index.
    /// `BackendProfileStore.fetchProfiles` sorts by `lastSelected` descending and `saveProfile`
    /// stamps `lastSelected` on every write, so creating or saving any profile re-sorts the array
    /// and shifts every index. A binding holding the old index then reads and writes a DIFFERENT
    /// profile — or goes out of range. The worst case is the workflow settings panel, hosted in an
    /// AppKit panel created once (`NodeInspectorPanelManager.shared.show { … }`), whose captured
    /// binding SwiftUI never refreshes: editing node timeout or context budgets there wrote them
    /// into whichever profile had drifted into that slot.
    private var profileBinding: Binding<BackendProfileModel>? {
        guard profileService.profiles.contains(where: { $0.id == workflowProfileID }) else {
            return nil
        }
        let id = workflowProfileID
        return Binding(
            get: {
                profileService.profiles.first(where: { $0.id == id })
                    // The getter cannot fail a binding, so a profile deleted mid-edit falls back to
                    // an empty shell rather than trapping. The `.onChange` below tears the canvas
                    // down on the next update; this only has to survive until then.
                    ?? BackendProfileModel(id: id, displayName: "", details: .workflow(WorkflowConfig()))
            },
            set: { newValue in
                guard let index = profileService.profiles.firstIndex(where: { $0.id == id }) else {
                    DGLogger(category: "WorkflowDedicated").notice(
                        "[PROFILE] Dropped a canvas write for profile \(id) — it is no longer in "
                        + "the profile list. CONSEQUENCE: the edit is not applied to any profile; "
                        + "previously an index-keyed binding would have written it into whichever "
                        + "profile now occupied that slot."
                    )
                    return
                }
                profileService.profiles[index] = newValue
            }
        )
    }

    var body: some View {
        // [CF-55] ONE build per body pass. `displayData` constructs a whole `WorkflowRunDisplayData`
        // on every read — for a live run that is a topological sort of the layout plus a join of
        // every node's entire upstream output — and `body` re-runs on every streamed workflow
        // event (`nodeTimelines` is `@Observable`, mutated per tool and reasoning event). It used
        // to be read here for the canvas overlay AND, separately, by `executionContent` and three
        // times inside the run picker: four to five rebuilds per event, each copying every node's
        // output on the main actor. Everything below takes this one value (or just its `isLive`)
        // as a parameter; the only other mention of `displayData` in this file is its definition.
        let data = displayData
        ZStack {
            switch viewMode {
            case .execution:
                executionContent(data: data)

            case .canvas:
                ZStack {
                    if let binding = profileBinding {
                        // ⚠️ The canvas state is owned by the view model, not this view's `@State`.
                        // `viewMode` flips to `.execution` automatically when a run starts, which
                        // tears this subtree down — and while the state lived in the canvas view,
                        // that flip destroyed every unsaved edit silently.
                        // ⚠️ `runOverlay` is derived from the ALREADY-COMPUTED `data` at the top of
                        // `body`, never from a fresh fetch. `displayData` is read during `body`,
                        // and `body` re-evaluates on every streamed event — the header on
                        // `cachedLayout` records what an uncached load here cost last time.
                        WorkflowCanvasView(
                            profile: binding,
                            editGuard: viewModel.workflowEditGuard,
                            canvasState: viewModel.workflowCanvasState(for: binding.wrappedValue.id),
                            runOverlay: WorkflowCanvasRunOverlay(displayData: data)
                        )
                    } else {
                        Text("Workflow profile not found")
                            .foregroundColor(theme.secondaryText)
                    }

                    // Floating View Mode Selector Switch in canvas mode
                    VStack {
                        viewModeSegmentedControl
                            .padding(.top, 12)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            refreshLayoutAndValidation()
            // If we mount with an in-flight run already in memory (e.g. user
            // switched away and came back), surface it.
            autoSelectLiveRunIfNeeded()
        }
        .onChange(of: viewMode) { _, newMode in
            // Returning from the canvas is the one path that can have edited the
            // layout — reload it (and revalidate) rather than trusting the cache.
            if newMode == .execution { refreshLayoutAndValidation() }
        }
        .onChange(of: workflowProfileID) { oldID, newID in
            // A different workflow entirely — its layout has nothing to do with the
            // cached one, and neither does the selection.
            //
            // [CF-54] This view is NOT re-created on a profile switch: `MainApplicationView`'s
            // `chatArea` builds `WorkflowDedicatedView(workflowProfileID:conversationID:)` with
            // no `.id(profileID)`, so every `@State` here survives while `runHistory` silently
            // re-filters to the new workflow. The retained `selectedHistoricalRunID` then fails
            // to resolve (correct — the history list shows), but `selectedNodeID` kept a node id
            // from the OLD graph, and the `.onChange(of: selectedHistoricalRunID)` below writes
            // `selectedNodeID` only for a failed run — so the next run picked from the new
            // workflow's list opened with every row collapsed and no Final Outcome panel. Same
            // reset as the conversation handler below, for the same reason.
            selectedHistoricalRunID = nil
            selectedNodeID = nil
            followRunningNode = true
            hydratedTimelines = nil
            refreshLayoutAndValidation()
            autoSelectLiveRunIfNeeded()
            // ⚠️ If that selected THIS workflow's live run, land on the node that is actually
            // executing — `selectedNodeID = nil` SELECTS the Final Outcome row (nil is not "no
            // selection" here), which scrolls past the streaming node and shows a "Waiting for
            // execution" placeholder until the NEXT node transition moves focus. Same landing the
            // run-start observer and the picker's "Live Run" item already perform (XUI-3).
            if selectedHistoricalRunID != nil, executionState?.isRunning == true {
                selectedNodeID = currentRunningNodeID
            }
            logger.info("[WORKFLOW] Workflow profile switched \(oldID.uuidString.prefix(8)) → \(newID.uuidString.prefix(8)) (conversation \(conversationID.map { String($0.uuidString.prefix(8)) } ?? "none")) — dropped the previous workflow's run and node selection. CONSEQUENCE: a run opened from the new workflow's history lands on its Final Outcome panel instead of a node id that belongs to the old graph.")
        }
        .onChange(of: conversationID) { _, _ in
            // Switching to a different conversation invalidates any selection
            // that was tied to the previous conversation's history. Reset and
            // re-auto-select if the new conversation has a live run.
            selectedHistoricalRunID = nil
            selectedNodeID = nil
            followRunningNode = true
            autoSelectLiveRunIfNeeded()
        }
        .onChange(of: executionState?.isRunning) { _, isRunning in
            if isRunning == true {
                // Auto-select the freshly-inserted in-progress record so the
                // live view is shown without the user having to click into it.
                // The .running row already lives in `runHistory` by this point
                // (inserted by MessagingCoordinator before the stream starts).
                // Focus the running node (the `currentRunningNodeID` observer
                // moves focus as execution progresses); re-enable auto-follow.
                //
                // ⚠️ Through the SAME profile-guarded decision `autoSelectLiveRunIfNeeded` uses,
                // and this is the path that matters most: `executionState` is CONVERSATION-scoped
                // while this whole view is PROFILE-scoped (`runHistory` filters by
                // `workflowProfileID`). A run started for workflow A while the picker shows
                // workflow B used to assign A's record id here unguarded — an id B's filtered
                // history cannot resolve, so `displayData` went nil and the user was dumped into
                // the history list mid-run. This is the XUI-3 cross-profile leak on the primary
                // auto-select path; the profile-switch handler alone did not cover it, because
                // `isRunning` only flips when A's FIRST NODE dispatches, which is after the
                // switch has already been handled.
                //
                // `currentSelection: nil` is passed deliberately: a run STARTING is exactly the
                // event that should take over the view, so the "only when nothing is selected"
                // gate does not apply here — only the profile conjunct does.
                switch Self.liveRunAutoSelection(
                    currentSelection: nil,
                    liveRunID: executionState?.runRecordID,
                    liveRunIsRunning: true,
                    liveRunProfileID: executionState?.workflowProfileID,
                    viewProfileID: workflowProfileID
                ) {
                case .select(let recordID):
                    followRunningNode = true
                    selectedNodeID = currentRunningNodeID
                    selectedHistoricalRunID = recordID
                    if viewMode == .canvas {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewMode = .execution
                        }
                    }
                case .liveRunBelongsToAnotherWorkflow(let recordID):
                    logger.notice("[WORKFLOW] A run started in this conversation (record \(recordID.uuidString.prefix(8))) but belongs to workflow \((executionState?.workflowProfileID).map { String($0.uuidString.prefix(8)) } ?? "<none>"), not the \(self.workflowProfileID.uuidString.prefix(8)) this view shows — not auto-selecting it. CONSEQUENCE: this workflow's own view is left as it was instead of being dumped into the history list by an id its filtered history cannot resolve; the run is reachable by switching the profile picker to its workflow.")
                case .keep:
                    break
                }
            } else if isRunning == false,
                      executionState?.workflowError == nil,
                      executionState?.nodeResults.isEmpty == false {
                // Workflow finished cleanly while live — surface the Final
                // Outcome card automatically so the user lands on the
                // synthesis. The historical selection (set when the run
                // started) is preserved, so the view smoothly transitions
                // from live → finalized record on the same row.
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedNodeID = nil
                }
            }
        }
        .onChange(of: currentRunningNodeID) { _, newRunning in
            // Follow the active node: when execution moves to a new node, the
            // selection + Final Output area auto-route to it. Only while viewing
            // the LIVE run (not a past historical one) and the user hasn't pinned
            // a different node this run.
            guard followRunningNode,
                  selectedHistoricalRunID == executionState?.runRecordID,
                  let newRunning else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedNodeID = newRunning
            }
        }
        .onChange(of: executionState?.runRecordID) { _, _ in
            // [XUI-11] The live binding moved on — a run whose traces were being served from
            // memory now has none. See `hydrateTracesIfNeeded` for why the `isRunning` observer
            // above cannot cover this.
            hydrateTracesIfNeeded(for: selectedHistoricalRunID)
        }
        .onChange(of: selectedHistoricalRunID) { _, newID in
            // [XUI-11] Drop the previous run's traces FIRST — keeping them resident for the life of
            // the view is the residency this row is about.
            hydratedTimelines = nil
            hydrateTracesIfNeeded(for: newID)

            // Opening a FAILED historical run auto-focuses the first genuinely-failed
            // node — the debugging evidence — instead of the Final Outcome. Skips the
            // "Upstream dependency failed" cascade to land on the node that actually
            // crashed. Live-run starts insert a `.running` stub record, so those pass
            // through untouched.
            guard let newID,
                  let record = runHistory.first(where: { $0.id == newID }),
                  record.status == .failed else { return }
            let firstFailed = record.nodeResults.first {
                $0.isGenuineFailure
            } ?? record.nodeResults.first { $0.status == .failed }
            if let firstFailed {
                selectedNodeID = firstFailed.nodeID
            }
        }
    }

    // MARK: - Execution Content

    /// - Parameter data: the run model built ONCE at the top of `body` (CF-55). Never read
    ///   `displayData` in here — that is the rebuild this parameter exists to remove.
    private func executionContent(data: WorkflowRunDisplayData?) -> some View {
        VStack(spacing: 0) {
            if let data {
                // Title bar
                executionTitleBar(data: data)

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                // One vertical execution timeline — absorbs the status strip (its
                // run-state + total time live in the timeline header), the card strip,
                // and the output panel. Was one arm of an `executionLayout` prototype
                // switch; the `.original` strip+output layout and its four views were
                // deleted 2026-07-17 after shipping timeline-only.
                WorkflowExecutionTimelineView(
                        displayData: data,
                        selectedNodeID: pinningSelectionBinding,
                        awaitingNodeIDs: awaitingNodeIDs(for: data),
                        onAwaitingTap: { viewModel.interactionCenter.pulseBanner() },
                        // Re-run: resend this run's original input through the normal send path
                        // (same as retyping it). Terminal runs only.
                        onRerun: (!data.isRunning && !data.userInput.isEmpty) ? {
                            // Was a bare `guard … else { return }`: the button rendered enabled,
                            // the click was swallowed, and nothing was logged or shown. Use the
                            // resolving variant, which says WHY — this is a user-initiated path.
                            switch viewModel.backendConfiguration.resolveRequestConfig() {
                            case .failure(let reason):
                                logger.error("[WORKFLOW] Re-run of workflow \(self.workflowProfileID.uuidString.prefix(8)) REFUSED — no request config could be resolved (\(String(describing: reason))). CONSEQUENCE: the click did nothing; nothing was re-run and no banner was shown.")
                            case .success(let config):
                                // ⚠️ `resolveRequestConfig` resolves the CURRENTLY selected
                                // profile, not the one this run belongs to, and there is no API to
                                // build a config for an arbitrary profile id.
                                //
                                // This used to log the mismatch and RUN ANYWAY. Re-run is a real,
                                // side-effecting execution — tools, file writes, HTTP calls — and
                                // the header above the button names this workflow, so a mismatch
                                // means the user clicked "re-run THIS" and something else ran. The
                                // log line was honest and invisible. Now it refuses and says so.
                                let selected = viewModel.backendConfiguration.selectedProfileID
                                if let selected, selected != self.workflowProfileID {
                                    let intended = profileService.profiles.first { $0.id == self.workflowProfileID }?.displayName
                                        ?? String(localized: "this workflow")
                                    let actual = profileService.profiles.first { $0.id == selected }?.displayName
                                        ?? String(localized: "the selected profile")
                                    logger.error("[WORKFLOW] Re-run REFUSED — this run belongs to workflow \(self.workflowProfileID.uuidString.prefix(8)) ('\(intended)') but the selected profile is \(selected.uuidString.prefix(8)) ('\(actual)'). CONSEQUENCE: nothing was executed; re-running would have performed a real, side-effecting run of a DIFFERENT workflow than the one named on screen.")
                                    rerunMismatch = RerunMismatch(intended: intended, actual: actual)
                                    return
                                }
                                viewModel.sendMessage(
                                    attributedString: NSAttributedString(string: data.userInput),
                                    withConfig: config
                                )
                            }
                        } : nil,
                        // WF-UI4: the pill disables itself while a send/stream is in flight instead
                        // of rendering enabled and dropping the click downstream.
                        conversationID: conversationID,
                        rerunBlocked: viewModel.isSendInProgress
                    )

            } else {
                emptyExecutionState
            }
        }
        .frame(maxWidth: ViewLayout.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
        .alert(item: $rerunMismatch) { mismatch in
            Alert(
                title: Text("Can't re-run \(mismatch.intended)"),
                message: Text("This run belongs to \"\(mismatch.intended)\", but \"\(mismatch.actual)\" is currently selected. Re-running would execute \"\(mismatch.actual)\" instead — which may call tools or write files. Select \"\(mismatch.intended)\" and try again."),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Title Bar

    private func executionTitleBar(data: WorkflowRunDisplayData) -> some View {
        HStack(spacing: 10) {
            // Left: Back button + title
            TactileIconButton(
                icon: "chevron.left",
                tooltip: "Back to chat",
                size: .compact
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedHistoricalRunID = nil
                    selectedNodeID = nil
                    // Only clear live execution state if the run is NOT in
                    // progress — clearing mid-run would orphan an actively
                    // streaming `WorkflowExecutionState` (the backend keeps
                    // mutating it, but the view loses its only handle and the
                    // user has no way to navigate back). When a run is live,
                    // "back" instead just deselects any historical row and
                    // returns to the live view.
                    if let cid = conversationID,
                       viewModel.workflowExecutionStates[cid]?.isRunning != true {
                        viewModel.workflowExecutionStates.removeValue(forKey: cid)
                    }
                }
            }
            .accessibilityLabel("Back to chat")

            Text("Workflow execution")
                .font(theme.fontTitle3.weight(.semibold))
                .foregroundColor(theme.primaryText)
                // Truncate, never wrap: this is the element that absorbs the squeeze once the
                // controls to its right refuse to compress. Without an explicit limit a Text
                // grows a second line and the whole bar gets taller instead of narrower.
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                .accessibilityAddTraits(.isHeader)

            // Historical badge — only shown for historical runs.
            if !data.isLive {
                Text("Historical")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.surfaceOverlay))
            }

            // Run position counter — "1/N" for historical, "Live" for live runs
            // when there is at least one historical run.
            runPositionBadge(data: data)

            Spacer()

            // Right: Report + History menu + Canvas button
            reportButton(data: data)

            if !runHistory.isEmpty || !data.isLive {
                runPickerMenu(isLive: data.isLive)
            }

            viewModeSegmentedControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground.opacity(0.4))
        .overlay(
            Rectangle()
                .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    /// Opens the unified run report for the run this view is showing (live or the
    /// selected historical run). Rendered whenever there is a conversation to scope
    /// HITL rows to — a nil traceID still opens the panel, which explains
    /// "recorded before trace support" itself (the four-way unavailability states
    /// exist so entry points never have to guess).
    @ViewBuilder
    private func reportButton(data: WorkflowRunDisplayData) -> some View {
        if let cid = conversationID {
            TactileButton(
                title: "Report",
                icon: "chart.bar.doc.horizontal",
                variant: .secondary,
                size: .compact
            ) {
                ReportInspectorPanelManager.shared.show(
                    messageID: data.runID ?? UUID(),
                    conversationID: cid,
                    traceID: data.traceID,
                    theme: theme,
                    isDeveloperMode: isDeveloperMode,
                    answerPreview: data.finalOutput.isEmpty ? nil : data.finalOutput
                )
            }
            .fixedSize(horizontal: true, vertical: false)   // same reason as the segmented control
            .help("What happened during this run")
            .accessibilityLabel("Open the run report for this workflow run")
        }
    }

    /// What the run-position badge shows (register XUI-3). `nonisolated static` and pure — the
    /// `finalOutcomeTagLabel` shape — because the PRECEDENCE is the defect surface: the live
    /// run's `.running` stub sits in `runHistory`, so `historicalRunPosition` resolves while
    /// live and a position-first check made the "Live" badge unreachable dead code — a live run
    /// wore "1/N" like any archive row. Liveness wins.
    enum RunPickerBadge: Equatable {
        case live
        case position(index: Int, total: Int)
        case none
    }

    nonisolated static func runBadge(isLive: Bool, position: (index: Int, total: Int)?) -> RunPickerBadge {
        if isLive { return .live }
        if let position { return .position(index: position.index, total: position.total) }
        return .none
    }

    /// Whether the picker offers the "Live Run" item (register XUI-3): only while a run is
    /// actually in flight FOR THIS WORKFLOW, and not while it is already on screen. The item used
    /// to render whenever ANY selection existed — including with nothing running, where pressing
    /// it dumped the user into the history list under a label promising a live run.
    ///
    /// ⚠️ `liveRunInFlight` must be derived with the PROFILE conjunct (cold-read finding,
    /// 2026-08-31): `executionState` is CONVERSATION-scoped while this whole view is
    /// PROFILE-scoped (`runHistory` filters by `workflowProfileID`), so "something is running in
    /// this conversation" alone advertised workflow A's live run inside workflow B's picker —
    /// and selecting it dead-ended, because A's record id cannot resolve in B's filtered history.
    nonisolated static func showsLiveRunItem(liveRunInFlight: Bool, viewingLive: Bool) -> Bool {
        liveRunInFlight && !viewingLive
    }

    @ViewBuilder
    private func runPositionBadge(data: WorkflowRunDisplayData) -> some View {
        switch Self.runBadge(isLive: data.isLive, position: historicalRunPosition) {
        case .position(let index, let total):
            Text("\(index)/\(total)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.surfaceOverlay))
                // VoiceOver reads "1/5" literally, as "one slash five". The badge stays
                // terse on screen; only what's spoken changes.
                .accessibilityLabel("Viewing run \(index) of \(total)")
        case .live:
            Text("Live")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.successColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.successColor.opacity(0.12)))
        case .none:
            EmptyView()
        }
    }

    // MARK: - Run Picker Menu

    /// - Parameter isLive: whether the run on screen is the live one — `data.isLive` from the
    ///   title bar, i.e. the single `displayData` build at the top of `body` (CF-55). This menu
    ///   used to read `displayData` three times of its own, rebuilding the whole run model each
    ///   time, for one Bool.
    private func runPickerMenu(isLive: Bool) -> some View {
        let showsLiveItem = Self.showsLiveRunItem(
            // The profile conjunct is load-bearing — see `showsLiveRunItem`'s doc.
            liveRunInFlight: executionState?.isRunning == true
                && executionState?.runRecordID != nil
                && executionState?.workflowProfileID == workflowProfileID,
            viewingLive: isLive
        )
        return Menu {
            // XUI-3: this item is a JUMP BACK TO THE LIVE RUN, and it used to do the opposite —
            // `selectedHistoricalRunID = nil` makes `displayData` nil, which drops the user into
            // the run-history list mid-run with the whole title bar (this picker included) gone,
            // and nothing re-selects the live run. The live run is ADDRESSED through its record
            // id (the `.running` stub's — see `displayData`'s doc), so returning to it means
            // selecting that id, and following the running node again is the point of returning.
            // "Back to the list" is the title bar's back button, not this item.
            if showsLiveItem {
                Button {
                    // ⚠️ The containment guard re-checks at CLICK time what the gate checked at
                    // render time — a Menu can sit open across a profile switch or the run
                    // finishing, and assigning an id this view's filtered `runHistory` cannot
                    // resolve makes `displayData` nil: the history-list dump this item exists to
                    // prevent.
                    if let liveID = executionState?.runRecordID,
                       runHistory.contains(where: { $0.id == liveID }) {
                        selectedHistoricalRunID = liveID
                        // Land ON the streaming node, not the Final Outcome row —
                        // `selectedNodeID = nil` SELECTS that bottom row and scrolls past the
                        // node that is actually executing, and the follow observer only fires on
                        // the NEXT node transition. Same shape as the run-start auto-select.
                        selectedNodeID = currentRunningNodeID
                        followRunningNode = true
                    }
                } label: {
                    Label("Live Run", systemImage: "circle.fill")
                }
            }

            if !runHistory.isEmpty {
                if showsLiveItem { Divider() }

                ForEach(runHistory) { record in
                    Button {
                        selectedHistoricalRunID = record.id
                        selectedNodeID = nil
                    } label: {
                        // `Label` (like the "Live Run" item above) rather than a raw
                        // HStack: a Label's icon is decorative and its TEXT is what gets
                        // read, so the symbol name stops leaking as "xmark.circle.fill".
                        //
                        // Status and time are in the text because they weren't anywhere a
                        // reader could get them: status lived only in the glyph, and with
                        // duration alone every item said "12.4 seconds" with no way — for
                        // anyone — to tell which run you were picking.
                        //
                        // Prominent timer is the run duration. The previous
                        // `Text(record.timestamp, style: .relative)` rendered an
                        // auto-updating since-then string that kept growing for
                        // the lifetime of the view — meaningless for an already
                        // finished run.
                        Label(
                            "\(record.status.label) · \(DurationFormat.seconds(record.duration)) · \(record.timestamp.formatted(date: .omitted, time: .shortened))",
                            systemImage: record.status.icon
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                // Both glyphs are decoration — one is a category hint, the other says
                // "this is a menu", which VoiceOver already announces. Unhidden they were
                // read aloud as "clock.arrow.circlepath, Live, chevron.down".
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .accessibilityHidden(true)
                // XUI-3: state word from the SELECTION's liveness (`isLive`, the run on screen),
                // not from nil-ness — the live run is addressed via a non-nil
                // `selectedHistoricalRunID`, so the nil test said "History" while the live run
                // was on screen and "Live" while nothing ran.
                Text(isLive ? "Live" : "History")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .accessibilityHidden(true)
            }
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(theme.surfaceOverlay)
            )
        }
        // "Live" alone doesn't say what the control DOES, and the label has to carry that
        // — the visible text is one word of state, not a name. Same liveness source as the
        // visible word (XUI-3): the two used to disagree with the screen in the same direction.
        .accessibilityLabel(isLive
                            ? "Run picker, showing the live run"
                            : "Run picker, showing a past run")
    }

    // MARK: - Validation Summary Card

    private var validationSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(theme.errorColor)
                    .accessibilityHidden(true)
                Text("\(validationErrors.count) configuration issue\(validationErrors.count == 1 ? "" : "s")")
                    .font(theme.fontSubheadline.weight(.bold))
                    .foregroundColor(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                TactileButton(
                    title: "Fix in Canvas",
                    variant: .primary,
                    size: .compact
                ) {
                    withAnimation { viewMode = .canvas }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(validationErrors.prefix(5)) { issue in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(theme.errorColor)
                            .frame(width: 4, height: 4)
                        Text("**\(issue.nodeName)**: \(issue.message)")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                if validationErrors.count > 5 {
                    Text("+ \(validationErrors.count - 5) more...")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.leading, 10)
                }
            }

            Text("Resolve these before running the workflow.")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .italic()
        }
        .padding(14)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.errorColor.opacity(0.12), theme.errorColor.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.errorColor.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Empty State

    private var emptyExecutionState: some View {
        VStack(spacing: 0) {
            if runHistory.isEmpty {
                // Full centered hero — no history to show
                VStack(spacing: 18) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(theme.accentColor.opacity(0.45))
                        .padding(20)
                        .background(Circle().fill(theme.accentColor.opacity(0.08)))
                        // Hero decoration; the heading right below says the same thing.
                        .accessibilityHidden(true)

                    Text("Workflow Ready")
                        .font(.title2.weight(.bold))
                        .foregroundColor(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)

                    Text("Type your input below and run the workflow.\nSwitch mode to Canvas to edit the pipeline.")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)

                    // Validation issues summary
                    if !validationErrors.isEmpty {
                        validationSummaryCard
                            .padding(.top, 8)
                    }

                    viewModeSegmentedControl
                        .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Compact top banner + run history below
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.accentColor.opacity(0.85))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workflow Ready")
                            .font(theme.fontSubheadline.weight(.bold))
                            .foregroundColor(theme.primaryText)
                            .accessibilityAddTraits(.isHeader)
                        Text("Type your input below to start a new run.")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    viewModeSegmentedControl
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(theme.secondaryBackground.opacity(0.65))

                // Validation issues (compact, between banner and history)
                if !validationErrors.isEmpty {
                    validationSummaryCard
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                // Run history list
                WorkflowRunHistoryListView(
                    runHistory: runHistory,
                    selectedRunID: $selectedHistoricalRunID
                )
            }
        }
        .background(Color.clear)
    }

    // MARK: - Canvas Floating Button

    // MARK: - View Mode Segmented Control

    private var viewModeSegmentedControl: some View {
        HStack(spacing: 0) {
            viewModeSegmentButton(
                title: "Canvas",
                icon: "rectangle.3.group",
                mode: .canvas
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewMode = .canvas
                }
            }

            viewModeSegmentButton(
                title: "Execution",
                icon: "list.bullet.rectangle",
                mode: .execution
            ) {
                let binding = $viewMode
                viewModel.workflowEditGuard.attempt {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        binding.wrappedValue = .execution
                    }
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(theme.surfaceOverlay))
        .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func viewModeSegmentButton(
        title: LocalizedStringKey,
        icon: String,
        mode: ViewMode,
        action: @escaping () -> Void
    ) -> some View {
        let isSelected = viewMode == mode
        let isThemeContrast = buttonAccentStyle == .themeContrast

        let textColor: Color = {
            if isSelected {
                if isThemeContrast {
                    return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
                }
                return theme.primaryText
            }
            return theme.secondaryText
        }()

        let iconColor: Color = {
            if isSelected {
                if isThemeContrast {
                    return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
                }
                return theme.accentColor
            }
            return theme.secondaryText
        }()

        let fillColor: Color = {
            if isSelected {
                if isThemeContrast {
                    return theme.isDark ? Color.white : Color(red: 0.12, green: 0.12, blue: 0.14)
                }
                return theme.surfaceOverlayStrong
            }
            return Color.clear
        }()

        let strokeColor: Color = {
            if isSelected {
                if isThemeContrast {
                    return theme.isDark ? Color.white : Color(red: 0.12, green: 0.12, blue: 0.14)
                }
                return theme.accentColor.opacity(0.55)
            }
            return Color.clear
        }()

        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(iconColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(textColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(fillColor))
            .overlay(Capsule().strokeBorder(strokeColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel(mode == .canvas ? "Canvas view" : "Execution view")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

}
