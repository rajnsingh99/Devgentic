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
    @State private var viewMode: ViewMode = .execution
    @State private var selectedHistoricalRunID: UUID?
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
        let liveTimelines: [UUID: [TimelineEvent]]? = {
            guard let state = executionState, state.runRecordID == record.id else { return nil }
            return state.nodeTimelines
        }()
        // Pass the current layout so the adapter can resolve node kinds and hide
        // the Timeline tab for single-shot nodes (bots etc.).
        return .from(record: record, liveTimelines: liveTimelines, layout: cachedLayout)
    }

    /// Auto-selects the in-flight run's record when it exists but nothing is
    /// currently selected — covers two paths:
    ///   1. A run just started and we need to surface the live view.
    ///   2. The view appeared (mount or conversation switch) and there's
    ///      already a running execution from before this view mounted.
    /// We deliberately skip auto-select when `selectedHistoricalRunID` is
    /// already non-nil so user choices (including an explicit back press
    /// followed by selecting a different historical row) are respected.
    private func autoSelectLiveRunIfNeeded() {
        guard selectedHistoricalRunID == nil,
              let state = executionState,
              state.isRunning,
              let recordID = state.runRecordID else { return }
        selectedHistoricalRunID = recordID
    }

    /// Index of the historical run currently being viewed (1-based, newest first),
    /// for the "1/N" badge. Returns 0 when viewing live or when no history exists.
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
                    ?? BackendProfileModel(id: id, displayName: "", details: .workflow(WorkflowConfig(agentProfileIDs: [])))
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
        ZStack {
            switch viewMode {
            case .execution:
                executionContent

            case .canvas:
                ZStack {
                    if let binding = profileBinding {
                        // ⚠️ The canvas state is owned by the view model, not this view's `@State`.
                        // `viewMode` flips to `.execution` automatically when a run starts, which
                        // tears this subtree down — and while the state lived in the canvas view,
                        // that flip destroyed every unsaved edit silently.
                        // ⚠️ `runOverlay` is derived from the ALREADY-COMPUTED `displayData`, never
                        // from a fresh fetch. `displayData` is read during `body`, and `body`
                        // re-evaluates on every streamed event — the header on `cachedLayout`
                        // records what an uncached load here cost last time.
                        WorkflowCanvasView(
                            profile: binding,
                            editGuard: viewModel.workflowEditGuard,
                            canvasState: viewModel.workflowCanvasState(for: binding.wrappedValue.id),
                            runOverlay: WorkflowCanvasRunOverlay(displayData: displayData)
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
        .onChange(of: workflowProfileID) { _, _ in
            // A different workflow entirely — its layout has nothing to do with the
            // cached one.
            refreshLayoutAndValidation()
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
                followRunningNode = true
                selectedNodeID = currentRunningNodeID
                if let recordID = executionState?.runRecordID {
                    selectedHistoricalRunID = recordID
                }
                if viewMode == .canvas {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewMode = .execution
                    }
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
        .onChange(of: selectedHistoricalRunID) { _, newID in
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

    private var executionContent: some View {
        VStack(spacing: 0) {
            if let data = displayData {
                // Title bar
                executionTitleBar(data: data)

                Divider()

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
            Button {
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
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(8)
                    .background(Circle().fill(theme.surfaceOverlay))
            }
            .buttonStyle(.plain)
            // The primary way out of this view, and it announced as "button" — a glyph is
            // not a name.
            .help("Back to chat")
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
                runPickerMenu
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
            Button {
                ReportInspectorPanelManager.shared.show(
                    messageID: data.runID ?? UUID(),
                    conversationID: cid,
                    traceID: data.traceID,
                    theme: theme,
                    isDeveloperMode: isDeveloperMode,
                    answerPreview: data.finalOutput.isEmpty ? nil : data.finalOutput
                )
            } label: {
                Label("Report", systemImage: "chart.bar.doc.horizontal")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.surfaceOverlay))
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)   // same reason as the segmented control
            .help("What happened during this run")
            .accessibilityLabel("Open the run report for this workflow run")
        }
    }

    @ViewBuilder
    private func runPositionBadge(data: WorkflowRunDisplayData) -> some View {
        if let pos = historicalRunPosition {
            Text("\(pos.index)/\(pos.total)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.surfaceOverlay))
                // VoiceOver reads "1/5" literally, as "one slash five". The badge stays
                // terse on screen; only what's spoken changes.
                .accessibilityLabel("Viewing run \(pos.index) of \(pos.total)")
        } else if data.isLive && !runHistory.isEmpty {
            Text("Live")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.successColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.successColor.opacity(0.12)))
        }
    }

    // MARK: - Run Picker Menu

    private var runPickerMenu: some View {
        Menu {
            if displayData?.isLive == true || selectedHistoricalRunID != nil {
                Button {
                    selectedHistoricalRunID = nil
                    selectedNodeID = nil
                } label: {
                    Label("Live Run", systemImage: "circle.fill")
                }
            }

            if !runHistory.isEmpty {
                Divider()

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
                Text(selectedHistoricalRunID == nil ? "Live" : "History")
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
        // — the visible text is one word of state, not a name.
        .accessibilityLabel(selectedHistoricalRunID == nil
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
                Button {
                    withAnimation { viewMode = .canvas }
                } label: {
                    Text("Fix in Canvas")
                        .font(theme.fontCaption.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .scaleEffect(isHoveringFix ? 1.04 : 1.0)
                .onHover { isHoveringFix = $0 }
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

                Divider()

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
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewMode = .canvas
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 11, weight: .bold))
                        .accessibilityHidden(true)
                    Text("Canvas")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(viewMode == .canvas ? .white : theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(viewMode == .canvas ? theme.accentColor : Color.clear))
            }
            .buttonStyle(.plain)
            // Which half is active was encoded ONLY in the capsule fill and the text colour
            // — invisible to VoiceOver, which read both halves identically.
            .accessibilityLabel("Canvas view")
            .accessibilityAddTraits(viewMode == .canvas ? [.isButton, .isSelected] : .isButton)

            Button(action: {
                let binding = $viewMode
                viewModel.workflowEditGuard.attempt {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        binding.wrappedValue = .execution
                    }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11, weight: .bold))
                        .accessibilityHidden(true)
                    Text("Execution")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(viewMode == .execution ? .white : theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(viewMode == .execution ? theme.accentColor : Color.clear))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Execution view")
            .accessibilityAddTraits(viewMode == .execution ? [.isButton, .isSelected] : .isButton)
        }
        .padding(3)
        .background(Capsule().fill(theme.surfaceOverlay))
        .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
        // ⚠️ THE FIX FOR "Canva s" / "Executi on". In a crowded HStack SwiftUI compresses flexible
        // children, and a bare `Text` answers by WRAPPING — so adding the Report button pushed
        // these two labels into two lines each. Raising `ViewLayout.maxContentWidth` does NOT fix
        // it: that is a MAX and only binds when the window is WIDE, while the clipping happens
        // when it is narrow (the app's own `minWidth` is 760 and this bar wants ~780). Making the
        // control refuse to shrink moves the squeeze onto the title, which truncates cleanly —
        // the right thing to sacrifice, since the title is the one element you can infer.
        // Applied here rather than at the call site so all four usages are covered.
        .fixedSize(horizontal: true, vertical: false)
    }

}
