// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowDedicatedView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "WorkflowDedicated")

/// The dedicated view for a workflow profile, with execution (live), historical (past run) and canvas (builder)
/// modes. Execution mode shows a timeline of node cards with an auto-routed final output panel.
struct WorkflowDedicatedView: View {
    let workflowProfileID: UUID
    let conversationID: UUID?

    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(BackendProfileService.self) private var profileService
    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @State private var viewMode: ViewMode = .execution
    @State private var selectedHistoricalRunID: UUID?

    // Why: graft only the timelines, never the whole re-read record: the disk row can still be a `.running` stub that would
    // overwrite the authoritative in-memory record.
    /// The selected run's node traces, re-read from the store because the in-memory mirror drops them. Cached here
    /// because `displayData` is read during `body` and cannot await.
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

    // Why: `body` re-evaluates on every streamed event, so loading the layout there would run an uncached SwiftData fetch and
    // JSON decode at streaming frequency.
    /// Cached workflow layout; `nil` until the first load, which the display adapter treats as "started nodes only".
    /// Loaded when the layout can change (appear, profile switch, return from canvas).
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
        // Uses the full nested-layout context that pre-flight uses, so nesting cycle/depth errors show here too. Safe to
        // resolve here because this runs only on appear, mode switch and profile change.
        let nested = WorkflowLayoutStore.shared.resolveNestedLayouts(from: layout)
        validationIssues = WorkflowValidator.validate(
            layout: layout,
            profileMap: profileMap,
            subWorkflowLayouts: nested,
            rootProfileID: workflowProfileID
        )
    }

    /// Run history for this workflow in this conversation. Filtered by `workflowProfileID`: the store is keyed by
    /// conversation alone, and another workflow's runs cannot be resolved against this layout.
    private var runHistory: [WorkflowRunRecord] {
        guard let cid = conversationID else { return [] }
        return (viewModel.workflowRunHistory[cid] ?? [])
            .filter { $0.workflowProfileID == workflowProfileID }
    }

    /// Unified display data: every visible run, live or historical, is addressed through `selectedHistoricalRunID`. When
    /// the selected record is the in-flight run (matched by `runRecordID`), the live state is rendered instead of the
    /// stale `.running` snapshot. Live runs are auto-selected by `autoSelectLiveRunIfNeeded`.
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
        // Per-node timelines come from memory for a finalized record that still matches the live state, else from the store
        // re-read, else from the snapshot.
        let liveTimelines: [UUID: [TimelineEvent]]? =
            liveTimelines(forRun: record.id) ??
            (hydratedTimelines?.runID == record.id ? hydratedTimelines?.timelines : nil)
        // Pass the current layout so the adapter can resolve node kinds and hide
        // the Timeline tab for single-shot nodes (bots etc.).
        return .from(record: record, liveTimelines: liveTimelines, layout: cachedLayout)
    }

    // Why: keep the `!isEmpty` test: an empty-but-non-nil map would win the `??` in `from(record:)` and shadow the hydrated
    // traces.
    /// Returns the live state's traces for a run, or nil when it does not have them. Read by both `displayData` and the
    /// hydration trigger so they agree on whether a re-read is needed.
    private func liveTimelines(forRun runID: UUID) -> [UUID: [TimelineEvent]]? {
        guard let state = executionState, state.runRecordID == runID,
              !state.nodeTimelines.isEmpty else { return nil }
        return state.nodeTimelines
    }

    // Why: the loop is inline, not recursive: after the first `await` only `@State` may be touched, not `@Environment`
    // values.
    /// Re-reads the selected run's node traces when the in-memory mirror does not have them. Triggered by selection and
    /// by `.onChange(of: executionState?.runRecordID)`; the read is attempted at most twice.
    private func hydrateTracesIfNeeded(for runID: UUID?) {
        guard let runID, let listed = runHistory.first(where: { $0.id == runID }),
              WorkflowRunRecord.needsTraceHydration(
                  listed, liveTimelinesAvailable: liveTimelines(forRun: runID) != nil)
        else { return }

        Task { @MainActor in
            // Attempt 0 is the first read, 1 the single retry for the write race; bounded because runs that hold no trace must
            // not re-read in a loop.
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
                    // Animated because arriving timeline events can retract an error paragraph or swap a "Not run" line for a full
                    // trace.
                    withAnimation(.easeInOut(duration: 0.15)) {
                        hydratedTimelines = (runID: runID, timelines: timelines)
                    }
                    return
                }

                // The listed record can be finalized before its fire-and-forget disk write lands, so the re-read may return the
                // `.running` stub; log it, since hydration re-arms only from the `.onChange` triggers.
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

    // Why: the profile check is required: `executionState` is conversation-scoped but this view is profile-scoped, and a
    // stale non-nil selection blocks later auto-selects.
    /// Auto-selects the in-flight run's record when nothing is selected: on run start, on appear with a run in flight,
    /// and after a profile switch. An existing selection is never overridden, so explicit user choices are respected.
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

    /// What `autoSelectLiveRunIfNeeded` should do. `nonisolated static` and pure so the profile rule can be unit-tested.
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
        // A nil profile on the live state is treated as "not this workflow" so a malformed state cannot hijack the
        // selection.
        guard liveRunProfileID == viewProfileID else {
            return .liveRunBelongsToAnotherWorkflow(liveRunID)
        }
        return .select(liveRunID)
    }

    /// Index of the selected run in `runHistory` (1-based, newest first) for the "1/N" badge; nil when nothing is
    /// selected or the id is not in this workflow's history. The live run also resolves, so `Self.runBadge` decides
    /// whether live or archive wins.
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

    // Why: resolve by ID on every access, never a captured array index: saving any profile re-sorts the array, and the
    // inspector's AppKit panel keeps its binding.
    /// Resolved binding to the profile for the canvas view, keyed on the profile ID.
    private var profileBinding: Binding<BackendProfileModel>? {
        guard profileService.profiles.contains(where: { $0.id == workflowProfileID }) else {
            return nil
        }
        let id = workflowProfileID
        return Binding(
            get: {
                profileService.profiles.first(where: { $0.id == id })
                    // The getter cannot fail a binding, so a profile deleted mid-edit falls back to an empty shell until the `.onChange`
                    // below tears the canvas down.
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
        // Why: `displayData` rebuilds a whole `WorkflowRunDisplayData` (topological sort plus upstream output joins) on every
        // read, and `body` re-runs per streamed event.
        // Built once per body pass and passed down as a parameter.
        let data = displayData
        ZStack {
            switch viewMode {
            case .execution:
                executionContent(data: data)

            case .canvas:
                ZStack {
                    if let binding = profileBinding {
                        // The canvas state is owned by the view model so the automatic flip to `.execution` on run start does not destroy
                        // unsaved edits. `runOverlay` derives from the already-computed `data`.
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
            // A different workflow: its layout and selection are unrelated to the cached ones. This view is not re-created on a
            // profile switch, so `selectedNodeID` is reset along with the selection, as in the conversation handler below.
            selectedHistoricalRunID = nil
            selectedNodeID = nil
            followRunningNode = true
            hydratedTimelines = nil
            refreshLayoutAndValidation()
            autoSelectLiveRunIfNeeded()
            // If the selection is this workflow's live run, land on the executing node; nil would select the Final Outcome row
            // and scroll past it.
            if selectedHistoricalRunID != nil, executionState?.isRunning == true {
                selectedNodeID = currentRunningNodeID
            }
            logger.info("[WORKFLOW] Workflow profile switched \(oldID.uuidString.prefix(8)) → \(newID.uuidString.prefix(8)) (conversation \(conversationID.map { String($0.uuidString.prefix(8)) } ?? "none")) — dropped the previous workflow's run and node selection. CONSEQUENCE: a run opened from the new workflow's history lands on its Final Outcome panel instead of a node id that belongs to the old graph.")
        }
        .onChange(of: conversationID) { _, _ in
            // A different conversation invalidates any selection tied to the previous history; reset and re-auto-select if the
            // new one has a live run.
            selectedHistoricalRunID = nil
            selectedNodeID = nil
            followRunningNode = true
            autoSelectLiveRunIfNeeded()
        }
        .onChange(of: executionState?.isRunning) { _, isRunning in
            if isRunning == true {
                // Auto-selects the new in-progress record and focuses the running node, through the same profile-guarded decision as
                // `autoSelectLiveRunIfNeeded`. `currentSelection: nil` because a starting run should take over the view.
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
                // A run that finishes cleanly while live surfaces the Final Outcome card; the historical selection is kept so the
                // view transitions in place.
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedNodeID = nil
                }
            }
        }
        .onChange(of: currentRunningNodeID) { _, newRunning in
            // Follows the active node: selection and Final Output route to it, only while viewing the live run and the user has
            // not pinned a node.
            guard followRunningNode,
                  selectedHistoricalRunID == executionState?.runRecordID,
                  let newRunning else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedNodeID = newRunning
            }
        }
        .onChange(of: executionState?.runRecordID) { _, _ in
            // The live binding moved on, so a run whose traces were served from memory now has none; the `isRunning` observer
            // above cannot cover this.
            hydrateTracesIfNeeded(for: selectedHistoricalRunID)
        }
        .onChange(of: selectedHistoricalRunID) { _, newID in
            // [XUI-11] Drop the previous run's traces FIRST — keeping them resident for the life of
            // the view is the residency this row is about.
            hydratedTimelines = nil
            hydrateTracesIfNeeded(for: newID)

            // Opening a failed historical run focuses the first genuinely failed node, skipping the "Upstream dependency failed"
            // cascade. Live-run starts insert a `.running` stub and pass through.
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

    /// - Parameter data: the run model built once at the top of `body`; do not read `displayData` in here.
    private func executionContent(data: WorkflowRunDisplayData?) -> some View {
        VStack(spacing: 0) {
            if let data {
                // Title bar
                executionTitleBar(data: data)

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                // One vertical execution timeline that includes the run state and total time in its header, the card strip and the
                // output panel.
                WorkflowExecutionTimelineView(
                        displayData: data,
                        selectedNodeID: pinningSelectionBinding,
                        awaitingNodeIDs: awaitingNodeIDs(for: data),
                        onAwaitingTap: { viewModel.interactionCenter.pulseBanner() },
                        // Re-run: resend this run's original input through the normal send path
                        // (same as retyping it). Terminal runs only.
                        onRerun: (!data.isRunning && !data.userInput.isEmpty) ? {
                            // Uses the resolving variant, which reports why resolution failed, since this is a user-initiated path.
                            switch viewModel.backendConfiguration.resolveRequestConfig() {
                            case .failure(let reason):
                                logger.error("[WORKFLOW] Re-run of workflow \(self.workflowProfileID.uuidString.prefix(8)) REFUSED — no request config could be resolved (\(String(describing: reason))). CONSEQUENCE: the click did nothing; nothing was re-run and no banner was shown.")
                            case .success(let config):
                                // `resolveRequestConfig` resolves the currently selected profile, not the run's own, and Re-run has side effects, so
                                // a mismatch refuses and says so.
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
                    // Live execution state is cleared only when no run is in progress, otherwise the view would lose its only handle on
                    // a streaming `WorkflowExecutionState`. While live, "back" only deselects the historical row.
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
                // Truncates instead of wrapping: this element absorbs the squeeze, and a second line would make the bar taller.
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

    /// Opens the unified run report for the run on screen (live or historical). Shown whenever there is a conversation to
    /// scope HITL rows to; a nil traceID still opens the panel, which explains missing trace support.
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

    /// What the run-position badge shows. `nonisolated static` and pure; liveness takes precedence, because the live
    /// run's `.running` stub also resolves a history position.
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

    /// Whether the picker offers the "Live Run" item: only while a run is in flight for this workflow and not already on
    /// screen. `liveRunInFlight` must include the profile check, since `executionState` is conversation-scoped.
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

    /// - Parameter isLive: whether the run on screen is the live one (`data.isLive` from the title bar).
    private func runPickerMenu(isLive: Bool) -> some View {
        let showsLiveItem = Self.showsLiveRunItem(
            // The profile conjunct is load-bearing — see `showsLiveRunItem`'s doc.
            liveRunInFlight: executionState?.isRunning == true
                && executionState?.runRecordID != nil
                && executionState?.workflowProfileID == workflowProfileID,
            viewingLive: isLive
        )
        return Menu {
            // This item jumps back to the live run by selecting its record id; clearing the selection would drop the user into
            // the history list. "Back to the list" is the title bar's back button.
            if showsLiveItem {
                Button {
                    // Re-checks containment at click time: a Menu can stay open across a profile switch or the run finishing, and an
                    // unresolvable id would make `displayData` nil.
                    if let liveID = executionState?.runRecordID,
                       runHistory.contains(where: { $0.id == liveID }) {
                        selectedHistoricalRunID = liveID
                        // Lands on the streaming node; nil would select the Final Outcome row and scroll past it until the next node
                        // transition.
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
                        // A `Label` rather than a raw HStack so VoiceOver reads the text, not the symbol name. Status and time are in the
                        // text, and the timer is the run duration rather than a growing relative timestamp.
                        Label(
                            "\(record.status.label) · \(DurationFormat.seconds(record.duration)) · \(record.timestamp.formatted(date: .omitted, time: .shortened))",
                            systemImage: record.status.icon
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                // Both glyphs are decorative; unhidden they would be read aloud as symbol names.
                if isLive {
                    DevgenticActivityIndicator(style: .gyroscope, size: 11, tint: theme.accentColor)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .accessibilityHidden(true)
                }
                // The state word comes from the selection's liveness (`isLive`), not from whether the selection is nil.
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
        // The visible text is one word of state, so the label also says what the control does; it uses the same liveness
        // source as the visible word.
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
