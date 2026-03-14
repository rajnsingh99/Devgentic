//
//  WorkflowCanvasState.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Central state manager for the workflow canvas.
//  Owns all mutable canvas state: nodes, edges, selection, pan/zoom, and drag state.
//

import SwiftUI
import Combine

@MainActor
final class WorkflowCanvasState: ObservableObject {

    // MARK: - Canvas Data

    @Published var nodes: [WorkflowNode] = []
    @Published var edges: [WorkflowEdge] = []

    // MARK: - Selection

    @Published var selectedNodeID: UUID?
    @Published var selectedEdgeID: UUID?

    // MARK: - Node Configuration
    
    @Published var targetConfigNode: WorkflowNode?

    // MARK: - Edge Drawing

    @Published var edgeDragState: EdgeDragState?

    // MARK: - Node Dragging (centralized to survive re-renders)

    @Published var activeNodeDrag: (nodeID: UUID, offset: CGSize)?

    /// Returns the current drag offset for a node, or `.zero` if it isn't being dragged.
    func nodeDragOffset(for nodeID: UUID) -> CGSize {
        if let drag = activeNodeDrag, drag.nodeID == nodeID {
            return drag.offset
        }
        return .zero
    }

    // MARK: - Canvas Transform

    @Published var canvasOffset: CGSize = .zero
    var lastOffset: CGSize = .zero

    @Published var canvasScale: CGFloat = 1.0
    var lastScale: CGFloat = 1.0

    // MARK: - Dirty Tracking

    @Published private(set) var hasUnsavedChanges: Bool = false
    
    // MARK: - Hover Tracking
    
    @Published var isHoveringCanvas: Bool = false

    private let profileID: UUID
    private var initialLayout: WorkflowLayout?

    // MARK: - Constants

    static let nodeWidth: CGFloat = 200
    static let nodeHeight: CGFloat = 80
    static let portRadius: CGFloat = 6

    // MARK: - Init

    init(profileID: UUID) {
        self.profileID = profileID
    }

    // MARK: - Load / Save

    func load(from layout: WorkflowLayout) {
        nodes = layout.nodes
        edges = layout.edges
        initialLayout = layout
        hasUnsavedChanges = false
    }

    func currentLayout() -> WorkflowLayout {
        WorkflowLayout(nodes: nodes, edges: edges)
    }

    // MARK: - Node Operations

    func addNode(from profile: BackendProfileModel, at position: CGPoint? = nil) {
        // Prevent duplicate profiles on the canvas
        guard !nodes.contains(where: { $0.profileID == profile.id }) else { return }

        let pos = position ?? nextAvailablePosition()
        let node = WorkflowNode(
            profileID: profile.id,
            position: pos,
            displayName: profile.displayName,
            profileType: profile.profileType
        )
        nodes.append(node)
        markDirty()
    }

    func removeNode(_ nodeID: UUID) {
        // Remove all edges connected to this node
        edges.removeAll { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }
        nodes.removeAll { $0.id == nodeID }

        if selectedNodeID == nodeID { selectedNodeID = nil }
        markDirty()
    }

    func moveNode(_ nodeID: UUID, to position: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[index].position = position
        markDirty()
    }

    // MARK: - Edge Operations

    func addEdge(sourceNodeID: UUID, targetNodeID: UUID) -> Bool {
        // Prevent self-loops
        guard sourceNodeID != targetNodeID else { return false }

        // Prevent duplicate edges
        guard !edges.contains(where: { $0.sourceNodeID == sourceNodeID && $0.targetNodeID == targetNodeID }) else { return false }

        // Validate communication constraints
        guard let sourceNode = nodes.first(where: { $0.id == sourceNodeID }),
              let targetNode = nodes.first(where: { $0.id == targetNodeID }) else { return false }

        guard WorkflowEdge.isValid(sourceType: sourceNode.profileType, targetType: targetNode.profileType) else { return false }

        // Cycle detection
        let layout = currentLayout()
        guard !layout.wouldCreateCycle(source: sourceNodeID, target: targetNodeID) else { return false }

        let edge = WorkflowEdge(sourceNodeID: sourceNodeID, targetNodeID: targetNodeID)
        edges.append(edge)
        markDirty()
        return true
    }

    func removeEdge(_ edgeID: UUID) {
        edges.removeAll { $0.id == edgeID }
        if selectedEdgeID == edgeID { selectedEdgeID = nil }
        markDirty()
    }

    // MARK: - Selection

    func select(nodeID: UUID?) {
        selectedNodeID = nodeID
        selectedEdgeID = nil
    }

    func select(edgeID: UUID?) {
        selectedEdgeID = edgeID
        selectedNodeID = nil
    }

    func clearSelection() {
        selectedNodeID = nil
        selectedEdgeID = nil
    }

    func deleteSelected() {
        if let nodeID = selectedNodeID {
            removeNode(nodeID)
        } else if let edgeID = selectedEdgeID {
            removeEdge(edgeID)
        }
    }

    // MARK: - Canvas Transform

    func zoomIn() {
        canvasScale = min(canvasScale + 0.15, 2.0)
        lastScale = canvasScale
    }

    func zoomOut() {
        canvasScale = max(canvasScale - 0.15, 0.4)
        lastScale = canvasScale
    }

    func resetZoom() {
        canvasScale = 1.0
        lastScale = 1.0
        canvasOffset = .zero
        lastOffset = .zero
    }

    func updateScale(by multiplier: CGFloat) {
        canvasScale = min(max(lastScale * multiplier, 0.4), 2.0)
    }

    func commitScale() {
        lastScale = canvasScale
    }

    func updateOffset(by translation: CGSize) {
        canvasOffset = CGSize(
            width: lastOffset.width + translation.width,
            height: lastOffset.height + translation.height
        )
    }

    func addOffset(delta: CGSize) {
        canvasOffset = CGSize(
            width: canvasOffset.width + delta.width,
            height: canvasOffset.height + delta.height
        )
        // Keep the anchor in sync for when a standard 1-finger drag follows.
        lastOffset = canvasOffset
    }

    func commitOffset() {
        lastOffset = canvasOffset
    }

    // MARK: - Clear

    func clearCanvas() {
        nodes.removeAll()
        edges.removeAll()
        selectedNodeID = nil
        selectedEdgeID = nil
        markDirty()
    }

    func revert() {
        if let initial = initialLayout {
            load(from: initial)
        }
    }

    func markSaved() {
        initialLayout = currentLayout()
        hasUnsavedChanges = false
    }

    // MARK: - Port Positions

    /// Returns the center position of a node's output port in canvas coordinates.
    func outputPortPosition(for nodeID: UUID) -> CGPoint? {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return nil }
        let offset = nodeDragOffset(for: nodeID)
        return CGPoint(
            x: node.position.x + Self.nodeWidth + offset.width,
            y: node.position.y + Self.nodeHeight / 2 + offset.height
        )
    }

    /// Returns the center position of a node's input port in canvas coordinates.
    func inputPortPosition(for nodeID: UUID) -> CGPoint? {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return nil }
        let offset = nodeDragOffset(for: nodeID)
        return CGPoint(
            x: node.position.x + offset.width,
            y: node.position.y + Self.nodeHeight / 2 + offset.height
        )
    }

    /// Finds the node whose input port is closest to the given point, within a hit radius.
    func findInputPortTarget(near point: CGPoint, excluding sourceNodeID: UUID) -> UUID? {
        let hitRadius: CGFloat = 20
        for node in nodes where node.id != sourceNodeID {
            if let portPos = inputPortPosition(for: node.id) {
                let distance = hypot(point.x - portPos.x, point.y - portPos.y)
                if distance <= hitRadius {
                    return node.id
                }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func nextAvailablePosition() -> CGPoint {
        let baseX: CGFloat = 60
        let baseY: CGFloat = 80
        let spacingY: CGFloat = 120

        return CGPoint(x: baseX, y: baseY + CGFloat(nodes.count) * spacingY)
    }

    private func markDirty() {
        hasUnsavedChanges = true
    }
}
