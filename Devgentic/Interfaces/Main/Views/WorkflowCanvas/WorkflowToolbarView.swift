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
                VStack(alignment: .leading, spacing: 12) {
                    Button { showNodePalette = true } label: {
                        Label("Add Node", systemImage: "plus")
                            .font(theme.fontSubheadline.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .background(theme.accentColor)
                    .clipShape(Capsule())
                    .shadow(color: theme.accentColor.opacity(0.3), radius: 6, x: 0, y: 3)
                    .popover(isPresented: $showNodePalette, arrowEdge: .bottom) {
                        nodePaletteContent
                    }

                    statusGroup

                    // Validation errors indicator
                    if !canvasState.validationErrors.isEmpty {
                        Button {
                            canvasState.showValidationPanel.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                Text("\(canvasState.validationErrors.count) error\(canvasState.validationErrors.count == 1 ? "" : "s")")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            // MARK: Liquid Glass
                            .glassEffect(.regular, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // Top Right: Contextual Actions
                HStack(spacing: 12) {
                    if canvasState.selectedNodeID != nil || canvasState.selectedEdgeID != nil || canvasState.selectedAnnotationID != nil {
                        floatingActionButton(
                            title: "Delete",
                            icon: "trash",
                            color: .red,
                            action: { canvasState.deleteSelected() }
                        )
                    }

                    if !canvasState.nodes.isEmpty {
                        floatingActionButton(
                            title: "Clear",
                            icon: "arrow.uturn.backward.square",
                            color: theme.secondaryText,
                            action: onClearCanvas
                        )
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
                    Text("All changes saved")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        // MARK: Liquid Glass
                        .glassEffect(.regular, in: .capsule)
                        // --- To revert to pre-Liquid-Glass, comment out the line above and uncomment below ---
                        // .background(.ultraThinMaterial)
                        // .overlay(Capsule().stroke(theme.surfaceOverlayStrong, lineWidth: 1))
                        // .clipShape(Capsule())
                        // .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // MARK: Liquid Glass
        .glassEffect(.regular, in: .capsule)
        // --- To revert to pre-Liquid-Glass, comment out the line above and uncomment below ---
        // .background(.ultraThinMaterial)
        // .overlay(Capsule().stroke(theme.surfaceOverlayStrong, lineWidth: 1))
        // .clipShape(Capsule())
        // .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private func statusBadge(icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(.caption2))
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced)) // Fixed size: monospaced
        }
        .foregroundColor(theme.secondaryText)
    }

    private var zoomGroup: some View {
        HStack(spacing: 4) {
            Button(action: { canvasState.zoomOut() }) {
                Image(systemName: "minus")
                    .font(.system(.caption, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryText)
            .accessibilityLabel("Zoom out")

            Text("\(Int(canvasState.canvasScale * 100))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced)) // Fixed size: monospaced
                .foregroundColor(theme.primaryText)
                .frame(width: 44, alignment: .center)

            Button(action: { canvasState.zoomIn() }) {
                Image(systemName: "plus")
                    .font(.system(.caption, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryText)
            .accessibilityLabel("Zoom in")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            Button(action: { canvasState.resetZoom() }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(.caption, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryText)
            .accessibilityLabel("Reset zoom")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(.caption, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryText)
            .accessibilityLabel("Workflow settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // MARK: Liquid Glass
        .glassEffect(.regular, in: .capsule)
        // --- To revert to pre-Liquid-Glass, comment out the line above and uncomment below ---
        // .background(.ultraThinMaterial)
        // .overlay(Capsule().stroke(theme.surfaceOverlayStrong, lineWidth: 1))
        // .clipShape(Capsule())
        // .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private var saveRevertGroup: some View {
        HStack(spacing: 8) {
            Button(action: onRevert) {
                Text("Revert")
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            // MARK: Liquid Glass
            .glassEffect(.regular, in: .capsule)
            // --- To revert to pre-Liquid-Glass, comment out the line above and uncomment below ---
            // .background(.ultraThinMaterial)
            // .overlay(Capsule().stroke(theme.surfaceOverlayStrong, lineWidth: 1))
            // .clipShape(Capsule())

            Button(action: onSave) {
                Text("Save Changes")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(theme.accentColor)
            .clipShape(Capsule())
            .shadow(color: theme.accentColor.opacity(0.3), radius: 6, x: 0, y: 3)
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
