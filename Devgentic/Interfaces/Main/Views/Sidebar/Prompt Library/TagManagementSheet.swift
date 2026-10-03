// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TagManagementSheet.swift
//  Devgentic
//
//  Created 2026-04-21.
//
//  Global tag-management UI. Until now tags could only be edited inside each
//  prompt's detail view, which meant drift — "dev", "Dev", "development" would
//  accumulate as distinct tags, splitting the sidebar's tag-chip filter.
//  This sheet lists every tag in use with its usage count and offers rename
//  + delete across the whole library.
//

import SwiftUI
import AppKit

struct TagManagementSheet: View {

    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(ToastManager.self) private var toastManager

    @State private var tagsSnapshot: [(tag: String, count: Int)] = []
    @State private var searchQuery: String = ""
    @State private var editingTag: String? = nil
    @State private var editDraft: String = ""
    @State private var tagPendingDeletion: String? = nil

    @FocusState private var editFieldFocused: Bool

    private var filteredTags: [(tag: String, count: Int)] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return tagsSnapshot }
        return tagsSnapshot.filter { $0.tag.lowercased().contains(trimmed) }
    }

    private var totalUsageCount: Int {
        tagsSnapshot.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            searchBar

            if tagsSnapshot.isEmpty {
                emptyState
            } else if filteredTags.isEmpty {
                searchEmptyState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredTags, id: \.tag) { entry in
                            tagRow(for: entry)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .padding(.trailing, 6) // Clearance for overlay scroller
                }
            }

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            footer
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 460, idealHeight: 560)
        .background(theme.primaryBackground)
        .onAppear { reload() }
        .alert(
            "Delete Tag?",
            isPresented: Binding(
                get: { tagPendingDeletion != nil },
                set: { if !$0 { tagPendingDeletion = nil } }
            ),
            presenting: tagPendingDeletion
        ) { tag in
            Button("Delete", role: .destructive) {
                commitDelete(tag: tag)
            }
            Button("Cancel", role: .cancel) {}
        } message: { tag in
            Text("“\(tag)” will be removed from every prompt that uses it. Prompt bodies stay untouched.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "number")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Manage Tags")
                        .font(theme.fontTitle3.weight(.bold))
                        .foregroundColor(theme.primaryText)

                    Text("\(tagsSnapshot.count) \(tagsSnapshot.count == 1 ? "tag" : "tags")")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text("Rename or remove tags across all saved prompts in your library.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 8)

            TactileIconButton(
                icon: "xmark.circle.fill",
                tooltip: "Close (Esc)",
                accessibilityLabel: "Close",
                variant: .subtle,
                size: 26
            ) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)

            TextField(
                "",
                text: $searchQuery,
                prompt: Text("Search tags").foregroundColor(theme.placeholderText)
            )
            .textFieldStyle(.plain)
            .font(theme.fontCaption)
            .foregroundColor(theme.primaryText)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.surfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.surfaceOverlay)
                    .frame(width: 52, height: 52)
                Image(systemName: "tag.slash")
                    .font(.system(size: 24))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
            }
            Text("No tags in library")
                .font(theme.fontFootnote.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text("Assign tags to prompts in their detail view to manage and filter them here.")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
                .lineSpacing(2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 26))
                .foregroundColor(theme.secondaryText.opacity(0.7))
            Text("No tags match “\(searchQuery)”")
                .font(theme.fontFootnote.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Button("Clear Search") {
                searchQuery = ""
            }
            .buttonStyle(.plain)
            .font(theme.fontCaption)
            .foregroundColor(theme.accentColor)
            .pointingHandCursor()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row

    @ViewBuilder
    private func tagRow(for entry: (tag: String, count: Int)) -> some View {
        let isEditing = editingTag == entry.tag

        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 24, height: 24)
                Image(systemName: "tag.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.accentColor)
            }

            if isEditing {
                TextField(
                    "",
                    text: $editDraft,
                    prompt: Text("e.g. documentation").foregroundColor(theme.placeholderText)
                )
                .textFieldStyle(.plain)
                .font(theme.fontFootnote.weight(.semibold))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.surfaceOverlayStrong)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.accentColor.opacity(0.4), lineWidth: 1)
                )
                .focused($editFieldFocused)
                .onSubmit { commitRename(from: entry.tag) }
            } else {
                Text(entry.tag)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text("\(entry.count) \(entry.count == 1 ? "prompt" : "prompts")")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    Capsule().fill(theme.surfaceOverlay)
                )

            if isEditing {
                TactileIconButton(
                    icon: "xmark",
                    tooltip: "Cancel",
                    accessibilityLabel: "Cancel rename",
                    variant: .subtle,
                    size: 24
                ) {
                    cancelEdit()
                }
                .keyboardShortcut(.cancelAction)

                TactileIconButton(
                    icon: "checkmark",
                    tooltip: "Save rename",
                    accessibilityLabel: "Save rename",
                    variant: .primary,
                    size: 24,
                    isEnabled: isRenameValid(from: entry.tag)
                ) {
                    commitRename(from: entry.tag)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                TactileIconButton(
                    icon: "pencil",
                    tooltip: "Rename across all prompts",
                    accessibilityLabel: "Rename tag \(entry.tag)",
                    variant: .secondary,
                    size: 24
                ) {
                    startEdit(for: entry.tag)
                }

                TactileIconButton(
                    icon: "trash",
                    tooltip: "Remove from all prompts",
                    accessibilityLabel: "Delete tag \(entry.tag)",
                    variant: .destructive,
                    size: 24
                ) {
                    tagPendingDeletion = entry.tag
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isEditing ? theme.accentColor.opacity(0.08) : theme.secondaryBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isEditing ? theme.accentColor.opacity(0.35) : theme.dividerColor.opacity(0.25), lineWidth: 0.8)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("\(tagsSnapshot.count) total tags")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                Text("•")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText.opacity(0.5))
                Text("\(totalUsageCount) assignments")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            TactileButton(title: "Done", variant: .primary, size: .compact) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func reload() {
        tagsSnapshot = PromptService.shared.tagUsageCounts()
    }

    private func startEdit(for tag: String) {
        editingTag = tag
        editDraft = tag
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            editFieldFocused = true
        }
    }

    private func cancelEdit() {
        editingTag = nil
        editDraft = ""
    }

    private func isRenameValid(from original: String) -> Bool {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != original else { return false }
        // Allow merging into an existing tag — rename semantics handle dedupe.
        return true
    }

    private func commitRename(from original: String) {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRenameValid(from: original) else { return }
        let touched = PromptService.shared.renameTag(original, to: trimmed)
        if touched > 0 {
            toastManager.show("Renamed on \(touched) prompt\(touched == 1 ? "" : "s")", style: .success)
        } else {
            toastManager.show("Nothing to rename", style: .warning)
        }
        editingTag = nil
        editDraft = ""
        reload()
    }

    private func commitDelete(tag: String) {
        let touched = PromptService.shared.deleteTag(tag)
        if touched > 0 {
            toastManager.show("Removed “\(tag)” from \(touched) prompt\(touched == 1 ? "" : "s")", style: .success)
        } else {
            toastManager.show("Couldn't remove tag", style: .error)
        }
        reload()
    }
}
