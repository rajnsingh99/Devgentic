// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillCommandSuggestionView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The `/` picker: the skills this profile can invoke by name.
/// Matches `PromptSuggestionView` in row height and keyboard selection, and shows each skill's description.
struct SkillCommandSuggestionView: View {

    let items: [SkillCommandItem]
    /// Names several linked skills share — said here, because a collision removes the choice the
    /// list would otherwise appear to offer. See `SkillCommandOffer.collisionNotes`.
    var collisionNotes: [String] = []
    let query: String
    @Binding var selectedItemID: String?
    let onSelect: (SkillCommandItem) -> Void

    @State private var hoveredItemID: String?
    @Environment(\.appTheme) private var theme

    private let rowHeight: CGFloat = 44
    private let maxListHeight: CGFloat = 220

    var body: some View {
        if items.isEmpty {
            // Empty state rather than a hidden panel, so a `/` with no match does not look like a broken trigger.
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                // Worded "linked to this agent", since the picker is scoped to what this profile can reach.
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
            VStack(alignment: .leading, spacing: 4) {
                ForEach(collisionNotes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.orange)
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8))
                }
                list
            }
        }
    }

    private var list: some View {
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

    private func row(_ item: SkillCommandItem) -> some View {
        let isActive = selectedItemID == item.id || hoveredItemID == item.id
        return HStack(spacing: 8) {
            Image(systemName: "puzzlepiece")
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : theme.secondaryText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    // The skill name with its slash, monospaced; this is what gets typed and may differ from the display name.
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
