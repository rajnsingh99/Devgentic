// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowEditGuard.swift
//  Devgentic
//
//  Guards navigation away from a workflow canvas that has unsaved edits.
//  The active canvas registers its dirty-state + save/discard hooks; navigation
//  sites (conversation switch, interface switch, canvas→execution toggle) route
//  their transition through `attempt(_:)`, which either runs it immediately (when
//  the canvas is clean / not a workflow) or defers it behind a Save / Discard /
//  Cancel confirmation dialog.
//
//  Owned by `MainApplicationViewModel` so every navigation site (sidebar, mode
//  picker, dedicated view) can reach it via `@Environment(MainApplicationViewModel.self)`.
//

import Foundation

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

    /// The workflow profile whose canvas installed the current hooks, or nil when none is
    /// registered.
    ///
    /// ⚠️ Exists so an exit point can tell whether the canvas behind `saveHook` is the SAME canvas
    /// a bulk drain has already persisted (WF-PE1). Without it, quit ran `saveHook()` on top of
    /// `persistDirtyWorkflowCanvases` with no way to know the two were writing the same
    /// `WorkflowLayoutSD` row — which is harmless only for as long as both resolve to one shared
    /// `WorkflowCanvasState`. Recording the identity makes that assumption checkable instead of
    /// assumed, so a future divergence is caught by a log rather than by a user losing a graph.
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
