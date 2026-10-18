// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillDraftStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// One skill's in-progress edit.
@Observable @MainActor
final class SkillDraft {

    /// The values as last loaded from the library — what `isDirty` compares against.
    private(set) var loadedDescription: String
    private(set) var loadedBody: String

    var description: String
    var body: String
    var changeNote: String

    init(description: String, body: String) {
        self.loadedDescription = description
        self.loadedBody = body
        self.description = description
        self.body = body
        self.changeNote = ""
    }

    var isDirty: Bool { description != loadedDescription || body != loadedBody }

    /// Re-baselines after a successful write, so the editor stops reporting dirt it already saved.
    func markSaved() {
        loadedDescription = description
        loadedBody = body
        changeNote = ""
    }

    /// Throws away the edits and returns to what the library holds.
    func discard() {
        description = loadedDescription
        body = loadedBody
        changeNote = ""
    }

    // Why: only safe when the draft is clean: rebasing a dirty draft flips `isDirty` and disables Save with edits still on
    // screen.
    /// Re-baselines against values that changed underneath the editor.
    func rebaseIfClean(description newDescription: String, body newBody: String) {
        guard !isDirty else { return }
        loadedDescription = newDescription
        loadedBody = newBody
        self.description = newDescription
        self.body = newBody
    }
}

/// Holds one draft per skill, for the life of the app run.
@Observable @MainActor
final class SkillDraftStore {

    static let shared = SkillDraftStore()

    private var drafts: [String: SkillDraft] = [:]

    private init() {}

    /// The draft for this skill, created from the library on first use.
    /// Seeded once: a later call returns whatever the user has typed since.
    func draft(for skill: SkillSD) -> SkillDraft {
        if let existing = drafts[skill.id] {
            // The library may have moved on (another window, an agent edit) while this draft sat untouched; rebase only when clean,
            // so the user's work is kept.
            existing.rebaseIfClean(description: skill.latestVersion?.skillDescription ?? "",
                                   body: skill.latestVersion?.body ?? "")
            return existing
        }
        let draft = SkillDraft(description: skill.latestVersion?.skillDescription ?? "",
                               body: skill.latestVersion?.body ?? "")
        drafts[skill.id] = draft
        return draft
    }

    /// Drops a skill's draft after a delete, so its text is not resurrected for a skill that is gone.
    func forget(skillID: String) { drafts.removeValue(forKey: skillID) }

    /// Every skill with unsaved edits. Read at quit, which is the one exit where memory goes away.
    var skillIDsWithUnsavedEdits: [String] {
        drafts.filter { $0.value.isDirty }.map(\.key).sorted()
    }

    var hasUnsavedEdits: Bool { drafts.values.contains { $0.isDirty } }

    // Why: a singleton surviving a test is shared state: leaked drafts make `hasUnsavedEdits` depend on test order.
    /// Test seam: drops every draft.
    func resetForTesting() { drafts.removeAll() }
}
