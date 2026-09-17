// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillDraftStore.swift
//  Devgentic
//
//  In-progress skill edits that survive navigation.
//
//  ## Why this exists rather than a warn-on-leave prompt
//
//  The detail used to be a modal, and a modal forces a decision: you cannot leave without pressing
//  something. Rendering it inline removes that, and the obvious replacement — prompt before
//  navigating away — turns out to be unshippable here. A skill detail can be left SEVEN ways: the
//  Skills sidebar, a library row, the back chevron, ⌘[, the command palette, an ActivityBar tab
//  switch (⌘⌥7), and quit. The tab switch has no seam to intercept, so a prompt-based guard would
//  protect six exits and silently destroy work on the seventh — which is worse than no guard at all,
//  because it teaches the user they are protected.
//
//  ⚠️ THIS IS THE PROFILES ARCHITECTURE, NOT A NEW IDEA. `BackendProfileService.editBuffer` lives on
//  the SERVICE, not in a view, and nothing clears it on a tab switch — so a profile draft already
//  survives every exit. The prompt in `ProfileSidebarListView` exists for the ONE exit that destroys
//  it (`activateEditBuffer` replacing the buffer when a different profile is opened) plus quit. The
//  surviving draft is what makes that guard sufficient; the guard is not what makes the draft safe.
//
//  Keying per SKILL removes even that one case: opening a different skill does not disturb the first
//  skill's draft, so there is nothing to prompt about until memory itself goes away at quit.
//
//  ## What it is not
//
//  ⚠️ NOT persistence, and it must not become it. A draft is unsaved work held for the life of the
//  app run; `SkillStore.addVersion` is the only thing that writes. Persisting drafts would mean a
//  half-typed instruction surviving a crash and looking like a saved version, and versions are
//  append-only and reach every linked profile — the one thing worth being conservative about.
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

    /// Re-baselines against values that changed underneath the editor.
    ///
    /// ⚠️ Only safe to call when the draft is CLEAN. Rebasing a dirty draft would keep the user's
    /// text while moving the baseline under it, so `isDirty` would flip to false and Save would go
    /// disabled with their edits still on screen — the shape that made a similar fix elsewhere
    /// worse than the bug.
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
    ///
    /// ⚠️ Seeded ONCE. A later call returns whatever the user has typed since — that is the entire
    /// point, and re-seeding here would reintroduce the data loss this type removes.
    func draft(for skill: SkillSD) -> SkillDraft {
        if let existing = drafts[skill.id] {
            // The library may have moved on (another window, an agent edit) while this draft sat
            // untouched. Rebasing only when clean keeps the user's work and still shows them
            // current text when they have none of their own.
            existing.rebaseIfClean(description: skill.latestVersion?.skillDescription ?? "",
                                   body: skill.latestVersion?.body ?? "")
            return existing
        }
        let draft = SkillDraft(description: skill.latestVersion?.skillDescription ?? "",
                               body: skill.latestVersion?.body ?? "")
        drafts[skill.id] = draft
        return draft
    }

    /// Drops a skill's draft — after a delete, where keeping it would resurrect text for a skill
    /// that no longer exists.
    func forget(skillID: String) { drafts.removeValue(forKey: skillID) }

    /// Every skill with unsaved edits. Read at quit, which is the one exit where memory goes away.
    var skillIDsWithUnsavedEdits: [String] {
        drafts.filter { $0.value.isDirty }.map(\.key).sorted()
    }

    var hasUnsavedEdits: Bool { drafts.values.contains { $0.isDirty } }

    /// Test seam — drops every draft.
    ///
    /// ⚠️ A SINGLETON THAT SURVIVES A TEST IS SHARED STATE BETWEEN TESTS, which is a defect class
    /// this codebase has already filed against itself. Drafts hold only Strings, so a leaked one
    /// cannot crash anything by itself — but it makes `hasUnsavedEdits` depend on which tests ran
    /// before, which is how a quit-guard test starts passing or failing by execution order.
    func resetForTesting() { drafts.removeAll() }
}
