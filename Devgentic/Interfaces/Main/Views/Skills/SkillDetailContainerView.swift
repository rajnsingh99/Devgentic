// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillDetailContainerView.swift
//  Devgentic
//
//  One skill, edited in the MAIN CONTENT AREA rather than a modal.
//
//  ## Why this exists
//
//  The detail used to be a `.sheet` presented by `SkillLibraryContainerView`: the sidebar listed
//  skills, the main area listed them AGAIN, and selecting one put a long instruction body into a
//  380pt modal floating over an empty screen. The route already carried everything needed to render
//  inline — the sidebar navigated with the skill's id and the container received it — and then threw
//  it away into a sheet.
//
//  ## ⚠️⚠️ `.id(skillID)` IS THE WHOLE POINT OF THIS FILE
//
//  A sheet gets per-item view identity for free: `.sheet(item:)` tears the content down and rebuilds
//  it when the item changes. Inline, the branch, type and position are identical when the route moves
//  from skill A to skill B, so SwiftUI PRESERVES identity — `@State` survives, `.onAppear` does not
//  re-fire, and `load()` never runs. The editor would still hold A's text while the header said B.
//
//  That is not a cosmetic glitch, it is silent data corruption, and both of it:
//
//    - Pressing Save appends a version to B containing the text the user wrote for A.
//    - `commitDisplayName()` fires on the first focus change and renames B to A's label.
//
//  `.id(skillID)` restores the identity the sheet was providing. Do not remove it, and do not
//  "optimise" it away on the grounds that the view already takes the skill as a parameter — a
//  parameter change is not an identity change.
//
//  ⚠️ Mirrors `ProfileDetailContainerView`, including keeping the island bar visible in the
//  not-found arm: without it, a skill deleted in another window leaves the user on a dead screen
//  with no way back.
//

import SwiftUI

struct SkillDetailContainerView: View {

    let skillID: String

    @Environment(\.appTheme) private var theme
    @Environment(MainViewRouter.self) private var router

    /// ⚠️ Re-read through the store's revision rather than captured once: an edit made here, or a
    /// deletion made in the sidebar, has to invalidate this read too.
    private var skill: SkillSD? {
        _ = SkillStore.shared.revision
        return try? SkillStore.shared.fetchSkill(id: skillID).get()
    }

    var body: some View {
        Group {
            if let skill {
                SkillDetailView(skill: skill)
                    // ⚠️ SEE THE FILE HEADER. This line is what stops skill B's screen editing
                    // skill A's content.
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
