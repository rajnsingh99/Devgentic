// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    ///
    /// The RAW gesture translation, because `committedDragPosition` applies no floor — the preview
    /// and the commit agree by having nothing to disagree about.
    ///
    /// ⚠️ IF A BOUND IS EVER REINTRODUCED IT MUST BE APPLIED HERE TOO, never in the views. This one
    /// accessor has FOUR consumers: `WorkflowNodeView`'s and `StickyNoteView`'s `.offset(…)`, and
    /// `outputPortPosition`/`inputPortPosition`, which add it to place an edge's endpoints while
    /// the node moves. Clamping the two views instead — the obvious edit, and it compiles — leaves
    /// the EDGES on the raw translation, so the wires visibly detach from the card and float off
    /// while the card stays pinned: a worse artefact than the bug it fixes. That is register
    /// `CVC-10`; the version of this method that resolved the node's origin to apply a floor is in
    /// the history if it is ever wanted again.
    ///
    /// The id space is shared: `StickyNoteView` drives this same accessor with an annotation id.
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
        case .unsupported: return String(localized: "Unsupported node")
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

    /// Whether the graph this state holds came from a FAILED read.
    ///
    /// ⚠️ Gates the save-time owned-row reconcile. `WorkflowLayoutStore.load(for:)` returns `.empty`
    /// both for "never saved" and "the fetch threw", so a transient failure produces a canvas that
    /// is blank, clean and overlay-free — indistinguishable from a new workflow. Saving that canvas
    /// overwrites the real graph AND hands the reconcile an empty reference set, which hard-deletes
    /// every node configuration for the workflow along with its Keychain credentials. The layout
    /// overwrite is recoverable by re-reading disk; the credentials are not.
    ///
    /// Set by whoever loads this state. Deliberately NOT cleared by `markSaved()` — only a
    /// successful load may clear it, because a save does not make the earlier read any more true.
    private(set) var lastLoadDidFail = false

    /// Records that the layout handed to `load(from:)` came from a failed read.
    func markLoadFailed() {
        lastLoadDidFail = true
        logger.error("[WF_CANVAS] Workflow \(profileID) was loaded from a FAILED read — the canvas may look empty when it is not. CONSEQUENCE: the save-time owned-row reconcile is refused for this state until a load succeeds, so a transient fetch error cannot turn into permanent deletion of this workflow's node configurations and credentials.")
    }

    /// Every profile-row id a node could still come back pointing at — the current graph's, plus
    /// every snapshot still on the undo stack.
    ///
    /// ⚠️ THIS IS WHAT MAKES UNDO SAFE, and it exists because the simpler premise was FALSE. The
    /// save-time reconcile used to collect owned rows against the saved layout alone, on the stated
    /// reasoning that "while a deletion is still undoable, it has not been saved". Saving does not
    /// clear the undo stack — `markSaved()` touches only `initialLayout` and `hasUnsavedChanges`,
    /// and `undoStack.removeAll()` happens only in `load(from:)`. So delete a node, Save, then ⌘Z:
    /// the reconcile had already hard-deleted that node's private profile row AND its Keychain
    /// credential, and the node returned pointing at nothing. Model, instructions, tools and API key
    /// gone, for an entirely ordinary change-your-mind sequence.
    ///
    /// A row therefore survives while ANY undo step could restore a node that references it. The
    /// cost is a deleted node's row lingering until the stack is cleared, after which the next save
    /// collects it — traded against unrecoverable data loss.
    ///
    /// ⚠️ ONLY A RELOAD CLEARS IT. An earlier version of this comment said "a reload or Revert";
    /// Revert does not qualify. `revert()` clears the stack through `load(from:)` and then
    /// deliberately re-arms it with the pre-revert graph (`undoStack = [preRevert]`), so every id
    /// the canvas held a moment earlier is still protected — and it leaves `hasUnsavedChanges`
    /// false, so no save, and therefore no reconcile, runs for that workflow until the user edits
    /// and saves again. The leak is bounded by reopening the canvas, not by Revert.
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

    /// Captures the current graph so the next mutation can be undone.
    ///
    /// ⚠️ Call BEFORE mutating, never after.
    ///
    /// [WF-CS3] `coalescingKey` is `replaceNode`'s node id, and ONLY `replaceNode` passes one. A
    /// live-bound inspector control (`TextField("Node Name", text: $node.displayName)`, in all
    /// five inspectors) calls `replaceNode` once per KEYSTROKE, so pushing unconditionally meant
    /// 25 characters of typing evicted the whole 25-deep undo history — including the accidental
    /// delete the stack exists to protect. A run of calls for the same node within
    /// `undoCoalescingWindow` now shares the ONE snapshot taken at the start of that run; every
    /// other mutating method still calls this with no key, which both pushes unconditionally and
    /// resets the coalescing state, so a structural edit always gets its own undo step and the
    /// next `replaceNode` after it starts a fresh session.
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

    /// Ends the current coalescing run, so the NEXT `replaceNode` on the same node starts a fresh
    /// undo step instead of folding into the one before it.
    ///
    /// ⚠️ Exists for the Profile inspector's Cancel (register INS-2), which RESTORES the node through
    /// the same binding — and therefore the same `coalescingKey` — as the edits it is undoing.
    /// Without this, what ⌘Z does after a Cancel depended on wall-clock timing: inside the 3s window
    /// the restore folded into the pre-edit snapshot and left a no-op step on the stack; outside it,
    /// the snapshot captured the EDITED graph, so ⌘Z re-applied the very edits the user had just
    /// discarded. A discard must be one deliberate step or none.
    func endUndoCoalescingRun() {
        lastCoalescedNodeID = nil
        lastCoalescedAt = nil
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
        // [WF-CS3] The just-popped snapshot is gone; if a coalescing session for the node it
        // covered were left standing, the NEXT `replaceNode` on that node would coalesce into a
        // snapshot that no longer exists on the stack — that edit would become unrecoverable
        // (⌘Z again finds nothing) instead of stepping back to the state Undo just restored.
        lastCoalescedNodeID = nil
        lastCoalescedAt = nil
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

    /// Resolves every profile the validator needs, READ LIVE at each validation.
    ///
    /// ⚠️ A CLOSURE, NOT A STORED SNAPSHOT, and the difference is a blocking false error. This was
    /// `var resolvedProfileMap: [UUID: BackendProfileModel]`, written in exactly one place —
    /// `WorkflowCanvasView.loadLayout()` — and read by `revalidate()`, which runs on every
    /// `markDirty()`. Once a node's configuration became a profile row CREATED AT ADD TIME, that
    /// snapshot was always one row behind: `addNode` -> `markDirty()` -> `revalidate()` looked up a
    /// row minted moments earlier, found nothing, and reported the node's configuration as missing.
    ///
    /// ⚠️ NOT a run refusal, though the issue carries the blocking `.error` severity — verified, and
    /// worth stating because the obvious reading is wrong. `WorkflowExecutor` re-resolves its OWN
    /// profile map from the store at run time and pre-flights against that, so the run proceeded
    /// fine; the canvas's map feeds only the toolbar pill and the validation panel. The symptom was
    /// a permanently-stuck false error badge whose remedy text ("Delete it and add the node again")
    /// reproduces the error when followed.
    ///
    /// ⚠️ It also did NOT clear on reload, as first assumed: `addNode` marks the canvas dirty, and
    /// the old write sat BELOW `loadLayout()`'s `acceptsDiskReload` guard, so every remount returned
    /// before reaching it. (It reached a second path too — a since-deleted convert-on-open migration
    /// minted a row per node — which is why the fix is at the lookup, not at either caller.)
    ///
    /// The same staleness bit the older reference model more quietly (a profile created while the
    /// canvas sat dirty validated as deleted), so this is one fix for both.
    ///
    /// ⚠️ A TEST MUST STILL INSTALL ONE before adding a profile node. The empty default is a safe
    /// starting value, NOT a usable one: `revalidate()`'s tripwire calls `assertionFailure` when it
    /// runs with no lookup installed and a profile node on the canvas, and asserts trap in the debug
    /// configuration tests build under. Assign `profileLookup = { [:] }` for a test that genuinely
    /// wants an empty library. (This comment used to say the opposite.) Production installs it in
    /// `WorkflowCanvasView.loadLayout()`, at every mount and profile switch.
    var profileLookup: () -> [UUID: BackendProfileModel] = { [:] } {
        didSet { profileLookupInstalled = true }
    }

    /// Whether anyone has installed a `profileLookup`.
    ///
    /// ⚠️ Tracked explicitly rather than inferred from the lookup returning empty, because those are
    /// two different states and conflating them makes the tripwire below lie: a workflow whose
    /// profiles genuinely are all missing is a REAL condition the validator must report, not a
    /// programming error. The first version of this check asserted on emptiness and fired inside
    /// tests that were legitimately validating against no profiles at all.
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

    // MARK: - Reveal (CVC-9)

    /// The canvas-space rectangle currently on screen.
    ///
    /// Derived from `visibleCanvasCenter` alone, so the view's transform is still stated exactly
    /// ONCE in this file. `.zero` before first layout, which reads as "nothing is visible" and makes
    /// every containment test below fail closed.
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

    /// The `canvasOffset` that puts canvas point `point` at the centre of the viewport.
    ///
    /// ⚠️ Written as a DELTA off `visibleCanvasCenter` on purpose, so the inversion invariant keeps
    /// holding: `visibleCanvasCenter == c − offset/scale` is the ONE statement of the view's
    /// `scaleEffect(anchor: .center)`-then-`.offset` transform, and restating `viewport/2` here
    /// would make it two. Substituting back proves it:
    /// `offset' = offset − (point − centre)·scale` ⇒ `c − offset'/scale = centre + (point − centre) = point`.
    ///
    /// ⚠️ Deliberately does NOT inherit `visibleCanvasCenter`'s (400, 300) fallback. That fallback
    /// exists to keep a NEW node on screen before first layout; reusing it here would compute a pan
    /// off a zero viewport and then PERSIST it into `canvasOffset` AND `lastOffset`, mis-framing the
    /// canvas the instant real layout arrives. `nil` means "no viewport to centre in".
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

    /// Brings `nodeID` into view by centring the node, and only when it is not already comfortably
    /// on screen. Returns whether the canvas actually moved.
    ///
    /// The validation panel's rows only ever SELECTED the offending node (register CVC-9). On any
    /// graph bigger than the pane that is a tap that appears to do nothing: the selection ring is
    /// drawn on a node the user cannot see, and the panel gives no other way to find it.
    ///
    /// ⚠️ Conditional, not unconditional. Walking a list of eight issues on a small graph would
    /// otherwise re-frame the canvas eight times and destroy the user's spatial map for no
    /// information gain. `revealMargin` matters because the canvas is `.clipped()`: a node flush to
    /// the edge is technically inside the frame while its ports and selection ring are sliced off.
    @discardableResult
    func revealNode(_ nodeID: UUID) -> Bool {
        guard let node = nodes.first(where: { $0.id == nodeID }) else {
            // ⚠️ The CONSEQUENCE names what the CALLER produces, not what this method returns
            // (cold-read finding). The validation row selects FIRST and unconditionally, so the
            // outcome is not "selects nothing" — it is a selection pointing at a node the canvas
            // does not contain, which is exactly the phantom-Delete shape `survivingSelection`
            // fixes on the load path.
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
        // ⚠️ Through `addOffset`, NEVER a bare `canvasOffset =`. `addOffset` also syncs `lastOffset`,
        // and `updateOffset(by:)` computes `lastOffset + translation` — a stale anchor makes the
        // very next one-finger pan snap the canvas back by the reveal's whole distance.
        addOffset(delta: CGSize(
            width: target.width - canvasOffset.width,
            height: target.height - canvasOffset.height
        ))
        return true
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

    /// The position a COMPLETED drag commits to.
    ///
    /// ⚠️⚠️ **THERE IS DELIBERATELY NO FLOOR. A NODE MAY SIT AT ANY COORDINATE, INCLUDING NEGATIVE
    /// ONES ON EITHER AXIS.** (Owner decision, 2026-09-02, superseding the clamp `CVC-6` narrowed
    /// and `CVC-10` made honest.) Do not reintroduce a `max(0, …)` here or anywhere on this path.
    ///
    /// The clamp that used to live here was never a decision — it was residue. A flat `max(0, …)`
    /// in `moveNode` guarded nothing in particular; `CVC-6` narrowed it to "floor only an axis that
    /// STARTED at ≥ 0" because the flat version teleported a legitimately-negative node 310pt
    /// sideways on a drag in which the pointer never moved horizontally. That fixed the teleport
    /// and kept the wall, and the wall contradicted the rest of the canvas three ways:
    ///   • PANNING is unbounded — `updateOffset`/`addOffset` clamp nothing — so the canvas really is
    ///     infinite in all four directions, and only dragging a node was not.
    ///   • PLACEMENT already produces negative coordinates: `nextAvailablePosition` derives from
    ///     `visibleCanvasCenter`, so a node added on a panned canvas lands at x < 0, and the ring
    ///     probe reaches `ideal − 2·step` with no pan at all. The app would CREATE a node where the
    ///     user could never DRAG one.
    ///   • Being origin-conditional made it a ONE-WAY DOOR: a node already negative moved freely
    ///     there, a node at x ≥ 0 could never enter. Two nodes on one canvas, different rules,
    ///     decided by where each happened to be created.
    /// Reported from the field as "the canvas is infinite but this node won't go left any more".
    ///
    /// ⚠️ `CVC-10` is why this function still exists rather than the gesture doing the arithmetic
    /// inline: the drag PREVIEW and this commit must always agree, and they disagreed for months
    /// because the preview carried the raw translation while this floored it. There is nothing to
    /// disagree about today — but if a bound is ever wanted (a "return to content" affordance, a
    /// soft edge), it goes HERE, and `WorkflowCanvasGeometryTests`' preview/commit property test is
    /// what will catch it being applied to only one of the two.
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
        // [CVC-5] The open inspector is not the only thing that can outlive its node — the SELECTION
        // can too, and this method used to stop one field short of it. `undo()` and `clearCanvas()`
        // both clear all three ids for exactly this reason; `load` was the odd one out.
        //
        // A selection id absent from the new graph highlights nothing (every highlight reader
        // iterates existing items) yet still lights the toolbar's Delete pill and arms ⌫, because
        // both test `!= nil` with no membership check. Pressing it deletes NOTHING while pushing an
        // undo snapshot and calling `markDirty()` — so a byte-identical, freshly loaded canvas goes
        // unsaved, the sidebar badge lights, and navigation and quit start prompting. Worst on the
        // Revert path, whose whole design is that the discarded work is exactly ONE ⌘Z away: the
        // no-op snapshot pushes the recovery step to the second ⌘Z.
        pruneSelectionToLoadedLayout(layout)
        // ⚠️ MUST clear the undo stack. Its snapshots describe the PREVIOUS graph, and this method is
        // how a different profile's layout arrives — an undo across that boundary would splice one
        // workflow's nodes into another's canvas, which is the WF-CV1 data-loss shape all over again.
        undoStack.removeAll()
        // [WF-CS3] …and the coalescing token with it. Revert reloads THIS profile's own saved
        // layout, which very plausibly still has a node at the id being coalesced — leaving the
        // token set would make the next `replaceNode` on that node skip pushing a snapshot onto
        // the now-EMPTY stack, so that edit could never be undone at all.
        lastCoalescedNodeID = nil
        lastCoalescedAt = nil
        revalidate()
    }

    /// The selection that SURVIVES a wholesale graph replacement: an id is kept only if the loaded
    /// layout still contains it (register CVC-5).
    ///
    /// ⚠️ NOT an unconditional clear. `load(from:)` is also the ordinary same-workflow reload path
    /// (`WorkflowCanvasView.loadLayout()` on mount and on the Canvas↔Execution flip), which re-reads
    /// the SAME ids — clearing outright would silently drop the user's selection on every benign
    /// remount. The rule is membership, not "a load happened".
    ///
    /// `nonisolated static` and pure so the survivor rule itself is truth-tableable: the caller is
    /// a `@MainActor` method whose effect is three private-ish fields, and this rule IS the fix.
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

    /// Adds a profile-backed node.
    ///
    /// ⚠️ `nodeID` is supplied BY THE CALLER for owned nodes, and that is not a convenience. The
    /// node's private profile row stores `ownerNodeID`, so the id has to exist before the row is
    /// created — the caller mints it, saves the row, then hands the same id here. A default is kept
    /// for the reference-only case (a sub-workflow node, which points at another workflow's canvas
    /// and owns nothing).
    func addNode(from profile: BackendProfileModel, nodeID: UUID = UUID(), at position: CGPoint? = nil) {
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

        // ⚠️ THE ONE-NODE-PER-PROFILE RULE IS GONE (2026-08-29). It existed because a node
        // REFERENCED a shared profile, so two nodes on one profile meant two nodes that edited each
        // other's settings. A node now owns a private profile row of its own, minted per node — so
        // two differently-tuned Summarizer nodes are legal, and were the point of the change.
        //
        // A sub-workflow node is the one kind that still references rather than owns, but adding the
        // same child workflow twice is legitimate too (run it against two different inputs), so no
        // guard is reinstated here for that case either.

        // ⚠️ ALIASING TRIPWIRE. An owned row names the ONE node it belongs to. If a future
        // duplicate/paste path copies a node without also copying its row, two nodes end up sharing
        // one configuration — editing either changes both, and the save-time reconcile deletes the
        // row as soon as EITHER node goes, breaking the survivor. There is no such path today
        // (`addNode` is the only funnel that creates a `.profile` node), so this is a guard against
        // the change that introduces one, reported at the moment it becomes true rather than when
        // the shared row is later collected.
        //
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
    /// returned to where it began — would leave a step whose ⌘Z visibly does nothing, the defect
    /// `replaceNode` guards against below. And any FUTURE non-gesture mover — an auto-layout, an
    /// alignment command, a drag-free accessibility action — would call this method rather than the
    /// gesture and silently get no undo. ⚠️ None of those exists today: `moveNode` has exactly one
    /// call site and so does `moveStickyNote`. An earlier version of this comment asserted the set
    /// was populated, which was never true; the argument stands on the boundary, not the roster.
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
        // A drag that lands where it began is not an edit.
        //
        // ⚠️ ITS DOMINANT TRIGGER IS GONE, and saying so is the point of this note. The gesture used
        // to clamp with `max(0, …)`, so "node at x=0, dragged further left" was a guaranteed no-op
        // that `minimumDistance: 3` still delivered to `.onEnded`. With the floor removed that drag
        // is a real move: one undo step and one `markDirty()` each. Intended — but it means wall
        // drags now churn a 25-deep undo stack and fire the quit/navigation guards, where before
        // they were free.
        //
        // ⚠️ What remains is a drag RETURNED to its exact start. An earlier version of this comment
        // also claimed "every non-gesture mover (auto-layout, an alignment command, a sticky note's
        // accessibility actions)" — none of those exist. `moveNode` has exactly ONE call site
        // (`WorkflowNodeView`'s `.onEnded`), `moveStickyNote` exactly one, and the accessibility
        // actions on both views are select / edit / configure / delete / recolour, none of which
        // moves anything. The guard stays because it is a MODEL boundary — the tests drive it
        // directly, and any future non-gesture mover gets it for free — not because that set is
        // populated today. Without it, such a caller burns an undo slot on a step ⌘Z cannot show
        // AND marks the canvas unsaved for a change that never happened.
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

    /// Bumped on EVERY refusal write, so the banner's self-dismiss timer restarts even when the
    /// same refusal repeats (cold-read finding, 2026-08-31): the banner's `.task` was keyed on
    /// the ENUM VALUE, so miss → retry → miss (identical `.missedDrop` twice — the expected
    /// repeat pattern) never restarted the 3s sleep and the second miss lost its acknowledgment
    /// almost immediately. The view keys its dismiss task on THIS.
    private(set) var edgeRefusalGeneration: Int = 0

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

    /// `nil` position → `nextAvailablePosition()` (register CVC-2). The Add-Note palette item
    /// still carried the retired `(60, 80 + count × 120)` formula that `nextAvailablePosition`'s
    /// own doc names as the defect it replaced — pan away and the new note landed off-screen
    /// (undo armed, canvas dirty, nothing visible), and a delete made the count collide so the
    /// next note stacked exactly on an existing one. Defaulting HERE, not at the call site, means
    /// no future caller can reintroduce the formula without writing it explicitly. The probe
    /// envelope (220×120) is ≥ the default note (180×120), so a slot it declares free is free.
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
        // ⚠️ Clamp BEFORE comparing, and compare the CLAMPED value. The floor now lives in
        // `StickyNote.minimumSize` and the resize handle reads the SAME constant (register CVC-8),
        // so a release arrives already at or above it — but this is the model boundary and must not
        // trust its caller: a sub-floor size can still reach here from a decoded layout (there is no
        // clamp in `StickyNote.init(from:)`) or from a future non-gesture caller. Comparing the RAW
        // argument would push a snapshot for a release that resolves to the size the note already had.
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
        // ⚠️ [CVC-7] The old CONSEQUENCE clause said "permanent once saved". That is FALSE and drifted
        // in the same direction the Clear alert's copy did: `markSaved()` touches only
        // `initialLayout` and `hasUnsavedChanges`, never `undoStack` — which is exactly what
        // `undoRecoverableProfileIDs` exists to protect. The real limit is a RELOAD (`load(from:)`
        // is the one site that clears the stack, reachable only on a clean canvas) or quitting.
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

        case .unsupported:
            // [WF-PE4] The node's real ports are unknown to this build, so none are declared and
            // the edges still DRAW via the index-0 anchor fallback — the user sees the preserved
            // topology. ⚠️ The validator says NOTHING about these edges: its dangling-port rule
            // skips empty-port nodes (the single-implicit-default carve-out), so the executor's
            // whole-run refusal on unsupported nodes is the ONLY backstop. Do not relax that
            // refusal (e.g. into partial runs) without first giving these edges validation cover.
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

    /// The cap on an output-port BADGE, in characters (register CVV-3).
    ///
    /// Derived from the cap the product already commits to for Router rule labels, so every legal
    /// Router label and the reserved `error` port render IN FULL and only Gate free text — which has
    /// no cap at any layer — is shortened. ⚠️ READ from `ConditionNodeConfig.maxLabelLength` rather
    /// than restated: a literal here could drift below the label cap and start truncating labels the
    /// inspector accepts and the validator approves.
    nonisolated static var portBadgeCharacterCap: Int { ConditionNodeConfig.maxLabelLength }

    /// Display text for an output-port badge. PURELY COSMETIC — never a port identity.
    ///
    /// ⚠️ NEVER feed this back into `outputPortLabels`, `withErrorPort` or
    /// `WorkflowEdge.sourcePortLabel`. Two distinct long options can collapse to the same badge
    /// text; that must stay a cosmetic collision, never a merged routing port. Capping at the SOURCE
    /// would be a silent port rename, and port labels are matched by exact string.
    ///
    /// The badge is anchored to the leading edge of the port and grows rightward only, so it can no
    /// longer paint over its OWN card — but `.fixedSize()` means the `Text` always takes its ideal
    /// width, so a view-level `.lineLimit`/`.frame(maxWidth:)` cannot bound it and an unbounded Gate
    /// option ran clear across the neighbouring node's card, icon and input port. Newlines are
    /// flattened first for the same reason: a multi-line badge would grow DOWN over the ports below.
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

    /// Old port label → new port label for an edit of the same node.
    ///
    /// Identity differs by kind, which is why this is not a positional diff everywhere:
    /// `ConditionRule` carries a stable `let id: UUID`, so a rule can be renamed AND reordered in
    /// one edit and still be tracked. Gate options are plain strings with no identity, so renames
    /// are recovered from position + set difference — see `gateRenameMap` for what that can and
    /// cannot distinguish, and why the validator backstop still matters.
    ///
    /// The map is applied SIMULTANEOUSLY: `replaceNode` consults it exactly once per edge, against
    /// the edge's pre-edit label. A shift-rename permutation (Low→High while High→Critical in one
    /// Save) is therefore safe by construction — no entry can contaminate another. [WF-CS1] An
    /// earlier filter here didn't know that: it dropped any entry whose OLD label survives on the
    /// new node, which applied exactly half of every permutation, silently leaving one branch
    /// running on the wrong rule.
    ///
    /// What IS ambiguous — and each gets its own refuse-and-log arm rather than a guess — is:
    /// a NEW label carried by more than one port; an OLD label still carried by an unrenamed
    /// twin (the edge may belong to the keeper); either side being the reserved "error" label,
    /// which counting cannot see because `withErrorPort` de-duplicates it; and any Gate save a
    /// delete may be hiding in, where positional identity itself breaks (see `gateRenameMap`).
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
            // A rename away from a label that another rule KEEPS is equally unowned: the port
            // still exists as a live source, so an edge on it may belong to the keeper. (The
            // divergent-rename check above cannot see this — a keeper never enters the map.)
            let keptLabels = Set(oldConfig.rules.compactMap { rule -> String? in
                guard let newRule = newRulesByID[rule.id], newRule.label == rule.label else { return nil }
                return rule.label
            })
            for (oldLabel, _) in map where keptLabels.contains(oldLabel) {
                map.removeValue(forKey: oldLabel)
                logger.warning("[WF_CANVAS] Port rename from shared label '\(oldLabel)' NOT applied: another rule still carries that label, so an edge on '\(oldLabel)' may belong to it. CONSEQUENCE: those edges stay on the surviving port instead of following the renamed twin.")
            }
            // ⚠️ [WF-CS12] The legacy catch-all's port belongs to the RULE it names — decode
            // guarantees a non-empty `fallbackLabel` names a real rule — so a fallback change is a
            // port rename ONLY for a phantom label naming no rule (pre-normalization data built in
            // memory). Clearing it (new value empty) deletes that phantom port; deletions dangle
            // for the validator, they don't re-point. The old unconditional write here ran AFTER
            // the rules loop and CLOBBERED the rename entry of the very rule the catch-all names —
            // the normal case, since the inspector clears the catch-all on every Save — re-pointing
            // that rule's edges to a nonexistent "" port whenever it was renamed in the same Save.
            if oldConfig.fallbackLabel != newConfig.fallbackLabel,
               !oldConfig.fallbackLabel.isEmpty,
               !newConfig.fallbackLabel.isEmpty,
               !oldConfig.rules.contains(where: { $0.label == oldConfig.fallbackLabel }) {
                map[oldConfig.fallbackLabel] = newConfig.fallbackLabel
            }

        case (.gate(let oldConfig), .gate(let newConfig)):
            map = gateRenameMap(old: oldConfig.options, new: newConfig.options)

        default:
            return [:]
        }

        // The destination filter: a rename whose NEW label is carried by more than one port on the
        // edited node has an ambiguous target — re-pointing would pick a branch by luck. Leave the
        // edge where it is; the validator reports the dangle and the user resolves the duplicate.
        //
        // ⚠️ The reserved failure label gets its own arm, in BOTH directions, because counting
        // cannot see it: `withErrorPort` de-duplicates, so a user rule/option literally named
        // "error" and the reserved failure port collapse into ONE counted label. A rename AWAY from
        // "error" would unwire failure routing (the engine activates that literal on failure and
        // cascade skip); a rename INTO it would make the edge fire on failures too. Both refuse.
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

    /// [WF-CS2] Rename recovery for Gate options, which are plain strings with no identity.
    ///
    /// The old logic abandoned tracking on ANY count change (`guard old.count == new.count else
    /// return [:]`), so renaming an option in the same Save as Add Option, a row delete, or
    /// blanking a row's text (which the save-time `filter { !$0.isEmpty }` then drops) stranded
    /// every edge on the renamed port — while the canvas kept drawing the edge anchored to port
    /// index 0, looking wired to the new label.
    ///
    /// Position is the only anchor, and it is only trustworthy while NOTHING was deleted: the
    /// inspector appends adds at the end and edits text in place, so with zero deletes every
    /// surviving text keeps its exact index. Deletes are what break it — and a delete is NOT
    /// detectable from the count (a delete plus two adds still grows it). So recovery is limited
    /// to what is PROVABLE:
    ///
    ///  - Any DISPLACED survivor (text present in both lists but at a different index) proves a
    ///    delete happened, which invalidates every positional inference → the whole map refuses.
    ///  - Under count GROWTH, a vanished row is trusted as a rename only when a LATER survivor
    ///    still anchors its own index — that survivor proves no delete occurred at or before this
    ///    row. Vanished rows after the last anchored survivor (the suffix) are exactly where
    ///    "renamed the last row" and "deleted the last row, then added" are byte-identical, and
    ///    guessing wrong re-points an edge onto a live WRONG branch — strictly worse than the
    ///    dangling edge the validator reports. Those refuse, and the refusal is logged.
    ///  - At EQUAL count, positional matching keeps its long-shipped semantics (the pre-existing
    ///    zip behaviour): a suffix rename still tracks, accepting the same delete-plus-add
    ///    ambiguity that behaviour always carried.
    ///  - A save that SHRANK is ambiguous everywhere (delete-then-rename is byte-identical to
    ///    rename-then-delete) → no map, logged.
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

    /// Finds the node whose input port is closest to the given point, within the hit radius.
    ///
    /// ⚠️ TRUE NEAREST (register CVV-2). This returned the FIRST in-radius node in array order,
    /// so with two input ports under 40pt apart the winner depended on insertion order — and the
    /// primary-target highlight now derives from this function, so first-match would have pulsed
    /// one node while the drop landed on another.
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

    /// Surfaces an edge drag that ended on empty canvas (register CVV-2).
    ///
    /// The miss used to be the one indistinguishable non-event left on this path: every graph
    /// refusal (cycle/duplicate/self-loop) shows a banner and logs, but a release outside the
    /// accept radius fell through the drop closure — no edge, no banner, no log, and the user
    /// repeated the gesture with no idea what was wrong.
    ///
    /// ⚠️ The abort guard is deliberate: a release back at the source port is the user changing
    /// their mind, and a refusal banner there would punish cancelling.
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
        // ⚠️ Nodes AND annotations (cold-read finding, 2026-08-31): staggered by `nodes.count`
        // alone, two consecutive default-placed sticky notes on a saturated canvas landed at
        // the IDENTICAL point — the exact stacking this function's own doc names as its reason
        // to exist.
        return CGPoint(x: ideal.x, y: ideal.y + CGFloat(nodes.count + annotations.count + 1) * stepY)
    }

    func markDirty() {
        hasUnsavedChanges = true
        revalidate()
    }

    /// Layouts of every workflow reachable through this canvas's sub-workflow nodes.
    ///
    /// ⚠️ Cached, not refetched per edit. `revalidate()` runs from `markDirty()` — every node drag
    /// and every keystroke in an inspector — and `resolveNestedLayouts` walks the whole nesting tree
    /// with a SwiftData fetch and JSON decode per reachable workflow. That is why a cache exists.
    ///
    /// ⚠️ THE KEY IS (REFERENCES, STORE GENERATION), and the second half is load-bearing. It used to
    /// be the reference SET alone — which does not change when a child workflow's CONTENT changes.
    /// Add nodes inside a child, or wire a cycle into it, and this canvas kept validating against
    /// the copy fetched when the reference first appeared, for the rest of the session. The nesting
    /// cycle and depth rules are `.error` severity, so it failed both ways: a graph that had become
    /// cyclic still read "Workflow Ready", and one whose cycle had been REMOVED kept a blocking
    /// error the user could not clear. `WorkflowLayoutStore.writeGeneration` moves on every layout
    /// write, so any edit to any child invalidates this by construction.
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

    /// The tool catalogue the validator's availability arm reads, resolved LIVE at each validation.
    ///
    /// ⚠️ A closure, not a snapshot — same reason as `profileLookup`. It is also the only way the
    /// availability arm is reachable from a test: naming `UnifiedToolStore.shared` here made the arm
    /// depend on a `@MainActor` singleton backed by the real MCP store, which a unit test cannot pose.
    var toolSourceLookup: () -> [ToolSource] = { UnifiedToolStore.shared.sources }

    /// Re-runs validation because the TOOL CATALOGUE changed under an open canvas (register INS-12).
    ///
    /// ⚠️ `revalidate()` READS the catalogue but nothing re-ran it when the catalogue MOVED: its only
    /// callers are `markDirty()`, `undo()` and `load(from:)`. So disabling an MCP server while a
    /// workflow was open left the toolbar pill and the validation panel showing the pre-toggle
    /// verdict until the next graph edit — and this is the ONLY place in the app that availability
    /// arm runs at all (the executor's pre-flight and `WorkflowDedicatedView` both pass no sources),
    /// so that stale window is the user's entire design-time notice of a run that will now fail.
    ///
    /// ⚠️ A re-appear hook would NOT have worked: the canvas lives inside `chatArea`, which
    /// `MainApplicationView` keeps mounted and merely fades to opacity 0, so navigating to the Tool
    /// Library and back fires no `onAppear`.
    func revalidateForToolCatalogChange(generation: Int) {
        // Belt-and-braces: makes "must not trip `revalidate()`'s profile-lookup tripwire" true by
        // construction rather than by argument. The observer cannot fire before the first
        // `onAppear`, but `loadLayout()` has one path that returns before installing the lookup.
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

    /// Forces a validation pass. Test seam only.
    ///
    /// ⚠️ Exists because `revalidate()` is `private` — file-scoped, which `@testable` does not
    /// elevate — and the add-node -> validate SEQUENCE is exactly what went untested while a
    /// blocking false error shipped in it.
    func revalidateForTesting() { revalidate() }

    /// Runs the pure validator against the current layout and profile map.
    private func revalidate() {
        refreshNestedLayoutsIfNeeded()

        // ⚠️ TRIPWIRE. `profileLookup` defaults to `{ [:] }` and is installed in exactly one place
        // (`WorkflowCanvasView.loadLayout()`). A future path that mutates a CACHED state — they
        // outlive their views, see `MainApplicationViewModel.workflowCanvasState(for:)` — before
        // that view has mounted would validate against an empty map and report every profile node
        // as missing its configuration: the same symptom just fixed, at a different entry point.
        // Reported here, where it becomes true, rather than as a mystery badge on the canvas.
        //
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
