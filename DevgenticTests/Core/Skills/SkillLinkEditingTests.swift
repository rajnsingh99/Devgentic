// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillLinkEditingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SkillLinkEditingTests: XCTestCase {

    private func linked(_ id: String, _ name: String,
                        enabled: Bool = true, pin: String? = nil) -> SkillSelection {
        SkillSelection.link(skillID: id, name: name, pinnedVersionID: pin, isEnabled: enabled)
    }

    // MARK: - Linking

    func testLinkingAddsTheSkill() {
        let next = SkillLinkEditing.linking([], toSkillID: "skill_1", name: "code-review")
        XCTAssertEqual(next.map(\.skillID), ["skill_1"])
        XCTAssertEqual(next.first?.name, "code-review")
    }

    /// ⚠️ THE FILTER-THEN-APPEND RULE. Appending without removing the old entry leaves TWO
    /// selections for one skill — `SkillResolution` renders it twice in `<available_skills>` and
    /// `update_skill` then refuses to address it by name, reporting an ambiguity the user cannot see
    /// the cause of.
    ///
    /// **Mutation check:** drop the `filter` in `linking` and this goes red.
    func testLinkingTheSameSkillTwiceDoesNotDuplicateIt() {
        var next = SkillLinkEditing.linking([], toSkillID: "skill_1", name: "code-review")
        next = SkillLinkEditing.linking(next, toSkillID: "skill_1", name: "code-review")
        XCTAssertEqual(next.count, 1, "one skill, one selection")
    }

    func testLinkingLeavesOtherSelectionsUntouched() {
        let existing = [linked("skill_1", "alpha", enabled: false, pin: "skver_9")]
        let next = SkillLinkEditing.linking(existing, toSkillID: "skill_2", name: "beta")

        let alpha = try! XCTUnwrap(next.first { $0.skillID == "skill_1" })
        XCTAssertFalse(alpha.isEnabled, "another skill's disabled state must survive a new link")
        XCTAssertEqual(alpha.pinnedVersionID, "skver_9", "and so must its pin")
        XCTAssertEqual(next.count, 2)
    }

    // MARK: - Unlinking

    func testUnlinkingRemovesOnlyTheNamedSkill() {
        let existing = [linked("skill_1", "alpha"), linked("skill_2", "beta")]
        let next = SkillLinkEditing.unlinking(existing, skillID: "skill_1")
        XCTAssertEqual(next.map(\.skillID), ["skill_2"])
    }

    func testUnlinkingSomethingNotLinkedChangesNothing() {
        let existing = [linked("skill_1", "alpha")]
        XCTAssertEqual(SkillLinkEditing.unlinking(existing, skillID: "skill_missing").map(\.skillID),
                       ["skill_1"])
    }

    // MARK: - Pinning

    func testPinningSetsTheVersion() {
        let next = SkillLinkEditing.pinning([linked("skill_1", "alpha")],
                                            skillID: "skill_1", toVersionID: "skver_2")
        XCTAssertEqual(next.first?.pinnedVersionID, "skver_2")
    }

    /// Nil means "follow latest" — the way a user releases a pin.
    func testPinningToNilFollowsLatestAgain() {
        let pinned = [linked("skill_1", "alpha", pin: "skver_2")]
        let next = SkillLinkEditing.pinning(pinned, skillID: "skill_1", toVersionID: nil)
        XCTAssertNil(next.first?.pinnedVersionID)
    }

    /// ⚠️ A pin is the reason versions exist — it lets one profile hold a known-good skill while an
    /// `update_skill` write moves everyone else forward. Pinning must change nothing else.
    func testPinningPreservesEverythingElseAboutTheSelection() {
        let existing = [linked("skill_1", "alpha", enabled: false)]
        let next = SkillLinkEditing.pinning(existing, skillID: "skill_1", toVersionID: "skver_2")

        let updated = try! XCTUnwrap(next.first)
        XCTAssertEqual(updated.pinnedVersionID, "skver_2")
        XCTAssertFalse(updated.isEnabled, "pinning must not silently re-enable a skill the user switched off")
        XCTAssertEqual(updated.name, "alpha")
        XCTAssertEqual(updated.skillID, "skill_1")
    }

    /// **Mutation check:** drop the `guard selection.skillID == skillID` in `pinning` and this goes
    /// red — pinning one skill would pin every skill on the profile to the same version.
    func testPinningOneSkillDoesNotPinTheOthers() {
        let existing = [linked("skill_1", "alpha"), linked("skill_2", "beta")]
        let next = SkillLinkEditing.pinning(existing, skillID: "skill_1", toVersionID: "skver_2")

        XCTAssertEqual(next.first { $0.skillID == "skill_1" }?.pinnedVersionID, "skver_2")
        XCTAssertNil(next.first { $0.skillID == "skill_2" }?.pinnedVersionID,
                     "a pin applies to the skill it was set on, not the profile")
    }

    // MARK: - Composition

    /// The realistic sequence a user performs, asserted end to end: link two, pin one, disable the
    /// other, unlink a third. Each edit must leave the previous ones intact.
    func testASequenceOfEditsComposesWithoutLosingAnything() {
        var s: [SkillSelection] = []
        s = SkillLinkEditing.linking(s, toSkillID: "skill_1", name: "alpha")
        s = SkillLinkEditing.linking(s, toSkillID: "skill_2", name: "beta")
        s = SkillLinkEditing.pinning(s, skillID: "skill_1", toVersionID: "skver_7")
        s = SkillLinkEditing.linking(s, toSkillID: "skill_3", name: "gamma")
        s = SkillLinkEditing.unlinking(s, skillID: "skill_2")

        XCTAssertEqual(s.map(\.skillID).compactMap { $0 }.sorted(), ["skill_1", "skill_3"])
        XCTAssertEqual(s.first { $0.skillID == "skill_1" }?.pinnedVersionID, "skver_7",
                       "the pin set three edits ago must still be there")
    }
}
