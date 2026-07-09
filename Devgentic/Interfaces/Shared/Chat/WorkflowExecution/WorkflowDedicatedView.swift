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

    enum ViewMode {
        case canvas
        case execution
    }

    /// [UI-REDESIGN PROTOTYPE] Which execution layout to render. Flip to `.original` to restore
    /// the classic horizontal card strip + output panel (both paths stay compiled); `.timelineA`
    /// renders the vertical execution-timeline prototype (WorkflowExecutionTimelineView).
    private enum ExecutionLayout {
        case original
        case timelineA
    }
    private let executionLayout: ExecutionLayout = .timelineA

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

    /// Refreshes validation issues from the current layout + profile store.
    private func refreshValidation() {
        let layout = WorkflowLayoutStore.shared.load(for: workflowProfileID)
        let profileMap = Dictionary(
            profileService.profiles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        validationIssues = WorkflowValidator.validate(layout: layout, profileMap: profileMap)
    }

    /// Run history for this conversation.
    private var runHistory: [WorkflowRunRecord] {
        guard let cid = conversationID else { return [] }
        return viewModel.workflowRunHistory[cid] ?? []
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
            let layout = WorkflowLayoutStore.shared.load(for: workflowProfileID)
            return .from(live: state, layout: layout)
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
        let layout = WorkflowLayoutStore.shared.load(for: workflowProfileID)
        return .from(record: record, liveTimelines: liveTimelines, layout: layout)
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
    private var profileBinding: Binding<BackendProfileModel>? {
        guard let idx = profileService.profiles.firstIndex(where: { $0.id == workflowProfileID }) else {
            return nil
        }
        return Binding(
            get: { profileService.profiles[idx] },
            set: { profileService.profiles[idx] = $0 }
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
                        WorkflowCanvasView(profile: binding, editGuard: viewModel.workflowEditGuard)
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
            refreshValidation()
            // If we mount with an in-flight run already in memory (e.g. user
            // switched away and came back), surface it.
            autoSelectLiveRunIfNeeded()
        }
        .onChange(of: viewMode) { _, newMode in
            if newMode == .execution { refreshValidation() }
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
                $0.status == .failed && !$0.detail.hasPrefix("Upstream dependency")
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

                switch executionLayout {
                case .timelineA:
                    // [UI-REDESIGN PROTOTYPE A] One vertical execution timeline — absorbs the
                    // status strip (its run-state + total time live in the timeline header),
                    // the card strip, and the output panel. Selection semantics unchanged.
                    WorkflowExecutionTimelineView(
                        displayData: data,
                        selectedNodeID: pinningSelectionBinding,
                        awaitingNodeIDs: awaitingNodeIDs(for: data),
                        onAwaitingTap: { viewModel.interactionCenter.pulseBanner() },
                        // Re-run: resend this run's original input through the normal send path
                        // (same as retyping it). Terminal runs only.
                        onRerun: (!data.isRunning && !data.userInput.isEmpty) ? {
                            guard let config = viewModel.backendConfiguration.getRequestConfig() else { return }
                            viewModel.sendMessage(
                                attributedString: NSAttributedString(string: data.userInput),
                                withConfig: config
                            )
                        } : nil
                    )

                case .original:
                    // Status strip: ✓ Completed | Total time 13.3s
                    executionStatusStrip(data: data)

                    Divider().opacity(0.4)

                    // Agent cards strip with status-aware connectors. Awaiting-input badges (D2)
                    // are driven by the unified InteractionCenter; the HITL request itself now
                    // renders in the shared above-input banner (P4 removed the in-canvas panel).
                    WorkflowOutcomeStripView(
                        displayData: data,
                        selectedNodeID: pinningSelectionBinding,
                        awaitingNodeIDs: awaitingNodeIDs(for: data),
                        onAwaitingTap: { viewModel.interactionCenter.pulseBanner() }
                    )

                    Divider().opacity(0.4)

                    // Output area: selected node detail or final output
                    WorkflowOutputView(displayData: data, selectedNodeID: selectedNodeID)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                emptyExecutionState
            }
        }
        .frame(maxWidth: ViewLayout.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(theme.primaryBackground)
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

            Text("Workflow execution")
                .font(theme.fontTitle3.weight(.semibold))
                .foregroundColor(theme.primaryText)

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

            // Right: History menu + Canvas button
            if !runHistory.isEmpty || !data.isLive {
                runPickerMenu
            }

            viewModeSegmentedControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground)
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
        } else if data.isLive && !runHistory.isEmpty {
            Text("Live")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.green.opacity(0.12)))
        }
    }

    // MARK: - Status Strip

    private func executionStatusStrip(data: WorkflowRunDisplayData) -> some View {
        HStack(spacing: 10) {
            statusStripIndicator(data: data)

            if data.duration > 0 || data.isRunning {
                Rectangle()
                    .fill(theme.tertiaryText.opacity(0.3))
                    .frame(width: 1, height: 12)

                Text("Total time \(formatDuration(data.duration))")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.primaryBackground)
    }

    @ViewBuilder
    private func statusStripIndicator(data: WorkflowRunDisplayData) -> some View {
        let (icon, color, label) = stripStatusFor(data: data)
        HStack(spacing: 6) {
            if data.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(color)
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
        }
    }

    private func stripStatusFor(data: WorkflowRunDisplayData) -> (icon: String, color: Color, label: String) {
        if data.isRunning {
            return ("circle.fill", .blue, "Running")
        }
        if data.workflowError != nil {
            return ("xmark.circle.fill", .red, "Failed")
        }
        let failedCount = data.nodeResults.filter { $0.status == .failed }.count
        if failedCount > 0 {
            return ("exclamationmark.triangle.fill", .orange, "\(failedCount) Failed")
        }
        if data.nodeResults.isEmpty {
            return ("circle.dotted", .gray, "Waiting")
        }
        return ("checkmark.circle.fill", .green, "Completed")
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
                        HStack {
                            Image(systemName: statusIcon(for: record.status))
                            // Prominent timer is the run duration. The previous
                            // `Text(record.timestamp, style: .relative)` rendered an
                            // auto-updating since-then string that kept growing for
                            // the lifetime of the view — meaningless for an already
                            // finished run.
                            Text(formatDuration(record.duration))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                Text(selectedHistoricalRunID == nil ? "Live" : "History")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(theme.surfaceOverlay)
            )
        }
    }

    // MARK: - Validation Summary Card

    private var validationSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.red)
                Text("\(validationErrors.count) configuration issue\(validationErrors.count == 1 ? "" : "s")")
                    .font(theme.fontSubheadline.weight(.bold))
                    .foregroundColor(theme.primaryText)
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
                            .fill(Color.red)
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
                        colors: [Color.red.opacity(0.12), Color.red.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
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

                    Text("Workflow Ready")
                        .font(.title2.weight(.bold))
                        .foregroundColor(theme.primaryText)

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

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workflow Ready")
                            .font(theme.fontSubheadline.weight(.bold))
                            .foregroundColor(theme.primaryText)
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
        .background(theme.primaryBackground)
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
                    Text("Canvas")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(viewMode == .canvas ? .white : theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(viewMode == .canvas ? theme.accentColor : Color.clear))
            }
            .buttonStyle(.plain)

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
                    Text("Execution")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(viewMode == .execution ? .white : theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(viewMode == .execution ? theme.accentColor : Color.clear))
            }
            .buttonStyle(.plain)
        }
        .padding(3)
        .background(Capsule().fill(theme.surfaceOverlay))
        .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: - Helpers

    private func statusIcon(for status: WorkflowRunRecord.RunStatus) -> String {
        switch status {
        case .running:   return "circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        if d < 1 { return "<1s" }
        if d < 60 { return "\(String(format: "%.1f", d))s" }
        return "\(Int(d / 60))m \(Int(d.truncatingRemainder(dividingBy: 60)))s"
    }
}
