//
//  WorkflowFinalOutcomeCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 12/04/26.
//
//  Final card in the workflow outcome strip — represents the synthesised result.
//  Visual shell matches `WorkflowOutcomeCardView` exactly (same dimensions,
//  header / body / footer layout) so the strip reads as a uniform pipeline. The
//  body shows a brief synthesis preview when complete, or a placeholder while
//  the workflow is still running. Tapping selects the card and routes the Final
//  Output area below to the workflow-level synthesised output (vs. a node's
//  individual output).
//

import SwiftUI

struct WorkflowFinalOutcomeCardView: View {
    let displayData: WorkflowRunDisplayData
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    // MARK: - Derived status

    /// Aggregate status for the synthesis card. Mirrors `NodeDisplayData.NodeStatus`
    /// so it can render through the same status-driven theming as agent cards.
    private var aggregateStatus: WorkflowRunDisplayData.NodeDisplayData.NodeStatus {
        if displayData.isRunning {
            // Only "synthesising" once every upstream node has settled; while nodes are still
            // executing, this card is just waiting for inputs — so it renders neutral (like other
            // waiting nodes) instead of grabbing the accent/running treatment the whole run.
            let allNodesSettled = !displayData.nodeResults.isEmpty
                && displayData.nodeResults.allSatisfy {
                    $0.status == .completed || $0.status == .failed || $0.status == .skipped
                }
            return allNodesSettled ? .running : .pending
        }
        if displayData.workflowError != nil {
            return .failed
        }
        let failedCount = displayData.nodeResults.filter { $0.status == .failed }.count
        if failedCount > 0 { return .failed }
        if displayData.nodeResults.isEmpty { return .pending }
        return .completed
    }

    private var statusColor: Color { aggregateStatus.color(theme) }

    private var bodyText: String {
        let trimmed = displayData.finalOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let error = displayData.workflowError, !error.isEmpty { return error }
        switch aggregateStatus {
        case .running: return "Synthesising final output…"
        case .pending: return "Awaiting node outputs…"
        default:       return "No final output produced."
        }
    }

    private var durationText: String {
        let d = displayData.duration
        if d <= 0 { return "" }
        if d < 1 { return "<1s" }
        if d < 60 { return "\(String(format: "%.1f", d))s" }
        return "\(Int(d / 60))m \(Int(d.truncatingRemainder(dividingBy: 60)))s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                statusBadge
                Text("Final Outcome")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                let dur = durationText
                if !dur.isEmpty {
                    Text(dur)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Body: brief synthesis preview / placeholder. Matches the 11pt
            // body in `WorkflowOutcomeCardView` so the strip reads uniformly.
            Text(bodyText)
                .font(.system(size: 11))
                .foregroundColor(displayData.workflowError != nil ? .red.opacity(0.85) : theme.secondaryText)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            // Footer
            HStack(spacing: 6) {
                Text(footerLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(statusColor)
                Spacer(minLength: 0)
                if displayData.totalNodes > 0 {
                    Text("\(displayData.completedNodes)/\(displayData.totalNodes)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(statusColor.opacity(0.8))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(statusColor.opacity(0.08))
        }
        .frame(width: 240, height: 180)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? statusColor : statusColor.opacity(isHovering ? 0.55 : 0.35),
                    lineWidth: isSelected ? 2 : 1.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Footer label

    private var footerLabel: String {
        let failedCount = displayData.nodeResults.filter { $0.status == .failed }.count
        if displayData.isRunning { return "Running…" }
        if displayData.workflowError != nil { return "Failed" }
        if failedCount > 0 { return "\(failedCount) Failed" }
        if displayData.nodeResults.isEmpty { return "Waiting" }
        return "Completed"
    }

    // MARK: - Status badge

    @ViewBuilder
    private var statusBadge: some View {
        if aggregateStatus == .running {
            ProgressView()
                .controlSize(.small)
                .tint(statusColor)
        } else {
            Image(systemName: aggregateStatus.icon)
                .foregroundColor(statusColor)
                .font(.system(size: 14))
        }
    }
}
