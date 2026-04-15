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
//  Execution layout (per wireframe):
//  - Title bar: Back + "Workflow execution" | History + Canvas
//  - Horizontal card strip: fixed vertical cards with timeline preview + Final Outcome
//  - Output area: tapped card's full AgentTimelineView or final workflow output
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

    /// Unified display data — resolves from historical record or live state.
    private var displayData: WorkflowRunDisplayData? {
        if let historicalID = selectedHistoricalRunID,
           let record = runHistory.first(where: { $0.id == historicalID }) {
            return .from(record: record)
        }
        if let state = executionState {
            return .from(live: state)
        }
        return nil
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
                        WorkflowCanvasView(profile: binding)
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
        .onAppear { refreshValidation() }
        .onChange(of: viewMode) { _, newMode in
            if newMode == .execution { refreshValidation() }
        }
        .onChange(of: executionState?.isRunning) { _, isRunning in
            if isRunning == true {
                // Auto-switch to execution and reset to live view
                selectedHistoricalRunID = nil
                selectedNodeID = nil
                if viewMode == .canvas {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewMode = .execution
                    }
                }
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

                // Agent cards strip
                WorkflowOutcomeStripView(
                    displayData: data,
                    selectedNodeID: $selectedNodeID
                )

                Divider()

                // Interaction panel (live runs only, if any pending HITL)
                if data.isLive {
                    if let state = executionState {
                        WorkflowInteractionPanel(executionState: state)
                    }
                }

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
        HStack(spacing: 12) {
            // Left: Back button + title
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedHistoricalRunID = nil
                    selectedNodeID = nil
                    // Clear live execution state to go back to ready state
                    if let cid = conversationID {
                        viewModel.workflowExecutionStates.removeValue(forKey: cid)
                    }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(6)
                    .background(Circle().fill(theme.surfaceOverlay))
            }
            .buttonStyle(.plain)

            Text(data.isLive ? "Workflow execution" : "Workflow execution")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)

            if !data.isLive {
                Text("(Historical)")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
            }

            if data.isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else if data.totalNodes > 0 {
                Text("\(data.completedNodes)/\(data.totalNodes)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.surfaceOverlay))
            }

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
            .background(
                Capsule().fill(theme.surfaceOverlay)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground)
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
                            Text(record.timestamp, style: .relative)
                            Text("\u{00B7}")
                            Text(formatDuration(record.duration))
                                .foregroundColor(.secondary)
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
            withAnimation(.easeInOut(duration: 0.2)) {
                viewMode = .execution
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
