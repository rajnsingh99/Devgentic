// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowEdgeView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

private let edgeLogger = DGLogger(category: "WorkflowEdgeView")

// MARK: - Committed Edge

/// Bezier curve connections between workflow nodes; renders committed edges and the in-progress drag preview.
struct WorkflowEdgeView: View {
    let edge: WorkflowEdge
    let sourcePoint: CGPoint
    let targetPoint: CGPoint
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    var canvasState: WorkflowCanvasState
    /// How this connection behaved on the displayed run. `.undetermined` when no run is shown,
    /// which draws exactly as the canvas always has.
    var runState: WorkflowCanvasRunOverlay.EdgeState = .undetermined

    @Environment(\.appTheme) private var theme
    @State private var dashOffset: CGFloat = 0

    /// Run treatment: untaken branches recede instead of disappearing, so the branch that fired is visible.
    /// The connection stays selectable and deletable while the run is on screen.
    private var runOpacityScale: Double { Self.runOpacityScale(for: runState) }

    /// `nonisolated static` and pure so the curve and the arrowhead can be proven to fade by the same factor.
    nonisolated static func runOpacityScale(
        for runState: WorkflowCanvasRunOverlay.EdgeState
    ) -> Double {
        switch runState {
        case .fired:        return 1.0
        case .notTaken:     return 0.28
        case .undetermined: return 1.0
        }
    }

    /// The arrowhead's opacity multiplier on `targetColor`: `baseEdgeOpacity`'s selected, error, ordinary precedence,
    /// times the same run scale the curve gets, so a `.notTaken` branch does not keep a bright arrowhead.
    nonisolated static func arrowOpacity(
        isSelected: Bool,
        isErrorEdge: Bool,
        runState: WorkflowCanvasRunOverlay.EdgeState
    ) -> Double {
        let base: Double = isSelected ? 1.0 : (isErrorEdge ? 0.90 : 0.70)
        return base * runOpacityScale(for: runState)
    }

    private var runLineWidthBoost: CGFloat {
        runState == .fired ? 1.0 : 0
    }

    private var isErrorEdge: Bool {
        edge.sourcePortLabel == WorkflowEdge.errorPortLabel
    }

    private var sourceColor: Color {
        guard let sourceNode = canvasState.nodes.first(where: { $0.id == edge.sourceNodeID }) else {
            return isErrorEdge ? theme.errorColor : theme.secondaryText
        }
        return sourceNode.kind.portColor(forLabel: edge.sourcePortLabel, in: theme)
    }

    private var targetColor: Color {
        if isErrorEdge {
            // Error path blends into a warm error tint so the whole wire is visually distinguishable
            return theme.errorColor.opacity(0.85)
        }
        return color(ofNode: edge.targetNodeID, end: "target")
    }

    private var baseEdgeOpacity: Double {
        if isSelected { return 0.98 }
        if isErrorEdge { return 0.85 }
        return 0.70
    }

    /// Resolved here rather than on `WorkflowCanvasState`, which has no `@Environment` and therefore no theme.
    private func color(ofNode id: UUID, end: String) -> Color {
        guard let kind = canvasState.nodes.first(where: { $0.id == id })?.kind else {
            // A missing endpoint logs an error instead of silently drawing an ordinary Trigger-coloured connection.
            edgeLogger.error(
                "[WF_CANVAS] Edge \(edge.id) has no \(end) node \(id) on the canvas — drawing it "
                + "neutral. CONSEQUENCE: the edge is orphaned; it still renders and is still "
                + "selectable, and validation reports it as a dangling connection."
            )
            return theme.secondaryText
        }
        return kind.identityColor(in: theme)
    }

    // Why: `String(localized:)` is required: `.accessibilityLabel(_: S)` binds a non-localizing overload.
    /// Composed by `WorkflowCanvasState` so the wording is testable.
    private var accessibilityDescription: String {
        let suffix: String?
        switch runState {
        case .fired:        suffix = String(localized: "this branch ran")
        case .notTaken:     suffix = String(localized: "this branch was not taken")
        case .undetermined: suffix = nil
        }
        return canvasState.accessibilityDescription(for: edge, runStateSuffix: suffix)
    }

    private var midPoint: CGPoint {
        // Evaluate the exact midpoint along the cubic Bezier curve at t = 0.5
        let dx = abs(targetPoint.x - sourcePoint.x)
        let controlOffset = max(dx * 0.5, 50)
        let c1 = CGPoint(x: sourcePoint.x + controlOffset, y: sourcePoint.y)
        let c2 = CGPoint(x: targetPoint.x - controlOffset, y: targetPoint.y)
        
        // Cubic Bezier midpoint at t = 0.5: (start + 3*c1 + 3*c2 + end) / 8.
        let x = (sourcePoint.x + 3 * c1.x + 3 * c2.x + targetPoint.x) / 8
        let y = (sourcePoint.y + 3 * c1.y + 3 * c2.y + targetPoint.y) / 8
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        ZStack {
            // Invisible wider hit area for selection
            bezierPath
                .stroke(Color.black.opacity(0.001), lineWidth: 24)
                .onTapGesture(perform: onTap)
                .accessibilityElement()
                .accessibilityLabel(accessibilityDescription)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityAction(named: Text("Select connection"), onTap)
                .accessibilityAction(named: Text("Delete connection"), onDelete)

            // Visible edge line
            bezierPath
                .stroke(
                    LinearGradient(
                        colors: [
                            sourceColor.opacity(baseEdgeOpacity * runOpacityScale),
                            targetColor.opacity(baseEdgeOpacity * runOpacityScale)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(
                        lineWidth: (isSelected ? 2.5 : (isErrorEdge ? 1.75 : 1.5)) + runLineWidthBoost,
                        lineCap: .round,
                        dash: isSelected ? [6, 4] : (isErrorEdge ? [6, 3] : (runState == .fired ? [8, 4] : [])),
                        dashPhase: dashOffset
                    )
                )
                .onAppear {
                    if isSelected || runState == .fired {
                        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                            dashOffset = -24
                        }
                    }
                }
                .onChange(of: isSelected) { _, selected in
                    if selected || runState == .fired {
                        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                            dashOffset = -24
                        }
                    } else {
                        dashOffset = 0
                    }
                }

            // Arrowhead at target
            arrowHead

            // Selection Controls at curve midpoint (Branch Tag + Delete Button)
            if isSelected {
                HStack(spacing: 5) {
                    if let label = edge.sourcePortLabel, !label.isEmpty {
                        Text(label)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(sourceColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(theme.primaryBackground)
                                    .overlay(Capsule().stroke(sourceColor.opacity(0.4), lineWidth: 0.75))
                            )
                    }

                    TactileIconButton(
                        icon: "xmark",
                        tooltip: "Delete connection",
                        accessibilityLabel: "Delete connection",
                        variant: .destructive,
                        size: 20,
                        action: onDelete
                    )
                }
                .padding(3)
                .background(
                    Capsule()
                        .fill(theme.controlBackground.opacity(0.92))
                        .shadow(color: theme.shadowColor.opacity(0.28), radius: 5, y: 2)
                )
                .position(midPoint)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var bezierPath: Path {
        Self.makeBezierPath(from: sourcePoint, to: targetPoint)
    }

    private var arrowHead: some View {
        Self.makeArrowPath(at: targetPoint)
            .fill(targetColor.opacity(Self.arrowOpacity(
                isSelected: isSelected,
                isErrorEdge: isErrorEdge,
                runState: runState
            )))
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
    var color: Color = .accentColor

    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            WorkflowEdgeView.makeBezierPath(from: sourcePoint, to: currentPoint)
                .stroke(
                    color.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4])
                )
                
            WorkflowEdgeView.makeArrowPath(at: currentPoint)
                .fill(color.opacity(0.95))
        }
    }
}
