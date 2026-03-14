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
    @ObservedObject var canvasState: WorkflowCanvasState
    let onAddNode: () -> Void
    let onClearCanvas: () -> Void
    let onSave: () -> Void
    let onRevert: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack {
            // Top Action Area
            HStack(alignment: .top) {
                // Top Left: Add Profile & Status
                VStack(alignment: .leading, spacing: 12) {
                    Button(action: onAddNode) {
                        Label("Add Profile", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .background(theme.accentColor)
                    .clipShape(Capsule())
                    .shadow(color: theme.accentColor.opacity(0.3), radius: 6, x: 0, y: 3)

                    statusGroup
                }

                Spacer()

                // Top Right: Contextual Actions
                HStack(spacing: 12) {
                    if canvasState.selectedNodeID != nil || canvasState.selectedEdgeID != nil {
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .overlay(
                            Capsule().stroke(theme.surfaceOverlayStrong, lineWidth: 1)
                        )
                        .clipShape(Capsule())
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(
            Capsule().stroke(theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private func statusBadge(icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundColor(theme.secondaryText)
    }

    private var zoomGroup: some View {
        HStack(spacing: 4) {
            Button(action: { canvasState.zoomOut() }) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryText)

            Text("\(Int(canvasState.canvasScale * 100))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .frame(width: 44, alignment: .center)

            Button(action: { canvasState.zoomIn() }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryText)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            Button(action: { canvasState.resetZoom() }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundColor(theme.primaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(
            Capsule().stroke(theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    private var saveRevertGroup: some View {
        HStack(spacing: 8) {
            Button(action: onRevert) {
                Text("Revert")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial)
            .overlay(
                Capsule().stroke(theme.surfaceOverlayStrong, lineWidth: 1)
            )
            .clipShape(Capsule())

            Button(action: onSave) {
                Text("Save Changes")
                    .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .overlay(
                    Capsule().stroke(theme.surfaceOverlayStrong, lineWidth: 1)
                )
                .clipShape(Capsule())
                .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}
