// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowAddNodeSheet.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The two-option add flow for profile-backed workflow nodes: "New node" builds a private profile row, "Import from
/// a profile" copies a shared one once and detaches. A node's configuration is scoped to its workflow, with no live
/// link to the shared profile library.
struct WorkflowAddNodeSheet: View {

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Shared library profiles offered for import; must be `sharedProfiles`, since another node's owned row is not a
    /// profile the user has anywhere else.
    let profiles: [BackendProfileModel]
    let workflowProfileID: UUID

    /// Build a new node from scratch. `name` is trimmed and non-empty by the time this fires.
    let onCreateFresh: (ProfileType, String) -> Void
    /// Copy an existing profile into a node-owned row.
    let onImport: (BackendProfileModel) -> Void

    private enum Step { case chooser, fresh, importList }
    @State private var step: Step = .chooser
    @State private var freshType: ProfileType = .agent
    @State private var freshName: String = ""

    private var trimmedFreshName: String {
        freshName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            switch step {
            case .chooser:    chooser
            case .fresh:      freshForm
            case .importList: importList
            }
        }
        .frame(width: 500, height: 500)
        .background(theme.primaryBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if step != .chooser {
                TactileIconButton(
                    icon: "chevron.left",
                    tooltip: "Back",
                    accessibilityLabel: "Back",
                    size: .compact
                ) {
                    step = .chooser
                }
            } else {
                Image(systemName: "plus.square.on.square")
                    .font(theme.fontTitle2)
                    .foregroundStyle(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(headerSubtitle)
                    .font(theme.fontCaption2)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            TactileButton(title: "Cancel", variant: .subtle, size: .compact) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.primaryBackground)
    }

    private var headerTitle: String {
        switch step {
        case .chooser:    return "Add a Node"
        case .fresh:      return "New Node"
        case .importList: return "Import from a Profile"
        }
    }

    private var headerSubtitle: String {
        switch step {
        case .chooser:
            return "This node's settings live in this workflow only."
        case .fresh:
            return "Configure model, prompt, and tools on the canvas after adding."
        case .importList:
            return "Copies the profile once. Later changes to it won't affect this node."
        }
    }

    // MARK: - Chooser

    private var chooser: some View {
        VStack(spacing: 14) {
            AddNodeOptionCard(
                icon: "plus.circle.fill",
                iconColor: theme.accentColor,
                title: "New node",
                detail: "Start from scratch. Create an Agent or Bot and configure its prompt, model, and capabilities on the canvas.",
                action: { step = .fresh }
            )

            AddNodeOptionCard(
                icon: "doc.on.doc.fill",
                iconColor: ProfileType.workflow.displayColor,
                title: "Import from a profile",
                detail: "Start from one of your existing profiles. It is copied into this workflow — the original remains untouched.",
                action: { step = .importList }
            )

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Fresh

    private var freshForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Name Field
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundStyle(theme.primaryText)

                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)

                    TextField(
                        "",
                        text: $freshName,
                        prompt: Text("e.g. Summarizer or Research Agent").foregroundColor(theme.placeholderText)
                    )
                    .textFieldStyle(.plain)
                    .font(theme.fontFootnote)
                    .foregroundStyle(theme.primaryText)
                    .onSubmit {
                        if !trimmedFreshName.isEmpty {
                            onCreateFresh(freshType, trimmedFreshName)
                            dismiss()
                        }
                    }

                    if !freshName.isEmpty {
                        Button {
                            freshName = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .accessibilityLabel("Clear node name")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(theme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.dividerColor.opacity(0.35), lineWidth: 1)
                )
            }

            // Type Selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Type")
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundStyle(theme.primaryText)

                VStack(spacing: 8) {
                    NodeTypeSelectCard(
                        type: .agent,
                        isSelected: freshType == .agent,
                        title: "Agent",
                        subtitle: "Can use tools, skills, and autonomous execution"
                    ) {
                        freshType = .agent
                    }

                    NodeTypeSelectCard(
                        type: .bot,
                        isSelected: freshType == .bot,
                        title: "Bot",
                        subtitle: "Conversation only for prompt processing and Q&A"
                    ) {
                        freshType = .bot
                    }
                }
            }

            Spacer()

            // Footer
            HStack {
                Spacer()
                TactileButton(
                    title: "Add Node",
                    icon: "plus",
                    variant: .primary,
                    size: .regular,
                    isDisabled: trimmedFreshName.isEmpty
                ) {
                    onCreateFresh(freshType, trimmedFreshName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Import

    private var importList: some View {
        WorkflowProfilePickerView(
            profiles: profiles,
            workflowProfileID: workflowProfileID,
            showsHeader: false,
            showsFooter: false,
            onSelect: { profile in
                onImport(profile)
                dismiss()
            }
        )
    }
}

// MARK: - Option Card (Chooser)

private struct AddNodeOptionCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconColor.opacity(isHovered ? 0.20 : 0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(theme.fontHeadline)
                        .foregroundStyle(theme.primaryText)
                    Text(detail)
                        .font(theme.fontCaption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isHovered ? theme.accentColor : theme.tertiaryText)
                    .padding(.top, 10)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHovered ? theme.accentColor.opacity(0.4) : theme.dividerColor.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: isHovered ? theme.shadowColor.opacity(0.12) : .clear, radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Node Type Select Card

private struct NodeTypeSelectCard: View {
    let type: ProfileType
    let isSelected: Bool
    let title: String
    let subtitle: String
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    private var color: Color {
        type.displayColor
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(isSelected ? 0.22 : (isHovered ? 0.16 : 0.10)))
                        .frame(width: 36, height: 36)
                    ProfileTypeIcon(type: type, size: 18, color: color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text(subtitle)
                        .font(theme.fontCaption2)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? color : theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.surfaceOverlayStrong : (isHovered ? theme.surfaceOverlay : theme.secondaryBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? color.opacity(0.65) : (isHovered ? theme.dividerColor.opacity(0.4) : theme.dividerColor.opacity(0.25)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}
