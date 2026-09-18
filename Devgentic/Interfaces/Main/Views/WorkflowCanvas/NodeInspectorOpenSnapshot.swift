// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NodeInspectorOpenSnapshot.swift
//  Devgentic
//
//  Register INS-2 — what an inspector wrote STRAIGHT THROUGH its `@Binding`, and must put back
//  when the user presses Cancel.
//
//  ⚠️ The write-through is deliberate and stays. `ProfileNodeInspectorView`'s orchestration controls
//  assign into `node.nodeConfig` the moment they change, which is what makes the live canvas rename
//  work, what the 3-second undo coalescing was engineered for, and — crucially — what stops the
//  three close routes that never reach Done (the node vanishing, a second node's inspector
//  superseding this one, and canvas teardown, including the Run auto-flip) from silently discarding
//  an orchestration edit. Buffering those fields in `@State` instead, as the register's own
//  suggested fix proposed, would reintroduce exactly the loss `NodeInspectorPendingCommit` was
//  built to prevent: "set a 300s timeout, press Run" would run on the default.
//
//  So Cancel is given a restore point rather than the fields being deferred. That is option C stated
//  for these fields: a teardown COMMITS, and Cancel is the one explicit discard.
//

import Foundation

struct NodeInspectorOpenSnapshot: Equatable, Sendable {
    let nodeID: UUID
    let displayName: String
    let nodeConfig: WorkflowNodeConfig?

    init(_ node: WorkflowNode) {
        self.nodeID = node.id
        self.displayName = node.displayName
        self.nodeConfig = node.nodeConfig
    }

    /// The node as it was when the panel opened, or `nil` when there is nothing to write.
    ///
    /// Two distinct `nil` cases, and both must be silent no-ops:
    ///
    /// - **The identity no longer matches.** The node was deleted, or the canvas was reverted,
    ///   cleared or reloaded while the panel was open. `bindingForNode` fabricates a placeholder
    ///   with a FRESH uuid on every read in that case, so writing the snapshot back would resurrect
    ///   a node the user removed — or worse, stamp this node's settings onto whatever the binding
    ///   now points at.
    /// - **Nothing actually changed.** The user opened the panel, touched nothing, and pressed
    ///   Cancel. `WorkflowCanvasState.replaceNode`'s own equality guard would refuse that write
    ///   anyway, but deciding it HERE is what makes it testable — and what keeps the log honest
    ///   about which of the two happened.
    ///
    /// ⚠️ Restores only what this panel writes through: the node's name and its per-node config.
    /// `kind` is deliberately untouched — the Profile inspector never edits it, and a Cancel must
    /// not undo a port rename or a config change some other surface made in the meantime.
    nonisolated func restored(into node: WorkflowNode) -> WorkflowNode? {
        guard node.id == nodeID else { return nil }
        var out = node
        out.displayName = displayName
        out.nodeConfig = nodeConfig
        return out == node ? nil : out
    }

    /// Which of the two `nil` cases applies, for the log. Never used to decide anything.
    nonisolated func unchangedOrGoneReason(for node: WorkflowNode) -> String {
        node.id == nodeID
            ? "nothing was changed while the panel was open"
            : "the node is no longer on the canvas — deleted, or the canvas was reverted, cleared or reloaded"
    }
}
