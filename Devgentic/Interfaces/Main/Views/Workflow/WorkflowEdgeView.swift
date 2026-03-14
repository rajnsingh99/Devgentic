//
//  WorkflowEdgeView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Bezier curve connections between workflow nodes.
//  Renders both committed edges and the in-progress drag preview.
//

import SwiftUI

// MARK: - Committed Edge

struct WorkflowEdgeView: View {
    let edge: WorkflowEdge
    let sourcePoint: CGPoint
    let targetPoint: CGPoint
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var midPoint: CGPoint {
        // Evaluate the midpoint for a symmetric cubic Bezier S-curve
        CGPoint(
            x: (sourcePoint.x + targetPoint.x) / 2,
            y: (sourcePoint.y + targetPoint.y) / 2
        )
    }

    var body: some View {
        ZStack {
            // Invisible wider hit area for selection and hovering
            bezierPath
                .stroke(Color.clear, lineWidth: 24)
                .contentShape(bezierPath.stroke(style: StrokeStyle(lineWidth: 24)))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovering = hovering
                    }
                }
                .onTapGesture(perform: onTap)

            // Visible edge line
            bezierPath
                .stroke(
                    theme.secondaryText.opacity(isHovering ? 0.8 : 0.5),
                    style: StrokeStyle(lineWidth: isHovering ? 2.5 : 1.5, lineCap: .round)
                )

            // Arrowhead at target
            arrowHead

            // Delete Button at the center on hover
            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                        .background(Circle().fill(theme.primaryBackground).padding(2))
                }
                .buttonStyle(.plain)
                .position(midPoint)
                // Keep the edge in hovered state when the mouse is explicitly over the button
                .onHover { btnHover in
                    if btnHover {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHovering = true
                        }
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var bezierPath: Path {
        Self.makeBezierPath(from: sourcePoint, to: targetPoint)
    }

    private var arrowHead: some View {
        let angle = atan2(targetPoint.y - sourcePoint.y, targetPoint.x - sourcePoint.x)
        let arrowSize: CGFloat = 8
        let tipX = targetPoint.x - 2 // Slight offset to not overlap the port
        let tipY = targetPoint.y

        return Path { path in
            path.move(to: CGPoint(x: tipX, y: tipY))
            path.addLine(to: CGPoint(
                x: tipX - arrowSize * cos(angle - .pi / 6),
                y: tipY - arrowSize * sin(angle - .pi / 6)
            ))
            path.move(to: CGPoint(x: tipX, y: tipY))
            path.addLine(to: CGPoint(
                x: tipX - arrowSize * cos(angle + .pi / 6),
                y: tipY - arrowSize * sin(angle + .pi / 6)
            ))
        }
        .stroke(
            theme.secondaryText.opacity(isHovering ? 0.8 : 0.5),
            style: StrokeStyle(lineWidth: isHovering ? 2.5 : 1.5, lineCap: .round)
        )
    }

    static func makeBezierPath(from source: CGPoint, to target: CGPoint) -> Path {
        let dx = abs(target.x - source.x)
        let controlOffset = max(dx * 0.5, 50)

        return Path { path in
            path.move(to: source)
            path.addCurve(
                to: target,
                control1: CGPoint(x: source.x + controlOffset, y: source.y),
                control2: CGPoint(x: target.x - controlOffset, y: target.y)
            )
        }
    }
}

// MARK: - Edge Drag Preview

struct WorkflowEdgeDragPreview: View {
    let sourcePoint: CGPoint
    let currentPoint: CGPoint

    @Environment(\.appTheme) private var theme

    var body: some View {
        WorkflowEdgeView.makeBezierPath(from: sourcePoint, to: currentPoint)
            .stroke(
                theme.accentColor.opacity(0.6),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4])
            )
    }
}
