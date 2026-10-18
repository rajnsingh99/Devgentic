// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillImportPlan.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// What to do when an imported skill has a name the library already uses: add a version, import as new, or skip.
/// Default: add-a-version when exactly one skill has the name (versions are append-only), skip when several do.
/// Import-as-new is never the default: it creates an unreachable duplicate (skills are addressed by name).
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
    /// Matched on `name`, not `displayName`: `name` is what `load_skill` resolves and what a collision costs.
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
            // Never guess: an update landing in the wrong skill is silent and unrecoverable.
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
