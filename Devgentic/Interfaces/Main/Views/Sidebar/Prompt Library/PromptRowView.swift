// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PromptRowView.swift
//  Devgentic
//

import SwiftUI

struct PromptRowView: View {

    let prompt: DevPrompt
    let isSelected: Bool
    let isKeyboardFocused: Bool

    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    /// Stages the prompt into the chat input (outside the sidebar) and
    /// returns to chat. Wired by `PromptLibrarySidebarView`.
    let onUseInChat: () -> Void

    // Batch selection (optional). When `isSelectionMode == true`, the row
    // swaps its tap target to `onToggleBatchSelect` and renders a checkmark
    // circle on the leading edge instead of the normal accent indicator.
    var isSelectionMode: Bool = false
    var isBatchSelected: Bool = false
    var onToggleBatchSelect: () -> Void = {}
    var onEnterSelectionMode: () -> Void = {}

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    /// Built-in prompts can't be deleted — the library ships them as seeds.
    /// Gate all delete affordances at the row level so the user doesn't see
    /// enabled-looking controls that silently fail.
    private var canDelete: Bool { prompt.isUserDefined }

    var body: some View {
        HStack(spacing: 0) {
            if isSelectionMode {
                batchSelectionIndicator
            }
            standardContentView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .sidebarRowBackground(isSelected: isSelected, isHovering: isHovering)
        .overlay(keyboardFocusRing)
        .opacity(isSelectionMode && !canDelete ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onToggleBatchSelect()
            } else {
                onSelect()
            }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            if !isSelectionMode {
                onEnterSelectionMode()
                onToggleBatchSelect()
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovering = hovering
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isSelectionMode)
        .contextMenu {
            Button {
                onUseInChat()
            } label: {
                Label("Use in Chat", systemImage: "arrow.up.forward.app")
            }

            Divider()

            Button {
                onSelect()
            } label: {
                Label("Open", systemImage: "doc.text")
            }

            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }

            Button {
                onTogglePin()
            } label: {
                Label(prompt.isPinned ? "Unpin" : "Pin", systemImage: prompt.isPinned ? "pin.slash" : "pin")
            }

            Divider()

            Button {
                copyPromptText()
            } label: {
                Label("Copy Prompt Text", systemImage: "doc.on.doc")
            }

            // Entry point into batch mode — long-press on a row is the other
            // way in, but this is more discoverable. Hidden on built-ins
            // since they can't be batch-deleted; starting from one would be
            // a dead-end.
            if !isSelectionMode && canDelete {
                Button {
                    onEnterSelectionMode()
                    onToggleBatchSelect()
                } label: {
                    Label("Select Prompts…", systemImage: "checkmark.circle")
                }
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canDelete)
            .help(canDelete ? "Delete this prompt" : "Built-in prompts can't be deleted")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityActions {
            Button("Use in chat") { onUseInChat() }
            Button("Edit") { onEdit() }
            Button(prompt.isPinned ? "Unpin" : "Pin") { onTogglePin() }
            if canDelete {
                Button("Delete") { onDelete() }
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [prompt.title]
        parts.append("in \(prompt.category)")
        if !prompt.isUserDefined { parts.append("built-in") }
        if prompt.isPinned { parts.append("pinned") }
        if isSelected { parts.append("currently open") }
        if isSelectionMode && isBatchSelected { parts.append("selected for batch action") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Batch selection indicator

    /// Renders a checkmark/empty-circle for deletable rows, or a dimmed lock
    /// icon for built-ins (which can't participate in batch delete). The
    /// lock icon is a clearer signal than just graying out the circle,
    /// which users tend to read as "disabled but try again."
    @ViewBuilder
    private var batchSelectionIndicator: some View {
        Group {
            if canDelete {
                Image(systemName: isBatchSelected ? "checkmark.circle.fill" : "circle")
                    .font(theme.fontHeadline)
                    .foregroundColor(isBatchSelected ? theme.accentColor : theme.tertiaryText)
            } else {
                Image(systemName: "lock.fill")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.tertiaryText.opacity(0.7))
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .transition(.scale.combined(with: .opacity))
        .accessibilityHidden(true)  // Parent row label handles announcement.
    }

    // MARK: - Content

    @ViewBuilder
    private var standardContentView: some View {
        HStack(alignment: .top, spacing: 0) {
            // Accent gradient line on left for selected state
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.trailing, 6)
                    .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if prompt.isPinned {
                        Image(systemName: "pin.fill")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.accentColor.opacity(0.85))
                            .rotationEffect(.degrees(45))
                            .accessibilityHidden(true)
                    }

                    Text(prompt.title)
                        .font(theme.fontFootnote.weight(.medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Spacer()

                    // Hover actions take the badge's slot — only one shows at a time.
                    if isHovering {
                        hoverActions
                            .transition(.opacity)
                    } else {
                        categoryBadge
                            .transition(.opacity)
                    }
                }

                Text(prompt.text)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var categoryBadge: some View {
        Text(prompt.category)
            .font(theme.fontCodeCaption.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(theme.accentColor.opacity(0.1))
            .foregroundColor(theme.accentColor.opacity(0.8))
            .clipShape(Capsule())
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            HoverIconButton(
                systemImage: "arrow.up.forward.app",
                help: "Use in chat",
                tint: theme.accentColor,
                action: onUseInChat
            )
            HoverIconButton(
                systemImage: prompt.isPinned ? "pin.slash.fill" : "pin",
                help: prompt.isPinned ? "Unpin" : "Pin",
                action: onTogglePin
            )
            HoverIconButton(
                systemImage: "pencil",
                help: "Edit",
                action: onEdit
            )
            // Delete is omitted entirely for built-ins — disabled-but-visible
            // invites confusion ("why is it there if I can't use it?"). The
            // "Built-in" badge on hover already signals the constraint.
            if canDelete {
                HoverIconButton(
                    systemImage: "trash",
                    help: "Delete",
                    tint: theme.errorColor,
                    action: onDelete
                )
            }
        }
    }

    @ViewBuilder
    private var keyboardFocusRing: some View {
        if isKeyboardFocused && !isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.accentColor.opacity(0.5), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Actions

    private func copyPromptText() {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(prompt.text, forType: .string)
        #endif
    }
}

// MARK: - Hover Icon Button

/// Small inline action button shown on row hover. Kept fileprivate to keep
/// the palette consistent with `PromptRowView`.
private struct HoverIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(theme.fontCaption2.weight(.semibold))
                .frame(width: 20, height: 20)
                .foregroundColor(tint ?? theme.secondaryText)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? theme.surfaceOverlayStrong : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
