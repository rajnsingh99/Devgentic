//
//  WorkflowValidationPanelView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/04/26.
//
//  Floating validation panel that displays workflow configuration issues
//  as an actionable list. Uses glassmorphic styling consistent with the
//  WorkflowToolbarView capsules.
//

import SwiftUI

struct WorkflowValidationPanelView: View {
    let issues: [WorkflowValidationIssue]
    let onSelectNode: (UUID) -> Void
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme

    private var errorCount: Int {
        issues.filter { $0.severity == .error }.count
    }

    private var warningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            issueList
            if errorCount > 0 {
                footer
            }
        }
        .background(theme.surfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)

            Text("\(issues.count) issue\(issues.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)

            if errorCount > 0 {
                countPill(count: errorCount, color: theme.errorColor)
            }

            if warningCount > 0 {
                countPill(count: warningCount, color: theme.warningColor)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Issue List

    private var issueList: some View {
        ScrollView(.vertical) {
            VStack(spacing: 2) {
                ForEach(issues) { issue in
                    issueRow(issue)
                }
            }
        }
        .frame(maxHeight: 250)
    }

    private func issueRow(_ issue: WorkflowValidationIssue) -> some View {
        let isTappable = issue.nodeID != nil

        return HStack(spacing: 8) {
            // Severity icon
            Image(systemName: issue.severity == .error
                  ? "xmark.circle.fill"
                  : "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundColor(issue.severity == .error
                                 ? theme.errorColor
                                 : theme.warningColor)

            // Node name + message
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.nodeName)
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(issue.message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.controlBackground.opacity(0.01))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let nodeID = issue.nodeID {
                onSelectNode(nodeID)
            }
        }
        .allowsHitTesting(isTappable)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            Text("\(errorCount) error\(errorCount == 1 ? "" : "s") must be resolved before running")
                .font(.system(.caption))
                .foregroundColor(theme.errorColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    private func countPill(count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}
