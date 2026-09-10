// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    /// Re-baselines `original` onto a snapshot that was persisted by someone OTHER than this
    /// buffer, leaving `draft` — and therefore the user's other in-progress edits — untouched.
    ///
    /// ⚠️ This is not `markSaved()` and the difference is load-bearing. Several surfaces write a
    /// profile to disk while a detail editor is open on it: the Tool Library, the workflow canvas,
    /// the composer's capability chips. What they persist is that ONE facet, not the whole draft.
    /// `markSaved()` would declare the entire draft saved and quietly swallow every other pending
    /// edit; `load()` would overwrite the draft and destroy them outright. Re-basing `original`
    /// alone is the only operation that keeps `isDirty` honest afterwards — it stays true if and
    /// only if the user still has unsaved work.
    ///
    /// ⚠️ Not calling this at all is what made **Revert lie**: `original` kept a tool list that no
    /// longer existed on disk, so Revert restored the editor to a state the save path had already
    /// replaced, and told the user their change was discarded when it was not.
    func rebase(onto persisted: BackendProfileModel) {
        original = persisted
    }

    /// Replaces both original and draft with a freshly-loaded profile.
    /// Used when switching profiles or after an external reload.
    func load(_ profile: BackendProfileModel) {
        original = profile
        draft = profile
    }
}
