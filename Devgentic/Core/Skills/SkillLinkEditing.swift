// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillLinkEditing.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The three edits a user can make to a profile's skill links: link, unlink, pin.
/// Each returns a new array and never mutates in place, so an edit to one link cannot disturb another.
enum SkillLinkEditing {

    /// Links a skill, replacing any existing link to the same skill.
    /// Filters first, then appends, so one skill never has two selections (a duplicate in
    /// `<available_skills>`).
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
    /// Changes nothing else about the selection, such as `isEnabled` or the resolved name.
    static func pinning(_ current: [SkillSelection], skillID: String, toVersionID versionID: String?) -> [SkillSelection] {
        current.map { selection in
            guard selection.skillID == skillID else { return selection }
            var updated = selection
            updated.pinnedVersionID = versionID
            return updated
        }
    }
}
