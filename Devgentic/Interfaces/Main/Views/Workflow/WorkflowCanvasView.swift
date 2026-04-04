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

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WorkflowCanvasView")

struct WorkflowCanvasView: View {
    @Binding var profile: BackendProfileModel
    var onDelete: ((UUID) -> Void)? = nil
    @Environment(BackendProfileService.self) var profileService
    @Environment(\.appTheme) private var theme

    @StateObject private var canvasState: WorkflowCanvasState
    @State private var showingProfilePicker = false
    @State private var showingClearAlert = false

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @State private var scrollMonitor: Any?
    #endif

    init(profile: Binding<BackendProfileModel>, onDelete: ((UUID) -> Void)? = nil) {
        self._profile = profile
        self.onDelete = onDelete
        self._canvasState = StateObject(wrappedValue: WorkflowCanvasState(profileID: profile.wrappedValue.id))
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

            // Floating Controls Overlay
            WorkflowToolbarView(
                canvasState: canvasState,
                onAddNode: { showingProfilePicker = true },
                onClearCanvas: { showingClearAlert = true },
                onSave: saveLayout,
                onRevert: { canvasState.revert() }
            )
        }
        .onAppear {
            loadLayout()
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            setupScrollMonitor()
            #endif
        }
        .onDisappear {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            removeScrollMonitor()
            #endif
        }
        .onChange(of: profile.id) { _ in
            loadLayout()
        }
        .onDeleteCommand {
            canvasState.deleteSelected()
        }
        .sheet(isPresented: $showingProfilePicker) {
            WorkflowProfilePickerView(
                profiles: profileService.profiles,
                existingNodeProfileIDs: Set(canvasState.nodes.map(\.profileID)),
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
        .sheet(item: Binding<WorkflowNode?>(
            get: { canvasState.targetConfigNode },
            set: { canvasState.targetConfigNode = $0 }
        )) { node in
            if let targetProfile = profileService.profiles.first(where: { $0.id == node.profileID }) {
                WorkflowProfileEditorView(profile: targetProfile)
                    .environment(profileService)
            }
        }
    }

    // MARK: - Canvas Content (Nodes + Edges)

    private var canvasContent: some View {
        ZStack {
            // Layer 1: Committed Edges
            ForEach(canvasState.edges) { edge in
                if let sourcePos = canvasState.outputPortPosition(for: edge.sourceNodeID),
                   let targetPos = canvasState.inputPortPosition(for: edge.targetNodeID) {
                    WorkflowEdgeView(
                        edge: edge,
                        sourcePoint: sourcePos,
                        targetPoint: targetPos,
                        isSelected: canvasState.selectedEdgeID == edge.id,
                        onTap: { canvasState.select(edgeID: edge.id) },
                        onDelete: { canvasState.removeEdge(edge.id) }
                    )
                }
            }

            // Layer 2: Drag Preview Edge
            if let drag = canvasState.edgeDragState,
               let sourcePos = canvasState.outputPortPosition(for: drag.sourceNodeID) {
                WorkflowEdgeDragPreview(
                    sourcePoint: sourcePos,
                    currentPoint: drag.currentPoint
                )
            }

            // Layer 3: Nodes
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
        Canvas { context, canvasSize in
            let gridSpacing: CGFloat = 20
            let dotSize: CGFloat = 1.5
            let dotColor = theme.surfaceOverlay

            // Account for current pan offset and scale
            let offsetX = canvasState.canvasOffset.width.truncatingRemainder(dividingBy: gridSpacing * canvasState.canvasScale)
            let offsetY = canvasState.canvasOffset.height.truncatingRemainder(dividingBy: gridSpacing * canvasState.canvasScale)
            let scaledSpacing = gridSpacing * canvasState.canvasScale

            var x = offsetX
            while x < canvasSize.width {
                var y = offsetY
                while y < canvasSize.height {
                    let rect = CGRect(
                        x: x - dotSize / 2,
                        y: y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(dotColor)
                    )
                    y += scaledSpacing
                }
                x += scaledSpacing
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
            Image(systemName: "square.3.layers.3d.down.right")
                .font(.system(size: 48))
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
                    .font(.system(size: 14, weight: .medium))
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
        canvasState.load(from: layout)
    }

    private func saveLayout() {
        let layout = canvasState.currentLayout()
        WorkflowLayoutStore.shared.save(layout, for: profile.id)

        // Also sync the agents array in ProfileDetails for backward compat
        let referencedProfiles = profileService.profiles.filter { p in
            layout.nodes.contains(where: { $0.profileID == p.id })
        }
        let referencedIDs = referencedProfiles.map(\.id)
        profile.details = .workflow(WorkflowConfig(agentProfileIDs: referencedIDs))
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

/// Sidecar persistence for workflow canvas layout.
/// Stores node positions and edges keyed by workflow profile ID.
final class WorkflowLayoutStore {
    static let shared = WorkflowLayoutStore()
    private let userDefaultsPrefix = "workflowLayout_"

    func load(for profileID: UUID) -> WorkflowLayout {
        let key = userDefaultsPrefix + profileID.uuidString
        guard let data = UserDefaults.standard.data(forKey: key),
              let layout = try? JSONDecoder().decode(WorkflowLayout.self, from: data) else {
            return .empty
        }
        return layout
    }

    func save(_ layout: WorkflowLayout, for profileID: UUID) {
        let key = userDefaultsPrefix + profileID.uuidString
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func delete(for profileID: UUID) {
        let key = userDefaultsPrefix + profileID.uuidString
        UserDefaults.standard.removeObject(forKey: key)
    }
}
