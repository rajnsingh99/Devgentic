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

private let edgeLogger = DGLogger(category: "WorkflowEdgeView")

// MARK: - Committed Edge

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

    /// Run treatment. A Router with three ports drew three IDENTICAL curves before this existed, so
    /// the branch that actually fired was unknowable from the canvas — the one thing a graph view
    /// is better placed to show than a timeline.
    ///
    /// Untaken branches recede instead of disappearing: the connection is still part of the design
    /// and must stay selectable and deletable while the run is on screen.
    private var runOpacityScale: Double {
        switch runState {
        case .fired:        return 1.0
        case .notTaken:     return 0.28
        case .undetermined: return 1.0
        }
    }

    private var runLineWidthBoost: CGFloat {
        runState == .fired ? 1.0 : 0
    }

    private var sourceColor: Color { color(ofNode: edge.sourceNodeID, end: "source") }
    private var targetColor: Color { color(ofNode: edge.targetNodeID, end: "target") }

    /// ⚠️ Resolved HERE rather than on `WorkflowCanvasState`, which has no `@Environment` and
    /// therefore no theme (WF-CU10). This view already holds one, and it was the only caller of the
    /// state's two `nodeColor` overloads — a verbatim copy of `WorkflowNodeView.profileColor` that
    /// had to agree with it for an edge to match the node it leaves.
    private func color(ofNode id: UUID, end: String) -> Color {
        guard let kind = canvasState.nodes.first(where: { $0.id == id })?.kind else {
            // ⚠️ Was a silent `return .gray` — the SAME literal the Trigger kind used — so an edge
            // whose endpoint had been deleted rendered as a perfectly ordinary Trigger-coloured
            // connection and reported nothing.
            edgeLogger.error(
                "[WF_CANVAS] Edge \(edge.id) has no \(end) node \(id) on the canvas — drawing it "
                + "neutral. CONSEQUENCE: the edge is orphaned; it still renders and is still "
                + "selectable, and validation reports it as a dangling connection."
            )
            return theme.secondaryText
        }
        return kind.identityColor(in: theme)
    }

    /// Composed by `WorkflowCanvasState` so the wording is testable.
    ///
    /// ⚠️ `String(localized:)`, not bare literals (WF-CU8): this value is handed to
    /// `.accessibilityLabel(_: S)`, which binds the non-localizing `StringProtocol` overload, so
    /// the String Catalog extractor never sees these and they would ship untranslated.
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
                // ⚠️ Connections were entirely absent from the accessibility tree — a bare drawn
                // path with a tap gesture and nothing else. The graph's TOPOLOGY is the one thing a
                // node-graph editor exists to convey, so a VoiceOver user could reach the nodes
                // (badly) and never learn how any of them were wired together.
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
                            sourceColor.opacity((isSelected ? 0.95 : 0.55) * runOpacityScale),
                            targetColor.opacity((isSelected ? 0.95 : 0.55) * runOpacityScale)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(
                        lineWidth: (isSelected ? 2.5 : 1.5) + runLineWidthBoost,
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
