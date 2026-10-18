// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NodeInspectorOpenSnapshot.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// What an inspector wrote straight through its `@Binding`, kept so Cancel can put it back.
/// Closing without Cancel commits the edits; Cancel is the one explicit discard.
struct NodeInspectorOpenSnapshot: Equatable, Sendable {
    let nodeID: UUID
    let displayName: String
    let nodeConfig: WorkflowNodeConfig?

    init(_ node: WorkflowNode) {
        self.nodeID = node.id
        self.displayName = node.displayName
        self.nodeConfig = node.nodeConfig
    }

    /// The node as it was when the panel opened, or nil when there is nothing to write back.
    /// Nil when the identity does not match (node deleted or canvas reloaded) or nothing changed; both are silent no-ops.
    /// Restores only the node's name and per-node config; `kind` is untouched.
    nonisolated func restored(into node: WorkflowNode) -> WorkflowNode? {
        guard node.id == nodeID else { return nil }
        var out = node
        out.displayName = displayName
        out.nodeConfig = nodeConfig
        return out == node ? nil : out
    }

    /// Which of the two nil cases applies, for the log only.
    nonisolated func unchangedOrGoneReason(for node: WorkflowNode) -> String {
        node.id == nodeID
            ? "nothing was changed while the panel was open"
            : "the node is no longer on the canvas — deleted, or the canvas was reverted, cleared or reloaded"
    }
}
