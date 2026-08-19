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

private let logger = DGLogger(category: "WorkflowCanvasState")

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

    // MARK: - Accessibility descriptions

    /// What VoiceOver reads for a node: what it is, what it is called, how it went on the displayed
    /// run, and how it is WIRED.
    ///
    /// ⚠️ Lives here, not in the view, because the connection counts are the substantive part and a
    /// view's private computed property cannot be tested. A graph editor's whole content is its
    /// topology; without the counts a node is a name floating in space.
    func accessibilityDescription(for node: WorkflowNode, runStatusLabel: String? = nil) -> String {
        let incoming = edges.filter { $0.targetNodeID == node.id }.count
        let outgoing = edges.filter { $0.sourceNodeID == node.id }.count
        let kind = Self.accessibilityKindLabel(for: node.kind)

        // ⚠️ `String(localized:)`, not a bare literal. These are `String` values handed to
        // `.accessibilityLabel(_: S)`, which binds the StringProtocol overload — the extractor never
        // sees them, so unlike the surrounding `Text("…")` literals they would silently never be
        // OFFERED for translation (WF-CU8). `runStatusLabel` is ALREADY localized upstream, so the
        // sentence was a mongrel: a translated status inside English scaffolding.
        var parts = [String(localized: "\(kind) node, \(node.displayName)")]
        if let runStatusLabel { parts.append(runStatusLabel) }

        // ⚠️ TWO independently-pluralized halves, NOT one "connection(s)" suffix.
        //
        // The old form was `connection\(incoming + outgoing == 1 ? "" : "s")`: an English plural
        // letter concatenated onto the noun, agreeing with a SUM. A sum is not a format argument, so
        // no catalog mechanism can ever reach it — plural `variations` and `substitutions` both need
        // an `argNum` pointing at a real argument. It was also wrong in ENGLISH: one incoming and
        // one outgoing gave "1 incoming, 1 outgoing connections", and 1+0 gave "1 incoming,
        // 0 outgoing connection".
        //
        // ⚠️ Each form is its OWN key with the count as a real argument, so a translator can attach
        // per-language plural variations to either. Deliberately NOT `^[…](inflect: true)`: I could
        // not demonstrate that markup resolving — a test asserting singular-vs-plural got the raw
        // `^[2 outgoing connection](inflect: true)` back, both with and without a catalog entry —
        // and shipping markup that may reach a user verbatim is worse than an explicit branch.
        // Two keys per count handle English correctly; languages needing more forms get them from
        // the catalog rather than from this code.
        //
        // English before: "2 incoming, 0 outgoing connections"  (and "1 incoming, 1 outgoing connections")
        // English after:  "2 incoming connections, 0 outgoing connections"
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
        // ⚠️ TWO WHOLE SENTENCES, not a `" \(port) output"` fragment spliced into a frame. A
        // translator cannot move a fragment relative to the sentence it is glued into, and a
        // language that puts the qualifier before the noun had no way to express it at all.
        // English output is unchanged: "Connection from N0 error output to N1".
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

    /// Spoken node-kind name. Deliberately separate from the card's visible subtitle, which for an
    /// Action node is the tool name — useful on screen, but it does not say what KIND of node you
    /// have landed on.
    /// ⚠️ `.profile` uses `localizedTitleString`, NEVER `rawValue`. `ProfileType`'s rawValues are
    /// user-facing English ("Bot", "Image Generator", …) that ALSO reach SwiftData and JSON as
    /// PERSISTED tokens; `ProfileType+Display.swift` documents this exact bypass. Its literals are
    /// character-identical to `localizedTitle`'s, so both bind the same catalog entries and a node's
    /// spoken label can never disagree with its visible subtitle.
    static func accessibilityKindLabel(for kind: WorkflowNodeKind) -> String {
        switch kind {
        case .profile(_, let pType): return pType.localizedTitleString
        case .condition: return String(localized: "Router")
        case .code:      return String(localized: "Code")
        case .gate:      return String(localized: "Gate")
        case .trigger:   return String(localized: "Trigger")
        case .action:    return String(localized: "Action")
        }
    }

    /// What VoiceOver reads for a sticky note: what colour it is and what it SAYS.
    ///
    /// ⚠️ Lives here, not in the view, for the same reason the node and edge descriptions do — a
    /// view's private computed property cannot be tested, and a note's TEXT is its entire content.
    ///
    /// ⚠️ Must NOT speak the on-screen placeholder ("Double-click to edit…"): it names a pointer
    /// gesture a VoiceOver user cannot perform, and it would masquerade as the note's content.
    /// Every note is born EMPTY, so the empty case is the common case, not an edge case — it says
    /// it is empty, and the "Edit text" action carries the how.
    ///
    /// Deliberately NOT truncated. The text is documentation the author put on the canvas and has
    /// no other spoken route, so cutting it short hides data.
    func accessibilityDescription(for note: StickyNote) -> String {
        let colorName = Self.accessibilityColorLabel(for: note.color)
        let body = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            return String(localized: "\(colorName) sticky note, empty")
        }
        return String(localized: "\(colorName) sticky note, \(body)")
    }

    /// Spoken sticky-note colour name.
    ///
    /// ⚠️ Cannot be derived from `swiftUIColor`: `.other` DRAWS as yellow but is a tint written by a
    /// NEWER build, and speaking it as "Yellow" would state something false about persisted data.
    /// `rawValue` is a storage token and must never be spoken.
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

    /// Snapshots taken BEFORE each structural mutation, newest last.
    ///
    /// ⚠️ The canvas has no autosave (user decision), so before this the only route back from an
    /// accidental delete was Revert — which throws away every other unsaved edit too. That was
    /// already poor, and the 2026-08-14 quit-time canvas persistence made it worse by closing the
    /// informal "quit without saving" escape hatch. A node deleted by mistake took its entire
    /// wiring with it, unrecoverably.
    ///
    /// Bounded because a canvas session is long-lived: an unbounded stack of whole-graph snapshots
    /// grows for as long as the app runs.
    @ObservationIgnored private var undoStack: [WorkflowLayout] = []

    /// Depth cap. Whole-layout snapshots, so this is thousands of nodes' worth at the limit, and a
    /// user who needs more than 25 steps back wants Revert.
    private static let maxUndoDepth = 25

    var canUndo: Bool { !undoStack.isEmpty }

    /// Captures the current graph so the next mutation can be undone.
    ///
    /// ⚠️ Call BEFORE mutating, never after.
    private func pushUndoSnapshot() {
        undoStack.append(currentLayout())
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
    }

    /// Restores the graph as it was before the last structural mutation.
    ///
    /// ⚠️ Deliberately does NOT restore `hasUnsavedChanges` to false — undoing an edit still leaves
    /// the canvas differing from disk in general, and claiming "saved" here would let the quit guard
    /// wave the user past real unsaved work.
    func undo() {
        guard let previous = undoStack.popLast() else {
            logger.info("[WF_CANVAS] Undo requested with an empty stack for profile \(profileID) — nothing to undo. CONSEQUENCE: the canvas is unchanged.")
            return
        }
        let before = (nodes.count, edges.count, annotations.count)
        nodes = previous.nodes
        edges = previous.edges
        annotations = previous.annotations
        // Selection and the open inspector may point at things that no longer exist.
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

    // MARK: - Viewport

    /// The canvas pane's current size, pushed by `WorkflowCanvasView` on layout.
    ///
    /// ⚠️ Needed HERE because the two things that add nodes — the toolbar and the profile picker
    /// sheet — live OUTSIDE the `GeometryReader` that knows it, so placement cannot ask a proxy.
    /// `@ObservationIgnored`: written on every window resize and read only imperatively by
    /// `nextAvailablePosition()`; observing it would invalidate nothing and cost churn.
    @ObservationIgnored var viewportSize: CGSize = .zero

    /// The canvas-space point currently at the middle of the viewport.
    ///
    /// The view applies `scaleEffect(canvasScale, anchor: .center)` and THEN `.offset(canvasOffset)`
    /// (WorkflowCanvasView.body), so a canvas point p lands on screen at
    /// `center + (p − center)·scale + offset`. Solving for the point at the viewport centre
    /// (screen == center) gives `p = center − offset / scale`. ⚠️ If the view's transform order
    /// ever changes, this inversion must change WITH it — they are the same fact stated twice.
    ///
    /// The fallback covers headless use and the frame before first layout, where the viewport is
    /// still `.zero` — without it a new node's top-left would be computed off a (0,0) "centre" and
    /// land half off-canvas.
    var visibleCanvasCenter: CGPoint {
        guard viewportSize.width > 0, viewportSize.height > 0, canvasScale > 0 else {
            return CGPoint(x: 400, y: 300)
        }
        return CGPoint(
            x: viewportSize.width / 2 - canvasOffset.width / canvasScale,
            y: viewportSize.height / 2 - canvasOffset.height / canvasScale
        )
    }

    /// The workflow profile this state belongs to.
    ///
    /// ⚠️ Readable so the hosting view can ASSERT it is editing the state for the profile it is
    /// displaying. A mismatch means the canvas is showing one workflow's graph under another's
    /// identity, and the next Save writes the wrong graph to the wrong profile — the defect that
    /// made `WorkflowCanvasView` stop freezing an injected state into `@State`.
    let profileID: UUID
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
        case .trigger:
            // Chevron
            return CGSize(width: 120, height: 50)
        case .action:
            // Integration card (similar footprint to profile)
            return CGSize(width: 200, height: 76)
        }
    }

    // ⚠️ WF-CU10: `nodeColor(for:)` and its static twin were DELETED here. They were a verbatim
    // copy of `WorkflowNodeView.profileColor` that had to agree with it for an edge to match the
    // node it leaves, and this type has no `@Environment` and therefore no theme, so a themed
    // colour cannot be resolved from it. Their only caller was `WorkflowEdgeView`, which owns a
    // theme and now calls `WorkflowNodeKind.identityColor(in:)` directly.

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
        // Wholesale replacement — Revert, a profile switch and discard-unreadable all land here, and
        // any node the inspector was bound to may be gone. Same reason as `removeNode`.
        targetConfigNode = nil
        // ⚠️ MUST clear the undo stack. Its snapshots describe the PREVIOUS graph, and this method is
        // how a different profile's layout arrives — an undo across that boundary would splice one
        // workflow's nodes into another's canvas, which is the WF-CV1 data-loss shape all over again.
        undoStack.removeAll()
        revalidate()
    }

    func currentLayout() -> WorkflowLayout {
        WorkflowLayout(nodes: nodes, edges: edges, annotations: annotations)
    }

    /// The layout to persist under `targetProfileID`, or `nil` if this state does not belong to it.
    ///
    /// ⚠️ EVERY WRITE PATH MUST GO THROUGH THIS, never `currentLayout()` directly.
    /// `WorkflowLayoutStore.save` is an in-place whole-blob upsert with no history, so writing one
    /// workflow's nodes under another's id destroys that workflow's stored graph outright — no undo,
    /// no confirmation, no backup. That is not hypothetical: while `WorkflowCanvasView` froze an
    /// injected state into `@State`, the canvas kept workflow A's state after the displayed profile
    /// became B, and Save wrote A's graph over B's.
    ///
    /// Returning `nil` rather than trapping is deliberate: refusing the write preserves both
    /// graphs and leaves the edits in memory, whereas a crash at the moment of saving would be the
    /// one outcome worse than the bug.
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

    func addNode(from profile: BackendProfileModel, at position: CGPoint? = nil) {
        // ⚠️ WF-CS9 — imageGen is not a supported workflow step (product decision 2026-08-16).
        // The picker no longer offers one, so this should be unreachable. It is here because THIS
        // METHOD IS THE ONLY FUNNEL that puts a `.profile` node on a canvas: `addStructuralNode`
        // cannot build one, there is no drag / drop / paste / duplicate / import path in this
        // directory, and the only other `.profile(...)` construction site is the legacy decoder.
        // A future second caller must not be able to re-open the hole in silence.
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

        // Prevent duplicate profiles on the canvas.
        // ⚠️ Was a bare `return`: the picker row simply did nothing and no log said why.
        guard !nodes.contains(where: { $0.profileID == profile.id }) else {
            logger.notice(
                "[WF_CANVAS] Add SKIPPED for profile '\(profile.displayName)' (\(profile.id)) on "
                + "workflow \(profileID): it is already on the canvas. CONSEQUENCE: no second node "
                + "is created — one profile maps to at most one node."
            )
            return
        }

        pushUndoSnapshot()
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
        pushUndoSnapshot()
        let name = nodes.first(where: { $0.id == nodeID })?.displayName ?? nodeID.uuidString
        let cascaded = edges.filter { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }.count

        // Remove all edges connected to this node
        edges.removeAll { $0.sourceNodeID == nodeID || $0.targetNodeID == nodeID }
        nodes.removeAll { $0.id == nodeID }

        logger.info("[WF_CANVAS] Deleted node '\(name)' (\(nodeID)) and \(cascaded) connected edge(s) from profile \(profileID). CONSEQUENCE: those branches are gone from the in-memory layout; recoverable with Undo (\(undoStack.count) step(s) available) or by Revert, which also discards every other unsaved edit.")

        if selectedNodeID == nodeID { selectedNodeID = nil }
        // ⚠️ The OPEN INSPECTOR must go with the node. Leaving `targetConfigNode` set left a panel
        // on screen bound to a node that no longer exists: its binding fabricated a placeholder
        // (`bindingForNode`'s `?? WorkflowNode(...)` fallback, a fresh UUID per read), so the name
        // box silently changed to the placeholder's, and every subsequent edit hit `replaceNode`'s
        // index guard and was dropped — then Save closed the panel exactly as a successful save
        // would.
        if targetConfigNode?.id == nodeID { targetConfigNode = nil }
        markDirty()
    }

    /// Commits a COMPLETED node drag.
    ///
    /// ⚠️ ONE CALL PER DRAG, which is why one snapshot here is one undo step. `WorkflowNodeView`'s
    /// gesture keeps the in-flight drag in `activeNodeDrag` — a view-space offset applied with
    /// `.offset(dragOffset)`, never a model write — and reaches this only from `.onEnded`
    /// (WorkflowNodeView.swift:309-316).
    ///
    /// ⚠️ Do NOT move the push into the gesture, which is what WF-CS6 was filed as. Besides being
    /// impossible (`pushUndoSnapshot()` is private to this type), a drag that is cancelled — or one
    /// clamped back to its origin by `max(0, …)` — would leave a step whose ⌘Z visibly does nothing,
    /// the defect `replaceNode` guards against below. Worse, every NON-gesture mover (auto-layout,
    /// an alignment command, a sticky note's accessibility actions) calls this method rather than
    /// the gesture and would silently get no undo.
    ///
    /// Before this, a drag pushed nothing at all, so ⌘Z after one popped the snapshot from before
    /// some EARLIER, unrelated edit: the node the user had just added vanished while the dragged
    /// node stayed moved (WF-CS6).
    func moveNode(_ nodeID: UUID, to position: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
            // ⚠️ Was a bare `return`. The node can vanish mid-drag: its inspector deletes it, or a
            // revert / clear / profile-switch reloads the canvas while the mouse is still down.
            logger.error(
                "[WF_CANVAS] Node move DROPPED: no node \(nodeID) on the canvas for profile "
                + "\(profileID) (deleted, or the canvas was reverted/cleared/reloaded, while the "
                + "drag was in flight). CONSEQUENCE: the node snaps back to where the drag started, "
                + "nothing is pushed to the undo stack, and the canvas is left unchanged."
            )
            return
        }
        // A drag that lands where it began is not an edit. REACHABLE, not theoretical: the gesture
        // clamps with `max(0, …)`, so a node already at x=0 dragged further left ends at the
        // identical point while `minimumDistance: 3` still fires `.onEnded`. Without this it would
        // burn an undo slot on a step ⌘Z cannot show AND mark the canvas unsaved, firing the quit
        // and navigation guards for a change that never happened.
        guard nodes[index].position != position else {
            logger.debug(
                "[WF_CANVAS] Node move for \(nodeID) resolved to its existing position (released "
                + "where it started, or clamped to the canvas edge). CONSEQUENCE: no undo step is "
                + "pushed and the canvas is NOT marked dirty."
            )
            return
        }
        // ⚠️ AFTER both guards. Same rule as `replaceNode`.
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

    /// Why a connection was refused. `nil` from `refuseEdge` means it was created.
    ///
    /// ⚠️ Typed so the refusal can be SHOWN. Every one of these used to be a bare `return false`:
    /// the preview line simply vanished on release with no dialog, no panel entry and no log, and
    /// three different causes were indistinguishable. Worse, the drop-target highlight actively
    /// pulsed the input port as valid throughout the drag — the canvas affirmed "drop here" and
    /// then refused in silence.
    enum EdgeRefusal: Equatable {
        case selfLoop
        case duplicate
        case missingNode
        case wouldCreateCycle

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
            }
        }
    }

    /// The most recent refused connection, for the canvas to surface. Cleared on the next attempt.
    var lastEdgeRefusal: EdgeRefusal?

    /// Whether an edge from `sourceNodeID` to `targetNodeID` would be accepted.
    ///
    /// ⚠️ Used by the DROP-TARGET HIGHLIGHT so the canvas stops promising a connection it will
    /// refuse. Pure — it must not mutate, because it runs during the drag for every candidate node.
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

    func addStickyNote(at position: CGPoint) {
        pushUndoSnapshot()
        let note = StickyNote(position: position)
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
        // ⚠️ Clamp BEFORE comparing, and compare the CLAMPED value. The view's own floor is 100×60
        // but this one is 120×80, so EVERY release between those two floors arrives as a genuine
        // change yet resolves to the size the note already had. Comparing the raw argument would
        // push a snapshot for each of them.
        let clamped = CGSize(width: max(120, size.width), height: max(80, size.height))
        guard annotations[index].size != clamped else {
            logger.debug(
                "[WF_CANVAS] Sticky-note resize for \(noteID) resolved to its existing size "
                + "\(Int(clamped.width))×\(Int(clamped.height)) (released where it started, or "
                + "clamped up to the 120×80 floor). CONSEQUENCE: no undo step is pushed and the "
                + "canvas is NOT marked dirty."
            )
            return
        }
        pushUndoSnapshot()
        annotations[index].size = clamped
        markDirty()
    }

    /// Commits an edit SESSION's text — not a keystroke.
    ///
    /// ⚠️ The granularity is already right and must stay that way: `StickyNoteView` holds the draft
    /// in view-local `@State editText` and reaches this only through `commitText()`, which fires on
    /// focus loss, on a tap out, or on unmount, and only when the text actually changed. So the
    /// snapshot below captures the pre-edit text once per session. WF-CS6 was filed as if this were
    /// per-keystroke; it never has been. The per-keystroke offender is `replaceNode` (WF-CS3).
    func updateStickyNoteText(_ noteID: UUID, text: String) {
        guard let index = annotations.firstIndex(where: { $0.id == noteID }) else {
            // ⚠️ The costliest of these. `commitText()` also runs from `.onDisappear`, which is how
            // starting a run — flipping to the Execution view — tears the canvas down mid-edit.
            // Reaching here means real typed content is gone. Char count only, never the text.
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
        logger.notice("[WF_CANVAS] CLEARED the canvas for profile \(profileID): \(nodes.count) node(s), \(edges.count) edge(s), \(annotations.count) note(s) removed. CONSEQUENCE: the whole graph is gone from memory; recoverable with Undo until the next load, and permanent once saved.")
        nodes.removeAll()
        edges.removeAll()
        annotations.removeAll()
        selectedNodeID = nil
        selectedEdgeID = nil
        selectedAnnotationID = nil
        targetConfigNode = nil
        markDirty()
    }

    /// Discards every unsaved edit, restoring the last-saved layout — the document-level escape,
    /// as against `undo()`'s one-edit-at-a-time.
    ///
    /// ⚠️ UNDOABLE, deliberately. `load(from:)` clears the undo stack (cross-profile safety,
    /// invariant 44), which meant Revert destroyed the unsaved work AND the history that could
    /// have rescued it — the most destructive control on the canvas was the only unrecoverable
    /// one, and it sits one confusion away from the Undo button. Re-arming the stack AFTER the
    /// load is safe precisely because revert is same-profile by construction; a profile switch
    /// reaches `load` directly and still clears.
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

    /// The canvas subtree is going away (WF-CU9).
    ///
    /// ⚠️ Separated from the view's `.onDisappear` so the state half is unit-testable: a SwiftUI
    /// `body`/lifecycle is unreachable from a test in this project, so a bare assignment inside the
    /// modifier would have no coverage at all.
    ///
    /// ⚠️ Nothing else clears this on teardown. The writers that nil `targetConfigNode` are
    /// `undo()`, `load(from:)`, `removeNode` and `clearCanvas` — none of which run when the view
    /// disappears — and THIS OBJECT OUTLIVES THE VIEW (it is resolved from the view model), so the
    /// `targetConfigNode` observer never sees a change either. Left set, the state claims an
    /// inspector is open with no panel behind it, and because `WorkflowNode` is `Hashable` the
    /// value-compared `onChange` would not re-fire on re-selecting the SAME node — that node's
    /// inspector would refuse to reopen.
    func canvasDidDisappear(panelWasOnScreen: Bool) {
        guard targetConfigNode != nil || panelWasOnScreen else { return }
        let name = targetConfigNode?.displayName ?? "unknown"
        let id = targetConfigNode?.id.uuidString ?? "unknown"

        logger.notice(
            "[WF_CANVAS] Node inspector DISMISSED for profile \(profileID) because the canvas was "
            + "torn down (open node '\(name)' \(id); panel on screen: \(panelWasOnScreen)). "
            + "CONSEQUENCE: every inspector field except the node name is buffered in the panel's "
            + "own state until its Save/Done button, so anything edited and NOT YET SAVED IS "
            + "DISCARDED here with no prompt — including a profile node's unsaved profile-detail "
            + "edits. Already-saved values, the node name, and the per-node timeout/retry settings "
            + "are written through live and survive; the canvas graph is untouched. Not dismissing "
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
    /// Condition nodes get their rule labels + fallback.
    /// Profile nodes expose a default output port (empty label) for normal flow
    /// and an "error" port for failure routing.
    func outputPortLabels(for node: WorkflowNode) -> [String] {
        Self.outputPortLabels(for: node)
    }

    /// The one definition of a node's output ports.
    ///
    /// `nonisolated static` so the rename map and `WorkflowValidator` can ask the same question
    /// without a canvas and without the main actor — the validator runs on the executor's actor
    /// during pre-flight. Pure: it reads only `node.kind`. A second copy of this list is exactly
    /// how an edge and its port drift apart.
    nonisolated static func outputPortLabels(for node: WorkflowNode) -> [String] {
        switch node.kind {
        case .condition(let config):
            // Rule labels + the reserved failure port. A Condition cannot fail on its own today,
            // but a CASCADE SKIP activates `error` on any node, so this is what lets a recovery
            // branch hang off a condition whose upstream died.
            return withErrorPort(config.outputPortLabels)

        case .profile, .action:
            return ["", WorkflowEdge.errorPortLabel]

        case .gate(let config):
            // [E1] One output port per option — the user's choice routes to the matching port.
            // ⚠️ The error port matters MOST here: a gate that times out or is cancelled fails with
            // `activePorts == nil`, the driver activates `error`, and before WF61 no edge could
            // leave that port — so an unanswered gate silently killed its whole subtree.
            return withErrorPort(config.options)

        case .code:
            // Default flow + failure routing. A JS error or a cascade skip both activate `error`;
            // without the port there was nowhere for it to go.
            return ["", WorkflowEdge.errorPortLabel]

        case .trigger:
            // Entry-point marker only — never executes, so it has no failure to route.
            return []
        }
    }

    /// Appends the reserved failure port unless a user-authored label already occupies that string.
    ///
    /// ⚠️ De-duplication is not cosmetic. Condition rule labels and Gate options are free text
    /// (alphanumeric), so a user can legitimately name one "error". Emitting it twice would render
    /// two ports at different heights that `firstIndex(of:)` collapses onto one, so an edge drawn
    /// from the lower one would silently address the upper. The validator warns about the collision
    /// separately; this just guarantees the list stays a set.
    nonisolated private static func withErrorPort(_ labels: [String]) -> [String] {
        labels.contains(WorkflowEdge.errorPortLabel) ? labels : labels + [WorkflowEdge.errorPortLabel]
    }

    /// Whether it is safe to replace this canvas from the stored layout.
    ///
    /// ⚠️ The state can outlive the view that shows it — `WorkflowDedicatedView` injects it so
    /// edits survive the Canvas↔Execution flip that a starting run triggers. So `.onAppear` fires
    /// again on a canvas that is already mid-edit, and reloading there would replace the user's
    /// work with the last-saved layout AND clear the dirty flag: the very loss that keeping the
    /// state alive prevents, reintroduced on the way back.
    ///
    /// A freshly created state is clean, so the first load always runs.
    var acceptsDiskReload: Bool { !hasUnsavedChanges }

    // MARK: - Port renaming

    /// Replaces a node and re-points any edges whose output port that edit renamed.
    ///
    /// ⚠️ Every write of an edited node must go through here, not through `nodes[idx] = newValue`.
    /// Edges address their source port by LABEL (`WorkflowEdge.sourcePortLabel`), so renaming a
    /// Condition rule or a Gate option used to strand every edge wired to it: the run skipped the
    /// whole downstream branch, while the canvas kept drawing those edges as if connected (the
    /// port-position lookup falls back to index 0 for an unknown label) and validation reported
    /// nothing. A rename is the most ordinary edit there is — "True"/"False" → "Urgent"/"Routine"
    /// to make the graph readable — and it silently broke the workflow.
    ///
    /// Edges whose port genuinely disappears (a deleted rule) are deliberately LEFT in place
    /// rather than dropped: silently deleting the user's wiring is its own data loss, and
    /// `WorkflowValidator` now reports the dangling port as an error the user can see and fix.
    func replaceNode(id nodeID: UUID, with newNode: WorkflowNode) {
        // ⚠️ AFTER the guard, not before — a refused replace must not leave a no-op step on the
        // undo stack, or ⌘Z appears to do nothing.
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else {
            // ⚠️ Was a bare `return`. This is the seam an inspector's Save writes through, so a
            // silent miss meant the user's whole editing session went nowhere while the panel
            // closed with its normal success animation and nothing reached the log.
            logger.error("[WF_CANVAS] Node edit DISCARDED: no node \(nodeID) on the canvas to replace (it was deleted, or the canvas was reverted/cleared, while its inspector was open). CONSEQUENCE: every change made in that panel is lost. The inspector is now closed when its node disappears, so reaching this means a new path bypassed that.")
            return
        }
        pushUndoSnapshot()
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

    /// Old port label → new port label for an edit of the same node.
    ///
    /// Identity differs by kind, which is why this is not a positional diff everywhere:
    /// `ConditionRule` carries a stable `let id: UUID`, so a rule can be renamed AND reordered in
    /// one edit and still be tracked. Gate options are plain strings with no identity, so they can
    /// only be matched positionally — a rename is tracked, a simultaneous reorder is not, which is
    /// why the validator backstop matters rather than this being the only defence.
    static func portRenameMap(from oldNode: WorkflowNode, to newNode: WorkflowNode) -> [String: String] {
        var map: [String: String] = [:]

        switch (oldNode.kind, newNode.kind) {
        case (.condition(let oldConfig), .condition(let newConfig)):
            let newRulesByID = Dictionary(newConfig.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for oldRule in oldConfig.rules {
                guard let newRule = newRulesByID[oldRule.id], newRule.label != oldRule.label else { continue }
                map[oldRule.label] = newRule.label
            }
            if oldConfig.fallbackLabel != newConfig.fallbackLabel {
                map[oldConfig.fallbackLabel] = newConfig.fallbackLabel
            }

        case (.gate(let oldConfig), .gate(let newConfig)):
            guard oldConfig.options.count == newConfig.options.count else { return [:] }
            for (old, new) in zip(oldConfig.options, newConfig.options) where old != new {
                map[old] = new
            }

        default:
            return [:]
        }

        // A rename INTO a label that still exists on another port would re-point edges onto the
        // wrong branch. Drop those rather than guess.
        let survivingLabels = Set(outputPortLabels(for: newNode))
        return map.filter { oldLabel, _ in !survivingLabels.contains(oldLabel) }
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

    /// Top-left for a newly added node: centred in the CURRENT VIEWPORT, on the nearest free slot.
    ///
    /// ⚠️ This was `(60, 80 + count × 120)` — pure node count in unpanned canvas coordinates. Pan
    /// away from the origin and press Add Node, and the node landed off-screen: the button appeared
    /// to do nothing. Delete a node and the count collided, so a new node could land EXACTLY on top
    /// of an existing one. The position now derives from where the user is LOOKING, probing outward
    /// ring by ring for a slot that overlaps neither a node nor a sticky note.
    ///
    /// Internal (not private) solely for tests — the same widening this codebase already applied to
    /// `resolveExecutableTools`.
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

        // Ring 0 is the centre itself; each ring widens by one slot in every direction. Five rings
        // is 121 candidates — far more slots than fit on any screen, so reaching the fallback means
        // the entire visible area (and a ring beyond it) is genuinely packed.
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

        // Saturated viewport: stagger below by count so successive adds still get DISTINCT
        // positions — the collision this whole function exists to avoid must not return here.
        return CGPoint(x: ideal.x, y: ideal.y + CGFloat(nodes.count + 1) * stepY)
    }

    func markDirty() {
        hasUnsavedChanges = true
        revalidate()
    }

    /// Layouts of every workflow reachable through this canvas's sub-workflow nodes.
    ///
    /// ⚠️ Cached, and refreshed only when the SET of sub-workflow references changes — not on every
    /// edit. `revalidate()` runs from `markDirty()`, i.e. on every node drag and every keystroke in
    /// an inspector; a SwiftData fetch there would be a fetch per keystroke.
    private var nestedLayoutCache: [UUID: WorkflowLayout] = [:]
    private var nestedLayoutCacheKey: Set<UUID> = []

    /// Refreshes `nestedLayoutCache` if this canvas's sub-workflow references changed.
    private func refreshNestedLayoutsIfNeeded() {
        let refs = Set(WorkflowLayoutStore.subWorkflowProfileIDs(in: currentLayout()))
        guard refs != nestedLayoutCacheKey else { return }
        nestedLayoutCacheKey = refs
        nestedLayoutCache = refs.isEmpty
            ? [:]
            : WorkflowLayoutStore.shared.resolveNestedLayouts(from: currentLayout())
    }

    /// Runs the pure validator against the current layout and profile map.
    private func revalidate() {
        refreshNestedLayoutsIfNeeded()
        validationIssues = WorkflowValidator.validate(
            layout: currentLayout(),
            profileMap: resolvedProfileMap,
            availableToolSources: UnifiedToolStore.shared.sources,
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
