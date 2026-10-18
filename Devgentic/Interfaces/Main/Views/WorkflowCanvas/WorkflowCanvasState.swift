// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowCanvasState.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

private let logger = DGLogger(category: "WorkflowCanvasState")

/// Central state for the workflow canvas.
/// Owns nodes, edges, selection, pan/zoom and drag state.
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

    // Why: edge endpoints add this offset too; any bound on dragging must be applied here, not in the node views.
    /// Returns the in-flight drag offset for a node, or `.zero` if it isn't being dragged.
    /// The id space is shared: sticky notes use this accessor with an annotation id.
    func nodeDragOffset(for nodeID: UUID) -> CGSize {
        guard let drag = activeNodeDrag, drag.nodeID == nodeID else { return .zero }
        return drag.offset
    }

    // MARK: - Canvas Transform

    var canvasOffset: CGSize = .zero
    @ObservationIgnored var lastOffset: CGSize = .zero

    var canvasScale: CGFloat = 1.0
    @ObservationIgnored var lastScale: CGFloat = 1.0

    // MARK: - Accessibility descriptions

    /// Returns the text VoiceOver reads for a node: its kind, name, run status and connection counts.
    func accessibilityDescription(for node: WorkflowNode, runStatusLabel: String? = nil) -> String {
        let incoming = edges.filter { $0.targetNodeID == node.id }.count
        let outgoing = edges.filter { $0.sourceNodeID == node.id }.count
        let kind = Self.accessibilityKindLabel(for: node.kind)

        // Uses `String(localized:)` so these `String` values reach the translation catalog.
        var parts = [String(localized: "\(kind) node, \(node.displayName)")]
        if let runStatusLabel { parts.append(runStatusLabel) }

        // Each count gets its own localized singular/plural key so translators can vary the plural form.
        parts.append(incoming == 1
            ? String(localized: "1 incoming connection")
            : String(localized: "\(incoming) incoming connections"))
        parts.append(outgoing == 1
            ? String(localized: "1 outgoing connection")
            : String(localized: "\(outgoing) outgoing connections"))
        return parts.joined(separator: ", ")
    }

    /// What VoiceOver reads for a connection: which node it leaves, by which port, and where it
    /// goes — plus whether it carried the run.
    func accessibilityDescription(for edge: WorkflowEdge, runStateSuffix: String? = nil) -> String {
        // Whole localized sentences, not spliced fragments, so translators can reorder the qualifier.
        let unknown = String(localized: "unknown node")
        let from = nodes.first(where: { $0.id == edge.sourceNodeID })?.displayName ?? unknown
        let to = nodes.first(where: { $0.id == edge.targetNodeID })?.displayName ?? unknown

        var description: String
        if let portLabel = edge.sourcePortLabel {
            description = String(localized: "Connection from \(from) \(portLabel) output to \(to)")
        } else {
            description = String(localized: "Connection from \(from) to \(to)")
        }
        if let runStateSuffix { description += ", \(runStateSuffix)" }
        return description
    }

    // Why: `.profile` must use `localizedTitleString`, never `rawValue`, which is a persisted token.
    /// Returns the spoken node-kind name, separate from the card's visible subtitle.
    static func accessibilityKindLabel(for kind: WorkflowNodeKind) -> String {
        switch kind {
        case .profile(_, let pType): return pType.localizedTitleString
        case .condition: return String(localized: "Router")
        case .code:      return String(localized: "Code")
        case .gate:      return String(localized: "Gate")
        case .trigger:   return String(localized: "Trigger")
        case .action:    return String(localized: "Action")
        case .unsupported: return String(localized: "Unsupported node")
        }
    }

    /// Returns the text VoiceOver reads for a sticky note: its colour and full text.
    /// An empty note says it is empty rather than speaking the on-screen placeholder; the text is never truncated.
    func accessibilityDescription(for note: StickyNote) -> String {
        let colorName = Self.accessibilityColorLabel(for: note.color)
        let body = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return String(localized: "\(colorName) sticky note, empty")
        }
        return String(localized: "\(colorName) sticky note, \(body)")
    }

    // Why: `.other` draws as yellow but is a tint from a newer build; never speak it as "Yellow" or speak `rawValue`.
    /// Returns the spoken sticky-note colour name.
    static func accessibilityColorLabel(for color: StickyNoteColor) -> String {
        switch color {
        case .yellow: return String(localized: "Yellow")
        case .blue:   return String(localized: "Blue")
        case .green:  return String(localized: "Green")
        case .pink:   return String(localized: "Pink")
        case .purple: return String(localized: "Purple")
        case .other:  return String(localized: "Custom color")
        }
    }

    // MARK: - Undo

    /// Snapshots taken before each structural mutation, newest last, capped at `maxUndoDepth`.
    @ObservationIgnored private var undoStack: [WorkflowLayout] = []

    /// Depth cap. Whole-layout snapshots, so this is thousands of nodes' worth at the limit, and a
    /// user who needs more than 25 steps back wants Revert.
    private static let maxUndoDepth = 25

    var canUndo: Bool { !undoStack.isEmpty }

    // Why: gates the save-time owned-row reconcile; saving a failed-read canvas would delete node configurations and credentials.
    /// Whether the graph this state holds came from a failed read.
    /// Only a successful load clears it; `markSaved()` does not.
    private(set) var lastLoadDidFail = false

    /// Records that the layout handed to `load(from:)` came from a failed read.
    func markLoadFailed() {
        lastLoadDidFail = true
        logger.error("[WF_CANVAS] Workflow \(profileID) was loaded from a FAILED read — the canvas may look empty when it is not. CONSEQUENCE: the save-time owned-row reconcile is refused for this state until a load succeeds, so a transient fetch error cannot turn into permanent deletion of this workflow's node configurations and credentials.")
    }

    // Why: saving does not clear the undo stack, so the reconcile must protect these rows
    // or undo would restore a node whose profile row is gone.
    /// Returns every profile-row id a node could still point at: the current graph's plus every undo snapshot's.
    /// A row survives while any undo step could restore a node referencing it; only a reload clears the stack.
    var undoRecoverableProfileIDs: Set<UUID> {
        var ids = Set(nodes.compactMap(\.profileID))
        for snapshot in undoStack {
            ids.formUnion(snapshot.nodes.compactMap(\.profileID))
        }
        return ids
    }

    /// [WF-CS3] Which node `replaceNode`'s last COALESCED push was for, and when — every other
    /// mutating method's plain `pushUndoSnapshot()` call clears this, so it only ever survives
    /// across consecutive `replaceNode` calls for the same node.
    @ObservationIgnored private var lastCoalescedNodeID: UUID?
    @ObservationIgnored private var lastCoalescedAt: Date?

    /// Overridable only under `@testable import` — lets tests move the coalescing window without
    /// real `Task.sleep`s.
    @ObservationIgnored var undoCoalescingClock: () -> Date = Date.init

    /// How long a run of `replaceNode` calls on the SAME node counts as one editing session. Wide
    /// enough to span a normal typing pause, narrow enough that leaving the inspector and coming
    /// back later to make a deliberate second edit still gets its own undo step.
    private static let undoCoalescingWindow: TimeInterval = 3.0

    // Why: per-keystroke inspector edits would otherwise evict the whole undo history.
    /// Captures the current graph so the next mutation can be undone; call before mutating.
    /// Calls sharing a `coalescingKey` within `undoCoalescingWindow` share one snapshot; a call without a key always pushes.
    private func pushUndoSnapshot(coalescingKey: UUID? = nil) {
        let now = undoCoalescingClock()
        if let coalescingKey, coalescingKey == lastCoalescedNodeID,
           let lastAt = lastCoalescedAt, now.timeIntervalSince(lastAt) < Self.undoCoalescingWindow {
            lastCoalescedAt = now   // slide the window so a long typing session stays coalesced
            return
        }
        lastCoalescedNodeID = coalescingKey
        lastCoalescedAt = coalescingKey != nil ? now : nil
        undoStack.append(currentLayout())
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
    }

    // Why: the inspector's Cancel restores through the same binding; without this its undo behaviour depended on timing.
    /// Ends the current coalescing run so the next `replaceNode` on the same node starts a fresh undo step.
    func endUndoCoalescingRun() {
        lastCoalescedNodeID = nil
        lastCoalescedAt = nil
    }

    /// Restores the graph as it was before the last structural mutation.
    /// Does not reset `hasUnsavedChanges`, so the quit guard still sees real unsaved work.
    func undo() {
        guard let previous = undoStack.popLast() else {
            logger.info("[WF_CANVAS] Undo requested with an empty stack for profile \(profileID) — nothing to undo. CONSEQUENCE: the canvas is unchanged.")
            return
        }
        // Drops the coalescing token; its snapshot was just popped, so a later edit must push a new one.
        lastCoalescedNodeID = nil
        lastCoalescedAt = nil
        let before = (nodes.count, edges.count, annotations.count)
        nodes = previous.nodes
        edges = previous.edges
        annotations = previous.annotations
        // Selection and the open inspector may point at nodes the new graph does not contain.
        selectedNodeID = nil
        selectedEdgeID = nil
        selectedAnnotationID = nil
        targetConfigNode = nil
        hasUnsavedChanges = true
        revalidate()
        logger.info("[WF_CANVAS] Undo applied for profile \(profileID): \(before.0)→\(nodes.count) node(s), \(before.1)→\(edges.count) edge(s), \(before.2)→\(annotations.count) note(s). \(undoStack.count) step(s) still available. CONSEQUENCE: the canvas differs from disk and stays marked unsaved.")
    }

    // MARK: - Dirty Tracking

    private(set) var hasUnsavedChanges: Bool = false

    // MARK: - Validation

    /// Current validation issues, recomputed on every markDirty() and load().
    private(set) var validationIssues: [WorkflowValidationIssue] = []

    /// Whether the validation panel is visible on the canvas.
    var showValidationPanel: Bool = false

    // Why: a closure rather than a stored snapshot: a snapshot lags behind rows created at add time and reports a false error.
    /// Resolves every profile the validator needs, read live at each validation.
    /// Production installs it when the canvas loads; a test must assign one before adding a profile node.
    var profileLookup: () -> [UUID: BackendProfileModel] = { [:] } {
        didSet { profileLookupInstalled = true }
    }

    /// Whether a `profileLookup` has been installed.
    /// Tracked apart from the lookup returning empty: a workflow whose profiles are all missing is a real condition.
    @ObservationIgnored private var profileLookupInstalled = false

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

    // MARK: - Viewport

    /// The canvas pane's current size, pushed by `WorkflowCanvasView` on layout.
    /// Observation is ignored: it changes on every resize and is only read imperatively for node placement.
    @ObservationIgnored var viewportSize: CGSize = .zero

    // Why: if the view's transform order changes, this inversion must change with it.
    /// Returns the canvas-space point currently at the middle of the viewport.
    /// Inverts the view's `scaleEffect(anchor: .center)` then `.offset` transform; uses a fixed point before first layout.
    var visibleCanvasCenter: CGPoint {
        guard viewportSize.width > 0, viewportSize.height > 0, canvasScale > 0 else {
            return CGPoint(x: 400, y: 300)
        }
        return CGPoint(
            x: viewportSize.width / 2 - canvasOffset.width / canvasScale,
            y: viewportSize.height / 2 - canvasOffset.height / canvasScale
        )
    }

    // MARK: - Reveal (CVC-9)

    /// Returns the canvas-space rectangle currently on screen, or `.zero` before first layout.
    /// Derived from `visibleCanvasCenter` so the view transform is stated once.
    var visibleCanvasRect: CGRect {
        guard viewportSize.width > 0, viewportSize.height > 0, canvasScale > 0 else { return .zero }
        let centre = visibleCanvasCenter
        let width = viewportSize.width / canvasScale
        let height = viewportSize.height / canvasScale
        return CGRect(
            x: centre.x - width / 2,
            y: centre.y - height / 2,
            width: width,
            height: height
        )
    }

    // Why: must not use the (400, 300) placement fallback; that would persist a bogus pan before first layout.
    /// Returns the `canvasOffset` that centres canvas point `point` in the viewport, or `nil` without a viewport.
    /// Computed as a delta off `visibleCanvasCenter` so the view transform is stated once.
    func offsetToCentre(on point: CGPoint) -> CGSize? {
        guard viewportSize.width > 0, viewportSize.height > 0, canvasScale > 0 else { return nil }
        let centre = visibleCanvasCenter
        return CGSize(
            width: canvasOffset.width - (point.x - centre.x) * canvasScale,
            height: canvasOffset.height - (point.y - centre.y) * canvasScale
        )
    }

    /// Screen points of slack a node needs inside the viewport before a reveal is deemed
    /// unnecessary. Named rather than inlined because this directory has already shipped one silent
    /// radius inflation (`edgeDragAbortRadius`, 24 → 50), so the boundary is pinned by test.
    static let revealMargin: CGFloat = 24

    /// Centres `nodeID` in view only when it is not already comfortably on screen; returns whether the canvas moved.
    /// `revealMargin` keeps nodes from sitting flush to the clipped edge, where their ports are cut off.
    @discardableResult
    func revealNode(_ nodeID: UUID) -> Bool {
        guard let node = nodes.first(where: { $0.id == nodeID }) else {
            // The caller selects first, so a skipped reveal leaves a selection on a node the canvas does not contain.
            logger.warning(
                "[WF_CANVAS] Reveal SKIPPED for node \(nodeID) on profile \(self.profileID): that "
                + "node is not on the canvas — the issue list is stale relative to the graph. "
                + "CONSEQUENCE: the canvas does not move, and the selection made just before this "
                + "call points at a node that is not on it, so the Delete control lights with "
                + "nothing highlighted."
            )
            return false
        }
        let rect = CGRect(origin: node.position, size: Self.nodeSize(for: node.kind))
        // The margin is SCREEN points; the rect is canvas points — divide by the scale to compare.
        let inset = Self.revealMargin / canvasScale
        if visibleCanvasRect.insetBy(dx: inset, dy: inset).contains(rect) {
            return false
        }
        guard let target = offsetToCentre(on: CGPoint(x: rect.midX, y: rect.midY)) else {
            logger.warning(
                "[WF_CANVAS] Reveal SKIPPED for node \(nodeID) on profile \(self.profileID): "
                + "viewport \(Int(self.viewportSize.width))×\(Int(self.viewportSize.height)) at "
                + "scale \(self.canvasScale) — no viewport to centre in. CONSEQUENCE: the node "
                + "stays where it is, off-screen if it was off-screen, and the validation row's "
                + "tap only draws a selection ring the user cannot see."
            )
            return false
        }
        // Goes through `addOffset`, which also syncs `lastOffset`; a bare assignment makes the next pan snap back.
        addOffset(delta: CGSize(
            width: target.width - canvasOffset.width,
            height: target.height - canvasOffset.height
        ))
        return true
    }

    /// The workflow profile this state belongs to.
    /// Readable so the hosting view can assert it is editing the state for the profile it displays.
    let profileID: UUID
    private var initialLayout: WorkflowLayout?

    // MARK: - Constants

    static let portRadius: CGFloat = 6

    // Why: the drag preview and this commit must agree; any bound added later belongs here.
    /// Returns the position a completed drag commits to: origin plus translation, with no floor.
    /// A node may sit at any coordinate, including negative ones.
    nonisolated static func committedDragPosition(origin: CGPoint, translation: CGSize) -> CGPoint {
        CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
    }

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
            // Pill shape / Approval gate
            return CGSize(width: 190, height: 64)
        case .trigger:
            // Chevron
            return CGSize(width: 120, height: 50)
        case .action:
            // Integration card (similar footprint to profile)
            return CGSize(width: 200, height: 76)
        case .unsupported:
            // [WF-PE4] Same footprint as a profile card so the preserved graph keeps its shape.
            return CGSize(width: 200, height: 80)
        }
    }

    // MARK: - Init

    init(profileID: UUID) {
        self.profileID = profileID
    }

    // MARK: - Load / Save

    func load(from layout: WorkflowLayout) {
        // A successful read is the ONLY thing that clears the failed-read gate. Callers that loaded
        // from a failed read call `markLoadFailed()` immediately after this.
        lastLoadDidFail = false
        nodes = layout.nodes
        edges = layout.edges
        annotations = layout.annotations
        initialLayout = layout
        hasUnsavedChanges = false
        // Wholesale replacement — Revert, a profile switch and discard-unreadable all land here, and
        // any node the inspector was bound to may be gone. Same reason as `removeNode`.
        targetConfigNode = nil
        // A selection id absent from the new graph would light Delete and push a no-op undo snapshot.
        pruneSelectionToLoadedLayout(layout)
        // Clears the undo stack: its snapshots describe the previous graph, and undo across profiles would mix workflows.
        undoStack.removeAll()
        // Clears the coalescing token too; the stack it referred to is now empty.
        lastCoalescedNodeID = nil
        lastCoalescedAt = nil
        revalidate()
    }

    /// Returns the selection that survives a graph replacement: an id is kept only if the loaded layout contains it.
    /// Pure and `nonisolated` so the rule can be tested directly.
    nonisolated static func survivingSelection(
        node: UUID?,
        edge: UUID?,
        annotation: UUID?,
        in layout: WorkflowLayout
    ) -> (node: UUID?, edge: UUID?, annotation: UUID?) {
        (
            node.flatMap { id in layout.nodes.contains(where: { $0.id == id }) ? id : nil },
            edge.flatMap { id in layout.edges.contains(where: { $0.id == id }) ? id : nil },
            annotation.flatMap { id in layout.annotations.contains(where: { $0.id == id }) ? id : nil }
        )
    }

    /// Applies `survivingSelection` and reports what it dropped.
    private func pruneSelectionToLoadedLayout(_ layout: WorkflowLayout) {
        let surviving = Self.survivingSelection(
            node: selectedNodeID,
            edge: selectedEdgeID,
            annotation: selectedAnnotationID,
            in: layout
        )
        if surviving.node != selectedNodeID
            || surviving.edge != selectedEdgeID
            || surviving.annotation != selectedAnnotationID {
            logger.info(
                "[WF_CANVAS] Selection DROPPED on layout load for profile \(self.profileID) — "
                + "node \(self.selectedNodeID?.uuidString ?? "none"), "
                + "edge \(self.selectedEdgeID?.uuidString ?? "none"), "
                + "note \(self.selectedAnnotationID?.uuidString ?? "none") is not in the loaded "
                + "graph (\(layout.nodes.count) node(s), \(layout.edges.count) edge(s), "
                + "\(layout.annotations.count) note(s)). CONSEQUENCE: the Delete control is "
                + "withdrawn instead of staying lit with nothing highlighted; pressing it would "
                + "have deleted nothing while marking this disk-identical canvas unsaved and "
                + "pushing a no-op undo step that costs Revert its one-⌘Z recovery."
            )
        }
        selectedNodeID = surviving.node
        selectedEdgeID = surviving.edge
        selectedAnnotationID = surviving.annotation
    }

    func currentLayout() -> WorkflowLayout {
        WorkflowLayout(nodes: nodes, edges: edges, annotations: annotations)
    }

    // Why: every write path must use this, not `currentLayout()`;
    // saving one workflow's nodes under another's id destroys its stored graph.
    /// Returns the layout to persist under `targetProfileID`, or `nil` if this state belongs to another profile.
    /// Returning `nil` refuses the write and keeps the edits in memory.
    func layout(forProfile targetProfileID: UUID) -> WorkflowLayout? {
        guard targetProfileID == profileID else {
            logger.error(
                "[WF_CANVAS] Refusing to produce a layout for profile \(targetProfileID): this canvas "
                + "state belongs to profile \(profileID) and holds \(nodes.count) node(s). "
                + "CONSEQUENCE: nothing is written — saving would have replaced \(targetProfileID)'s "
                + "stored graph with a different workflow's. The edits stay in memory and the canvas "
                + "stays dirty."
            )
            return nil
        }
        return currentLayout()
    }

    // MARK: - Node Operations

    /// Adds a profile-backed node.
    /// The caller supplies `nodeID` for owned nodes: the private profile row stores `ownerNodeID`, so it is created first.
    func addNode(from profile: BackendProfileModel, nodeID: UUID = UUID(), at position: CGPoint? = nil) {
        // This method is the only funnel that puts a `.profile` node on a canvas, so image generation is refused here.
        guard profile.profileType != .imageGen else {
            logger.error(
                "[WF_CANVAS] REFUSED node add for profile '\(profile.displayName)' (\(profile.id)) "
                + "on workflow \(profileID): image generation profiles cannot run as a workflow "
                + "step. CONSEQUENCE: no node is created and the canvas is unchanged — and because "
                + "the Add Node picker already filters this type out, reaching here means a SECOND "
                + "add path exists that bypasses `WorkflowProfilePickerView.offerableProfileTypes`."
            )
            return
        }

        // Aliasing tripwire: a row owned by another node means two nodes would share one configuration.
        // `assert` is stripped in release, so it is paired with an error log naming the consequence.
        if let owner = profile.ownerNodeID, owner != nodeID {
            logger.error(
                "[WF_CANVAS] Node \(nodeID) on workflow \(profileID) was created against profile row "
                + "\(profile.id), which is already owned by node \(owner). CONSEQUENCE: two nodes now "
                + "share one private configuration — edits to either affect both, and the save-time "
                + "reconcile will delete the row when either node is removed, leaving the other "
                + "pointing at nothing. A duplicate/paste path must COPY the row "
                + "(`WorkflowNodeProfileFactory.importedProfile`), not reuse it."
            )
            assertionFailure("addNode reused node-owned profile \(profile.id) for a second node")
        }

        pushUndoSnapshot()
        let pos = position ?? nextAvailablePosition()
        let node = WorkflowNode(
            id: nodeID,
            profileID: profile.id,
            position: pos,
            displayName: profile.displayName,
            profileType: profile.profileType
        )
        nodes.append(node)
        markDirty()
    }

    func removeNode(_ nodeID: UUID) {
        pushUndoSnapshot()
        let name = nodes.first(where: { $0.id == nodeID })?.displayName ?? nodeID.uuidString
        let cascaded = edges.filter { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }.count

        // Remove all edges connected to this node
        edges.removeAll { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }
        nodes.removeAll { $0.id == nodeID }

        logger.info("[WF_CANVAS] Deleted node '\(name)' (\(nodeID)) and \(cascaded) connected edge(s) from profile \(profileID). CONSEQUENCE: those branches are gone from the in-memory layout; recoverable with Undo (\(undoStack.count) step(s) available) or by Revert, which also discards every other unsaved edit.")

        if selectedNodeID == nodeID { selectedNodeID = nil }
        // The open inspector must go with the node, or it stays bound to a node that does not exist.
        if targetConfigNode?.id == nodeID { targetConfigNode = nil }
        markDirty()
    }

    // Why: the snapshot lives here, not in the gesture, so cancelled or returned drags leave no no-op undo step.
    /// Commits a completed node drag as one undo step.
    /// Called once per drag from the gesture's end, not during it.
    func moveNode(_ nodeID: UUID, to position: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
            // The node can vanish mid-drag (inspector delete, revert, clear or profile switch); the drop is logged, not silent.
            logger.error(
                "[WF_CANVAS] Node move DROPPED: no node \(nodeID) on the canvas for profile "
                + "\(profileID) (deleted, or the canvas was reverted/cleared/reloaded, while the "
                + "drag was in flight). CONSEQUENCE: the node snaps back to where the drag started, "
                + "nothing is pushed to the undo stack, and the canvas is left unchanged."
            )
            return
        }
        // A drag that ends where it began is not an edit; the guard avoids a wasted undo slot and a false dirty flag.
        guard nodes[index].position != position else {
            logger.debug(
                "[WF_CANVAS] Node move for \(nodeID) on profile \(profileID) resolved to its "
                + "existing position — the drag was released exactly where it began. CONSEQUENCE: "
                + "no undo step is pushed and the canvas is NOT marked dirty. (This line used to say "
                + "'or clamped to the canvas edge'; there is no edge any more — see "
                + "`committedDragPosition`.)"
            )
            return
        }
        // Snapshot after both guards so a refused move leaves no no-op undo step.
        pushUndoSnapshot()
        nodes[index].position = position
        markDirty()
    }

    // MARK: - Edge Operations

    /// Adds a structural (non-profile) node to the canvas.
    func addStructuralNode(kind: WorkflowNodeKind, displayName: String, at position: CGPoint? = nil) {
        pushUndoSnapshot()
        let pos = position ?? nextAvailablePosition()
        let node = WorkflowNode(kind: kind, position: pos, displayName: displayName)
        nodes.append(node)
        markDirty()
    }

    /// Why a connection was refused; `nil` from `refuseEdge` means it was created.
    /// Typed so the refusal can be shown to the user.
    enum EdgeRefusal: Equatable {
        case selfLoop
        case duplicate
        case missingNode
        case wouldCreateCycle
        /// The drag ended on empty canvas — outside every input port's accept radius (CVV-2).
        /// Not a graph refusal: `edgeRefusalReason` never returns it; only
        /// `recordMissedEdgeDrop` writes it.
        case missedDrop

        var userMessage: String {
            switch self {
            case .selfLoop:
                return String(localized: "A node can't connect to itself.")
            case .duplicate:
                return String(localized: "That connection already exists from this port.")
            case .missingNode:
                return String(localized: "One of those nodes is no longer on the canvas.")
            case .wouldCreateCycle:
                return String(localized: "That would create a loop — workflows have to flow one way.")
            case .missedDrop:
                return String(localized: "No connection made — release directly on a node's input port.")
            }
        }
    }

    /// The most recent refused connection, for the canvas to surface. Cleared on the next attempt.
    var lastEdgeRefusal: EdgeRefusal?

    /// Incremented on every refusal write so the banner's self-dismiss timer restarts even for a repeated refusal.
    /// The view keys its dismiss task on this.
    private(set) var edgeRefusalGeneration: Int = 0

    /// Returns the reason an edge from `sourceNodeID` to `targetNodeID` would be refused, or `nil` if accepted.
    /// Pure: it runs for every candidate node during a drag and must not mutate.
    func edgeRefusalReason(sourceNodeID: UUID, targetNodeID: UUID, sourcePortLabel: String? = nil) -> EdgeRefusal? {
        guard sourceNodeID != targetNodeID else { return .selfLoop }

        if edges.contains(where: {
            $0.sourceNodeID == sourceNodeID && $0.targetNodeID == targetNodeID && $0.sourcePortLabel == sourcePortLabel
        }) { return .duplicate }

        guard nodes.contains(where: { $0.id == sourceNodeID }),
              nodes.contains(where: { $0.id == targetNodeID }) else { return .missingNode }

        if currentLayout().wouldCreateCycle(source: sourceNodeID, target: targetNodeID) { return .wouldCreateCycle }

        return nil
    }

    @discardableResult
    func addEdge(sourceNodeID: UUID, targetNodeID: UUID, sourcePortLabel: String? = nil) -> Bool {
        if let refusal = edgeRefusalReason(sourceNodeID: sourceNodeID, targetNodeID: targetNodeID, sourcePortLabel: sourcePortLabel) {
            lastEdgeRefusal = refusal
            edgeRefusalGeneration += 1
            let sourceName = nodes.first(where: { $0.id == sourceNodeID })?.displayName ?? sourceNodeID.uuidString
            let targetName = nodes.first(where: { $0.id == targetNodeID })?.displayName ?? targetNodeID.uuidString
            logger.notice("[WF_CANVAS] Connection REFUSED '\(sourceName)' → '\(targetName)' via port '\(sourcePortLabel ?? "(default)")': \(refusal). CONSEQUENCE: no edge is drawn and the graph is unchanged; the reason is now shown on the canvas instead of the connection silently failing to appear.")
            return false
        }

        lastEdgeRefusal = nil
        pushUndoSnapshot()
        let edge = WorkflowEdge(sourceNodeID: sourceNodeID, targetNodeID: targetNodeID, sourcePortLabel: sourcePortLabel)
        edges.append(edge)
        markDirty()
        return true
    }

    func removeEdge(_ edgeID: UUID) {
        pushUndoSnapshot()
        if let edge = edges.first(where: { $0.id == edgeID }) {
            let from = nodes.first(where: { $0.id == edge.sourceNodeID })?.displayName ?? "?"
            let to = nodes.first(where: { $0.id == edge.targetNodeID })?.displayName ?? "?"
            logger.info("[WF_CANVAS] Deleted connection '\(from)' → '\(to)' via port '\(edge.sourcePortLabel ?? "(default)")'. CONSEQUENCE: that branch no longer runs; recoverable with Undo.")
        }
        edges.removeAll { $0.id == edgeID }
        if selectedEdgeID == edgeID { selectedEdgeID = nil }
        markDirty()
    }

    // MARK: - Annotation Operations

    /// A `nil` position defaults to `nextAvailablePosition()` here so no caller can reintroduce a fixed-offset formula.
    func addStickyNote(at position: CGPoint? = nil) {
        pushUndoSnapshot()
        let note = StickyNote(position: position ?? nextAvailablePosition())
        annotations.append(note)
        selectedAnnotationID = note.id
        markDirty()
    }

    func removeStickyNote(_ noteID: UUID) {
        pushUndoSnapshot()
        let chars = annotations.first(where: { $0.id == noteID })?.text.count ?? 0
        logger.info("[WF_CANVAS] Deleted sticky note \(noteID) (\(chars) chars). CONSEQUENCE: the note's text is gone from the in-memory layout; recoverable with Undo.")
        annotations.removeAll { $0.id == noteID }
        if selectedAnnotationID == noteID { selectedAnnotationID = nil }
        markDirty()
    }

    /// Commits a COMPLETED sticky-note drag. One call per drag, so one snapshot here is one undo
    /// step — identical contract to `moveNode`, including that the push stays out of the gesture.
    func moveStickyNote(_ noteID: UUID, to position: CGPoint) {
        guard let index = annotations.firstIndex(where: { $0.id == noteID }) else {
            logger.error(
                "[WF_CANVAS] Sticky-note move DROPPED: no note \(noteID) on the canvas for profile "
                + "\(profileID) (deleted, or the canvas was reverted/cleared/reloaded, while the "
                + "drag was in flight). CONSEQUENCE: the note snaps back to where the drag started "
                + "and nothing is pushed to the undo stack."
            )
            return
        }
        guard annotations[index].position != position else {
            logger.debug(
                "[WF_CANVAS] Sticky-note move for \(noteID) resolved to its existing position. "
                + "CONSEQUENCE: no undo step is pushed and the canvas is NOT marked dirty."
            )
            return
        }
        pushUndoSnapshot()
        annotations[index].position = position
        markDirty()
    }

    /// Commits a COMPLETED sticky-note resize. One call per gesture — the in-flight size is the
    /// view's own `@State localResizeSize` and only `.onEnded` reaches here.
    func resizeStickyNote(_ noteID: UUID, to size: CGSize) {
        guard let index = annotations.firstIndex(where: { $0.id == noteID }) else {
            logger.error(
                "[WF_CANVAS] Sticky-note resize DROPPED: no note \(noteID) on the canvas for "
                + "profile \(profileID) (deleted, or the canvas was reverted/cleared/reloaded, "
                + "while the resize was in flight). CONSEQUENCE: the note keeps its previous size "
                + "and nothing is pushed to the undo stack."
            )
            return
        }
        // Clamps before comparing, since a sub-floor size can arrive from a decoded layout or a non-gesture caller.
        let clamped = StickyNote.resizedSize(from: size, translation: .zero)
        guard annotations[index].size != clamped else {
            logger.debug(
                "[WF_CANVAS] Sticky-note resize for \(noteID) resolved to its existing size "
                + "\(Int(clamped.width))×\(Int(clamped.height)) (released where it started, or "
                + "clamped up to the \(Int(StickyNote.minimumSize.width))×"
                + "\(Int(StickyNote.minimumSize.height)) floor). CONSEQUENCE: no undo step is "
                + "pushed and the canvas is NOT marked dirty."
            )
            return
        }
        pushUndoSnapshot()
        annotations[index].size = clamped
        markDirty()
    }

    /// Commits an edit session's text, not a keystroke.
    /// `StickyNoteView` calls this from `commitText()` on focus loss, tap out or unmount, so one snapshot covers the session.
    func updateStickyNoteText(_ noteID: UUID, text: String) {
        guard let index = annotations.firstIndex(where: { $0.id == noteID }) else {
            // `commitText()` also runs on disappear, so reaching here means typed content is lost; logs the char count only.
            logger.error(
                "[WF_CANVAS] Sticky-note text edit DISCARDED: no note \(noteID) on the canvas for "
                + "profile \(profileID) (deleted, or the canvas was reverted/cleared/reloaded, "
                + "possibly by a run starting, while the note was being edited). CONSEQUENCE: "
                + "\(text.count) character(s) the user typed are lost with no undo step and no "
                + "on-screen notice."
            )
            return
        }
        guard annotations[index].text != text else { return }
        pushUndoSnapshot()
        annotations[index].text = text
        markDirty()
    }

    func updateStickyNoteColor(_ noteID: UUID, color: StickyNoteColor) {
        guard let index = annotations.firstIndex(where: { $0.id == noteID }) else {
            logger.error(
                "[WF_CANVAS] Sticky-note colour change DROPPED: no note \(noteID) on the canvas "
                + "for profile \(profileID). CONSEQUENCE: the note keeps its previous colour and "
                + "nothing is pushed to the undo stack."
            )
            return
        }
        guard annotations[index].color != color else { return }
        pushUndoSnapshot()
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
        pushUndoSnapshot()
        // The undo stack survives saving; only a reload via `load(from:)` or quitting makes the clear permanent.
        logger.notice("[WF_CANVAS] CLEARED the canvas for profile \(profileID): \(nodes.count) node(s), \(edges.count) edge(s), \(annotations.count) note(s) removed. CONSEQUENCE: the whole graph is gone from memory; recoverable with Undo until the canvas is reloaded (a save followed by a remount) or the app quits. The clear itself writes nothing to disk.")
        nodes.removeAll()
        edges.removeAll()
        annotations.removeAll()
        selectedNodeID = nil
        selectedEdgeID = nil
        selectedAnnotationID = nil
        targetConfigNode = nil
        markDirty()
    }

    /// Discards every unsaved edit and restores the last-saved layout.
    /// The revert is undoable: the stack is re-armed with the pre-revert graph after `load(from:)` clears it.
    func revert() {
        guard let initial = initialLayout else {
            logger.info("[WF_CANVAS] Revert requested with no saved baseline for profile \(profileID) — nothing to revert to. CONSEQUENCE: the canvas is unchanged.")
            return
        }
        guard hasUnsavedChanges else { return }

        let preRevert = currentLayout()
        logger.info("[WF_CANVAS] Discarding unsaved changes for profile \(profileID): \(preRevert.nodes.count)→\(initial.nodes.count) node(s), \(preRevert.edges.count)→\(initial.edges.count) edge(s), \(preRevert.annotations.count)→\(initial.annotations.count) note(s). CONSEQUENCE: the canvas matches the last save; the discarded state is one Undo away.")
        load(from: initial)
        undoStack = [preRevert]
    }

    func markSaved() {
        initialLayout = currentLayout()
        hasUnsavedChanges = false
    }

    // Why: this object outlives the view, so a stale `targetConfigNode` would stop the same node's inspector from reopening.
    /// Resets inspector state when the canvas subtree goes away.
    /// Separate from the view's `.onDisappear` so it can be unit-tested.
    func canvasDidDisappear(panelWasOnScreen: Bool) {
        guard targetConfigNode != nil || panelWasOnScreen else { return }
        let name = targetConfigNode?.displayName ?? "unknown"
        let id = targetConfigNode?.id.uuidString ?? "unknown"

        logger.notice(
            "[WF_CANVAS] Node inspector DISMISSED for profile \(profileID) because the canvas was "
            + "torn down (open node '\(name)' \(id); panel on screen: \(panelWasOnScreen)). "
            + "CONSEQUENCE: a PROFILE node's buffered draft was already committed by "
            + "`NodeInspectorPendingCommit` before this ran (Phase 2, option C — teardown commits; "
            + "Cancel is the one explicit discard), and the node name plus per-node timeout/retry "
            + "settings write through live. The OTHER inspector kinds (Router/Code/Gate/Action) "
            + "still buffer until their own Save, so their unsaved edits ARE discarded here. "
            + "The canvas graph is untouched. Not dismissing "
            + "it left a borderless, always-on-top, all-Spaces panel floating above every other "
            + "view — with no Cancel and a disabled Done on a profile node whose task description "
            + "is empty."
        )
        targetConfigNode = nil
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
    /// Condition nodes expose rule labels plus the fallback; profile nodes expose a default port and an "error" port.
    func outputPortLabels(for node: WorkflowNode) -> [String] {
        Self.outputPortLabels(for: node)
    }

    /// The one definition of a node's output ports.
    /// Pure and `nonisolated` so the rename map and `WorkflowValidator` can ask without a canvas or the main actor.
    nonisolated static func outputPortLabels(for node: WorkflowNode) -> [String] {
        switch node.kind {
        case .condition(let config):
            // Rule labels plus the reserved failure port; a cascade skip activates `error` on any node.
            return withErrorPort(config.outputPortLabels)

        case .profile, .action:
            return ["", WorkflowEdge.errorPortLabel]

        case .gate(let config):
            // One port per option, plus `error`: a timed-out or cancelled gate fails through that port.
            return withErrorPort(config.options)

        case .code:
            // Default flow + failure routing. A JS error or a cascade skip both activate `error`;
            // without the port there was nowhere for it to go.
            return ["", WorkflowEdge.errorPortLabel]

        case .trigger:
            // Entry-point marker only — never executes, so it has no failure to route.
            return []

        case .unsupported:
            // The node's real ports are unknown to this build, so none are declared and edges draw via the index-0 fallback.
            // The validator skips these edges; the executor's refusal of unsupported nodes is the only backstop.
            return []
        }
    }

    /// Appends the reserved failure port unless a user-authored label already uses that string.
    /// Labels are free text, so duplicates would render two ports that `firstIndex(of:)` collapses onto one.
    nonisolated private static func withErrorPort(_ labels: [String]) -> [String] {
        labels.contains(WorkflowEdge.errorPortLabel) ? labels : labels + [WorkflowEdge.errorPortLabel]
    }

    /// The cap on an output-port badge, in characters.
    /// Read from `ConditionNodeConfig.maxLabelLength` so legal Router labels render in full.
    nonisolated static var portBadgeCharacterCap: Int { ConditionNodeConfig.maxLabelLength }

    // Why: never feed this back into port labels: two long options may share a badge,
    // but ports match by exact string.
    /// Returns display text for an output-port badge; purely cosmetic, never a port identity.
    /// Newlines are flattened and the text capped because `.fixedSize()` would let it overrun neighbouring nodes.
    nonisolated static func portBadgeText(
        _ label: String,
        maxCharacters: Int = portBadgeCharacterCap
    ) -> String {
        let flattened = label
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard flattened.count > maxCharacters else { return flattened }
        return String(flattened.prefix(maxCharacters - 1)) + "\u{2026}"
    }

    /// Whether it is safe to replace this canvas from the stored layout.
    /// The state can outlive its view, so a re-appear on a mid-edit canvas must not reload and discard the user's work.
    var acceptsDiskReload: Bool { !hasUnsavedChanges }

    // MARK: - Port renaming

    // Why: all edited-node writes must go through here; edges address ports by label, so a bare assignment strands them.
    /// Replaces a node and re-points edges whose output port the edit renamed.
    /// Edges whose port disappears are left in place for the validator to report, not dropped.
    func replaceNode(id nodeID: UUID, with newNode: WorkflowNode) {
        // Snapshot after the guard so a refused replace leaves no no-op undo step.
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else {
            // This is the seam an inspector's Save writes through, so a missed node is logged rather than dropped silently.
            logger.error("[WF_CANVAS] Node edit DISCARDED: no node \(nodeID) on the canvas to replace (it was deleted, or the canvas was reverted/cleared, while its inspector was open). CONSEQUENCE: every change made in that panel is lost. The inspector is now closed when its node disappears, so reaching this means a new path bypassed that.")
            return
        }
        // [WF-CS3] A write that changes nothing (a redundant Binding fire, a Save with no edits)
        // must not consume an undo step either — same reasoning as the missing-node guard above.
        guard newNode != nodes[idx] else { return }
        pushUndoSnapshot(coalescingKey: nodeID)
        let oldNode = nodes[idx]
        nodes[idx] = newNode

        let renames = Self.portRenameMap(from: oldNode, to: newNode)
        if !renames.isEmpty {
            var repointed = 0
            for edgeIdx in edges.indices where edges[edgeIdx].sourceNodeID == nodeID {
                guard let currentLabel = edges[edgeIdx].sourcePortLabel,
                      let newLabel = renames[currentLabel] else { continue }
                let edge = edges[edgeIdx]
                edges[edgeIdx] = WorkflowEdge(
                    id: edge.id,
                    sourceNodeID: edge.sourceNodeID,
                    targetNodeID: edge.targetNodeID,
                    sourcePortLabel: newLabel
                )
                repointed += 1
            }
            if repointed > 0 {
                logger.info("[WF_CANVAS] Node '\(newNode.displayName)' (\(nodeID)) renamed \(renames.count) output port(s) — re-pointed \(repointed) edge(s) so their branches keep running: \(renames.map { "\($0.key)→\($0.value)" }.sorted().joined(separator: ", ")).")
            }
        }

        markDirty()
    }

    /// Returns old port label to new port label for an edit of the same node.
    /// Applied simultaneously, so shift-renames are safe; ambiguous cases (shared labels, "error") refuse and log.
    static func portRenameMap(from oldNode: WorkflowNode, to newNode: WorkflowNode) -> [String: String] {
        var map: [String: String] = [:]

        switch (oldNode.kind, newNode.kind) {
        case (.condition(let oldConfig), .condition(let newConfig)):
            let newRulesByID = Dictionary(newConfig.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var ambiguousOldLabels: Set<String> = []
            for oldRule in oldConfig.rules {
                guard let newRule = newRulesByID[oldRule.id], newRule.label != oldRule.label else { continue }
                if let existing = map[oldRule.label], existing != newRule.label {
                    // Two old rules shared one label and diverged. Edges address the port by that
                    // shared label, so there is no telling which rule an edge meant to follow.
                    ambiguousOldLabels.insert(oldRule.label)
                    continue
                }
                map[oldRule.label] = newRule.label
            }
            for label in ambiguousOldLabels {
                map.removeValue(forKey: label)
                logger.warning("[WF_CANVAS] Port rename from shared label '\(label)' NOT applied: two rules carried that label and were renamed to different things, so an edge on '\(label)' has no single owner. CONSEQUENCE: those edges keep the old label and the validator reports them as dangling rather than this guessing a branch.")
            }
            // A rename away from a label another rule keeps is unowned: the edge may belong to the keeper.
            let keptLabels = Set(oldConfig.rules.compactMap { rule -> String? in
                guard let newRule = newRulesByID[rule.id], newRule.label == rule.label else { return nil }
                return rule.label
            })
            for (oldLabel, _) in map where keptLabels.contains(oldLabel) {
                map.removeValue(forKey: oldLabel)
                logger.warning("[WF_CANVAS] Port rename from shared label '\(oldLabel)' NOT applied: another rule still carries that label, so an edge on '\(oldLabel)' may belong to it. CONSEQUENCE: those edges stay on the surviving port instead of following the renamed twin.")
            }

        case (.gate(let oldConfig), .gate(let newConfig)):
            map = gateRenameMap(old: oldConfig.options, new: newConfig.options)

        default:
            return [:]
        }

        // Destination filter: a new label carried by more than one port is ambiguous, so the edge is left in place.
        // The reserved "error" label is refused in both directions because label counting cannot see it.
        var newLabelCounts: [String: Int] = [:]
        for label in outputPortLabels(for: newNode) {
            newLabelCounts[label, default: 0] += 1
        }
        return map.filter { oldLabel, newLabel in
            if oldLabel == WorkflowEdge.errorPortLabel {
                logger.warning("[WF_CANVAS] Port rename '\(oldLabel)'→'\(newLabel)' NOT applied: '\(WorkflowEdge.errorPortLabel)' is the reserved failure label and its port survives every rename. CONSEQUENCE: edges stay on '\(WorkflowEdge.errorPortLabel)' so failure routing keeps working; wire the renamed port by hand if the edge was meant to follow the rule.")
                return false
            }
            if newLabel == WorkflowEdge.errorPortLabel {
                logger.warning("[WF_CANVAS] Port rename '\(oldLabel)'→'\(newLabel)' NOT applied: '\(WorkflowEdge.errorPortLabel)' is the reserved failure label, so the destination would also fire on every failure and cascade skip. CONSEQUENCE: edges wired to '\(oldLabel)' keep their old label and the validator reports them as dangling.")
                return false
            }
            if newLabelCounts[newLabel, default: 0] == 1 { return true }
            logger.warning("[WF_CANVAS] Port rename '\(oldLabel)'→'\(newLabel)' NOT applied: \(newLabelCounts[newLabel, default: 0]) ports on the edited node now share the label '\(newLabel)', so the destination is ambiguous. CONSEQUENCE: edges wired to '\(oldLabel)' keep their old label and the validator reports them as dangling rather than this guessing a branch.")
            return false
        }
    }

    /// Recovers renames for Gate options, which are plain strings with no identity.
    /// Position is trusted only while no delete can have happened; shrinking saves and displaced survivors yield no map.
    private static func gateRenameMap(old: [String], new: [String]) -> [String: String] {
        let oldSet = Set(old), newSet = Set(new)
        guard new.count >= old.count else {
            let vanished = old.filter { !newSet.contains($0) }
            if !vanished.isEmpty {
                logger.notice("[WF_CANVAS] Gate options \(vanished.map { "'\($0)'" }.joined(separator: ", ")) removed in a Save that shrank the option count — a delete cannot be told apart from a rename-plus-delete. CONSEQUENCE: if one of these was meant as a rename, its edges did NOT follow; they now dangle and the validator reports them.")
            }
            return [:]
        }

        // Survivors must sit at their exact old indices — adds append and renames edit in place,
        // so any displaced survivor proves a delete, and a delete shifts every later row.
        var lastAnchoredSurvivorIndex = -1
        for (index, label) in old.enumerated() where newSet.contains(label) {
            guard index < new.count, new[index] == label else {
                logger.notice("[WF_CANVAS] Gate option '\(label)' moved from row \(index + 1) in this Save, which proves a row was deleted — positional rename tracking is unsafe for the whole edit. CONSEQUENCE: no edges are re-pointed; any renamed option's edges now dangle and the validator reports them.")
                return [:]
            }
            lastAnchoredSurvivorIndex = index
        }

        // Consumable budget of genuinely new texts, so a rename can't grab a shifted survivor or
        // claim the same new text twice.
        var addedCounts: [String: Int] = [:]
        for label in new where !oldSet.contains(label) {
            addedCounts[label, default: 0] += 1
        }

        var map: [String: String] = [:]
        var ambiguousOldLabels: Set<String> = []
        for (index, oldLabel) in old.enumerated() where !newSet.contains(oldLabel) {
            if new.count > old.count, index > lastAnchoredSurvivorIndex {
                logger.notice("[WF_CANVAS] Gate option '\(oldLabel)' (row \(index + 1)) vanished past the last surviving row in a Save that also ADDED options — a rename of that row is byte-identical to deleting it and adding a new one, so no guess is made. CONSEQUENCE: if it was a rename, its edges did NOT follow; they now dangle and the validator reports them. Re-wire the new port by hand.")
                continue
            }
            let candidate = new[index]     // index < new.count: guarded by new.count >= old.count
            guard !oldSet.contains(candidate), addedCounts[candidate, default: 0] > 0 else { continue }
            if let existing = map[oldLabel], existing != candidate {
                // Duplicate old texts renamed to different things — no single owner for the label.
                ambiguousOldLabels.insert(oldLabel)
                continue
            }
            map[oldLabel] = candidate
            addedCounts[candidate]! -= 1
        }
        for label in ambiguousOldLabels {
            map.removeValue(forKey: label)
            logger.warning("[WF_CANVAS] Gate option rename from duplicated text '\(label)' NOT applied: two rows carried that text and were renamed to different things. CONSEQUENCE: edges on '\(label)' keep the old label and the validator reports them as dangling rather than this guessing a branch.")
        }
        return map
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

    /// The accept radius around an input port's centre for an edge drop. Named so the drop
    /// test, the primary-target highlight and the missed-drop log all agree on one number
    /// (register CVV-2 — the log must name the radius the drop was actually judged against).
    static let inputPortHitRadius: CGFloat = 20

    /// A release within this distance of the drag's SOURCE port is the user cancelling the
    /// gesture, not missing a target — no refusal notice fires (see `recordMissedEdgeDrop`).
    static let edgeDragAbortRadius: CGFloat = 24

    /// Returns the node whose input port is closest to `point`, within the hit radius.
    /// Picks the true nearest, not the first match, so the drop highlight and drop target agree.
    func findInputPortTarget(near point: CGPoint, excluding sourceNodeID: UUID) -> UUID? {
        var best: (id: UUID, distance: CGFloat)? = nil
        for node in nodes where node.id != sourceNodeID {
            if let portPos = inputPortPosition(for: node.id) {
                let distance = hypot(point.x - portPos.x, point.y - portPos.y)
                if distance <= Self.inputPortHitRadius, distance < (best?.distance ?? .infinity) {
                    best = (node.id, distance)
                }
            }
        }
        return best?.id
    }

    /// Surfaces an edge drag that ended on empty canvas with a banner and a log.
    /// A release back at the source port is a cancel and produces no refusal.
    func recordMissedEdgeDrop(from sourceNodeID: UUID, sourcePortLabel: String?, at point: CGPoint) {
        if let origin = outputPortPosition(for: sourceNodeID, portLabel: sourcePortLabel),
           hypot(point.x - origin.x, point.y - origin.y) <= Self.edgeDragAbortRadius {
            return
        }
        lastEdgeRefusal = .missedDrop
        edgeRefusalGeneration += 1
        let sourceName = nodes.first(where: { $0.id == sourceNodeID })?.displayName ?? sourceNodeID.uuidString
        logger.notice("[WF_CANVAS] Connection drag from '\(sourceName)' (port '\(sourcePortLabel ?? "(default)")') released at (\(Int(point.x)), \(Int(point.y))) with no input port within \(Int(Self.inputPortHitRadius))pt. CONSEQUENCE: no edge was created; the miss now shows the same on-canvas notice as a refused connection instead of the preview line silently vanishing.")
    }

    // MARK: - Helpers

    /// Returns the top-left for a new node: centred in the current viewport, on the nearest free slot.
    /// Probes outward ring by ring for a slot overlapping no node or sticky note. Internal for tests.
    func nextAvailablePosition() -> CGPoint {
        // Generous envelope: the widest card is 220pt (code), the tallest 120pt (condition).
        let envelope = CGSize(width: 220, height: 120)
        let margin: CGFloat = 20
        let center = visibleCanvasCenter
        let ideal = CGPoint(x: center.x - envelope.width / 2, y: center.y - envelope.height / 2)

        func isFree(_ origin: CGPoint) -> Bool {
            let candidate = CGRect(origin: origin, size: envelope)
            let blockedByNode = nodes.contains { node in
                CGRect(origin: node.position, size: Self.nodeSize(for: node.kind))
                    .insetBy(dx: -margin, dy: -margin)
                    .intersects(candidate)
            }
            if blockedByNode { return false }
            return !annotations.contains { note in
                CGRect(origin: note.position, size: note.size)
                    .insetBy(dx: -margin, dy: -margin)
                    .intersects(candidate)
            }
        }

        // Ring 0 is the centre; five rings is 121 candidates, so reaching the fallback means the visible area is packed.
        let stepX = envelope.width + 2 * margin
        let stepY = envelope.height + 2 * margin
        for ring in 0...5 {
            for j in -ring...ring {
                for i in -ring...ring where max(abs(i), abs(j)) == ring {
                    let candidate = CGPoint(x: ideal.x + CGFloat(i) * stepX,
                                            y: ideal.y + CGFloat(j) * stepY)
                    if isFree(candidate) { return candidate }
                }
            }
        }

        // Saturated viewport: stagger by node plus annotation count so successive adds get distinct positions.
        return CGPoint(x: ideal.x, y: ideal.y + CGFloat(nodes.count + annotations.count + 1) * stepY)
    }

    func markDirty() {
        hasUnsavedChanges = true
        revalidate()
    }

    // Why: revalidate() runs on every drag and keystroke; refetching the nesting tree each time is too costly.
    /// Layouts of every workflow reachable through this canvas's sub-workflow nodes.
    /// Cached and keyed on the references and the store's write generation, so any child edit invalidates it.
    private var nestedLayoutCache: [UUID: WorkflowLayout] = [:]
    private var nestedLayoutCacheKey: NestedLayoutCacheKey?

    /// What the nested-layout cache is valid FOR: which children, as of which store generation.
    private struct NestedLayoutCacheKey: Equatable {
        let references: Set<UUID>
        let storeGeneration: Int
    }

    /// Refreshes `nestedLayoutCache` if this canvas's sub-workflow references changed, or if any
    /// layout has been written since it was built.
    private func refreshNestedLayoutsIfNeeded() {
        let key = NestedLayoutCacheKey(
            references: Set(WorkflowLayoutStore.subWorkflowProfileIDs(in: currentLayout())),
            storeGeneration: WorkflowLayoutStore.shared.writeGeneration
        )
        guard key != nestedLayoutCacheKey else { return }
        nestedLayoutCacheKey = key
        nestedLayoutCache = key.references.isEmpty
            ? [:]
            : WorkflowLayoutStore.shared.resolveNestedLayouts(from: currentLayout())
    }

    /// The tool catalogue the validator's availability check reads, resolved live at each validation.
    /// A closure so tests can supply their own sources.
    var toolSourceLookup: () -> [ToolSource] = { UnifiedToolStore.shared.sources }

    /// Re-runs validation because the tool catalogue changed under an open canvas.
    /// Called by a catalogue observer, since the canvas stays mounted and fires no `onAppear` on return.
    func revalidateForToolCatalogChange(generation: Int) {
        // Skips validation until a lookup is installed, so the profile-lookup tripwire cannot fire.
        guard profileLookupInstalled else {
            logger.info(
                "[WF_CANVAS] Tool-catalogue change (generation \(generation)) reached canvas "
                + "\(profileID) before its view installed a profile lookup — validation was NOT "
                + "re-run. CONSEQUENCE: tool-availability warnings on this canvas stay as they were "
                + "until its next edit or reload; no false 'configuration is missing' errors are "
                + "reported."
            )
            return
        }
        let before = validationIssues.count
        revalidate()
        if before != validationIssues.count {
            logger.info(
                "[WF_CANVAS] Tool catalogue changed (generation \(generation)) — canvas \(profileID) "
                + "re-validated: \(before) → \(validationIssues.count) issue(s). CONSEQUENCE: the "
                + "toolbar pill and the validation panel now reflect the current tool catalogue "
                + "instead of the one from the last graph edit."
            )
        }
    }

    /// Forces a validation pass; a test seam because `revalidate()` is private.
    func revalidateForTesting() { revalidate() }

    /// Runs the pure validator against the current layout and profile map.
    private func revalidate() {
        refreshNestedLayoutsIfNeeded()

        // Tripwire: validating before `profileLookup` is installed would report every profile node as missing its configuration.
        // `assert` is stripped in release, so it is paired with an error log naming the consequence.
        let resolved = profileLookup()
        if !profileLookupInstalled, nodes.contains(where: { $0.profileID != nil }) {
            logger.error(
                "[WF_CANVAS] Validating workflow \(profileID) with an EMPTY profile lookup while "
                + "\(nodes.filter { $0.profileID != nil }.count) profile node(s) are on the canvas. "
                + "CONSEQUENCE: every one of them is reported as missing its configuration — a false "
                + "blocking error. The lookup is installed by `WorkflowCanvasView.loadLayout()`; "
                + "reaching here means this state was mutated before its view mounted."
            )
            assertionFailure("revalidate() ran with no profileLookup installed for \(profileID)")
        }


        validationIssues = WorkflowValidator.validate(
            layout: currentLayout(),
            profileMap: resolved,
            availableToolSources: toolSourceLookup(),
            subWorkflowLayouts: nestedLayoutCache,
            rootProfileID: profileID
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
