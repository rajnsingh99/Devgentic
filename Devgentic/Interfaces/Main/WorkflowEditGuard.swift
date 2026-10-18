// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowEditGuard.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Guards navigation away from a workflow canvas with unsaved edits: the canvas registers its dirty state and
/// save/discard hooks. Navigation sites route through `attempt(_:)`, which runs at once when clean or defers behind
/// a Save / Discard / Cancel dialog.
@Observable @MainActor
final class WorkflowEditGuard {

    /// Mirrored from the active `WorkflowCanvasState.hasUnsavedChanges`. Drives the
    /// dirty dot on the Workflow tab and decides whether `attempt` defers.
    var hasUnsavedChanges: Bool = false

    /// True while the Save / Discard / Cancel confirmation dialog is shown.
    var isPrompting: Bool = false

    /// Hooks installed by the active `WorkflowCanvasView`. `save` persists the
    /// layout; `discard` reverts to the last-saved snapshot. `@ObservationIgnored`
    /// because they're plumbing, not observable UI state.
    @ObservationIgnored var saveHook: (() -> Void)?
    @ObservationIgnored var discardHook: (() -> Void)?

    /// The workflow profile whose canvas installed the current hooks, or nil when none is registered. Lets an exit
    /// point tell whether the canvas behind `saveHook` is the one a bulk drain already persisted.
    @ObservationIgnored private(set) var registeredProfileID: UUID?

    /// The navigation deferred while the prompt is up.
    @ObservationIgnored private var pendingNavigation: (() -> Void)?

    /// Run `navigation` now if the canvas is clean (or none is registered);
    /// otherwise stash it and raise the prompt. Always call nav sites through this.
    func attempt(_ navigation: @escaping () -> Void) {
        guard hasUnsavedChanges else {
            navigation()
            return
        }
        pendingNavigation = navigation
        isPrompting = true
    }

    /// Dialog action: save the layout, then proceed with the deferred navigation.
    func confirmSave() {
        saveHook?()
        proceed()
    }

    /// Dialog action: discard edits (revert to last-saved), then proceed.
    func confirmDiscard() {
        discardHook?()
        proceed()
    }

    /// Dialog action: stay put — abandon the deferred navigation.
    func cancel() {
        pendingNavigation = nil
        isPrompting = false
    }

    private func proceed() {
        let nav = pendingNavigation
        pendingNavigation = nil
        isPrompting = false
        nav?()
    }

    // MARK: - Canvas registration

    /// Called by the active `WorkflowCanvasView` to (re)install its hooks.
    func register(profileID: UUID, save: @escaping () -> Void, discard: @escaping () -> Void) {
        registeredProfileID = profileID
        saveHook = save
        discardHook = discard
    }

    /// Called when the canvas disappears — clears hooks + dirty state so stale
    /// closures never fire and the tab dot clears.
    func unregister() {
        hasUnsavedChanges = false
        saveHook = nil
        discardHook = nil
        registeredProfileID = nil
    }
}
