//
//  WorkflowOutputView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Bottom area of the workflow execution screen. Three rendering states drive
//  the body, all keyed off the currently selected card:
//
//    1. Running   — the selected node is actively executing. Renders its live
//                   timeline using `AgentTimelineView` with chatFidelity=true,
//                   matching the in-chat agent experience exactly.
//    2. Pending   — the selected node hasn't started yet, or no node has started.
//                   Renders a "Waiting for execution" placeholder.
//    3. Completed — the selected node finished, or the Final Outcome card is
//                   selected with a synthesised output ready. Renders the markdown
//                   content through the shared `WorkflowMarkdownView` pipeline
//                   (parseMarkdown → ContentBlock → CodeBlockView / MarkdownTableView),
//                   wrapped in a Final-Output panel header with a Copy action.
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

    /// Which content the user is currently viewing for the selected completed
    /// node. Only meaningful when the node has a non-empty `nodeTimeline`; for
    /// timeline-less nodes (bots, or historical runs without live state) the
    /// toggle is hidden and only Output is shown. Resets to `.output` whenever
    /// `selectedNodeID` changes so each new selection starts predictably.
    @State private var contentTab: ContentTab = .output

    enum ContentTab: Hashable { case output, timeline }

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
        .onChange(of: selectedNodeID) { _, _ in
            contentTab = .output
        }
    }

    // MARK: - Per-node content

    @ViewBuilder
    private func nodeContent(for node: WorkflowRunDisplayData.NodeDisplayData) -> some View {
        switch node.status {
        case .running:
            runningTimeline(for: node)

        case .pending:
            waitingPlaceholder(message: "Waiting for execution")

        case .completed, .failed, .skipped:
            // Completed/failed nodes with a captured timeline get a two-tab
            // view (Output ↔ Timeline) so agent reasoning + tool calls remain
            // accessible after completion. Timeline-less nodes (bots, or
            // post-restart historical) render Output directly without a tab.
            let hasTimeline = !node.nodeTimeline.isEmpty
            if hasTimeline && node.status != .skipped {
                tabbedNodeContent(for: node)
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

    /// Completed/failed agent-node body with the Output/Timeline segmented
    /// toggle in the header.
    @ViewBuilder
    private func tabbedNodeContent(for node: WorkflowRunDisplayData.NodeDisplayData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            outputPanelHeader(
                icon: node.status == .failed ? "exclamationmark.triangle.fill" : "sparkle",
                iconColor: node.status == .failed ? .red : .purple,
                title: node.profileName,
                subtitle: contentTab == .output
                    ? (node.status == .failed ? "Error from \(node.profileName)" : "Result from \(node.profileName)")
                    : "Reasoning & tool calls",
                copyTarget: contentTab == .output ? node.detail : nil,
                segmented: { contentTabPicker }
            )

            Divider().opacity(0.4)

            switch contentTab {
            case .output:
                ScrollView(.vertical) {
                    if node.status == .failed {
                        Text(node.detail)
                            .font(theme.fontBody)
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        WorkflowMarkdownView(text: node.detail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            case .timeline:
                ScrollView(.vertical) {
                    AgentTimelineView(
                        events: node.nodeTimeline,
                        isStreaming: false,
                        chatFidelity: true,
                        streamingStartedAt: displayData.timestamp
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    /// Segmented control rendered inline in the panel header — only built for
    /// the tabbed branch above.
    private var contentTabPicker: some View {
        HStack(spacing: 2) {
            tabPickerButton(.output, label: "Output", icon: "doc.text")
            tabPickerButton(.timeline, label: "Timeline", icon: "list.bullet.indent")
        }
        .padding(2)
        .background(Capsule().fill(theme.surfaceOverlay))
    }

    private func tabPickerButton(_ tab: ContentTab, label: String, icon: String) -> some View {
        let isSelected = contentTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                contentTab = tab
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isSelected ? theme.controlBackground : Color.clear)
            )
        }
        .buttonStyle(.plain)
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

    private func outputPanelHeader<Segmented: View>(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        copyTarget: String?,
        @ViewBuilder segmented: () -> Segmented = { EmptyView() }
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

            segmented()

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
