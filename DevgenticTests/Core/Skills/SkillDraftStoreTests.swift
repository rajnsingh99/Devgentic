// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillDraftStoreTests.swift
//  devgenticTests
//
//  ⚠️⚠️ THE PROPERTY THAT REPLACES A MODAL. The skill detail used to be a sheet, which forced a
//  decision on the way out. Inline, it can be left seven ways and one of them — the ⌘⌥7 tab switch —
//  has no seam to intercept, so a prompt-based guard would protect six exits and silently destroy
//  work on the seventh. Holding the draft outside the view makes every navigation exit lossless
//  instead, which is exactly how profiles work: `editBuffer` lives on the service and nothing clears
//  it on a tab switch.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SkillDraftStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var store: SkillStore!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(for: DevgenticSchema.schema,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = SkillStore.shared
        store.setContainerForTesting(container)
        // ⚠️ The draft store is a singleton and outlives this test. Without this, `hasUnsavedEdits`
        // depends on which tests ran before — order-dependent assertions are how a suite starts
        // reporting results that have nothing to do with the code under test.
        SkillDraftStore.shared.resetForTesting()
    }

    override func tearDown() async throws {
        // ⚠️ Drafts FIRST, container second. A draft holds only Strings, but `draft(for:)`
        // dereferences the SkillSD it is handed — so clearing after the container is gone invites
        // exactly the "model instance was destroyed by ModelContext.reset" crash.
        SkillDraftStore.shared.resetForTesting()
        store?.setContainerForTesting(nil); store = nil; container = nil
        try await super.tearDown()
    }

    private func seed(_ name: String, body: String = "Original instructions.") throws -> SkillSD {
        try store.create(name: name, description: "A skill.", body: body).get()
    }

    /// ⚠️ THE WHOLE POINT: leaving and returning must not lose typing. Every navigation exit goes
    /// through this path, so this one assertion covers the sidebar, the tab switch, the palette and
    /// the back chevron at once.
    ///
    /// **Mutation check:** re-seed from the library in `draft(for:)` instead of returning the
    /// existing draft, and this goes red.
    func testADraftSurvivesLeavingAndReturning() throws {
        let skill = try seed("code-review")
        let draft = SkillDraftStore.shared.draft(for: skill)
        draft.body = "Half-typed replacement."

        // Navigating away and back is exactly this: the view is rebuilt and asks for the draft again.
        let afterReturning = SkillDraftStore.shared.draft(for: skill)
        XCTAssertEqual(afterReturning.body, "Half-typed replacement.",
                       "the draft must outlive the view — every navigation exit depends on it")
        XCTAssertTrue(afterReturning.isDirty)
    }

    /// ⚠️ Per SKILL, so opening a different one cannot disturb the first. This is what removes the
    /// need for the prompt profiles have — their buffer IS replaced at this moment, so they must ask.
    func testTwoSkillsKeepSeparateDrafts() throws {
        let a = try seed("alpha"), b = try seed("beta")
        SkillDraftStore.shared.draft(for: a).body = "alpha edit"
        SkillDraftStore.shared.draft(for: b).body = "beta edit"

        XCTAssertEqual(SkillDraftStore.shared.draft(for: a).body, "alpha edit")
        XCTAssertEqual(SkillDraftStore.shared.draft(for: b).body, "beta edit")
    }

    /// ⚠️ A CLEAN draft rebases to what the library now holds — an agent edit or another window
    /// moved it on, and showing stale text would be its own bug.
    func testACleanDraftPicksUpALibraryChange() throws {
        let skill = try seed("rebase-me")
        _ = SkillDraftStore.shared.draft(for: skill)

        _ = try store.addVersion(toSkillWithID: skill.id, description: "A skill.",
                                 body: "Newer instructions.", allowedTools: nil,
                                 files: [], note: "n").get()

        XCTAssertEqual(SkillDraftStore.shared.draft(for: skill).body, "Newer instructions.",
                       "a clean draft must show what the library now holds")
    }

    /// ⚠️⚠️ …but a DIRTY one must NOT. Rebasing under the user's text would keep their words on
    /// screen while moving the baseline, so `isDirty` flips false and Save goes disabled with their
    /// edits still showing — the shape that made a similar "fix" worse than the bug it targeted.
    func testADirtyDraftIsNotRebasedOutFromUnderTheUser() throws {
        let skill = try seed("dont-clobber")
        let draft = SkillDraftStore.shared.draft(for: skill)
        draft.body = "MY unsaved work."

        _ = try store.addVersion(toSkillWithID: skill.id, description: "A skill.",
                                 body: "Someone else's newer text.", allowedTools: nil,
                                 files: [], note: "n").get()

        let after = SkillDraftStore.shared.draft(for: skill)
        XCTAssertEqual(after.body, "MY unsaved work.", "the user's text must survive a library change")
        XCTAssertTrue(after.isDirty, "and must still report dirty, or Save goes disabled with edits on screen")
    }

    /// Quit is the ONE exit that loses a draft, so it is the one place skills are gated.
    func testUnsavedDraftsAreReportedForTheQuitGuard() throws {
        let clean = try seed("clean-one"), dirty = try seed("dirty-one")
        _ = SkillDraftStore.shared.draft(for: clean)
        SkillDraftStore.shared.draft(for: dirty).description = "changed"

        XCTAssertTrue(SkillDraftStore.shared.hasUnsavedEdits)
        XCTAssertEqual(SkillDraftStore.shared.skillIDsWithUnsavedEdits, [dirty.id],
                       "only the dirty one may gate quit — gating on a clean draft would prompt on every quit")
    }

    /// Saving re-baselines, so the editor stops reporting dirt it already wrote.
    func testMarkSavedClearsTheDirtyState() throws {
        let skill = try seed("saves")
        let draft = SkillDraftStore.shared.draft(for: skill)
        draft.body = "new"
        XCTAssertTrue(draft.isDirty)
        draft.markSaved()
        XCTAssertFalse(draft.isDirty)
        XCTAssertTrue(draft.changeNote.isEmpty, "the note belongs to the version just written, not the next one")
    }

    /// A deleted skill's draft must not outlive it, or quit stays gated on work for a skill that
    /// no longer exists.
    func testForgettingDropsTheDraft() throws {
        let skill = try seed("goes-away")
        SkillDraftStore.shared.draft(for: skill).body = "unsaved"
        XCTAssertTrue(SkillDraftStore.shared.hasUnsavedEdits)

        SkillDraftStore.shared.forget(skillID: skill.id)
        XCTAssertFalse(SkillDraftStore.shared.hasUnsavedEdits)
    }
}
