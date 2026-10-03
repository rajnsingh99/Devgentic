// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowToolbarView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Modern Floating UI overlay for the workflow canvas.
//  Provides add-node, zoom controls, context actions, and save states in glassmorphic capsules.
//

import SwiftUI

struct WorkflowToolbarView: View {
    var canvasState: WorkflowCanvasState
    let onAddProfile: () -> Void
    let onAddStructuralNode: (WorkflowNodeKind, String) -> Void
    let onClearCanvas: () -> Void
    let onShowGuideline: () -> Void
    let onSave: () -> Void
    let onRevert: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var showNodePalette = false

    var body: some View {
        VStack {
            // Top Action Area
            HStack(alignment: .top) {
                // Top Left: Add Profile & Status
                VStack(alignment: .leading, spacing: 10) {
                    ToolbarPillButton(title: "Add Node", icon: "plus", isPrimary: true) {
                        showNodePalette = true
                    }
                    .popover(isPresented: $showNodePalette, arrowEdge: .bottom) {
                        nodePaletteContent
                    }

                    statusGroup

                    // Validation errors indicator
                    if !canvasState.validationErrors.isEmpty {
                        ToolbarPillButton(
                            // ⚠️ [CVV-8] TWO KEYS, not one with a concatenated plural letter. The
                            // old form built `"\(n) error" + ("" or "s")` as a Swift String, which
                            // was both unextractable AND unpluralizable — the "s" would arrive as a
                            // `%@` argument no translator can inflect. Written as two
                            // `LocalizedStringKey` literals, the Int interpolation emits `%lld`, so
                            // a translator can attach per-language plural variations to the second
                            // key. Same reasoning as `WorkflowCanvasState.accessibilityDescription`.
                            title: canvasState.validationErrors.count == 1
                                ? "1 error"
                                : "\(canvasState.validationErrors.count) errors",
                            icon: "exclamationmark.triangle.fill",
                            color: .red
                        ) {
                            canvasState.showValidationPanel.toggle()
                        }
                    }
                }

                Spacer()

                // Top Right: Contextual Actions
                HStack(spacing: 8) {
                    // The in-app workflow manual — one place for every node's behaviour, including
                    // the unattended (scheduled / chat-bridge) differences a canvas cannot show.
                    ToolbarPillButton(
                        title: "Guide",
                        icon: "book.closed",
                        color: theme.secondaryText
                    ) {
                        onShowGuideline()
                    }

                    // ⚠️ A VISIBLE undo affordance, not just ⌘Z. The canvas has no autosave and no
                    // focus model, so a user who deletes a node by mistake needs a control they can
                    // see — and if the Delete KEY turns out not to fire (no focusable content in
                    // this hierarchy), the toolbar is the only path in and must be the way back out.
                    if canvasState.canUndo {
                        ToolbarPillButton(
                            title: "Undo",
                            icon: "arrow.uturn.backward",
                            color: theme.secondaryText
                        ) {
                            canvasState.undo()
                        }
                    }

                    if canvasState.selectedNodeID != nil || canvasState.selectedEdgeID != nil || canvasState.selectedAnnotationID != nil {
                        ToolbarPillButton(
                            title: "Delete",
                            icon: "trash",
                            color: .red
                        ) {
                            canvasState.deleteSelected()
                        }
                    }

                    // [CVV-9] Annotations are CONTENT — the same widening the empty-state placard
                    // got. Gated on nodes alone, a canvas holding only sticky notes offered no Clear
                    // pill even though `clearCanvas()` removes the notes (and the alert this pill
                    // opens says so in as many words).
                    if !WorkflowCanvasView.showsEmptyPlacard(
                        nodeCount: canvasState.nodes.count,
                        annotationCount: canvasState.annotations.count
                    ) {
                        ToolbarPillButton(
                            title: "Clear",
                            icon: "arrow.uturn.backward.square",
                            color: theme.secondaryText
                        ) {
                            onClearCanvas()
                        }
                    }
                }
            }

            Spacer()

            // Bottom Action Area
            HStack(alignment: .bottom) {
                // Bottom Left: Zoom Controls
                zoomGroup

                Spacer()

                // Bottom Right: Save / Revert Status
                if canvasState.hasUnsavedChanges {
                    saveRevertGroup
                } else if !WorkflowCanvasView.showsEmptyPlacard(
                    nodeCount: canvasState.nodes.count,
                    annotationCount: canvasState.annotations.count
                ) {
                    // [CVV-9] Same widening: a saved notes-only canvas must still confirm it is saved.
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(theme.accentColor)
                        Text("All changes saved")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.surfaceOverlay)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.secondaryText.opacity(0.18), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
        .padding(20)
        // Ensure touches on empty space pass through to the canvas
        .allowsHitTesting(true)
    }

    // MARK: - Components

    private var statusGroup: some View {
        HStack(spacing: 12) {
            statusBadge(icon: "square.on.square", count: canvasState.nodes.count)
            statusBadge(icon: "arrow.right", count: canvasState.edges.count)

            // Validation badge
            if !canvasState.validationErrors.isEmpty {
                Button {
                    canvasState.showValidationPanel.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(canvasState.validationErrors.count)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(theme.errorColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            } else if !canvasState.validationWarnings.isEmpty {
                Button {
                    canvasState.showValidationPanel.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10, weight: .semibold))
                        Text("\(canvasState.validationWarnings.count)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(theme.warningColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceOverlay)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.secondaryText.opacity(0.18), lineWidth: 1)
        )
    }

    private func statusBadge(icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.accentColor)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundColor(theme.primaryText)
    }

    private var zoomGroup: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(icon: "minus", help: "Zoom out") {
                canvasState.zoomOut()
            }

            Text("\(Int(canvasState.canvasScale * 100))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .frame(width: 44, alignment: .center)

            ToolbarIconButton(icon: "plus", help: "Zoom in") {
                canvasState.zoomIn()
            }

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(width: 0.5, height: 14)
                .padding(.horizontal, 2)

            ToolbarIconButton(icon: "arrow.counterclockwise", help: "Reset zoom") {
                canvasState.resetZoom()
            }

        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceOverlay)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.secondaryText.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: theme.shadowColor.opacity(0.08), radius: 3, x: 0, y: 1)
    }

    private var saveRevertGroup: some View {
        HStack(spacing: 8) {
            // "Discard Changes", pairing with "Save Changes" beside it: the bottom-right cluster
            // is DOCUMENT-level (keep or discard everything since the last save), the top cluster
            // is EDIT-level (Undo/Delete/Clear). It was titled "Revert", which read as a sibling of
            // Undo — and confusing the two was unrecoverable until revert became undoable.
            ToolbarPillButton(title: "Discard Changes", icon: "arrow.counterclockwise") {
                onRevert()
            }

            ToolbarPillButton(title: "Save Changes", icon: "checkmark", isPrimary: true) {
                onSave()
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: canvasState.hasUnsavedChanges)
    }

    // MARK: - Node Palette

    private var nodePaletteContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Node")
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
                .padding(.bottom, 4)

            // Profiles
            paletteSection(title: "PROFILES", icon: "person.2", color: theme.accentColor) {
                Button {
                    showNodePalette = false
                    onAddProfile()
                } label: {
                    paletteItem(icon: "person.crop.rectangle.stack", label: "Bot / Agent / Workflow", color: theme.accentColor)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            // Logic
            //
            // ⚠️ [CVV-8] The SECOND argument to `onAddStructuralNode` is the node's PERSISTED
            // `displayName`, not chrome — it must stay an untranslated literal. `WorkflowNodeView`'s
            // `nodeKindLabel` compares `displayName` against "Router" to decide whether to show the
            // rule count, so localizing the palette's "Router" would silently drop that subtitle in
            // every non-English locale. Only the `title:` and `label:` arguments are user-facing
            // copy, which is why only those two took `LocalizedStringKey`. Same for "Code", "Gate"
            // and "Action" below; `icon:` values are SF Symbol names, likewise not copy.
            paletteSection(title: "LOGIC", icon: "arrow.triangle.branch", color: theme.nodeIdentityColor(for: .router)) {
                Button {
                    showNodePalette = false
                    onAddStructuralNode(
                        .condition(ConditionNodeConfig()),
                        "Router"
                    )
                } label: {
                    paletteItem(icon: "arrow.triangle.branch", label: "Router (match → branch)", color: theme.nodeIdentityColor(for: .router))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            // Utility
            paletteSection(title: "UTILITY", icon: "wrench", color: theme.nodeIdentityColor(for: .code)) {
                Button {
                    showNodePalette = false
                    onAddStructuralNode(
                        .code(CodeNodeConfig()),
                        "Code"
                    )
                } label: {
                    paletteItem(icon: "chevron.left.forwardslash.chevron.right", label: "Code / Transform", color: theme.nodeIdentityColor(for: .code))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button {
                    showNodePalette = false
                    onAddStructuralNode(
                        .gate(GateNodeConfig()),
                        "Gate"
                    )
                } label: {
                    paletteItem(icon: "hand.raised", label: "HITL Gate", color: theme.nodeIdentityColor(for: .gate))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button {
                    showNodePalette = false
                    onAddStructuralNode(
                        .action(ActionNodeConfig()),
                        "Action"
                    )
                } label: {
                    paletteItem(icon: "bolt.horizontal.fill", label: "Action (Run a Tool)", color: theme.nodeIdentityColor(for: .action))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            // Annotate
            paletteSection(title: "ANNOTATE", icon: "note.text", color: .yellow) {
                Button {
                    showNodePalette = false
                    // CVC-2: no position — the state centres the note in the current viewport on
                    // a free slot, exactly like Add Node. The count-based formula that lived here
                    // put notes off-screen on a panned canvas and stacked them after a delete.
                    canvasState.addStickyNote()
                } label: {
                    paletteItem(icon: "note.text", label: "Sticky Note", color: .yellow)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    @ViewBuilder
    private func paletteSection(title: LocalizedStringKey, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.secondaryText)
            }
            content()
        }
    }

    private func paletteItem(icon: String, label: LocalizedStringKey, color: Color) -> some View {
        PaletteItemRow(icon: icon, label: label, color: color)
    }
}

private struct PaletteItemRow: View {
    let icon: String
    let label: LocalizedStringKey
    let color: Color
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .font(theme.fontCaption)
                .foregroundStyle(theme.primaryText)
            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? theme.surfaceOverlayStrong : theme.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isHovered ? color.opacity(0.35) : theme.dividerColor.opacity(0.2), lineWidth: 0.5)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Toolbar Pill Button (8pt continuous rounded rectangle with hover)

struct ToolbarPillButton: View {
    /// ⚠️ `LocalizedStringKey`, NOT `String` (register CVV-8). `Text(_: S) where S: StringProtocol`
    /// is `@_disfavoredOverload`, so a `String` VARIABLE binds it and the String Catalog extractor
    /// never sees the value — every one of this button's titles ("Add Node", "Guide", "Undo",
    /// "Delete", "Clear", "Discard Changes", "Save Changes") was passed as a literal and then
    /// rendered through that overload, so none of them was extractable. Taking the key here means
    /// the literals at the call sites bind `Text(_ key: LocalizedStringKey)` instead, with no
    /// change at any call site.
    let title: LocalizedStringKey
    let icon: String?
    var isPrimary: Bool = false
    var color: Color? = nil
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle

    private var isMaterialPrimary: Bool {
        isPrimary && buttonAccentStyle == .themeContrast
    }

    private var isAccentPrimary: Bool {
        isPrimary && buttonAccentStyle == .accent
    }

    // ⚠️ EXTRACTED, EXPLICITLY TYPED, AND THEY MUST STAY THAT WAY. Inline these back into `body`
    // and the Swift 6.3 type checker (Xcode 27) fails the file outright with "unable to type-check
    // this expression in reasonable time" — five nested `Color` ternaries in one literal, three of
    // them through `??`, is past what it will solve. Each annotation below closes one branch of the
    // search. No behaviour changes: every expression is the one that was inline.
    private var iconColor: Color {
        if isMaterialPrimary {
            return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
        } else if isAccentPrimary {
            return theme.accentColor
        }
        return color ?? theme.accentColor
    }

    private var titleColor: Color {
        if isMaterialPrimary {
            return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
        } else if isAccentPrimary {
            return isHovered ? theme.primaryText : theme.primaryText.opacity(0.95)
        }
        return color ?? theme.primaryText
    }

    private var fillColor: Color {
        if isMaterialPrimary {
            return theme.isDark
                ? Color.white.opacity(isHovered ? 1.0 : 0.95)
                : Color(red: 0.12, green: 0.12, blue: 0.14).opacity(isHovered ? 1.0 : 0.95)
        }
        return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay
    }

    private var borderColor: Color {
        if isMaterialPrimary {
            return theme.isDark
                ? Color.white
                : Color(red: 0.12, green: 0.12, blue: 0.14)
        } else if isAccentPrimary {
            return isHovered ? theme.accentColor.opacity(0.55) : theme.secondaryText.opacity(0.18)
        }
        return isHovered ? (color ?? theme.accentColor).opacity(0.45) : theme.secondaryText.opacity(0.18)
    }

    private var shadowColor: Color {
        if isMaterialPrimary {
            return theme.isDark
                ? Color.black.opacity(isHovered ? 0.35 : 0.20)
                : Color.black.opacity(isHovered ? 0.25 : 0.12)
        } else if isAccentPrimary {
            return isHovered ? theme.accentColor.opacity(0.25) : theme.shadowColor.opacity(0.08)
        }
        return isHovered ? theme.shadowColor.opacity(0.18) : theme.shadowColor.opacity(0.08)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(iconColor)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(titleColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: isHovered ? 4 : 2, x: 0, y: 1)
            .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Toolbar Icon Button (with hover scaling)

struct ToolbarIconButton: View {
    let icon: String
    /// ⚠️ `LocalizedStringKey`, NOT `String` (register CVV-8) — `.help(_: S)` has the same
    /// non-localizing `StringProtocol` overload `Text` does, so "Zoom out", "Zoom in" and
    /// "Reset zoom" were passed as literals and then rendered through it, invisible to the
    /// String Catalog extractor.
    let help: LocalizedStringKey
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    init(icon: String, help: LocalizedStringKey = "", action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(isHovered ? theme.accentColor : theme.primaryText)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? theme.surfaceOverlayStrong : Color.clear)
                )
                .scaleEffect(isHovered ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(help)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}
