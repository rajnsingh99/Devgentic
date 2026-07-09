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

@Observable @MainActor
final class WorkflowCanvasState {

    // MARK: - Canvas Data

    var nodes: [WorkflowNode] = []
    var edges: [WorkflowEdge] = []

    // MARK: - Selection

    var selectedNodeID: UUID?
    var selectedEdgeID: UUID?
    var selectedAnnotationID: UUID?

    // MARK: - Annotations (Sticky Notes)

    var annotations: [StickyNote] = []

    // MARK: - Node Configuration

    var targetConfigNode: WorkflowNode?

    // MARK: - Edge Drawing

    var edgeDragState: EdgeDragState?

    // MARK: - Node Dragging (centralized to survive re-renders)

    var activeNodeDrag: (nodeID: UUID, offset: CGSize)?

    /// Returns the current drag offset for a node, or `.zero` if it isn't being dragged.
    func nodeDragOffset(for nodeID: UUID) -> CGSize {
        if let drag = activeNodeDrag, drag.nodeID == nodeID {
            return drag.offset
        }
        return .zero
    }

    // MARK: - Canvas Transform

    var canvasOffset: CGSize = .zero
    @ObservationIgnored var lastOffset: CGSize = .zero

    var canvasScale: CGFloat = 1.0
    @ObservationIgnored var lastScale: CGFloat = 1.0

    // MARK: - Dirty Tracking

    private(set) var hasUnsavedChanges: Bool = false

    // MARK: - Validation

    /// Current validation issues, recomputed on every markDirty() and load().
    private(set) var validationIssues: [WorkflowValidationIssue] = []

    /// Whether the validation panel is visible on the canvas.
    var showValidationPanel: Bool = false

    /// Profile map for validation — populated by WorkflowCanvasView from profileService.
    var resolvedProfileMap: [UUID: BackendProfileModel] = [:]

    /// Convenience: error-severity issues only.
    var validationErrors: [WorkflowValidationIssue] {
        validationIssues.filter { $0.severity == .error }
    }

    /// Convenience: warning-severity issues only.
    var validationWarnings: [WorkflowValidationIssue] {
        validationIssues.filter { $0.severity == .warning }
    }

    // MARK: - Hover Tracking

    var isHoveringCanvas: Bool = false

    private let profileID: UUID
    private var initialLayout: WorkflowLayout?

    // MARK: - Constants

    static let portRadius: CGFloat = 6

    /// Returns the dynamically determined dimensions for a node based on its kind.
    static func nodeSize(for kind: WorkflowNodeKind) -> CGSize {
        switch kind {
        case .profile:
            return CGSize(width: 200, height: 80)
        case .condition:
            // Hexagon/Diamond shape
            return CGSize(width: 140, height: 120)
        case .code:
            // Terminal-style window
            return CGSize(width: 220, height: 100)
        case .gate:
            // Pill shape / Warning border
            return CGSize(width: 160, height: 60)
        case .loop:
            // Circle
            return CGSize(width: 100, height: 100)
        case .trigger:
            // Chevron
            return CGSize(width: 120, height: 50)
        case .action:
            // Integration card (similar footprint to profile)
            return CGSize(width: 200, height: 76)
        }
    }

    func nodeColor(for nodeID: UUID) -> Color {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return .gray }
        return Self.nodeColor(for: node.kind)
    }

    static func nodeColor(for kind: WorkflowNodeKind) -> Color {
        switch kind {
        case .profile(_, let pType):
            return pType.displayColor
        case .condition:  return .yellow
        case .loop:       return .orange
        case .code:       return .cyan
        case .gate:       return .red
        case .trigger:    return .gray
        case .action:     return .teal
        }
    }

    // MARK: - Init

    init(profileID: UUID) {
        self.profileID = profileID
    }

    // MARK: - Load / Save

    func load(from layout: WorkflowLayout) {
        nodes = layout.nodes
        edges = layout.edges
        annotations = layout.annotations
        initialLayout = layout
        hasUnsavedChanges = false
        revalidate()
    }

    func currentLayout() -> WorkflowLayout {
        WorkflowLayout(nodes: nodes, edges: edges, annotations: annotations)
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

    /// Adds a structural (non-profile) node to the canvas.
    func addStructuralNode(kind: WorkflowNodeKind, displayName: String, at position: CGPoint? = nil) {
        let pos = position ?? nextAvailablePosition()
        let node = WorkflowNode(kind: kind, position: pos, displayName: displayName)
        nodes.append(node)
        markDirty()
    }

    func addEdge(sourceNodeID: UUID, targetNodeID: UUID, sourcePortLabel: String? = nil) -> Bool {
        // Prevent self-loops
        guard sourceNodeID != targetNodeID else { return false }

        // Prevent duplicate edges from the same port
        guard !edges.contains(where: {
            $0.sourceNodeID == sourceNodeID && $0.targetNodeID == targetNodeID && $0.sourcePortLabel == sourcePortLabel
        }) else { return false }

        // Verify nodes exist
        guard nodes.contains(where: { $0.id == sourceNodeID }),
              nodes.contains(where: { $0.id == targetNodeID }) else { return false }

        // Cycle detection
        let layout = currentLayout()
        guard !layout.wouldCreateCycle(source: sourceNodeID, target: targetNodeID) else { return false }

        let edge = WorkflowEdge(sourceNodeID: sourceNodeID, targetNodeID: targetNodeID, sourcePortLabel: sourcePortLabel)
        edges.append(edge)
        markDirty()
        return true
    }

    func removeEdge(_ edgeID: UUID) {
        edges.removeAll { $0.id == edgeID }
        if selectedEdgeID == edgeID { selectedEdgeID = nil }
        markDirty()
    }

    // MARK: - Annotation Operations

    func addStickyNote(at position: CGPoint) {
        let note = StickyNote(position: position)
        annotations.append(note)
        selectedAnnotationID = note.id
        markDirty()
    }

    func removeStickyNote(_ noteID: UUID) {
        annotations.removeAll { $0.id == noteID }
        if selectedAnnotationID == noteID { selectedAnnotationID = nil }
        markDirty()
    }

    func moveStickyNote(_ noteID: UUID, to position: CGPoint) {
        guard let index = annotations.firstIndex(where: { $0.id == noteID }) else { return }
        annotations[index].position = position
        markDirty()
    }

    func resizeStickyNote(_ noteID: UUID, to size: CGSize) {
        guard let index = annotations.firstIndex(where: { $0.id == noteID }) else { return }
        annotations[index].size = CGSize(
            width: max(120, size.width),
            height: max(80, size.height)
        )
        markDirty()
    }

    func updateStickyNoteText(_ noteID: UUID, text: String) {
        guard let index = annotations.firstIndex(where: { $0.id == noteID }) else { return }
        annotations[index].text = text
        markDirty()
    }

    func updateStickyNoteColor(_ noteID: UUID, color: StickyNoteColor) {
        guard let index = annotations.firstIndex(where: { $0.id == noteID }) else { return }
        annotations[index].color = color
        markDirty()
    }

    // MARK: - Selection

    func select(nodeID: UUID?) {
        selectedNodeID = nodeID
        selectedEdgeID = nil
        selectedAnnotationID = nil
    }

    func select(edgeID: UUID?) {
        selectedEdgeID = edgeID
        selectedNodeID = nil
        selectedAnnotationID = nil
    }

    func select(annotationID: UUID?) {
        selectedAnnotationID = annotationID
        selectedNodeID = nil
        selectedEdgeID = nil
    }

    func clearSelection() {
        selectedNodeID = nil
        selectedEdgeID = nil
        selectedAnnotationID = nil
    }

    func deleteSelected() {
        if let nodeID = selectedNodeID {
            removeNode(nodeID)
        } else if let edgeID = selectedEdgeID {
            removeEdge(edgeID)
        } else if let annotationID = selectedAnnotationID {
            removeStickyNote(annotationID)
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
        annotations.removeAll()
        selectedNodeID = nil
        selectedEdgeID = nil
        selectedAnnotationID = nil
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

    /// Returns the center position of a node's default (single) output port.
    func outputPortPosition(for nodeID: UUID) -> CGPoint? {
        return outputPortPosition(for: nodeID, portLabel: nil)
    }

    /// Returns the center position of a specific output port in canvas coordinates.
    /// For single-port nodes, `portLabel` is ignored. For multi-port nodes (condition),
    /// the port is identified by its label and stacked vertically.
    func outputPortPosition(for nodeID: UUID, portLabel: String?) -> CGPoint? {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return nil }
        let offset = nodeDragOffset(for: nodeID)
        let portLabels = outputPortLabels(for: node)
        let size = Self.nodeSize(for: node.kind)

        if portLabels.count <= 1 {
            // Single output port — centered on right edge
            return CGPoint(
                x: node.position.x + size.width + offset.width,
                y: node.position.y + size.height / 2 + offset.height
            )
        }

        // Multi-port — stack vertically on right edge
        let portIndex = portLabels.firstIndex(of: portLabel ?? "") ?? 0
        let spacing = size.height / CGFloat(portLabels.count + 1)
        return CGPoint(
            x: node.position.x + size.width + offset.width,
            y: node.position.y + spacing * CGFloat(portIndex + 1) + offset.height
        )
    }

    /// Returns all output port labels for a node based on its kind.
    /// Condition nodes get their rule labels + fallback.
    /// Profile nodes expose a default output port (empty label) for normal flow
    /// and an "error" port for failure routing.
    func outputPortLabels(for node: WorkflowNode) -> [String] {
        switch node.kind {
        case .condition(let config):
            return config.outputPortLabels
        case .profile:
            return ["", "error"]
        case .action:
            // Default flow + an error port so tool failures can route downstream.
            return ["", "error"]
        case .gate(let config):
            // [E1] One output port per option — the user's choice routes to the matching port.
            return config.options
        default:
            return [] // Structural nodes use single default port
        }
    }

    /// Returns the center position of a node's input port in canvas coordinates.
    func inputPortPosition(for nodeID: UUID) -> CGPoint? {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return nil }
        let offset = nodeDragOffset(for: nodeID)
        let size = Self.nodeSize(for: node.kind)
        return CGPoint(
            x: node.position.x + offset.width,
            y: node.position.y + size.height / 2 + offset.height
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

    func markDirty() {
        hasUnsavedChanges = true
        revalidate()
    }

    /// Runs the pure validator against the current layout and profile map.
    private func revalidate() {
        validationIssues = WorkflowValidator.validate(
            layout: currentLayout(),
            profileMap: resolvedProfileMap,
            availableToolSources: UnifiedToolStore.shared.sources
        )
    }

    /// Workflow variable names known statically (Code-node output variables).
    /// Surfaced in the Action inspector's binding editor for `{{ var.x }}` hints.
    var knownVariableNames: [String] {
        var names = Set<String>()
        for node in nodes {
            if case .code(let config) = node.kind,
               let v = config.outputVariable,
               !v.trimmingCharacters(in: .whitespaces).isEmpty {
                names.insert(v)
            }
        }
        return names.sorted()
    }
}
