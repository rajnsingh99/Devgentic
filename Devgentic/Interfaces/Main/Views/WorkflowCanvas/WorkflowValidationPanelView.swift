// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowValidationPanelView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A floating panel listing workflow configuration issues as an actionable list, styled like `WorkflowToolbarView`.
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
            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)
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
                .font(theme.fontCaption.weight(.semibold))
                .foregroundColor(.orange)

            // Two keys rather than a concatenated plural letter, so the count is `%lld` and each key carries its own
            // plural variations; same treatment as the toolbar pill that opens this panel.
            Text(issues.count == 1 ? "1 issue" : "\(issues.count) issues")
                .font(theme.fontCaption.weight(.semibold))
                .foregroundColor(theme.primaryText)

            if errorCount > 0 {
                countPill(count: errorCount, color: theme.errorColor)
            }

            if warningCount > 0 {
                countPill(count: warningCount, color: theme.warningColor)
            }

            Spacer()

            TactileIconButton(
                icon: "xmark",
                tooltip: "Dismiss",
                accessibilityLabel: "Dismiss",
                size: .compact,
                action: onDismiss
            )
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
                .font(theme.fontCaption.weight(.semibold))
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
                    .font(theme.fontCaption2)
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
        .pointingHandCursor(enabled: isTappable)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)
            Text(errorCount == 1
                 ? "1 error must be resolved before running"
                 : "\(errorCount) errors must be resolved before running")
                .font(theme.fontCaption2)
                .foregroundColor(theme.errorColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    private func countPill(count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(theme.fontCaption2.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}
