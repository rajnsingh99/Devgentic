// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileEditBuffer.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Why: a refresh alone must not light Save for an edit the user never made; every run detects live anyway
    // (`LiveModelDetection`), so nothing depends on persisting a refresh.
    /// Whether the draft differs from the last-persisted original, by value comparison.
    /// Detected model measurements are ignored (`ignoringDetectedMeasurements`): pickers re-detect on every open. A real
    /// model change still counts because it changes the model name.
    var isDirty: Bool {
        draft.ignoringDetectedMeasurements() != original.ignoringDetectedMeasurements()
    }

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

    // Why: other surfaces (Tool Library, workflow canvas) persist one facet while an editor is open; without re-basing, Revert
    // restores a stale state and claims a change was discarded when it was not.
    /// Re-baselines `original` onto a snapshot persisted by someone other than this buffer, leaving `draft` untouched.
    /// Unlike `markSaved()` (swallows other pending edits) or `load()` (overwrites the draft), re-basing `original` alone
    /// keeps `isDirty` true if and only if the user still has unsaved work.
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
