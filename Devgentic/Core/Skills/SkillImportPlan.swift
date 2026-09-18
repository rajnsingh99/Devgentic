// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillImportPlan.swift
//  Devgentic
//
//  What to do when an imported skill has a name the library already uses.
//
//  ## Why this needed deciding at all
//
//  `SkillStore.create` always inserts. So re-importing a skill you already had — the obvious way to
//  update one — produced a SECOND skill with the same name. That is worse than it sounds, because
//  skills are addressed by NAME at run time: two `code-review`s mean one of them is unreachable by
//  `load_skill`, chosen deterministically but arbitrarily. The user gets a library that looks right
//  and an agent that reads the wrong instructions.
//
//  ## The three outcomes, and why the default is the one it is
//
//    - **Add a version** — the import becomes a new version of the skill already there. Default
//      when exactly one skill has the name, because it is what re-importing almost always means,
//      and because it is REVERSIBLE: versions are append-only, so the previous one is still in the
//      history and still restorable. It also reaches every profile linked to that skill, which is
//      the entire point of the library owning one copy.
//    - **Import as new** — a genuinely different skill that happens to share a name. Available, but
//      never the default: it is the outcome that creates the unreachable-duplicate problem, and
//      there is no delete-and-merge afterwards that restores what the user meant.
//    - **Skip** — leave the library alone.
//
//  ⚠️ When MORE THAN ONE existing skill shares the name, the default is SKIP. There is no
//  defensible way to choose which one to version, and picking arbitrarily would land an update in a
//  skill the user did not mean — the same reasoning that makes `update_skill` refuse on ambiguity.
//
//  ⚠️ A pure decision, deliberately. It used to be implicit in `SkillStore.create` always inserting,
//  which is a decision with no name and no test. Three defects in this feature have come from logic
//  living inside a SwiftUI view or an unconditional write.
//

import Foundation

enum SkillImportResolution: Equatable, Sendable {
    /// Create a brand-new library skill.
    case createNew
    /// Append a version to the skill with this id.
    case addVersion(skillID: String)
    /// Import nothing for this entry.
    case skip
}

enum SkillImportPlan {

    /// What a name collision means, so the UI can say it rather than compute it inline.
    enum Collision: Equatable, Sendable {
        /// No existing skill uses this name.
        case none
        /// Exactly one does — it can be versioned.
        case one(skillID: String, displayName: String, versionCount: Int)
        /// Several do. Nothing can be chosen for the user.
        case several(count: Int)
    }

    /// Classifies an incoming name against what the library already holds.
    ///
    /// Matched on `name`, not `displayName`: `name` is what `load_skill` resolves and what a
    /// collision actually costs. Two skills may share a display label harmlessly.
    static func collision(for name: String, existing: [(id: String, name: String, displayName: String, versionCount: Int)]) -> Collision {
        let matches = existing.filter { $0.name == name }
        switch matches.count {
        case 0: return .none
        case 1:
            let match = matches[0]
            return .one(skillID: match.id, displayName: match.displayName, versionCount: match.versionCount)
        default:
            return .several(count: matches.count)
        }
    }

    /// The resolution to preselect. The user may change it; nothing here is applied without them.
    static func defaultResolution(for collision: Collision) -> SkillImportResolution {
        switch collision {
        case .none:
            return .createNew
        case .one(let skillID, _, _):
            // Reversible, and what re-importing almost always means.
            return .addVersion(skillID: skillID)
        case .several:
            // ⚠️ Never guess. An update landing in the wrong skill is silent and unrecoverable.
            return .skip
        }
    }

    /// One line explaining the situation, in the terms the consequence is felt in.
    static func explanation(for collision: Collision, skillName: String) -> String? {
        switch collision {
        case .none:
            return nil
        case .one(_, let displayName, let versionCount):
            return "'\(displayName)' already uses the name \(skillName) (\(versionCount) version\(versionCount == 1 ? "" : "s")). Adding a version updates it everywhere it is linked; the current version stays in its history."
        case .several(let count):
            return "\(count) skills already use the name \(skillName). Nothing is preselected — an agent addresses skills by name, so importing another would leave some of them unreachable."
        }
    }
}
