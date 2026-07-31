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
    let onSave: () -> Void
    let onRevert: () -> Void
    let onOpenSettings: () -> Void

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
                            title: "\(canvasState.validationErrors.count) error\(canvasState.validationErrors.count == 1 ? "" : "s")",
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
                    if canvasState.selectedNodeID != nil || canvasState.selectedEdgeID != nil || canvasState.selectedAnnotationID != nil {
                        ToolbarPillButton(
                            title: "Delete",
                            icon: "trash",
                            color: .red
                        ) {
                            canvasState.deleteSelected()
                        }
                    }

                    if !canvasState.nodes.isEmpty {
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
                } else if !canvasState.nodes.isEmpty {
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
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
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
                    .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
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

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            ToolbarIconButton(icon: "arrow.counterclockwise", help: "Reset zoom") {
                canvasState.resetZoom()
            }

            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)

            ToolbarIconButton(icon: "gearshape", help: "Workflow settings") {
                onOpenSettings()
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
        .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
    }

    private var saveRevertGroup: some View {
        HStack(spacing: 8) {
            ToolbarPillButton(title: "Revert", icon: "arrow.counterclockwise") {
                onRevert()
            }

            ToolbarPillButton(title: "Save Changes", icon: "checkmark", isPrimary: true) {
                onSave()
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: canvasState.hasUnsavedChanges)
    }

    private func floatingActionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // MARK: Liquid Glass
                .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
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
            }

            // Logic
            paletteSection(title: "LOGIC", icon: "arrow.triangle.branch", color: .yellow) {
                Button {
                    showNodePalette = false
                    onAddStructuralNode(
                        .condition(ConditionNodeConfig()),
                        "Condition"
                    )
                } label: {
                    paletteItem(icon: "arrow.triangle.branch", label: "Condition (IF / ELSE)", color: .yellow)
                }
                .buttonStyle(.plain)

                Button {
                    showNodePalette = false
                    onAddStructuralNode(
                        .loop(LoopNodeConfig()),
                        "Loop"
                    )
                } label: {
                    paletteItem(icon: "arrow.trianglehead.2.clockwise", label: "Loop (Iterate)", color: .orange)
                }
                .buttonStyle(.plain)
            }

            // Utility
            paletteSection(title: "UTILITY", icon: "wrench", color: .cyan) {
                Button {
                    showNodePalette = false
                    onAddStructuralNode(
                        .code(CodeNodeConfig()),
                        "Code"
                    )
                } label: {
                    paletteItem(icon: "chevron.left.forwardslash.chevron.right", label: "Code / Transform", color: .cyan)
                }
                .buttonStyle(.plain)

                Button {
                    showNodePalette = false
                    onAddStructuralNode(
                        .gate(GateNodeConfig()),
                        "Gate"
                    )
                } label: {
                    paletteItem(icon: "hand.raised", label: "HITL Gate", color: .red)
                }
                .buttonStyle(.plain)

                Button {
                    showNodePalette = false
                    onAddStructuralNode(
                        .action(ActionNodeConfig()),
                        "Action"
                    )
                } label: {
                    paletteItem(icon: "bolt.horizontal.fill", label: "Action (Run a Tool)", color: .teal)
                }
                .buttonStyle(.plain)
            }

            // Annotate
            paletteSection(title: "ANNOTATE", icon: "note.text", color: .yellow) {
                Button {
                    showNodePalette = false
                    canvasState.addStickyNote(at: CGPoint(x: 60, y: 80 + CGFloat(canvasState.nodes.count + canvasState.annotations.count) * 120))
                } label: {
                    paletteItem(icon: "note.text", label: "Sticky Note", color: .yellow)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    @ViewBuilder
    private func paletteSection(title: String, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
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

    private func paletteItem(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(theme.fontCaption)
                .foregroundColor(theme.primaryText)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.controlBackground)
        )
    }
}

// MARK: - Toolbar Pill Button (8pt continuous rounded rectangle with hover)

struct ToolbarPillButton: View {
    let title: String
    let icon: String?
    var isPrimary: Bool = false
    var color: Color? = nil
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(isPrimary ? .white : (color ?? theme.accentColor))
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isPrimary ? .white : (color ?? theme.primaryText))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isPrimary
                        ? (isHovered ? theme.accentColor.opacity(0.9) : theme.accentColor)
                        : (isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isPrimary
                        ? (isHovered ? Color.white.opacity(0.35) : theme.accentColor.opacity(0.5))
                        : (isHovered ? (color ?? theme.accentColor).opacity(0.45) : theme.secondaryText.opacity(0.18)),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isPrimary
                ? (isHovered ? theme.accentColor.opacity(0.45) : theme.accentColor.opacity(0.25))
                : (isHovered ? Color.black.opacity(0.15) : Color.black.opacity(0.08)),
                radius: isHovered ? 4 : 2,
                x: 0,
                y: 1
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
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
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    init(icon: String, help: String = "", action: @escaping () -> Void) {
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
        .help(help)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}
