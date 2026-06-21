//
//  WorkflowOutputView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Bottom area of the workflow execution screen. Three rendering states drive
//  the body, all keyed off the currently selected card:
//
//    1. Running   — the selected node is actively executing. Agentic nodes
//                   render their live timeline via `AgentTimelineView`
//                   (chatFidelity=true); single-shot nodes (bots etc.) stream to
//                   the run's final output, so they show a "Generating…" indicator.
//    2. Pending   — the selected node hasn't started yet, or no node has started.
//                   Renders a "Waiting for execution" placeholder.
//    3. Completed — the selected node finished, or the Final Outcome card is
//                   selected with a synthesised output ready. Agentic nodes show a
//                   unified chat-fidelity view (reasoning/tool-call timeline +
//                   the final answer below it, no Output/Timeline toggle); bots and
//                   the Final Outcome render the markdown output directly. All
//                   markdown flows through the shared `WorkflowMarkdownView`
//                   pipeline (parseMarkdown → ContentBlock → CodeBlockView /
//                   MarkdownTableView), wrapped in a panel header with Copy.
//
//  All branches reuse the same content-rendering pipeline used by chat bubbles,
//  so code blocks, tables, inline-code styling, and other markdown features
//  render identically here.
//

import SwiftUI

struct WorkflowOutputView: View {
    let displayData: WorkflowRunDisplayData
    let selectedNodeID: UUID?
    @Environment(\.appTheme) private var theme

    private var selectedNode: WorkflowRunDisplayData.NodeDisplayData? {
        guard let nodeID = selectedNodeID else { return nil }
        return displayData.nodeResults.first { $0.nodeID == nodeID }
    }

    var body: some View {
        Group {
            if let node = selectedNode {
                nodeContent(for: node)
            } else {
                finalOutcomeContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Per-node content

    @ViewBuilder
    private func nodeContent(for node: WorkflowRunDisplayData.NodeDisplayData) -> some View {
        switch node.status {
        case .running:
            if node.supportsTimeline {
                runningTimeline(for: node)
            } else {
                // Single-shot nodes (bots etc.) stream their text to the run's
                // final output, not a per-node timeline — show a generating
                // indicator until the node completes and its Output is ready.
                waitingPlaceholder(message: "Generating output…", showsSpinner: true)
            }

        case .pending:
            waitingPlaceholder(message: "Waiting for execution")

        case .completed, .failed, .skipped:
            // Agentic nodes (agents + Action tool calls) render the chat-fidelity
            // experience — the reasoning/tool-call timeline followed by the final
            // answer in one unified scroll, no Output/Timeline toggle. Single-shot
            // nodes (bots, image generators, structural transforms) and skipped
            // nodes have no meaningful trace, so they show Output directly.
            let hasTimeline = node.supportsTimeline && !node.nodeTimeline.isEmpty
            if hasTimeline && node.status != .skipped {
                timelineContent(for: node)
            } else {
                completedOutput(
                    title: node.status == .failed ? "Error" : "Output",
                    subtitle: subtitleFor(node: node),
                    content: node.detail,
                    copyTarget: node.detail,
                    isError: node.status == .failed
                )
            }
        }
    }

    /// Completed/failed agentic node: the reasoning + tool-call timeline (compact,
    /// chat fidelity) followed by the node's final answer (or error) in one
    /// scroll. Mirrors the chat bubble — which renders the trace above its final
    /// content — so the user reads the agent's steps and result top-to-bottom
    /// without a confusing Output/Timeline toggle.
    @ViewBuilder
    private func timelineContent(for node: WorkflowRunDisplayData.NodeDisplayData) -> some View {
        let isError = node.status == .failed
        VStack(alignment: .leading, spacing: 0) {
            outputPanelHeader(
                icon: isError ? "exclamationmark.triangle.fill" : "sparkle",
                iconColor: isError ? .red : .purple,
                title: node.profileName,
                subtitle: isError ? "Error from \(node.profileName)" : "Result from \(node.profileName)",
                copyTarget: node.detail
            )

            Divider().opacity(0.4)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    // Steps: reasoning + tool calls, deduplicated against the final
                    // answer so a "final answer == last thought" flow isn't repeated.
                    AgentTimelineView(
                        events: node.nodeTimeline,
                        isStreaming: false,
                        chatFidelity: true,
                        finalContentText: node.detail
                    )

                    // Final answer (or error) rendered prominently below the trace.
                    if !node.detail.isEmpty {
                        if isError {
                            Text(node.detail)
                                .font(theme.fontBody)
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            WorkflowMarkdownView(text: node.detail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func subtitleFor(node: WorkflowRunDisplayData.NodeDisplayData) -> String {
        "Result from \(node.profileName)"
    }

    // MARK: - Final outcome content

    @ViewBuilder
    private var finalOutcomeContent: some View {
        if displayData.nodeResults.isEmpty || displayData.nodeResults.allSatisfy({ $0.status == .pending }) {
            waitingPlaceholder(message: "Waiting for execution")
        } else if displayData.isRunning && displayData.finalOutput.isEmpty {
            // Workflow is mid-flight and no final output yet — surface a progress
            // placeholder rather than the completed panel.
            waitingPlaceholder(
                message: "Synthesising final output…",
                showsSpinner: true
            )
        } else if let error = displayData.workflowError, displayData.finalOutput.isEmpty {
            completedOutput(
                title: "Error",
                subtitle: "Workflow failed",
                content: error,
                copyTarget: error,
                isError: true
            )
        } else {
            completedOutput(
                title: "Final Output",
                subtitle: "Result from the workflow",
                content: displayData.finalOutput,
                copyTarget: displayData.finalOutput,
                isError: false
            )
        }
    }

    // MARK: - State views

    /// Renders the live timeline of a running node with chat-bubble fidelity.
    private func runningTimeline(for node: WorkflowRunDisplayData.NodeDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            outputPanelHeader(
                icon: "sparkle",
                iconColor: .blue,
                title: node.profileName,
                subtitle: "Live execution",
                copyTarget: nil
            )

            Divider().opacity(0.4)

            ScrollView(.vertical) {
                AgentTimelineView(
                    events: node.nodeTimeline,
                    isStreaming: node.isStreaming,
                    chatFidelity: true,
                    streamingStartedAt: displayData.timestamp
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Static placeholder shown when no node has started yet, or the selected
    /// node is still pending.
    private func waitingPlaceholder(message: String, showsSpinner: Bool = false) -> some View {
        VStack(spacing: 12) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: "hourglass")
                    .font(.system(size: 32))
                    .foregroundColor(theme.tertiaryText)
            }
            Text(message)
                .font(theme.fontSubheadline)
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Renders a completed node / workflow output through the shared markdown
    /// pipeline, wrapped in a panel header with a copy action.
    private func completedOutput(
        title: String,
        subtitle: String,
        content: String,
        copyTarget: String?,
        isError: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            outputPanelHeader(
                icon: isError ? "exclamationmark.triangle.fill" : "sparkle",
                iconColor: isError ? .red : .purple,
                title: title,
                subtitle: subtitle,
                copyTarget: copyTarget
            )

            Divider().opacity(0.4)

            ScrollView(.vertical) {
                if isError {
                    Text(content)
                        .font(theme.fontBody)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    WorkflowMarkdownView(text: content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
    }

    // MARK: - Panel header

    private func outputPanelHeader(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        copyTarget: String?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(iconColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            if let target = copyTarget, !target.isEmpty {
                CopyOutputButton(target: target)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground.opacity(0.4))
    }
}

// MARK: - Copy Button

/// Lightweight copy-to-pasteboard chip used in the panel header. Mirrors the
/// chat code-block copy affordance in look and behaviour, including the brief
/// "Copied" confirmation state.
private struct CopyOutputButton: View {
    let target: String
    @Environment(\.appTheme) private var theme
    @State private var isCopied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                Text(isCopied ? "Copied" : "Copy")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isCopied ? theme.successColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(theme.surfaceOverlay)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCopied ? "Copied" : "Copy output")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(target, forType: .string)
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isCopied = false
        }
    }
}
