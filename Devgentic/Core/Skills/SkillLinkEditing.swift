// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillLinkEditing.swift
//  Devgentic
//
//  The three edits a user can make to a profile's skill links: link, unlink, pin.
//
//  ⚠️⚠️ EXTRACTED BECAUSE THE WRITE PATH HAD NO TEST AT ALL. Linking a skill to a profile is the
//  stated goal of the V6 rewrite, and its only implementation was three closures passed inline to a
//  private method of a SwiftUI view — unreachable from a test, so a regression in any of them would
//  have been invisible until a user lost their links.
//
//  These are the DECISIONS. The persistence around them (sync the open edit buffer, write through
//  the service, rebase only on success) stays in the view, because it is coupled to
//  `BackendProfileService` state rather than to the selection list.
//
//  ⚠️ Every function here returns a NEW array and never mutates in place. `SkillSelection` is a
//  value type carrying a user's own preferences — `isEnabled` and `pinnedVersionID` — and the one
//  rule binding all three edits is that an edit to ONE link must not disturb another.
//

import Foundation

enum SkillLinkEditing {

    /// Links a skill, replacing any existing link to the same skill.
    ///
    /// ⚠️ Filters FIRST, then appends. Appending without the filter would leave two selections for
    /// one skill, which `SkillResolution` would render as a duplicate in `<available_skills>` and
    /// `update_skill` would then refuse to address by name.
    static func linking(_ current: [SkillSelection], toSkillID id: String, name: String) -> [SkillSelection] {
        var next = current.filter { $0.skillID != id }
        next.append(SkillSelection.link(skillID: id, name: name))
        return next
    }

    /// Removes a skill's link, leaving every other selection untouched.
    static func unlinking(_ current: [SkillSelection], skillID: String) -> [SkillSelection] {
        current.filter { $0.skillID != skillID }
    }

    /// Pins one linked skill to a version, or to `nil` meaning "follow latest".
    ///
    /// ⚠️ A pin is the reason versions exist: it is what lets one profile hold a known-good skill
    /// while an `update_skill` write moves everyone else forward. Pinning must therefore change
    /// NOTHING else about the selection — not `isEnabled`, not the name it resolved under.
    static func pinning(_ current: [SkillSelection], skillID: String, toVersionID versionID: String?) -> [SkillSelection] {
        current.map { selection in
            guard selection.skillID == skillID else { return selection }
            var updated = selection
            updated.pinnedVersionID = versionID
            return updated
        }
    }
}
