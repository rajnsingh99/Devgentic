//
//  WorkflowOutputView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Dual-mode output area for workflow execution:
//  - When a node is selected: shows that node's full AgentTimelineView + output
//  - When no node selected (Final Outcome): shows final synthesized output, variables, user input
//

import SwiftUI

struct WorkflowOutputView: View {
    let displayData: WorkflowRunDisplayData
    let selectedNodeID: UUID?
    @Environment(\.appTheme) private var theme

    /// Resolved selected node data, if any.
    private var selectedNode: WorkflowRunDisplayData.NodeDisplayData? {
        guard let nodeID = selectedNodeID else { return nil }
        return displayData.nodeResults.first { $0.nodeID == nodeID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let node = selectedNode {
                // MARK: - Node Detail Mode
                nodeDetailView(node)
            } else {
                // MARK: - Final Outcome Mode
                finalOutcomeView
            }
        }
    }

    // MARK: - Node Detail

    private func nodeDetailView(_ node: WorkflowRunDisplayData.NodeDisplayData) -> some View {
        VStack(spacing: 0) {
            // Node header
            HStack(spacing: 8) {
                Image(systemName: node.status.icon)
                    .foregroundColor(node.status.color)
                    .font(.system(size: 14))

                Text(node.profileName)
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Text(node.status.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(node.status.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(node.status.color.opacity(0.1)))

                Spacer()

                Label(formatDuration(node.duration), systemImage: "clock")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(theme.secondaryBackground.opacity(0.3))

            Divider()

            // Input section (historical runs)
            if let input = node.input, !input.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Label("Input", systemImage: "arrow.right.circle")
                            .font(theme.fontCaption.weight(.semibold))
                            .foregroundColor(theme.secondaryText)
                        if let source = node.inputSourceLabel {
                            Text("from \(source)")
                                .font(.system(size: 9))
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                    Text(input)
                        .font(.system(size: 12))
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground.opacity(0.2))

                Divider()
            }

            // Full AgentTimelineView + output
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if !node.nodeTimeline.isEmpty {
                        AgentTimelineView(events: node.nodeTimeline, isStreaming: node.isStreaming)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }

                    if !node.detail.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.status == .completed ? "Output" : "Error")
                                .font(theme.fontCaption.weight(.semibold))
                                .foregroundColor(theme.secondaryText)
                            if node.status == .completed {
                                WorkflowMarkdownView(text: node.detail)
                            } else {
                                Text(node.detail)
                                    .font(theme.fontBody)
                                    .foregroundColor(.red)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, node.nodeTimeline.isEmpty ? 12 : 0)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
    }

    // MARK: - Final Outcome

    private var finalOutcomeView: some View {
        VStack(spacing: 0) {
            // User input section (historical runs only)
            if !displayData.isLive && !displayData.userInput.isEmpty {
                userInputPanel
                Divider()
            }

            // Shared variables panel
            if !displayData.variables.isEmpty {
                variablesPanel
                Divider()
            }

            // Final output / status
            ScrollView(.vertical) {
                if !displayData.finalOutput.isEmpty {
                    WorkflowMarkdownView(text: displayData.finalOutput)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)

                } else if let error = displayData.workflowError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(theme.fontBody)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)

                } else if displayData.isRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Awaiting final output...")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)

                } else if displayData.nodeResults.isEmpty {
                    emptyState
                }
            }
        }
    }

    // MARK: - User Input Panel (Historical)

    private var userInputPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("User Input", systemImage: "text.bubble")
                .font(theme.fontCaption.weight(.semibold))
                .foregroundColor(theme.secondaryText)

            Text(displayData.userInput)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.3))
    }

    // MARK: - Variables Panel

    private var variablesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Workflow Variables", systemImage: "tray.2")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                Text("\(displayData.variables.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.surfaceOverlay))
            }

            ForEach(displayData.variables.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
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

    // MARK: - Empty State

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
        .padding(40)
    }

    // MARK: - Helpers

    private func formatDuration(_ d: TimeInterval) -> String {
        if d < 1 { return "<1s" }
        if d < 60 { return "\(String(format: "%.1f", d))s" }
        return "\(Int(d / 60))m \(Int(d.truncatingRemainder(dividingBy: 60)))s"
    }
}
