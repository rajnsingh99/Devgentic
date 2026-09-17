// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillCommandSuggestionView.swift
//  Devgentic
//
//  The `/` picker: the skills this profile can invoke by name.
//
//  ⚠️ Shaped after `PromptSuggestionView` deliberately — same row height, same keyboard selection
//  contract, same scroll-to-selection. Three pickers that behave differently in the same composer is
//  three things for a user to learn about one text field.
//
//  ⚠️ It shows the skill's DESCRIPTION, which is the text the model routes on. The user picking from
//  this list and the model deciding whether the skill fits are reading the same sentence, so a
//  description that reads badly here is one that routes badly there.
//

import SwiftUI

struct SkillCommandSuggestionView: View {

    let items: [SkillCommandItem]
    let query: String
    @Binding var selectedItemID: String?
    let onSelect: (SkillCommandItem) -> Void

    @State private var hoveredItemID: String?
    @Environment(\.appTheme) private var theme

    private let rowHeight: CGFloat = 44
    private let maxListHeight: CGFloat = 220

    var body: some View {
        if items.isEmpty {
            // ⚠️ An EMPTY STATE, not a hidden panel. `/` with no match means either a typo or a
            // library with nothing linkable; silently showing nothing reads as the trigger being
            // broken, which is the complaint that started this feature.
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                // ⚠️ "Linked to this agent", not "in the library". The picker is scoped to what
                // this profile can actually reach, so a full library with nothing linked here is
                // the common case — and pointing at the library's contents would send the user
                // looking for a problem that is not there.
                Text(query.isEmpty
                     ? "No skills linked to this agent — link one in the Skills library."
                     : "No linked skill matches '\(query)'.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            Button { onSelect(item) } label: { row(item) }
                                .buttonStyle(.plain)
                                .id(item.id)
                                .onHover { hovering in
                                    withAnimation(.easeInOut(duration: 0.1)) {
                                        hoveredItemID = hovering ? item.id : nil
                                    }
                                }
                            if items.last?.id != item.id {
                                Divider().padding(.leading, 40)
                            }
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(items.count) * rowHeight, maxListHeight))
                .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(theme.secondaryText.opacity(0.15), lineWidth: 1)
                )
                // Keyboard selection has to drag the list with it, or arrowing past the visible
                // rows moves an invisible cursor.
                .onChange(of: selectedItemID) { _, new in
                    guard let new else { return }
                    withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private func row(_ item: SkillCommandItem) -> some View {
        let isActive = selectedItemID == item.id || hoveredItemID == item.id
        return HStack(spacing: 8) {
            Image(systemName: "puzzlepiece")
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : theme.secondaryText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    // ⚠️ The NAME with its slash, monospaced — this is what gets typed into the
                    // message, and it is not always the display name.
                    Text("/\(item.name)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.primaryText)
                    if item.displayName != item.name {
                        Text(item.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Text(item.description)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(isActive ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
    }
}
