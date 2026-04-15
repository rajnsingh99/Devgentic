//
//  WorkflowFinalOutcomeCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 12/04/26.
//
//  The "Final Outcome" card shown at the end of the workflow outcome strip.
//  Displays the aggregated workflow result with output preview.
//

import SwiftUI

struct WorkflowFinalOutcomeCardView: View {
    let displayData: WorkflowRunDisplayData
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var overallColor: Color {
        if displayData.isRunning { return .blue }
        if let _ = displayData.workflowError { return .red }
        let failedCount = displayData.nodeResults.filter { $0.status == .failed }.count
        if failedCount > 0 { return .orange }
        return .green
    }

    private var statusLabel: String {
        if displayData.isRunning { return "Running..." }
        if let _ = displayData.workflowError { return "Failed" }
        let failedCount = displayData.nodeResults.filter { $0.status == .failed }.count
        if failedCount > 0 { return "\(failedCount) Failed" }
        return "Completed"
    }

    private var statusIcon: String {
        if displayData.isRunning { return "arrow.trianglehead.2.clockwise" }
        if let _ = displayData.workflowError { return "xmark.circle.fill" }
        let failedCount = displayData.nodeResults.filter { $0.status == .failed }.count
        if failedCount > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                if displayData.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: statusIcon)
                        .foregroundColor(overallColor)
                        .font(.system(size: 13))
                }
                Text("Final Outcome")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(overallColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 8)

            // Output preview
            if !displayData.finalOutput.isEmpty {
                Text(displayData.finalOutput)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else if let error = displayData.workflowError {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundColor(.red.opacity(0.7))
                        .padding(.top, 2)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else if displayData.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Awaiting...")
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }

            Divider()
                .padding(.horizontal, 8)

            // Footer
            HStack(spacing: 6) {
                Label(
                    "\(displayData.completedNodes)/\(displayData.totalNodes)",
                    systemImage: "square.on.square"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)

                Spacer(minLength: 0)

                Text(statusLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(overallColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? theme.accentColor.opacity(0.08) : (isHovering ? theme.surfaceOverlay : theme.controlBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? theme.accentColor : overallColor.opacity(isHovering ? 0.5 : 0.3),
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
}
