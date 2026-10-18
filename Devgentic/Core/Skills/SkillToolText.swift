// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillToolText.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Flattens the values a skill tool prints into text the model reads.
/// A label is app-voice structure (a heading, or a name quoted in a sentence); collapsing stops a name forging a heading.
/// Never for a skill body or bundled file content: the model re-emits those, so collapsing or escaping corrupts code.
enum SkillToolText {

    /// Flattens a value a skill tool renders as a one-line label.
    /// Capped as well as collapsed: several of these values are model-supplied and otherwise unbounded.
    static func label(_ raw: String, limit: Int = 200) -> String {
        let collapsed = raw
            .components(separatedBy: CharacterSet.controlCharacters.union(.newlines))
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
