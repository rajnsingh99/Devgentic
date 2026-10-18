// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NodeInspectorPendingCommit.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The seam that lets a panel close commit the profile inspector's buffered edits.
/// The inspector buffers edits in view `@State`; it registers a commit closure here that the close routes fire.
/// Done and Cancel must `clear()` before closing: Done has already saved and Cancel is an explicit discard.
@MainActor
final class NodeInspectorPendingCommit {

    static let shared = NodeInspectorPendingCommit()

    /// Non-nil while a profile inspector with a commit-worthy buffer is on screen.
    /// Last writer wins — there is exactly one inspector panel.
    private var commit: (() -> Void)?

    /// Whether a commit is currently registered. Observability for logs and tests.
    var hasPendingRegistration: Bool { commit != nil }

    /// Called by the profile inspector when its edit buffer exists.
    func register(_ commit: @escaping () -> Void) {
        self.commit = commit
    }

    /// Called by Done (already saved) and Cancel (explicit discard) BEFORE they close.
    func clear() {
        commit = nil
    }

    /// Called by the three non-Done close routes. Fires at most once per registration —
    /// clearing FIRST makes a re-entrant close (supersede during teardown) a no-op rather
    /// than a double save.
    func commitAndClear() {
        let pending = commit
        commit = nil
        pending?()
    }
}
