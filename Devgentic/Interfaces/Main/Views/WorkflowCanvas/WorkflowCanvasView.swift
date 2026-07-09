//
//  WorkflowCanvasView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Main workflow canvas container.
//  Provides an infinite-scroll surface with dot grid, pan/zoom,
//  and renders nodes + edges + drag previews.
//

import SwiftUI
import os
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

private let logger = DGLogger(category: "WorkflowCanvasView")

struct WorkflowCanvasView: View {
    @Binding var profile: BackendProfileModel
    var onDelete: ((UUID) -> Void)? = nil
    /// Optional navigation guard. Provided by `WorkflowDedicatedView` (main interface) so
    /// leaving a dirty canvas (switch conversation/interface/execution) prompts
    /// Save/Discard/Cancel. Nil in the profile-editor context, which uses its own
    /// `ProfileEditBuffer` discard guard instead.
    let editGuard: WorkflowEditGuard?
    @Environment(BackendProfileService.self) var profileService
    @Environment(\.appTheme) private var theme

    @State private var canvasState: WorkflowCanvasState
    @State private var showingProfilePicker = false
    @State private var showingClearAlert = false
    @State private var showingWorkflowConfig = false

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @State private var scrollMonitor: Any?
    #endif

    init(profile: Binding<BackendProfileModel>, onDelete: ((UUID) -> Void)? = nil, editGuard: WorkflowEditGuard? = nil) {
        self._profile = profile
        self.onDelete = onDelete
        self.editGuard = editGuard
        self._canvasState = State(wrappedValue: WorkflowCanvasState(profileID: profile.wrappedValue.id))
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
            }
            .background(theme.primaryBackground)

            // Empty State Overlay (when no nodes exist)
            if canvasState.nodes.isEmpty {
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

            // Floating Controls Overlay
            WorkflowToolbarView(
                canvasState: canvasState,
                onAddProfile: { showingProfilePicker = true },
                onAddStructuralNode: { kind, name in
                    canvasState.addStructuralNode(kind: kind, displayName: name)
                },
                onClearCanvas: { showingClearAlert = true },
                onSave: saveLayout,
                onRevert: { canvasState.revert() },
                onOpenSettings: { showingWorkflowConfig = true }
            )
        }
        .onAppear {
            loadLayout()
            registerEditGuard()
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            setupScrollMonitor()
            #endif
        }
        .onChange(of: canvasState.hasUnsavedChanges) { _, dirty in
            // Mirror the canvas dirty-state into the nav guard (drives the tab dot +
            // whether navigation defers behind the Save/Discard/Cancel prompt).
            editGuard?.hasUnsavedChanges = dirty
        }
        .onDisappear {
            editGuard?.unregister()
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            removeScrollMonitor()
            #endif
        }
        .onChange(of: profile.id) {
            loadLayout()
            registerEditGuard()
        }
        .onDeleteCommand {
            canvasState.deleteSelected()
        }
        .sheet(isPresented: $showingProfilePicker) {
            WorkflowProfilePickerView(
                profiles: profileService.profiles,
                existingNodeProfileIDs: Set(canvasState.nodes.compactMap(\.profileID)),
                workflowProfileID: profile.id,
                onSelect: { selectedProfile in
                    canvasState.addNode(from: selectedProfile)
                }
            )
        }
        .alert("Clear Canvas?", isPresented: $showingClearAlert) {
            Button("Clear All", role: .destructive) { canvasState.clearCanvas() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all nodes and connections from the canvas. This cannot be undone.")
        }
        .onChange(of: canvasState.targetConfigNode) { _, node in
            if let node = node {
                showInspectorPanel(for: node)
            } else {
                NodeInspectorPanelManager.shared.close()
            }
        }
        .onChange(of: showingWorkflowConfig) { _, isShowing in
            if isShowing {
                showWorkflowConfigPanel()
            } else {
                NodeInspectorPanelManager.shared.close()
            }
        }
    }

    // MARK: - Custom Inspector Panels

    private func showInspectorPanel(for node: WorkflowNode) {
        NodeInspectorPanelManager.shared.show(
            minSize: NSSize(width: 800, height: 520),
            theme: theme,
            onClose: { canvasState.targetConfigNode = nil }
        ) {
            switch node.kind {
            case .condition:
                ConditionNodeInspectorView(node: bindingForNode(node.id))
            case .loop:
                LoopNodeInspectorView(
                    node: bindingForNode(node.id),
                    parentWorkflowID: profile.id,
                    availableWorkflows: profileService.profiles
                )
            case .code:
                CodeNodeInspectorView(node: bindingForNode(node.id))
            case .gate:
                GateNodeInspectorView(node: bindingForNode(node.id))
            case .action:
                ActionNodeInspectorView(
                    node: bindingForNode(node.id),
                    availableVariables: canvasState.knownVariableNames
                )
            case .profile:
                ProfileNodeInspectorView(
                    node: bindingForNode(node.id),
                    profile: profileService.profiles.first(where: { $0.id == node.profileID })
                )
                .environment(profileService)
            default:
                EmptyView()
            }
        }
    }

    private func showWorkflowConfigPanel() {
        NodeInspectorPanelManager.shared.show(
            minSize: NSSize(width: 800, height: 560),
            theme: theme,
            onClose: { showingWorkflowConfig = false }
        ) {
            WorkflowConfigSheet(profile: $profile) {
                canvasState.markDirty()
            }
        }
    }

    /// Creates a two-way binding into `canvasState.nodes` for a specific node ID.
    private func bindingForNode(_ nodeID: UUID) -> Binding<WorkflowNode> {
        Binding(
            get: {
                canvasState.nodes.first(where: { $0.id == nodeID })
                    ?? WorkflowNode(kind: .loop(LoopNodeConfig()), position: .zero, displayName: "Loop")
            },
            set: { newValue in
                if let idx = canvasState.nodes.firstIndex(where: { $0.id == nodeID }) {
                    canvasState.nodes[idx] = newValue
                    canvasState.markDirty()
                }
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
                        canvasState: canvasState
                    )
                }
            }

            // Layer 2: Drag Preview Edge (port-aware)
            if let drag = canvasState.edgeDragState,
               let sourcePos = canvasState.outputPortPosition(for: drag.sourceNodeID, portLabel: drag.sourcePortLabel) {
                WorkflowEdgeDragPreview(
                    sourcePoint: sourcePos,
                    currentPoint: drag.currentPoint
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
                    canvasState: canvasState
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

            Canvas { context, canvasSize in
                let gridSpacing: CGFloat = 20
                let dotSize: CGFloat = 1.5
                let dotColor = theme.surfaceOverlay
                let majorDotColor = theme.secondaryText.opacity(0.2)

                // Account for current pan offset and scale
                let offsetX = canvasState.canvasOffset.width.truncatingRemainder(dividingBy: gridSpacing * canvasState.canvasScale)
                let offsetY = canvasState.canvasOffset.height.truncatingRemainder(dividingBy: gridSpacing * canvasState.canvasScale)
                let scaledSpacing = gridSpacing * canvasState.canvasScale

                var x = offsetX
                while x < canvasSize.width {
                    var y = offsetY
                    while y < canvasSize.height {
                        let absoluteX = x - canvasState.canvasOffset.width
                        let absoluteY = y - canvasState.canvasOffset.height
                        let indexX = Int(round(absoluteX / scaledSpacing))
                        let indexY = Int(round(absoluteY / scaledSpacing))
                        let isMajor = indexX % 5 == 0 && indexY % 5 == 0

                        let size = isMajor ? dotSize * 2.0 : dotSize
                        let rect = CGRect(
                            x: x - size / 2,
                            y: y - size / 2,
                            width: size,
                            height: size
                        )
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(isMajor ? majorDotColor : dotColor)
                        )
                        y += scaledSpacing
                    }
                    x += scaledSpacing
                }
            }
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
        let state = canvasState // Capture object reference safely
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
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(theme.primaryText)

            Text("Add profiles to build your workflow pipeline.\nConnect outputs to inputs to define execution order.")
                .font(.subheadline)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Button {
                showingProfilePicker = true
            } label: {
                Label("Add First Profile", systemImage: "plus.circle.fill")
                    .font(theme.fontBody.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(.purple)
        }
        .padding(40)
    }

    // MARK: - Persistence

    private func loadLayout() {
        let layout = WorkflowLayoutStore.shared.load(for: profile.id)
        // Set profile map BEFORE load — load() calls revalidate() which needs the map
        canvasState.resolvedProfileMap = Dictionary(
            profileService.profiles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        canvasState.load(from: layout)
    }

    /// Installs (or refreshes) this canvas's hooks into the nav guard so Save/Discard
    /// from the navigation prompt operate on THIS canvas's layout. No-op outside the
    /// main interface (editGuard is nil in the profile editor, which has its own guard).
    private func registerEditGuard() {
        guard let editGuard else { return }
        editGuard.hasUnsavedChanges = canvasState.hasUnsavedChanges
        editGuard.register(
            save: { saveLayout() },
            discard: { canvasState.revert() }
        )
    }

    private func saveLayout() {
        let layout = canvasState.currentLayout()
        WorkflowLayoutStore.shared.save(layout, for: profile.id)

        // Sync the agents array in ProfileDetails while preserving execution config
        let referencedProfiles = profileService.profiles.filter { p in
            layout.nodes.contains(where: { $0.profileID == p.id })
        }
        let referencedIDs = referencedProfiles.map(\.id)
        if case .workflow(var existingConfig) = profile.details {
            existingConfig.agentProfileIDs = referencedIDs
            profile.details = .workflow(existingConfig)
        } else {
            profile.details = .workflow(WorkflowConfig(agentProfileIDs: referencedIDs))
        }
        do {
            try profileService.saveProfile(profile)
        } catch {
            // Workflow save failures are logged; the layout is already persisted locally
            logger.error("Failed to save workflow profile: \(error.localizedDescription)")
        }

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
// `WorkflowLayoutStore` now lives at
// `Devgentic/Core/Persistence/SwiftData/WorkflowLayoutStore.swift` and is
// SwiftData-backed. Same `load/save/delete` API surface — no changes needed
// at call sites in this file.
