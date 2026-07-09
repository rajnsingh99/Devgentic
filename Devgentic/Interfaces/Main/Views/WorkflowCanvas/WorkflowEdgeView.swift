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
    var canvasState: WorkflowCanvasState

    @Environment(\.appTheme) private var theme
    @State private var dashOffset: CGFloat = 0

    private var sourceColor: Color {
        canvasState.nodeColor(for: edge.sourceNodeID)
    }

    private var targetColor: Color {
        canvasState.nodeColor(for: edge.targetNodeID)
    }

    private var midPoint: CGPoint {
        // Evaluate the midpoint for a symmetric cubic Bezier S-curve
        CGPoint(
            x: (sourcePoint.x + targetPoint.x) / 2,
            y: (sourcePoint.y + targetPoint.y) / 2
        )
    }

    var body: some View {
        ZStack {
            // Invisible wider hit area for selection
            bezierPath
                .stroke(Color.black.opacity(0.001), lineWidth: 24)
                .onTapGesture(perform: onTap)

            // Visible edge line
            bezierPath
                .stroke(
                    LinearGradient(
                        colors: [sourceColor.opacity(isSelected ? 0.95 : 0.55), targetColor.opacity(isSelected ? 0.95 : 0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(
                        lineWidth: isSelected ? 2.5 : 1.5,
                        lineCap: .round,
                        dash: isSelected ? [6, 4] : [],
                        dashPhase: dashOffset
                    )
                )
                .onAppear {
                    if isSelected {
                        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                            dashOffset = -20
                        }
                    }
                }
                .onChange(of: isSelected) { _, selected in
                    if selected {
                        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                            dashOffset = -20
                        }
                    } else {
                        dashOffset = 0
                    }
                }

            // Arrowhead at target
            arrowHead

            // Delete Button at the center on selection
            if isSelected {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.body))
                        .foregroundColor(.red)
                        .background(Circle().fill(theme.primaryBackground).padding(2))
                }
                .buttonStyle(.plain)
                .position(midPoint)
                .accessibilityLabel("Delete connection")
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var bezierPath: Path {
        Self.makeBezierPath(from: sourcePoint, to: targetPoint)
    }

    private var arrowHead: some View {
        Self.makeArrowPath(at: targetPoint)
            .fill(isSelected ? targetColor : targetColor.opacity(0.55))
    }

    static func makeArrowPath(at target: CGPoint) -> Path {
        let arrowSize: CGFloat = 10
        let tipX = target.x - 1 // Slight offset so it touches perfectly
        let tipY = target.y

        return Path { path in
            path.move(to: CGPoint(x: tipX, y: tipY))
            // Left-top corner of the triangle
            path.addLine(to: CGPoint(x: tipX - arrowSize, y: tipY - arrowSize * 0.5))
            // Left-bottom corner of the triangle
            path.addLine(to: CGPoint(x: tipX - arrowSize, y: tipY + arrowSize * 0.5))
            path.closeSubpath()
        }
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
        ZStack {
            WorkflowEdgeView.makeBezierPath(from: sourcePoint, to: currentPoint)
                .stroke(
                    theme.accentColor.opacity(0.6),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4])
                )
                
            WorkflowEdgeView.makeArrowPath(at: currentPoint)
                .fill(theme.accentColor.opacity(0.8))
        }
    }
}
