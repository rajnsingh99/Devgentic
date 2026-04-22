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

struct TagManagementSheet: View {

    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(ToastManager.self) private var toastManager

    @State private var tagsSnapshot: [(tag: String, count: Int)] = []
    @State private var editingTag: String? = nil
    @State private var editDraft: String = ""
    @State private var tagPendingDeletion: String? = nil

    @FocusState private var editFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if tagsSnapshot.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(tagsSnapshot, id: \.tag) { entry in
                            tagRow(for: entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            footer
        }
        .frame(minWidth: 440, idealWidth: 460, minHeight: 420, idealHeight: 500)
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
        HStack(spacing: 8) {
            Image(systemName: "number")
                .font(.system(.body, weight: .semibold))
                .foregroundColor(theme.accentColor)
            Text("Manage Tags")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(theme.primaryText)
            Spacer()
            Text("\(tagsSnapshot.count) tag\(tagsSnapshot.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "number.square")
                .font(.system(size: 40))
                .foregroundColor(theme.tertiaryText)
            Text("No tags yet")
                .font(.system(.body, weight: .medium))
                .foregroundColor(theme.primaryText)
            Text("Tag a prompt from its detail view to see it listed here.")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Row

    @ViewBuilder
    private func tagRow(for entry: (tag: String, count: Int)) -> some View {
        let isEditing = editingTag == entry.tag

        HStack(spacing: 10) {
            Image(systemName: "tag")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor.opacity(0.8))
                .frame(width: 14)

            if isEditing {
                TextField("Tag name", text: $editDraft)
                    .textFieldStyle(.plain)
                    .font(theme.fontBody)
                    .focused($editFieldFocused)
                    .onSubmit { commitRename(from: entry.tag) }
            } else {
                Text(entry.tag)
                    .font(theme.fontBody)
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(entry.count) prompt\(entry.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(theme.surfaceOverlay)
                )

            if isEditing {
                Button {
                    cancelEdit()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundColor(theme.secondaryText)
                        .background(Circle().fill(theme.surfaceOverlay))
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .keyboardShortcut(.cancelAction)

                Button {
                    commitRename(from: entry.tag)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundColor(.white)
                        .background(Circle().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(!isRenameValid(from: entry.tag))
                .help("Save")
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    startEdit(for: entry.tag)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundColor(theme.secondaryText)
                        .background(Circle().fill(theme.surfaceOverlay))
                }
                .buttonStyle(.plain)
                .help("Rename across all prompts")
                .accessibilityLabel("Rename tag \(entry.tag)")

                Button {
                    tagPendingDeletion = entry.tag
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .foregroundColor(theme.errorColor)
                        .background(Circle().fill(theme.errorColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Remove from all prompts")
                .accessibilityLabel("Delete tag \(entry.tag)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isEditing ? theme.accentColor.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
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
