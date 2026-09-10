// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  NodeInspectorPendingCommit.swift
//  Devgentic
//
//  Created on 31/08/26.
//
//  The seam that lets a panel CLOSE commit the profile inspector's buffered edits.
//
//  ⚠️ Phase 2 of node-owned configuration (owner decision: option C — teardown commits, Cancel is
//  the one explicit discard). The profile inspector buffers its profile draft in private view
//  `@State` until Done, but three close routes never go through Done: the node vanishing
//  (`targetConfigNode = nil`), a second node's inspector SUPERSEDING the open one, and canvas
//  teardown — which includes the auto-flip to Execution when the user presses Run, the single most
//  ordinary way to lose freshly typed instructions. Each used to discard the buffer silently.
//
//  The buffer lives where AppKit teardown cannot reach (a struct view's @State inside the panel's
//  NSHostingView), so the view REGISTERS a commit closure here and the three close routes fire it.
//  `ProfileEditBuffer` is a class, so the closure reads the LIVE draft at fire time.
//
//  ⚠️ Done and Cancel must `clear()` BEFORE closing: Done has already saved (firing again would
//  re-save and bump `lastSelected` — the redundant-write regression fixed 2026-08-30), and Cancel
//  is the user explicitly discarding, which the hook must not overrule.
//
//  Tested directly (`NodeInspectorPendingCommitTests`) — the WF-CU9 doctrine: the panel itself
//  needs a real window server, so everything decidable lives in state that does not.
//

import Foundation

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
