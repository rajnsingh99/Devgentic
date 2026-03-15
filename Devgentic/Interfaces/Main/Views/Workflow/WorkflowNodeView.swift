//
//  WorkflowNodeView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Individual draggable node card on the workflow canvas.
//  Renders a compact profile card with input/output ports.
//

import SwiftUI

struct WorkflowNodeView: View {
    let node: WorkflowNode
    let isSelected: Bool
    @ObservedObject var canvasState: WorkflowCanvasState
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false

    private let nodeWidth = WorkflowCanvasState.nodeWidth
    private let nodeHeight = WorkflowCanvasState.nodeHeight

    /// Drag offset sourced from centralized state — survives parent re-renders.
    private var dragOffset: CGSize {
        canvasState.nodeDragOffset(for: node.id)
    }

    var body: some View {
        ZStack {
            // Node Card
            nodeCard
                .position(
                    x: node.position.x + nodeWidth / 2,
                    y: node.position.y + nodeHeight / 2
                )

            // Output Port (right side)
            WorkflowPortView(
                portType: .output,
                profileType: node.profileType,
                isCompatibleTarget: false,
                isNodeHovered: isHovering,
                onDragStarted: { startPos in
                    canvasState.edgeDragState = EdgeDragState(
                        sourceNodeID: node.id,
                        currentPoint: startPos
                    )
                },
                onDragUpdated: { point in
                    canvasState.edgeDragState?.currentPoint = point
                },
                onDragEnded: { endPoint in
                    if let targetID = canvasState.findInputPortTarget(near: endPoint, excluding: node.id) {
                        _ = canvasState.addEdge(sourceNodeID: node.id, targetNodeID: targetID)
                    }
                    canvasState.edgeDragState = nil
                }
            )
            .position(
                x: node.position.x + nodeWidth,
                y: node.position.y + nodeHeight / 2
            )

            // Input Port (left side)
            WorkflowPortView(
                portType: .input,
                profileType: node.profileType,
                isCompatibleTarget: isCompatibleDropTarget,
                isNodeHovered: isHovering
            )
            .position(
                x: node.position.x,
                y: node.position.y + nodeHeight / 2
            )
        }
        // Apply structural offset directly. By avoiding constant .position recalculations
        // inside the nodes, we stop SwiftUI from layout thrashing and causing ghosts.
        .offset(dragOffset)
    }

    // MARK: - Node Card

    private var nodeCard: some View {
        HStack(spacing: 10) {
            // Profile Icon
            Image(systemName: iconName)
                .font(.system(size: 18))
                .foregroundColor(profileColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(node.profileType.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: nodeWidth, height: nodeHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? theme.accentColor : theme.surfaceOverlayStrong, lineWidth: isSelected ? 2 : 1)
        )
        .shadow(
            color: isSelected ? theme.accentColor.opacity(0.25) : Color.black.opacity(isHovering ? 0.12 : 0.06),
            radius: isSelected ? 8 : (isHovering ? 6 : 3),
            x: 0, y: 2
        )
        .scaleEffect(isHovering ? 1.02 : 1.0)
        // Scoped animation: only animates properties driven by isHovering
        // (scaleEffect + shadow), NOT .position() or anything else.
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Prevent configuring the workflow node itself yet, only Agents/Bots
            if node.profileType != .workflow {
                canvasState.targetConfigNode = node
            }
        }
        .onTapGesture {
            canvasState.select(nodeID: node.id)
        }
        .gesture(nodeDragGesture)
        .onHover { isHovering = $0 }
    }

    // MARK: - Drag to Move

    private var nodeDragGesture: some Gesture {
        // Track dragging in the canvas' unscaled coordinate system.
        // This ensures the mouse translation maps 1:1 visually regardless of scale/pan.
        DragGesture(minimumDistance: 3, coordinateSpace: .named("canvasContent"))
            .onChanged { value in
                // Select only once at drag start to avoid repeated @Published mutations
                if canvasState.activeNodeDrag == nil {
                    canvasState.select(nodeID: node.id)
                }
                canvasState.activeNodeDrag = (nodeID: node.id, offset: value.translation)
            }
            .onEnded { value in
                let newPosition = CGPoint(
                    x: max(0, node.position.x + value.translation.width),
                    y: max(0, node.position.y + value.translation.height)
                )
                canvasState.activeNodeDrag = nil
                canvasState.moveNode(node.id, to: newPosition)
            }
    }

    // MARK: - Helpers

    private var iconName: String {
        switch node.profileType {
        case .bot: return "cpu"
        case .agent: return "person.fill.viewfinder"
        case .workflow: return "square.3.layers.3d.down.right"
        case .imageGen: return "paintbrush.fill"
        }
    }

    private var profileColor: Color {
        switch node.profileType {
        case .bot: return .blue
        case .agent: return .green
        case .workflow: return .purple
        case .imageGen: return .orange
        }
    }

    /// Whether this node is a valid drop target for the current edge drag.
    private var isCompatibleDropTarget: Bool {
        guard let drag = canvasState.edgeDragState else { return false }
        guard drag.sourceNodeID != node.id else { return false }

        guard let sourceNode = canvasState.nodes.first(where: { $0.id == drag.sourceNodeID }) else { return false }
        return WorkflowEdge.isValid(sourceType: sourceNode.profileType, targetType: node.profileType)
    }
}
