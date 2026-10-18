// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowCanvasView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

private let logger = DGLogger(category: "WorkflowCanvasView")

/// The main workflow canvas: a pannable, zoomable surface with a dot grid that renders nodes, edges and drag
/// previews.
struct WorkflowCanvasView: View {
    @Binding var profile: BackendProfileModel
    var onDelete: ((UUID) -> Void)? = nil
    /// Optional navigation guard supplied by `WorkflowDedicatedView`, so leaving a dirty canvas prompts
    /// Save/Discard/Cancel. Nil in the profile-editor context, which uses its own `ProfileEditBuffer` discard guard.
    let editGuard: WorkflowEditGuard?

    /// The most recent run's outcome, projected onto the graph. Nil when there is no run to show,
    /// in which case the canvas renders exactly as it did before run status existed.
    let runOverlay: WorkflowCanvasRunOverlay?

    @Environment(BackendProfileService.self) var profileService
    @Environment(ToastManager.self) private var toastManager
    @Environment(MainViewRouter.self) private var router
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme
    /// Backing scale for the grid tile bitmap — a 1x tile on a Retina display draws soft dots.
    @Environment(\.displayScale) private var displayScale

    // Why: a non-optional @Environment object traps at runtime when absent (previews, other hosts).
    /// The app view model, optional so the view stays constructible without one; it only pushes the dirty mirror.
    @Environment(MainApplicationViewModel.self) private var mainViewModel: MainApplicationViewModel?

    /// The caller-owned canvas state; read `canvasState` instead of this property. Production callers resolve it from
    /// `MainApplicationViewModel.workflowCanvasState(for:)` so a workflow has exactly one state object.
    private let injectedCanvasState: WorkflowCanvasState?

    /// Fallback state for callers that supply none (previews and tests); read `canvasState` instead. Reaching it in the
    /// app yields a second, independent graph for the profile; `loadLayout()` logs an error when it is used.
    @State private var ownedCanvasState: WorkflowCanvasState

    // Why: never capture the injected state into `@State`: this view's identity outlives a profile change, so a frozen state
    // would show and save the previous workflow's graph under the new profile.
    /// The state this canvas edits, resolved per render.
    private var canvasState: WorkflowCanvasState { injectedCanvasState ?? ownedCanvasState }

    @State private var showingProfilePicker = false
    @State private var showingClearAlert = false
    @State private var showingGuideline = false

    // Why: never read the store from `body`; the unreadable check runs a SwiftData fetch and JSON decode.
    /// Set when this profile's stored canvas could not be decoded, with the counts the row still carries so the overlay
    /// can say what was lost. Refreshed only in `loadLayout()`.
    @State private var unreadableLayout: UnreadableLayoutInfo?

    /// Set when a save is refused because the stored layout was written by a newer build. A notice rather than the
    /// corruption overlay: the graph is intact and runnable, just read-only here. Scoped to the profile that produced it
    /// so a stale banner cannot render against another workflow.
    @State private var newerVersionNotice: ProfileScopedNotice?

    struct ProfileScopedNotice: Equatable {
        let profileID: UUID
        let message: String

        /// Returns the notice to render for `displayedProfileID`, or nil when the stored notice belongs to a different
        /// workflow. `nonisolated static` and pure so the scoping rule can be unit-tested.
        nonisolated static func message(
            for stored: ProfileScopedNotice?,
            displayedProfileID: UUID
        ) -> String? {
            guard let stored, stored.profileID == displayedProfileID else { return nil }
            return stored.message
        }
    }

    /// The notice to render, or nil when the stored one belongs to a different workflow.
    private var activeNewerVersionNotice: String? {
        ProfileScopedNotice.message(for: newerVersionNotice, displayedProfileID: profile.id)
    }
    @State private var showingDiscardUnreadableAlert = false

    struct UnreadableLayoutInfo: Equatable {
        /// The profile this info describes. Scoping it to the profile makes a stale overlay unrenderable, so Discard cannot
        /// target a readable graph.
        let profileID: UUID
        let nodeCount: Int
        let edgeCount: Int
        let annotationCount: Int

        /// True when the counts prove the row once held content — out-of-blob evidence, so it is
        /// trustworthy even though the blob itself is not.
        var heldContent: Bool { nodeCount > 0 || edgeCount > 0 || annotationCount > 0 }

        var summary: String {
            var parts: [String] = []
            if nodeCount > 0 { parts.append("\(nodeCount) node\(nodeCount == 1 ? "" : "s")") }
            if edgeCount > 0 { parts.append("\(edgeCount) connection\(edgeCount == 1 ? "" : "s")") }
            if annotationCount > 0 { parts.append("\(annotationCount) note\(annotationCount == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }

        /// Returns the info to render for `displayedProfileID`, or nil when the stored one belongs to a different workflow.
        /// `nonisolated static` and pure so the rule can be unit-tested.
        nonisolated static func active(
            _ stored: UnreadableLayoutInfo?,
            displayedProfileID: UUID
        ) -> UnreadableLayoutInfo? {
            guard let stored, stored.profileID == displayedProfileID else { return nil }
            return stored
        }
    }

    /// The unreadable-canvas overlay to render, or nil when the stored one belongs to another workflow. Read through
    /// this, never `unreadableLayout` directly.
    private var activeUnreadableLayout: UnreadableLayoutInfo? {
        UnreadableLayoutInfo.active(unreadableLayout, displayedProfileID: profile.id)
    }

    /// True only when the canvas holds nothing the user put there; annotations count as content. `nonisolated static` and
    /// pure so the rule can be unit-tested.
    nonisolated static func showsEmptyPlacard(nodeCount: Int, annotationCount: Int) -> Bool {
        nodeCount == 0 && annotationCount == 0
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @State private var scrollMonitor: Any?
    #endif

    /// Creates the canvas. `canvasState` is injected by callers whose view is torn down and rebuilt around a live edit,
    /// and is required of every production caller. The injected state is stored in a `let`; the `@State` fallback is
    /// never read once it is non-nil.
    init(
        profile: Binding<BackendProfileModel>,
        onDelete: ((UUID) -> Void)? = nil,
        editGuard: WorkflowEditGuard? = nil,
        canvasState: WorkflowCanvasState? = nil,
        runOverlay: WorkflowCanvasRunOverlay? = nil
    ) {
        self._profile = profile
        self.onDelete = onDelete
        self.editGuard = editGuard
        self.runOverlay = runOverlay
        self.injectedCanvasState = canvasState
        self._ownedCanvasState = State(wrappedValue: canvasState ?? WorkflowCanvasState(profileID: profile.wrappedValue.id))
    }

    var body: some View {
        ZStack {
            // Background & Canvas Layer
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // Background Grid
                    canvasBackground(in: geometry.size)

                    // Transformed Canvas Content
                    canvasContent
                        // Fix canvas size to prevent bounding box layout shifts when nodes reach edges
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .coordinateSpace(name: "canvasContent") // Unscaled local canvas space for 1:1 dragging
                        .animation(nil, value: canvasState.activeNodeDrag?.offset) // Suppress implicit drag animations
                        .scaleEffect(canvasState.canvasScale, anchor: .center)
                        .offset(canvasState.canvasOffset)
                }
                .clipped()
                .contentShape(Rectangle()) // Ensures the whole area catches gestures
                .gesture(canvasPanGesture)
                .gesture(canvasZoomGesture)
                .twoFingerPan { delta in
                    canvasState.addOffset(delta: delta)
                }
                .onHover { hovering in
                    canvasState.isHoveringCanvas = hovering
                }
                .onTapGesture {
                    canvasState.clearSelection()
                }
                // Pushes the pane size into the state so `nextAvailablePosition()` can centre new nodes; the toolbar and picker sit
                // outside this GeometryReader.
                .onAppear { canvasState.viewportSize = geometry.size }
                .onChange(of: geometry.size) { _, newSize in
                    canvasState.viewportSize = newSize
                }
            }
            .background(theme.primaryBackground)

            // Empty-state overlay, shown when the canvas holds no nodes and no notes. The unreadable-layout case wins, since an
            // undecodable canvas also renders as zero nodes.
            if let activeUnreadableLayout {
                unreadableLayoutOverlay(activeUnreadableLayout)
            } else if Self.showsEmptyPlacard(
                nodeCount: canvasState.nodes.count,
                annotationCount: canvasState.annotations.count
            ) {
                emptyStateOverlay
            }

            // Validation Panel (floating, bottom-left)
            if canvasState.showValidationPanel && !canvasState.validationIssues.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        WorkflowValidationPanelView(
                            issues: canvasState.validationIssues,
                            onSelectNode: { nodeID in
                                canvasState.select(nodeID: nodeID)
                                // Selecting alone would do nothing visible on a graph larger than the pane; `revealNode` is a no-op when the node is
                                // already comfortably on screen.
                                _ = withAnimation(.easeInOut(duration: 0.25)) {
                                    canvasState.revealNode(nodeID)
                                }
                            },
                            onDismiss: {
                                canvasState.showValidationPanel = false
                            }
                        )
                        .frame(maxWidth: 320)
                        .padding(.leading, 20)
                        .padding(.bottom, 70)
                        Spacer()
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: canvasState.showValidationPanel)
            }

            // Newer-version read-only notice; persistent while set because every save is refused until the app updates. Read
            // through `activeNewerVersionNotice`, never `newerVersionNotice` directly.
            if let notice = activeNewerVersionNotice {
                VStack {
                    Label(notice, systemImage: "arrow.up.circle.fill")
                        .font(theme.fontCaption.weight(.medium))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(theme.surfaceOverlayStrong)
                                .overlay(Capsule().stroke(theme.accentColor.opacity(0.5), lineWidth: 1))
                        )
                        .padding(.top, 90)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Refused-connection notice; without it a drag ending in a cycle, duplicate or miss would just make the preview line
            // vanish.
            if let refusal = canvasState.lastEdgeRefusal {
                VStack {
                    Spacer()
                    Label(refusal.userMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(theme.fontCaption.weight(.medium))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(theme.surfaceOverlayStrong)
                                .overlay(Capsule().stroke(theme.warningColor.opacity(0.5), lineWidth: 1))
                        )
                        .padding(.bottom, 120)
                        .accessibilityAddTraits(.isStaticText)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
                .task(id: canvasState.edgeRefusalGeneration) {
                    // Why: keyed on the generation, not the refusal value, so an identical repeat refusal restarts the timer.
                    // Self-clears after 3 seconds and restarts when a new refusal arrives, so it never clears a newer message.
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    canvasState.lastEdgeRefusal = nil
                }
            }

            // Undo shortcut hosted on a hidden Button: the canvas's only focus stop is its root `.focusable()`, and a Button's
            // `keyboardShortcut` fires without needing focus.
            Button("Undo") { canvasState.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!canvasState.canUndo)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            // Floating Controls Overlay
            WorkflowToolbarView(
                canvasState: canvasState,
                onAddProfile: { showingProfilePicker = true },
                onAddStructuralNode: { kind, name in
                    canvasState.addStructuralNode(kind: kind, displayName: name)
                },
                onClearCanvas: { showingClearAlert = true },
                onShowGuideline: { showingGuideline = true },
                onSave: saveLayout,
                onRevert: { canvasState.revert() }
            )
        }
        .sheet(isPresented: $showingGuideline) {
            WorkflowGuidelineView()
        }
        .onAppear {
            loadLayout()
            registerEditGuard()
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            setupScrollMonitor()
            #endif
        }
        // Observed in the view, where `@Observable` tracking works, so the validator re-runs when the tool catalogue
        // changes.
        .onChange(of: UnifiedToolStore.shared.catalogGeneration) { _, generation in
            canvasState.revalidateForToolCatalogChange(generation: generation)
        }
        .onChange(of: canvasState.hasUnsavedChanges) { _, dirty in
            // Mirrors the dirty state into the nav guard and into the view model's mirror, which keeps the badge lit after this
            // view goes away.
            editGuard?.hasUnsavedChanges = dirty
            mainViewModel?.setWorkflowCanvasDirty(dirty, for: profile.id)
        }
        .onDisappear {
            editGuard?.unregister()
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            removeScrollMonitor()
            #endif
            dismissInspectorForTeardown()
        }
        .onChange(of: profile.id) {
            loadLayout()
            registerEditGuard()
            // Re-arms the scroll monitor on a profile switch: its closure captures the state that existed when it was installed.
            // `.twoFingerPan` is `self` on macOS, so this AppKit monitor is the only trackpad-pan path.
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            removeScrollMonitor()
            setupScrollMonitor()
            #endif
        }
        // `.onDeleteCommand` needs a focusable ancestor to fire. Placed on the canvas ZStack rather than per node so focus
        // does not compete with the pan, zoom, drag and tap gestures.
        .focusable()
        // Suppresses only the visual focus ring; focus remains so `.onDeleteCommand` still fires. Selection is shown by
        // node/edge highlights.
        .focusEffectDisabled()
        .onDeleteCommand {
            canvasState.deleteSelected()
        }
        .sheet(isPresented: $showingProfilePicker) {
            WorkflowAddNodeSheet(
                // Only `sharedProfiles` are offered: another node's owned row is private to that node and must not be imported.
                profiles: profileService.sharedProfiles,
                workflowProfileID: profile.id,
                onCreateFresh: { type, name in addFreshNode(type: type, name: name) },
                onImport: { source in addImportedNode(from: source) }
            )
        }
        .alert("Clear Canvas?", isPresented: $showingClearAlert) {
            Button("Clear All", role: .destructive) { canvasState.clearCanvas() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The message matches `clearCanvas()`'s consequence: Undo restores the graph, but the undo stack is dropped when the
            // layout reloads from disk.
            Text("This removes every node, connection and sticky note from the canvas. Nothing is written to disk until you save, and Undo (⌘Z) brings them back — until you save and then leave the canvas, or quit.")
        }
        // Confirmation is required: this is the only control that deliberately discards the original bytes, which survive
        // while writes are refused.
        .alert("Discard the unreadable canvas?", isPresented: $showingDiscardUnreadableAlert) {
            Button("Discard and Start Over", role: .destructive) { discardUnreadableLayout() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                activeUnreadableLayout?.heldContent == true
                ? "The saved layout held \(activeUnreadableLayout?.summary ?? "content") that this version cannot read. Discarding replaces it with an empty canvas and the original data is gone for good — a future version will no longer be able to recover it.\n\nIf you might want it back, quit instead and export a copy of the database first."
                : "Discarding replaces the unreadable layout with an empty canvas. The original data is gone for good — a future version will no longer be able to recover it."
            )
        }
        .onChange(of: canvasState.targetConfigNode) { _, node in
            // Commits first: a vanished or superseded node's inspector would otherwise lose its buffered profile edits with its
            // hosting view.
            NodeInspectorPendingCommit.shared.commitAndClear()
            if let node = node {
                showInspectorPanel(for: node)
            } else {
                NodeInspectorPanelManager.shared.close()
            }
        }
    }

    // MARK: - Custom Inspector Panels

    // Why: the inspector is a separate always-on-top window, and the `.onChange` observer may never fire during an animated
    // removal, so close it directly with `firingCallback: false` and clear state synchronously.
    /// Takes the node inspector down with the canvas, on every teardown path (run auto-flip, mode switch, profile
    /// deletion).
    private func dismissInspectorForTeardown() {
        // Commits first, while the hosting view's state is alive; covers the Run auto-flip, "Manage Library…" navigation and
        // profile switches.
        NodeInspectorPendingCommit.shared.commitAndClear()
        let panelWasOnScreen = NodeInspectorPanelManager.shared.isPresented
        NodeInspectorPanelManager.shared.close(firingCallback: false)
        canvasState.canvasDidDisappear(panelWasOnScreen: panelWasOnScreen)
    }

    private func showInspectorPanel(for node: WorkflowNode) {
        NodeInspectorPanelManager.shared.show(
            minSize: NSSize(width: 1040, height: 680),
            theme: theme,
            onClose: { canvasState.targetConfigNode = nil }
        ) {
            UnifiedNodeConfigurationView(
                canvasState: canvasState,
                initialSelectedNodeID: node.id,
                profileService: profileService,
                toastManager: toastManager,
                router: router,
                themeManager: themeManager,
                onClose: {
                    NodeInspectorPanelManager.shared.close()
                }
            )
        }
    }


    /// Creates a two-way binding into `canvasState.nodes` for a specific node ID.
    private func bindingForNode(_ nodeID: UUID) -> Binding<WorkflowNode> {
        Binding(
            get: {
                canvasState.nodes.first(where: { $0.id == nodeID })
                    ?? WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Missing Node")
            },
            set: { newValue in
                // Why: never write `nodes[idx]` directly: edges address ports by label, and inspectors rename port labels, so a direct
                // write strands edges.
                // Writes the node through `replaceNode`.
                canvasState.replaceNode(id: nodeID, with: newValue)
            }
        )
    }

    // MARK: - Canvas Content (Nodes + Edges)

    private var canvasContent: some View {
        ZStack {
            // Layer 1: Committed Edges (port-aware source position)
            ForEach(canvasState.edges) { edge in
                if let sourcePos = canvasState.outputPortPosition(for: edge.sourceNodeID, portLabel: edge.sourcePortLabel),
                   let targetPos = canvasState.inputPortPosition(for: edge.targetNodeID) {
                    WorkflowEdgeView(
                        edge: edge,
                        sourcePoint: sourcePos,
                        targetPoint: targetPos,
                        isSelected: canvasState.selectedEdgeID == edge.id,
                        onTap: { canvasState.select(edgeID: edge.id) },
                        onDelete: { canvasState.removeEdge(edge.id) },
                        canvasState: canvasState,
                        runState: runOverlay?.edgeState(from: edge.sourceNodeID, to: edge.targetNodeID) ?? .undetermined
                    )
                }
            }

            // Layer 2: Drag Preview Edge (port-aware)
            if let drag = canvasState.edgeDragState,
               let sourcePos = canvasState.outputPortPosition(for: drag.sourceNodeID, portLabel: drag.sourcePortLabel) {
                let dragColor = canvasState.nodes.first(where: { $0.id == drag.sourceNodeID })?
                    .kind.portColor(forLabel: drag.sourcePortLabel, in: theme)
                    ?? (drag.sourcePortLabel == WorkflowEdge.errorPortLabel ? theme.errorColor : theme.accentColor)
                WorkflowEdgeDragPreview(
                    sourcePoint: sourcePos,
                    currentPoint: drag.currentPoint,
                    color: dragColor
                )
            }

            // Layer 3: Sticky Notes (behind nodes)
            ForEach(canvasState.annotations) { note in
                StickyNoteView(
                    note: note,
                    isSelected: canvasState.selectedAnnotationID == note.id,
                    canvasState: canvasState
                )
            }

            // Layer 4: Nodes
            ForEach(canvasState.nodes) { node in
                WorkflowNodeView(
                    node: node,
                    isSelected: canvasState.selectedNodeID == node.id,
                    canvasState: canvasState,
                    runStatus: runOverlay?.status(for: node.id),
                    runIsLive: runOverlay?.isLive ?? false
                )
            }
        }
    }

    // MARK: - Background Grid

    private func canvasBackground(in size: CGSize) -> some View {
        ZStack {
            RadialGradient(
                colors: [theme.secondaryBackground.opacity(0.4), theme.primaryBackground],
                center: .center,
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.8
            )
            .ignoresSafeArea()

            // Why: a per-dot `Canvas` path is far slower and re-blitting a cached tile through `Canvas` stays CPU-bound; tile
            // regeneration only happens on zoom or theme change.
            // Dot grid drawn as one GPU-tiled bitmap, so panning is a layer transform with no per-frame grid cost.
            gridTileFill(in: size)
        }
    }

    /// The tiled grid layer. Oversized by one tile on every edge and offset by the pan phase, so
    /// the pattern moves with the canvas; `ImagePaint` anchors its tiling to the shape's own
    /// origin, which is exactly what makes the offset carry the phase.
    @ViewBuilder
    private func gridTileFill(in size: CGSize) -> some View {
        let scaledSpacing = WorkflowGridTile.gridSpacing * canvasState.canvasScale
        if scaledSpacing >= 3,  // below ~3pt the dots are moiré soup; the gradient alone is calmer
           let tile = WorkflowGridTile.image(
               scaledSpacing: scaledSpacing,
               dotColor: theme.surfaceOverlay,
               majorDotColor: theme.secondaryText.opacity(0.2),
               displayScale: displayScale
           ) {
            let side = WorkflowGridTile.sideLength(scaledSpacing: scaledSpacing)
            let phaseX = WorkflowGridTile.phase(offset: canvasState.canvasOffset.width, side: side)
            let phaseY = WorkflowGridTile.phase(offset: canvasState.canvasOffset.height, side: side)
            Rectangle()
                .fill(ImagePaint(image: Image(decorative: tile, scale: displayScale > 0 ? displayScale : 2)))
                .frame(width: size.width + 2 * side, height: size.height + 2 * side)
                // Why: `.offset` composes with the ZStack alignment and leaves a grid-free strip when the phase is negative.
                // Positions the tiled rect by its centre with `.position`.
                .position(x: phaseX + size.width / 2, y: phaseY + size.height / 2)
                // Why: `revealNode` animates `canvasOffset` while the phase is a modulo of it, so the grid would slide the wrong way
                // against the content.
                // Never animates the grid phase.
                .animation(nil, value: canvasState.canvasOffset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Gestures

    private var canvasPanGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                canvasState.updateOffset(by: value.translation)
            }
            .onEnded { _ in
                canvasState.commitOffset()
            }
    }

    private var canvasZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                canvasState.updateScale(by: value)
            }
            .onEnded { _ in
                canvasState.commitScale()
            }
    }
    
    // MARK: - Trackpad Support (macOS)
    
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private func setupScrollMonitor() {
        // The capture is why the monitor must be re-armed whenever `canvasState` changes identity (see `.onChange(of:
        // profile.id)`).
        let state = canvasState // Capture object reference safely
        if scrollMonitor != nil {
            // Re-arming without removing first would leak the previous monitor AND leave two live
            // handlers, the older one still driving the previous workflow's canvas.
            logger.error(
                "[WF_CANVAS] Scroll monitor for profile \(profile.id) installed while one was ALREADY "
                + "active — the previous monitor was not removed. CONSEQUENCE: two trackpad handlers "
                + "are live, the stale one panning a different workflow's canvas, and the old monitor "
                + "is leaked for the life of the app. Every install must be paired with a removal."
            )
        }
        logger.debug("[WF_CANVAS] Trackpad scroll monitor armed for profile \(profile.id) (canvas state \(canvasState.profileID)).")
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak state] event in
            // Only capture trackpad events if the user is actively hovering over the canvas
            guard let state = state, state.isHoveringCanvas else { return event }
            
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            
            if dx != 0 || dy != 0 {
                // Ensure UI updates remain strictly on the main thread
                DispatchQueue.main.async {
                    state.addOffset(delta: CGSize(width: dx, height: dy))
                }
                return nil // Consume event to prevent bubbling to other scroll views
            }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
            logger.debug("[WF_CANVAS] Trackpad scroll monitor removed for profile \(profile.id).")
        }
    }
    #endif

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: ProfileType.workflow.iconName)
                .font(.system(size: 48)) // Fixed size: intentional
                .foregroundColor(.purple.opacity(0.5))

            Text("Workflow Canvas")
                .font(theme.fontTitle2)
                .fontWeight(.bold)
                .foregroundColor(theme.primaryText)

            Text("Add profiles to build your workflow pipeline.\nConnect outputs to inputs to define execution order.")
                .font(theme.fontSubheadline)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            TactileButton(
                title: "Add First Profile",
                icon: "plus.circle.fill",
                variant: .primary,
                size: .regular
            ) {
                showingProfilePicker = true
            }
        }
        .padding(40)
    }

    /// Shown instead of the empty-state invitation when the stored canvas could not be decoded. States that this is a
    /// read failure, what the canvas held, and that the original bytes are still there.
    @ViewBuilder
    private func unreadableLayoutOverlay(_ info: UnreadableLayoutInfo) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48)) // Fixed size: matches the empty-state glyph it replaces
                .foregroundColor(theme.warningColor)

            Text("This canvas could not be read")
                .font(theme.fontTitle2)
                .fontWeight(.bold)
                .foregroundColor(theme.primaryText)

            Text(
                info.heldContent
                // The counts live OUTSIDE the blob, written by the last successful save, so they are
                // still trustworthy — which is what makes this message specific instead of vague.
                ? "It last held \(info.summary), but the saved layout can't be decoded by this version.\n\nYour data has not been deleted — edits are being refused so it stays recoverable by a future build."
                : "The saved layout can't be decoded by this version.\n\nYour data has not been deleted — edits are being refused so it stays recoverable by a future build."
            )
            .font(theme.fontSubheadline)
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420)

            TactileButton(
                title: "Discard and Start Over",
                icon: "trash",
                variant: .destructive,
                size: .regular
            ) {
                showingDiscardUnreadableAlert = true
            }
        }
        .padding(40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            info.heldContent
            ? "This workflow canvas could not be read. It last held \(info.summary). The data is preserved and edits are refused."
            : "This workflow canvas could not be read. The data is preserved and edits are refused."
        )
    }

    // MARK: - Persistence

    private func loadLayout() {
        // Why: a mismatch would save one workflow's nodes over another's; `assert` is stripped in release, so it is paired with
        // an error log naming the consequence.
        // Invariant: this canvas edits the state belonging to the profile it displays.
        if canvasState.profileID != profile.id {
            logger.error(
                "[WF_CANVAS] STATE MISMATCH: the canvas is displaying profile \(profile.id) but holds "
                + "the state for profile \(canvasState.profileID). CONSEQUENCE: the graph on screen "
                + "belongs to a different workflow, and saving would overwrite \(profile.id)'s stored "
                + "layout with it. The load is ABORTED so nothing is written; the canvas keeps showing "
                + "the other workflow until it is remounted."
            )
            assertionFailure("WorkflowCanvasView is editing \(canvasState.profileID) while displaying \(profile.id)")
            return
        }

        // Why: that is invisible until quit, when both are written to the same row; `assert` is stripped in release, so it is
        // paired with an error log.
        // Reports when the canvas falls back to its own state, which means a second independent graph exists for this
        // profile.
        if injectedCanvasState == nil {
            logger.error(
                "[WF_CANVAS] Canvas for profile \(profile.id) mounted with NO injected state, so it "
                + "created its own. CONSEQUENCE: if any other surface is editing this same workflow, "
                + "two independent graphs now exist for one stored layout and the quit-time save will "
                + "write both to the same row — the second silently overwriting the first. Pass "
                + "`MainApplicationViewModel.workflowCanvasState(for:)` at this mount site."
            )
            assertionFailure("WorkflowCanvasView mounted without an injected WorkflowCanvasState for \(profile.id)")
        }

        // Never reloads over unsaved edits: the canvas state can outlive this view, so `.onAppear` may fire mid-edit. The
        // unreadable-layout refresh stays above this guard because it describes the stored row.
        refreshUnreadableLayoutState()

        // Set above the dirty guard so the validator resolves profiles for the displayed workflow even when the reload is
        // skipped. A closure rather than a snapshot; `profileService` is app-scoped.
        canvasState.profileLookup = { [profileService] in
            Dictionary(
                profileService.profiles.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        guard canvasState.acceptsDiskReload else {
            logger.info(
                "[WF_CANVAS] Skipped reloading the layout for profile \(profile.id) — the canvas has "
                + "unsaved edits in memory. CONSEQUENCE: the on-disk layout is deliberately NOT read; "
                + "the user's in-progress edits stay on screen and the dirty state is preserved."
            )
            registerEditGuardDirtyState()
            return
        }

        let loaded = WorkflowLayoutStore.shared.loadWithOutcome(for: profile.id)
        canvasState.load(from: loaded.layout)
        // [CVV-9] Logged once per load, never from `body` — the placard decision itself is a
        // per-frame render test and logging it there would spam at streaming frequency.
        if loaded.layout.nodes.isEmpty && !loaded.layout.annotations.isEmpty {
            logger.info(
                "[WF_CANVAS] Profile \(profile.id) loaded with 0 nodes and "
                + "\(loaded.layout.annotations.count) sticky note(s). CONSEQUENCE: the empty-canvas "
                + "placard is suppressed so it cannot paint over the notes or swallow their clicks; "
                + "the toolbar's Add Node pill remains the way to add the first node."
            )
        }
        if loaded.didFail {
            // The canvas now shows an empty graph that may not be empty; recording that stops the next save overwriting the real
            // one.
            canvasState.markLoadFailed()
        }
    }

    /// Creates a node backed by a brand-new private profile row. The node id is minted first because the row stores
    /// `ownerNodeID`; a failed save leaves the canvas unchanged.
    private func addFreshNode(type: ProfileType, name: String) {
        let nodeID = UUID()
        // Cheap synchronous read of an already-scanned list. Empty is fine and expected on a machine
        // with no local models — see `freshProfile`'s note on why that must still create the node.
        let defaultModel = MLXModelService.shared.installedModels.first?.displayName ?? ""
        let owned = WorkflowNodeProfileFactory.freshProfile(
            type: type,
            name: name,
            workflowID: profile.id,
            nodeID: nodeID,
            defaultMLXModelName: defaultModel
        )
        persistOwnedProfile(owned, nodeID: nodeID, origin: "fresh \(type.rawValue)")
    }

    /// Creates a node backed by a one-time copy of an existing profile. A sub-workflow node stays a reference to the
    /// other workflow's canvas rather than a copy.
    private func addImportedNode(from source: BackendProfileModel) {
        guard source.profileType != .workflow else {
            logger.info("[WF_CANVAS] Sub-workflow node for '\(source.displayName)' (\(source.id)) added as a REFERENCE, not a copy — its steps live on that workflow's own canvas. CONSEQUENCE: edits to that workflow are seen here, which is the intent for nesting.")
            canvasState.addNode(from: source)
            return
        }

        let nodeID = UUID()
        let owned = WorkflowNodeProfileFactory.importedProfile(
            from: source,
            workflowID: profile.id,
            nodeID: nodeID
        )
        persistOwnedProfile(owned, nodeID: nodeID, origin: "imported from \(source.id)")
    }

    /// Saves an owned row, then adds the node that owns it. The row must exist before the node references it, since the
    /// executor refuses a run whose node profile is missing.
    private func persistOwnedProfile(_ owned: BackendProfileModel, nodeID: UUID, origin: String) {
        do {
            // Validation is lenient on insert, so a fresh node with no model is created and flagged on the canvas instead of
            // being unaddable.
            try profileService.saveProfile(owned)
        } catch {
            logger.error(
                "[WF_CANVAS] Could NOT create the private profile row for a new node on workflow "
                + "\(profile.id) (\(origin)): \(error.localizedDescription). CONSEQUENCE: no node is "
                + "added and the canvas is unchanged — adding one anyway would point it at a row "
                + "that does not exist, which the executor refuses the entire run over."
            )
            return
        }
        logger.info("[WF_CANVAS] Added node \(nodeID.uuidString.prefix(8)) on workflow \(profile.id) backed by its OWN profile row \(owned.id.uuidString.prefix(8)) (\(origin)). CONSEQUENCE: the node's settings are scoped to this workflow — editing it changes nothing in the shared profile library.")
        canvasState.addNode(from: owned, nodeID: nodeID)
    }

    // Why: called from `loadLayout()` only, never `body`: the check runs a SwiftData fetch and JSON decode.
    /// Re-derives the unreadable-canvas overlay for the displayed profile. Asks before loading, because `load(for:)`
    /// returns `.empty` on failure and discards the reason.
    private func refreshUnreadableLayoutState() {
        if WorkflowLayoutStore.shared.isLayoutUnreadable(for: profile.id) {
            let counts = WorkflowLayoutStore.shared.storedCounts(for: profile.id)
            unreadableLayout = UnreadableLayoutInfo(
                profileID: profile.id,
                nodeCount: counts.nodes, edgeCount: counts.edges, annotationCount: counts.annotations
            )
        } else if unreadableLayout != nil {
            logger.info("[WF_CANVAS] Cleared the unreadable-canvas overlay while showing profile \(profile.id) — the stored layout decodes. CONSEQUENCE: the canvas is editable and the destructive Discard control is withdrawn.")
            unreadableLayout = nil
        }
    }

    /// Deliberately discards an unreadable canvas so the profile becomes editable again. Routes through
    /// `repairUnreadableLayout(_:for:reason:)`, the explicit, logged exception to `save`'s refusal.
    private func discardUnreadableLayout() {
        // Last line of defence: the only control that destroys a user's graph acts on the displayed profile, so repairing a
        // healthy row is refused here regardless of how it was reached.
        guard WorkflowLayoutStore.shared.isLayoutUnreadable(for: profile.id) else {
            logger.error(
                "[PERSISTENCE] Discard REFUSED for profile \(profile.id) — its stored layout decodes "
                + "fine, so there is nothing to repair. CONSEQUENCE: the graph is left untouched; "
                + "reaching here means a Discard control was shown for a workflow that is not the one "
                + "it describes."
            )
            unreadableLayout = nil
            return
        }

        let replacement = WorkflowLayout.empty
        let outcome = WorkflowLayoutStore.shared.repairUnreadableLayout(
            replacement, for: profile.id, reason: "user chose Discard and Start Over on the canvas"
        )
        guard outcome.didPersist else {
            // Leave the overlay up: the canvas is still unreadable, and clearing it here would tell
            // the user the problem was resolved when it was not.
            logger.error(
                "[PERSISTENCE] Discard FAILED for profile \(profile.id) — \(String(describing: outcome)). "
                + "CONSEQUENCE: the canvas remains unreadable and every save stays refused; the "
                + "overlay is left in place rather than falsely reporting success."
            )
            return
        }
        unreadableLayout = nil
        canvasState.load(from: replacement)
        canvasState.markSaved()
    }

    // Why: the main interface and the profile editor pass different guard instances, because both canvases can be mounted at
    // once and one shared guard would let the later registration clear the other's hooks.
    /// Installs or refreshes this canvas's hooks into the nav guard so Save/Discard from the navigation prompt operate on
    /// this canvas. The profile ID travels with the hooks (see `WorkflowEditGuard.registeredProfileID`).
    private func registerEditGuard() {
        guard let editGuard else { return }
        registerEditGuardDirtyState()
        editGuard.register(
            profileID: profile.id,
            save: { saveLayout() },
            discard: { canvasState.revert() }
        )
    }

    /// Pushes the canvas's current dirty state into the guard. Also runs on the early return in `loadLayout()` so a
    /// returning canvas with unsaved edits re-arms the tab dot and navigation prompt.
    private func registerEditGuardDirtyState() {
        editGuard?.hasUnsavedChanges = canvasState.hasUnsavedChanges
        // Also pushes the view-model mirror, which survives this view's teardown when `unregister()` clears the guard.
        mainViewModel?.setWorkflowCanvasDirty(canvasState.hasUnsavedChanges, for: profile.id)
    }

    private func saveLayout() {
        // Refuses to write one workflow's graph over another's; checked here as well as in `loadLayout()` because this call
        // destroys data and is reachable from the nav guard's `saveHook`.
        guard let layout = canvasState.layout(forProfile: profile.id) else {
            assertionFailure("saveLayout would write \(canvasState.profileID)'s graph to \(profile.id)")
            return
        }

        let outcome = WorkflowLayoutStore.shared.save(layout, for: profile.id)

        // Bails on a refusal before touching the profile, so the dirty flag stays lit and no profile write follows. A layout
        // saved by a newer build is read-only: re-encoding here would strip fields this build does not understand.
        if case .refusedNewerVersion(let blobVersion, let appVersion) = outcome {
            newerVersionNotice = ProfileScopedNotice(
                profileID: profile.id,
                message: String(localized: "This workflow was saved by a newer version of Devgentic (v\(blobVersion) format; this build writes v\(appVersion)). It's read-only here — update Devgentic to edit it.")
            )
            logger.error(
                "[PERSISTENCE] Canvas edit NOT saved for profile \(profile.id) — the stored layout is "
                + "from a newer build, so the write was refused. CONSEQUENCE: the unsaved-changes "
                + "indicator stays LIT, the workflow profile is not re-saved, and the on-canvas notice "
                + "tells the user to update the app."
            )
            return
        }

        if case .refusedUnreadable(let nodes, let edges, let annotations) = outcome {
            unreadableLayout = UnreadableLayoutInfo(
                profileID: profile.id, nodeCount: nodes, edgeCount: edges, annotationCount: annotations
            )
            logger.error(
                "[PERSISTENCE] Canvas edit NOT saved for profile \(profile.id) — the stored layout is "
                + "unreadable so the write was refused. CONSEQUENCE: the unsaved-changes indicator is "
                + "left LIT and the overlay now tells the user; the workflow profile is deliberately not "
                + "updated either, so the profile does not describe a canvas that was never written."
            )
            return
        }

        // `.failed` and `.notConfigured` also bail so nothing below runs; they get a toast since no overlay or banner covers
        // them. `WorkflowLayoutStore.save` leaves nothing pending on the shared context after `.failed`.
        guard outcome.didPersist else {
            let reason: String
            if case .failed(let message) = outcome {
                reason = message
            } else {
                reason = "the persistence store is not available"
            }
            logger.error(
                "[PERSISTENCE] Canvas edit NOT saved for profile \(profile.id) — \(reason). "
                + "CONSEQUENCE: the unsaved-changes indicator stays LIT, no owned-row reconcile "
                + "runs (it must never collect against a graph that never reached disk), and the "
                + "user sees an error toast. The edits remain in memory for another attempt."
            )
            toastManager.show(
                String(localized: "Couldn't save the workflow — \(reason). Your edits are still here; try saving again."),
                style: .error,
                duration: 5.0
            )
            return
        }

        // The write was not refused, so clear any standing newer-version notice for this profile.
        if newerVersionNotice?.profileID == profile.id {
            logger.info("[WF_CANVAS] Clearing the newer-version read-only notice for profile \(profile.id) — a save has now succeeded, so the stored layout is no longer from a newer build. CONSEQUENCE: the read-only banner is removed; it would otherwise contradict the successful save.")
            newerVersionNotice = nil
        }

        // Success path only: reconciles against the layout that reached disk, never the in-memory canvas, since it deletes
        // configuration. Skipped after a failed read, when a blank canvas would collect every node configuration.
        if canvasState.lastLoadDidFail {
            logger.error("[WF_CANVAS] Owned-row reconcile REFUSED for workflow \(profile.id): this canvas was loaded from a failed read, so its node set cannot be trusted as complete. CONSEQUENCE: rows for genuinely deleted nodes are left on disk this save — collected on the next save after a successful load — rather than risking deletion of configurations whose nodes still exist.")
        } else {
        profileService.reconcileOwnedProfiles(
            forWorkflow: profile.id,
            // Unions with the undo stack: a deleted-and-saved node is still one undo away, so its row must not be collected yet.
            // See `undoRecoverableProfileIDs`.
            referencedProfileIDs: Set(layout.nodes.compactMap(\.profileID))
                .union(canvasState.undoRecoverableProfileIDs)
        )
        }

        // Saves the profile only when it changed: in the profile editor `profile` is the edit buffer's draft. An
        // unconditional save is redundant and bumps `lastSelected`, reordering the recently-used list.
        let persisted = profileService.profiles.first { $0.id == profile.id }
        let profileNeedsWrite = persisted.map {
            $0.displayName != profile.displayName
                || $0.details != profile.details
                || $0.fileContextStrategy != profile.fileContextStrategy
        } ?? true

        guard profileNeedsWrite else {
            logger.debug("[WF_CANVAS] Workflow \(profile.id) profile record unchanged after the layout save — no write. CONSEQUENCE: its position in \"recently used\" is preserved, which an unconditional save would have disturbed on every canvas edit.")
            canvasState.markSaved()
            return
        }

        do {
            try profileService.saveProfile(profile)
            profileService.rebaseEditBuffer(to: profile)
        } catch {
            // Anything reaching here is a genuine failure worth telling the user about.
            logger.error(
                "[WF_CANVAS] Workflow profile record NOT updated for \(profile.id) after a "
                + "successful layout save: \(error.localizedDescription). CONSEQUENCE: the canvas "
                + "is on disk, but edits to the workflow's own name or execution settings are not; "
                + "the user is told via toast."
            )
            toastManager.show(
                String(localized: "The workflow canvas was saved, but its profile record couldn't be updated — \(error.localizedDescription)"),
                style: .warning,
                duration: 5.0
            )
        }

        // Every non-persisting outcome returned above, so reaching here means the bytes are on disk.
        canvasState.markSaved()
    }
}

// MARK: - Trackpad/Two-Finger Pan Support (iOS / iPadOS)

#if canImport(UIKit)
import UIKit

struct TwoFingerPanGestureModifier: ViewModifier {
    var onPan: (CGSize) -> Void
    
    func body(content: Content) -> some View {
        // Place in background to absorb touch events not claimed by standard UI components
        content.background(
            TwoFingerPanView(onPan: onPan)
        )
    }
}

struct TwoFingerPanView: UIViewRepresentable {
    var onPan: (CGSize) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPan: onPan)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPan: (CGSize) -> Void
        var lastTranslation: CGPoint = .zero

        init(onPan: @escaping (CGSize) -> Void) {
            self.onPan = onPan
        }

        @objc func handlePan(_ sender: UIPanGestureRecognizer) {
            guard let view = sender.view else { return }
            
            if sender.state == .began {
                lastTranslation = sender.translation(in: view)
            } else if sender.state == .changed {
                let translation = sender.translation(in: view)
                let dx = translation.x - lastTranslation.x
                let dy = translation.y - lastTranslation.y
                lastTranslation = translation
                
                if dx != 0 || dy != 0 {
                    onPan(CGSize(width: dx, height: dy))
                }
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
    }
}

extension View {
    func twoFingerPan(onPan: @escaping (CGSize) -> Void) -> some View {
        self.modifier(TwoFingerPanGestureModifier(onPan: onPan))
    }
}
#else
extension View {
    func twoFingerPan(onPan: @escaping (CGSize) -> Void) -> some View {
        self // Managed via native AppKit event monitor on macOS
    }
}
#endif

// MARK: - Workflow Layout Persistence
