//
//  ProfileEditBuffer.swift
//  Devgentic
//
//  Created on 27/03/26.
//
//  Single source of truth for profile edit state and dirty tracking.
//  Replaces the dual-tracking system (view-level initialProfileState +
//  service-level cleanSnapshots/hasUnsavedChanges) that caused phantom
//  save buttons and silent profile switches.
//
//  Design:
//    - `original` is a frozen snapshot of the last-persisted state.
//    - `draft` is the working copy the UI binds to.
//    - `isDirty` compares the two — no deferred async, no race conditions.
//    - Advanced config round-trips stay inside `draft` and never
//      pollute the comparison because `original` is never mutated
//      after load.
//

import SwiftUI

/// Observable edit buffer that holds a working copy of a profile alongside
/// the persisted original. All UI edits flow into `draft`; the `isDirty`
/// flag is computed by value comparison against the immutable `original`.
@Observable @MainActor
final class ProfileEditBuffer {

    // MARK: - State

    /// The working copy that UI controls bind to.
    var draft: BackendProfileModel

    /// The last-persisted snapshot. Set on load and after successful save.
    /// Never mutated by UI edits — this is the stable comparison baseline.
    private(set) var original: BackendProfileModel

    /// Whether the draft differs from the last-persisted original.
    /// Computed from value comparison — no Combine pipeline needed.
    var isDirty: Bool { draft != original }

    // MARK: - Init

    /// Creates a buffer pre-loaded with the given profile as both original and draft.
    init(profile: BackendProfileModel) {
        self.original = profile
        self.draft = profile
    }

    // MARK: - Public API

    /// Resets the draft to the original (persisted) state.
    func revert() {
        draft = original
    }

    /// Called after a successful save. Promotes the current draft to the new original.
    func markSaved() {
        original = draft
    }

    /// Replaces both original and draft with a freshly-loaded profile.
    /// Used when switching profiles or after an external reload.
    func load(_ profile: BackendProfileModel) {
        original = profile
        draft = profile
    }
}
