//
//  WorkflowConnectorView.swift
//  Devgentic
//
//  Created by Raj Singh on 2026-04-25.
//
//  Visual connector rendered between two cards in `WorkflowOutcomeStripView`.
//  The connector's appearance is driven by the *upstream* node's status — once
//  upstream produces output, downstream has its input, so a "completed" upstream
//  flips the connector to the success treatment regardless of downstream state.
//

import SwiftUI

struct WorkflowConnectorView: View {
    /// Status of the node feeding into this connector. Drives line colour, line
    /// style (solid vs dashed), and the centre badge.
    let upstreamStatus: WorkflowRunDisplayData.NodeDisplayData.NodeStatus

    @Environment(\.appTheme) private var theme

    private var lineColor: Color {
        upstreamStatus.color
    }

    private var isDashed: Bool {
        switch upstreamStatus {
        case .pending, .running, .skipped:
            return true
        case .completed, .failed:
            return false
        }
    }

    private var badgeIcon: String {
        switch upstreamStatus {
        case .pending:   return "circle.dotted"
        case .running:   return "arrow.trianglehead.2.clockwise"
        case .completed: return "checkmark"
        case .failed:    return "xmark"
        case .skipped:   return "arrow.right"
        }
    }

    var body: some View {
        ZStack {
            // Horizontal line through the centre.
            Rectangle()
                .fill(Color.clear)
                .frame(height: 2)
                .overlay(
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 1))
                        path.addLine(to: CGPoint(x: connectorWidth, y: 1))
                    }
                    .stroke(
                        lineColor.opacity(0.6),
                        style: StrokeStyle(
                            lineWidth: 1.5,
                            lineCap: .round,
                            dash: isDashed ? [3, 4] : []
                        )
                    )
                )

            // Centre badge.
            badge
        }
        .frame(width: connectorWidth, height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection: \(upstreamStatus.label)")
    }

    private var connectorWidth: CGFloat { 36 }

    @ViewBuilder
    private var badge: some View {
        if upstreamStatus == .running {
            ProgressView()
                .controlSize(.mini)
                .tint(lineColor)
                .frame(width: 18, height: 18)
                .background(Circle().fill(theme.primaryBackground))
                .overlay(Circle().stroke(lineColor.opacity(0.5), lineWidth: 1))
        } else {
            Image(systemName: badgeIcon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(lineColor)
                .frame(width: 18, height: 18)
                .background(Circle().fill(theme.primaryBackground))
                .overlay(Circle().stroke(lineColor.opacity(0.55), lineWidth: 1))
        }
    }
}
