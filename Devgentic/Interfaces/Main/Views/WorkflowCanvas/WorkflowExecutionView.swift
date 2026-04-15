//
//  WorkflowExecutionView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Displays workflow execution results as a horizontal strip of agent outcome
//  cards (one per node) above a scrollable final output area.
//  Data is streamed in real-time via AgentStreamEvent.workflowNode* events.
//

import SwiftUI

// MARK: - Workflow Node Result (Display Model)

/// Lightweight display model for a single node's execution result.
/// Built from `AgentStreamEvent.workflowNode*` events — does not require
/// access to the full `NodeResultEnvelope` (which is internal to WorkflowExecutor).
struct WorkflowNodeResult: Identifiable, Sendable {
    let id: UUID
    let nodeID: UUID
    let profileName: String
    let status: Status
    let detail: String
    let startTime: Date
    var endTime: Date?

    var duration: TimeInterval {
        (endTime ?? Date()).timeIntervalSince(startTime)
    }

    enum Status: Sendable {
        case running
        case completed
        case failed
        case skipped
    }
}

// MARK: - Execution State

/// Observable state manager for a single workflow execution run.
/// Fed by ActiveStreamManager's workflow-specific event processing.
@Observable
final class WorkflowExecutionState {

    /// Per-node results, ordered by event arrival.
    var nodeResults: [WorkflowNodeResult] = []

    /// Synthesised final output from terminal nodes.
    var finalOutput: String = ""

    /// Overall progress.
    var completedNodes: Int = 0
    var totalNodes: Int = 0

    /// Whether the workflow is currently executing.
    var isRunning: Bool = false

    /// Error if the entire workflow failed.
    var workflowError: String?

    /// Shared workflow variables (written by Code nodes).
    var variables: [String: String] = [:]

    /// Per-node timeline events for expanded node detail views.
    /// Keyed by nodeID, populated by ActiveStreamManager when sourceNodeID is present.
    var nodeTimelines: [UUID: [TimelineEvent]] = [:]

    /// Pending HITL interactions from workflow nodes (multiple can be concurrent).
    /// Keyed by operationID for fast lookup/removal on resolution.
    var pendingInteractions: [UUID: WorkflowInteractionRequest] = [:]

    // MARK: - Per-Node Timeline

    /// Appends a timeline event to a specific node's timeline.
    func appendNodeTimelineEvent(_ event: TimelineEvent, for nodeID: UUID) {
        nodeTimelines[nodeID, default: []].append(event)
    }

    // MARK: - Workflow HITL Interactions

    /// Registers a pending HITL interaction from a workflow node.
    func addPendingInteraction(_ request: WorkflowInteractionRequest) {
        pendingInteractions[request.id] = request
    }

    /// Removes a resolved interaction by its operationID.
    func removePendingInteraction(operationID: UUID) {
        pendingInteractions.removeValue(forKey: operationID)
    }

    // MARK: - Event Ingestion

    func handleNodeStarted(nodeID: UUID, profileName: String, index: Int, total: Int) {
        totalNodes = total
        isRunning = true

        // Add a running placeholder (avoid duplicates)
        guard !nodeResults.contains(where: { $0.nodeID == nodeID }) else { return }
        nodeResults.append(WorkflowNodeResult(
            id: UUID(), nodeID: nodeID, profileName: profileName,
            status: .running, detail: "Running...",
            startTime: Date()
        ))
    }

    func handleNodeCompleted(nodeID: UUID, profileName: String, summary: String) {
        if let idx = nodeResults.firstIndex(where: { $0.nodeID == nodeID }) {
            nodeResults[idx] = WorkflowNodeResult(
                id: nodeResults[idx].id, nodeID: nodeID, profileName: profileName,
                status: .completed, detail: summary,
                startTime: nodeResults[idx].startTime, endTime: Date()
            )
        } else {
            nodeResults.append(WorkflowNodeResult(
                id: UUID(), nodeID: nodeID, profileName: profileName,
                status: .completed, detail: summary,
                startTime: Date(), endTime: Date()
            ))
        }
    }

    func handleNodeFailed(nodeID: UUID, profileName: String, error: String) {
        if let idx = nodeResults.firstIndex(where: { $0.nodeID == nodeID }) {
            nodeResults[idx] = WorkflowNodeResult(
                id: nodeResults[idx].id, nodeID: nodeID, profileName: profileName,
                status: .failed, detail: error,
                startTime: nodeResults[idx].startTime, endTime: Date()
            )
        } else {
            nodeResults.append(WorkflowNodeResult(
                id: UUID(), nodeID: nodeID, profileName: profileName,
                status: .failed, detail: error,
                startTime: Date(), endTime: Date()
            ))
        }
    }

    func handleProgress(completed: Int, total: Int) {
        completedNodes = completed
        totalNodes = total
    }

    func handleLoopIteration(nodeID: UUID, profileName: String, iteration: Int, maxIterations: Int) {
        if let idx = nodeResults.firstIndex(where: { $0.nodeID == nodeID }) {
            nodeResults[idx] = WorkflowNodeResult(
                id: nodeResults[idx].id, nodeID: nodeID, profileName: profileName,
                status: .running, detail: "Iteration \(iteration)/\(maxIterations)...",
                startTime: nodeResults[idx].startTime
            )
        }
    }

    func handleFinalOutput(_ output: String) {
        finalOutput = output
        isRunning = false
    }

    func handleError(_ error: String) {
        workflowError = error
        isRunning = false
    }

    func reset() {
        nodeResults = []
        finalOutput = ""
        completedNodes = 0
        totalNodes = 0
        isRunning = false
        workflowError = nil
        nodeTimelines = [:]
        pendingInteractions = [:]
    }
}

// MARK: - Execution View

struct WorkflowExecutionView: View {
    let executionState: WorkflowExecutionState
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // --- Header ---
            executionHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(theme.secondaryBackground)

            Divider()

            // --- Shared Variables Panel (collapsible) ---
            if !executionState.variables.isEmpty {
                variablesPanel
                Divider()
            }

            if executionState.nodeResults.isEmpty && !executionState.isRunning {
                emptyState
            } else {
                // --- Agent Outcome Cards (Horizontal) ---
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(executionState.nodeResults) { result in
                            AgentOutcomeCard(result: result)
                        }

                        // Show placeholder for running nodes
                        if executionState.isRunning && executionState.completedNodes < executionState.totalNodes {
                            runningPlaceholderCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(minHeight: 100, maxHeight: 140)

                Divider()

                // --- Final Output (Vertical Scroll) ---
                ScrollView(.vertical) {
                    if !executionState.finalOutput.isEmpty {
                        Text(executionState.finalOutput)
                            .font(theme.fontBody)
                            .foregroundColor(theme.primaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else if let error = executionState.workflowError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(theme.fontBody)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else if executionState.isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Awaiting final output...")
                                .font(theme.fontCaption)
                                .foregroundColor(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                    }
                }
            }
        }
        .background(theme.primaryBackground)
    }

    // MARK: - Subviews

    private var executionHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title3)
                .foregroundColor(.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text("Workflow Execution")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                if executionState.totalNodes > 0 {
                    Text("\(executionState.completedNodes)/\(executionState.totalNodes) nodes \(executionState.isRunning ? "running" : "completed")")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }
            }

            Spacer()

            if executionState.isRunning {
                ProgressView()
                    .controlSize(.small)
            } else if !executionState.nodeResults.isEmpty {
                let failedCount = executionState.nodeResults.filter { $0.status == .failed }.count

                if failedCount > 0 {
                    Label("\(failedCount) failed", systemImage: "exclamationmark.triangle.fill")
                        .font(theme.fontCaption)
                        .foregroundColor(.orange)
                } else {
                    Label("All passed", systemImage: "checkmark.circle.fill")
                        .font(theme.fontCaption)
                        .foregroundColor(.green)
                }
            }
        }
    }

    private var variablesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Workflow Variables", systemImage: "tray.2")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Text("\(executionState.variables.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.surfaceOverlay))
            }

            ForEach(executionState.variables.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                    Text("=")
                        .font(.system(size: 10))
                        .foregroundColor(theme.secondaryText)
                    Text(String(value.prefix(100)) + (value.count > 100 ? "..." : ""))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.circle")
                .font(.system(size: 40))
                .foregroundColor(theme.secondaryText)
            Text("No execution results yet")
                .font(theme.fontSubheadline)
                .foregroundColor(theme.secondaryText)
            Text("Run the workflow to see node-by-node results here.")
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
    }

    private var runningPlaceholderCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Running...")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.surfaceOverlay)
                .frame(width: 100, height: 8)
        }
        .padding(12)
        .frame(width: 160, height: 90)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.surfaceOverlayStrong.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        )
    }
}

// MARK: - Agent Outcome Card

struct AgentOutcomeCard: View {
    let result: WorkflowNodeResult
    @Environment(\.appTheme) private var theme
    @State private var isExpanded = false

    private var statusIcon: String {
        switch result.status {
        case .running:   return "arrow.trianglehead.2.clockwise"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .skipped:   return "arrow.right.circle.fill"
        }
    }

    private var statusColor: Color {
        switch result.status {
        case .running:   return .blue
        case .completed: return .green
        case .failed:    return .red
        case .skipped:   return .gray
        }
    }

    private var durationText: String {
        let d = result.duration
        if d < 1 { return "<1s" }
        if d < 60 { return "\(String(format: "%.1f", d))s" }
        return "\(Int(d / 60))m \(Int(d.truncatingRemainder(dividingBy: 60)))s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedContent
                .padding(12)

            if isExpanded {
                Divider()
                expandedContent
                    .padding(12)
            }
        }
        .frame(width: isExpanded ? 320 : 180, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.3), lineWidth: 1.5)
        )
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }

    private var collapsedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if result.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                        .font(.system(size: 14))
                }
                Text(result.profileName)
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                Text(durationText)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
            }

            if !result.detail.isEmpty && result.status != .running {
                Text(String(result.detail.prefix(60)) + (result.detail.count > 60 ? "..." : ""))
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Status:")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                Text(statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(statusColor)
            }

            Label(durationText, systemImage: "clock")
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)

            if !result.detail.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.status == .completed ? "Output" : "Detail")
                        .font(theme.fontCaption.weight(.medium))
                        .foregroundColor(theme.secondaryText)
                    Text(String(result.detail.prefix(500)) + (result.detail.count > 500 ? "..." : ""))
                        .font(.system(size: 11))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var statusLabel: String {
        switch result.status {
        case .running:   return "Running..."
        case .completed: return "Completed"
        case .failed:    return "Failed"
        case .skipped:   return "Skipped"
        }
    }
}
