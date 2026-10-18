// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillDetailContainerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

// Why: `.id(skillID)` is required: without it SwiftUI keeps `@State` across skills and Save writes one skill's text into another
/// Edits one skill inline in the main content area, keyed by the route's skill id.
/// Mirrors `ProfileDetailContainerView`, including the island bar in the not-found arm.
struct SkillDetailContainerView: View {

    let skillID: String

    @Environment(\.appTheme) private var theme
    @Environment(MainViewRouter.self) private var router

    /// Re-read through the store's revision so an edit here or a deletion in the sidebar invalidates this read.
    private var skill: SkillSD? {
        _ = SkillStore.shared.revision
        return try? SkillStore.shared.fetchSkill(id: skillID).get()
    }

    var body: some View {
        Group {
            if let skill {
                SkillDetailView(skill: skill)
                    // Resets view identity per skill so one skill's screen never edits another's content.
                    .id(skillID)
            } else {
                VStack(spacing: 0) {
                    DynamicIslandBar(
                        title: "Skill Not Found",
                        icon: "sparkles.rectangle.stack"
                    )
                    ContentNotFoundView(
                        icon: "sparkles.rectangle.stack",
                        title: "Skill Not Found",
                        subtitle: "This skill may have been deleted. Use the back button to return to the library."
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
    }
}
