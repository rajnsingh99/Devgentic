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
    @State private var validationIssues: [WorkflowValidationIssue] = []

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

                    // Floating "Execution" button in canvas mode
                    VStack {
                        canvasFloatingButton
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
            autoSelectLiveRunIfNeeded()
        }
        .onChange(of: executionState?.isRunning) { _, isRunning in
            if isRunning == true {
                // Auto-select the freshly-inserted in-progress record so the
                // live view is shown without the user having to click into it.
                // The .running row already lives in `runHistory` by this point
                // (inserted by MessagingCoordinator before the stream starts).
                selectedNodeID = nil
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
            // Final Output area auto-routes to its live timeline. Only applies
            // to live runs (historical runs have no "current" node).
            guard selectedHistoricalRunID == nil, let newRunning else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedNodeID = newRunning
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

                // Status strip: ✓ Completed | Total time 13.3s
                executionStatusStrip(data: data)

                Divider().opacity(0.4)

                // Agent cards strip with status-aware connectors. Awaiting-input badges (D2)
                // are driven by the unified InteractionCenter; the HITL request itself now
                // renders in the shared above-input banner (P4 removed the in-canvas panel).
                WorkflowOutcomeStripView(
                    displayData: data,
                    selectedNodeID: $selectedNodeID,
                    awaitingNodeIDs: awaitingNodeIDs(for: data),
                    onAwaitingTap: { viewModel.interactionCenter.pulseBanner() }
                )

                Divider().opacity(0.4)

                // Output area: selected node detail or final output
                WorkflowOutputView(displayData: data, selectedNodeID: selectedNodeID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewMode = .canvas
                }
            } label: {
                Label("Canvas", systemImage: "rectangle.3.group")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(theme.surfaceOverlay))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                Text("\(validationErrors.count) configuration issue\(validationErrors.count == 1 ? "" : "s")")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button {
                    withAnimation { viewMode = .canvas }
                } label: {
                    Text("Fix in Canvas")
                        .font(theme.fontCaption.weight(.medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(validationErrors.prefix(5)) { issue in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 5, height: 5)
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
                        .padding(.leading, 11)
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Empty State

    private var emptyExecutionState: some View {
        VStack(spacing: 0) {
            if runHistory.isEmpty {
                // Full centered hero — no history to show
                VStack(spacing: 16) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 48))
                        .foregroundColor(.purple.opacity(0.4))

                    Text("Workflow Ready")
                        .font(.title2.weight(.bold))
                        .foregroundColor(theme.primaryText)

                    Text("Type your input below and run the workflow.\nSwitch to canvas mode to edit the pipeline.")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)

                    // Validation issues summary
                    if !validationErrors.isEmpty {
                        validationSummaryCard
                    }

                    Button {
                        withAnimation { viewMode = .canvas }
                    } label: {
                        Label("Open Canvas", systemImage: "rectangle.3.group")
                            .font(theme.fontBody.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.purple)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Compact top banner + run history below
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 24))
                        .foregroundColor(.purple.opacity(0.5))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Workflow Ready")
                            .font(theme.fontSubheadline.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Type your input below to start a new run.")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    Button {
                        withAnimation { viewMode = .canvas }
                    } label: {
                        Label("Canvas", systemImage: "rectangle.3.group")
                            .font(theme.fontCaption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.purple)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(theme.secondaryBackground.opacity(0.5))

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

    private var canvasFloatingButton: some View {
        Button {
            // Guarded: prompt Save/Discard/Cancel if the canvas has unsaved edits before
            // showing the execution view (the executor runs the on-DISK layout, so a run
            // with unsaved edits would silently use the stale workflow).
            let binding = $viewMode
            viewModel.workflowEditGuard.attempt {
                withAnimation(.easeInOut(duration: 0.2)) {
                    binding.wrappedValue = .execution
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                Text("Execution")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
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
