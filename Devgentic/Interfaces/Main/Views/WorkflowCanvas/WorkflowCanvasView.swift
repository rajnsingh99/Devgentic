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

    /// ⚠️ OPTIONAL on purpose. Both production mounts sit under the app root that injects it, but a
    /// non-optional `@Environment(MainApplicationViewModel.self)` traps at runtime when the object is
    /// absent — which would make this view unconstructible in a preview or a future host that has no
    /// view model. The only thing it is used for is pushing the dirty mirror, which is a UI
    /// convenience; degrading to "no badge" is the correct failure mode, not a crash.
    @Environment(MainApplicationViewModel.self) private var mainViewModel: MainApplicationViewModel?

    /// The caller-owned canvas state. ⚠️ NEVER read this directly — read `canvasState`.
    ///
    /// ⚠️ EVERY production caller now injects, and must (WF-PE1): both mount sites resolve it from
    /// `MainApplicationViewModel.workflowCanvasState(for:)`, so a workflow has exactly ONE state
    /// object no matter how many surfaces show it.
    private let injectedCanvasState: WorkflowCanvasState?

    /// Fallback state for a caller that supplies none. ⚠️ NEVER read this directly — read
    /// `canvasState`.
    ///
    /// ⚠️ NO PRODUCTION CALLER SHOULD REACH THIS — it exists for previews and tests. Reaching it in
    /// the app means a second, independent graph for a profile that another surface may also be
    /// editing, and the layout store has no compare-and-swap to catch the resulting overwrite. It is
    /// kept (rather than made non-optional) so the view stays constructible in isolation, and
    /// `loadLayout()` logs an error naming the consequence whenever it is used.
    @State private var ownedCanvasState: WorkflowCanvasState

    /// The state this canvas edits — resolved PER RENDER, never frozen.
    ///
    /// ⚠️ The injected state MUST NOT be captured into `@State`. `State(wrappedValue:)` is honoured
    /// only on the first materialisation of a view identity, and this view's identity outlives a
    /// profile change: `chatArea` is always mounted (opacity-toggled, `MainApplicationView`), and
    /// `WorkflowDedicatedView` re-renders in place when `selectedProfileID` changes rather than
    /// being rebuilt. Freezing it meant the canvas kept workflow A's state after `profile` became
    /// B — so the canvas SHOWED A's graph under B's name, `loadLayout()` skipped B (A's state was
    /// dirty, so `acceptsDiskReload` was false), and Save wrote A's nodes to B's layout,
    /// destroying B's saved graph with no undo and no confirmation.
    private var canvasState: WorkflowCanvasState { injectedCanvasState ?? ownedCanvasState }

    @State private var showingProfilePicker = false
    @State private var showingClearAlert = false
    @State private var showingGuideline = false

    /// Set when this profile's stored canvas could not be decoded, with the denormalized counts the
    /// row still carries so the overlay can say what was lost.
    ///
    /// ⚠️ Held in `@State` and refreshed only in `loadLayout()` — NEVER read from `body`.
    /// `WorkflowLayoutStore.isLayoutUnreadable(for:)` runs a SwiftData fetch and primes a JSON decode,
    /// and `WorkflowDedicatedView`'s own header documents a prior regression from doing exactly that
    /// inside `body`: "an UNCACHED SwiftData fetch + JSON blob decode at streaming frequency, on the
    /// main thread, for the whole run."
    @State private var unreadableLayout: UnreadableLayoutInfo?

    /// Set when a save is refused because the stored layout was written by a NEWER build (WF-PE2).
    /// A notice, not the corruption overlay: the graph is intact and runnable, just read-only here.
    ///
    /// ⚠️ [WF-CU4] SCOPED TO THE PROFILE THAT PRODUCED IT, and rendered only while that profile is
    /// the one on screen. It was a bare `String?` with exactly one writer and no path back to nil,
    /// so after a refused save the "read-only — update Devgentic" banner followed the user onto
    /// every workflow they opened next, for the rest of the session — telling them a perfectly
    /// writable workflow could not be edited. This host re-renders IN PLACE on a profile switch, so
    /// nothing rebuilt the view to clear it.
    ///
    /// Carrying the id rather than clearing on a transition is deliberate: a clear-on-switch can be
    /// missed by any future path that changes the displayed profile without going through the one
    /// hook that does the clearing, and the failure is silent and long-lived. Pairing the id with
    /// the text makes a stale banner unrenderable by construction. Compare `lastEdgeRefusal`, which
    /// self-clears via `.task(id:)`.
    ///
    /// ⚠️ `unreadableLayout` is now scoped the SAME way, and this comment used to say it was safe
    /// because it "is manually recomputed in `loadLayout()`". That was untrue on the
    /// `acceptsDiskReload` early-return path, where the recompute was skipped entirely — and unlike
    /// this banner, that one carries a button that destroys the displayed workflow's graph. Both
    /// notices now carry their profile id; neither can be rendered against a workflow it does not
    /// describe.
    @State private var newerVersionNotice: ProfileScopedNotice?

    struct ProfileScopedNotice: Equatable {
        let profileID: UUID
        let message: String

        /// The notice to render for `displayedProfileID`, or nil when the stored notice belongs to
        /// a different workflow.
        ///
        /// `nonisolated static` and pure so the scoping rule is testable directly — a SwiftUI
        /// view's private computed property is not reachable from a test (the same reason
        /// `WorkflowExecutionTimelineView.finalOutcomeTagLabel` and
        /// `WorkflowExecutor.classifierUserPrompt` were extracted), and this rule IS the fix.
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
        /// ⚠️ SCOPED TO THE PROFILE IT DESCRIBES, for the reason `ProfileScopedNotice` above is:
        /// this host re-renders IN PLACE on a profile switch, so nothing rebuilds the view to clear
        /// a `@State` notice. It used to be unscoped on the argument that `loadLayout()` recomputes
        /// it — which is false on the `acceptsDiskReload` early-return path, so switching onto a
        /// workflow holding unsaved edits kept the PREVIOUS workflow's overlay on screen. That
        /// overlay's Discard button targets the DISPLAYED profile, so the one control in the app
        /// that deliberately destroys data was aimed at a perfectly readable graph.
        ///
        /// Pairing the id with the counts makes a stale overlay unrenderable by construction rather
        /// than relying on every future path that changes the displayed profile to clear it.
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

        /// The info to render for `displayedProfileID`, or nil when the stored one belongs to a
        /// different workflow.
        ///
        /// `nonisolated static` and pure for the same reason `ProfileScopedNotice.message` is: a
        /// SwiftUI view's private computed property is unreachable from a test, and this rule IS
        /// the fix.
        nonisolated static func active(
            _ stored: UnreadableLayoutInfo?,
            displayedProfileID: UUID
        ) -> UnreadableLayoutInfo? {
            guard let stored, stored.profileID == displayedProfileID else { return nil }
            return stored
        }
    }

    /// The unreadable-canvas overlay to render, or nil when the stored one belongs to another
    /// workflow. ⚠️ Read through this, NEVER `unreadableLayout` directly — the raw value can
    /// describe a workflow that is not on screen.
    private var activeUnreadableLayout: UnreadableLayoutInfo? {
        UnreadableLayoutInfo.active(unreadableLayout, displayedProfileID: profile.id)
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @State private var scrollMonitor: Any?
    #endif

    /// `canvasState` is INJECTED by callers whose view is torn down and rebuilt around a live edit —
    /// `WorkflowDedicatedView` flips between Canvas and Execution, and a run starting flips it
    /// automatically. Owning the state in `@State` there meant the flip destroyed every unsaved
    /// edit.
    ///
    /// ⚠️ `canvasState` is nominally optional but is REQUIRED of every production caller (WF-PE1).
    /// The profile editor used to keep the default and get its own state; because `chatArea` stays
    /// mounted under a non-chat destination, that gave one workflow TWO independent graphs, and the
    /// quit path wrote both to the same row — the second silently destroying the first. Pass
    /// `MainApplicationViewModel.workflowCanvasState(for:)`; do not add a caller that omits it.
    ///
    /// ⚠️ An injected state is stored in a `let`, NOT in `@State` — see `canvasState`. The `@State`
    /// fallback is seeded with it only so the non-injected path keeps one object for the view's
    /// lifetime; once `injectedCanvasState` is non-nil the fallback is never read again.
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
                // Push the pane size into the state so `nextAvailablePosition()` can centre new
                // nodes in the visible viewport — the toolbar and picker sheet that trigger adds
                // live OUTSIDE this GeometryReader and cannot ask a proxy themselves.
                .onAppear { canvasState.viewportSize = geometry.size }
                .onChange(of: geometry.size) { _, newSize in
                    canvasState.viewportSize = newSize
                }
            }
            .background(theme.primaryBackground)

            // Empty State Overlay (when no nodes exist)
            //
            // ⚠️ The unreadable case must win. An undecodable canvas ALSO renders as zero nodes, so
            // without this branch it got the identical "Workflow Canvas / Add profiles to build your
            // workflow pipeline" invitation a brand-new workflow gets — byte-for-byte the same view,
            // inviting the user to rebuild a canvas whose every save is being refused.
            if let activeUnreadableLayout {
                unreadableLayoutOverlay(activeUnreadableLayout)
            } else if canvasState.nodes.isEmpty {
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

            // Newer-version read-only notice (WF-PE2). Persistent while set — unlike the edge
            // refusal it is not transient: every save will refuse until the app updates.
            // ⚠️ [WF-CU4] Read through `activeNewerVersionNotice`, NEVER `newerVersionNotice`
            // directly — that accessor is what keeps a notice from rendering over the workflow it
            // does not belong to.
            if let notice = activeNewerVersionNotice {
                VStack {
                    Label(notice, systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
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

            // Refused-connection notice.
            //
            // ⚠️ The one thing this MUST do is stop the refusal being invisible. A drag that ended
            // in a cycle, a duplicate, or a miss simply made the preview line vanish — three
            // different causes, one indistinguishable non-event, and nothing in the log either.
            if let refusal = canvasState.lastEdgeRefusal {
                VStack {
                    Spacer()
                    Label(refusal.userMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
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
                .task(id: refusal) {
                    // Self-clearing so it cannot become permanent chrome. Cancellation-safe: a new
                    // refusal restarts the task and the old sleep is cancelled, so the message never
                    // clears the newer one out from under the user.
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    canvasState.lastEdgeRefusal = nil
                }
            }

            // ⌘Z, hosted on a hidden Button rather than `.onKeyPress`/`.keyboardShortcut` on the
            // canvas itself.
            //
            // ⚠️ The canvas's ONLY focus stop is the `.focusable()` on this view's root ZStack
            // (below), added purely so `.onDeleteCommand` can fire. There is no PER-NODE focus and
            // no key handler to hang ⌘Z on, so a `keyboardShortcut` on a Button is still the right
            // vehicle: it participates in the menu-key path and fires without needing focus.
            //
            // ⚠️ An earlier version of this comment claimed the directory had "no `.focusable()`,
            // no `@FocusState`". Both are false — see the `.focusable()` below and
            // `StickyNoteView`'s `@FocusState private var isTextFocused`. Corrected 2026-08-17;
            // the absence that actually matters is per-node focus (WF-CU11), not focus as such.
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
        .onChange(of: canvasState.hasUnsavedChanges) { _, dirty in
            // Mirror the canvas dirty-state into the nav guard (drives whether navigation defers
            // behind the Save/Discard/Cancel prompt) AND into the view model's mirror, which is what
            // keeps the badge lit after this view goes away.
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
            // [WF-CU3] RE-ARM the scroll monitor. Its closure captured the `WorkflowCanvasState`
            // that existed when it was installed, and this host re-renders IN PLACE on a profile
            // switch (no `.id()` at the `WorkflowDedicatedView` mount site, unlike the profile
            // editor) — so without this the monitor keeps acting on the PREVIOUS workflow's state,
            // which `MainApplicationViewModel.workflowCanvasState(for:)` keeps alive in its cache.
            // Two-finger trackpad panning then either does nothing (the old state's
            // `isHoveringCanvas` is false) or silently pans the off-screen graph while swallowing
            // the event, for the rest of the session.
            //
            // ⚠️ `.twoFingerPan` at the canvas ZStack is NOT a second path that could cover this —
            // it is `self` on macOS (see the `#else` arm of its extension); this AppKit monitor is
            // the only trackpad-pan implementation on this platform.
            //
            // Safe to read the NEW state here: `loadLayout()` above already depends on
            // `canvasState` resolving to the incoming profile's state at this point, and it
            // demonstrably does — the canvas has always reloaded the correct graph on a switch.
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            removeScrollMonitor()
            setupScrollMonitor()
            #endif
        }
        // ⚠️ `.onDeleteCommand` NEEDS a focusable ancestor to fire, and before THIS LINE there was
        // none, so the Delete key was very likely dead for EVERY user, not only keyboard-only ones
        // — the toolbar pill was the only route to deleting anything. This is the one change here
        // that a test cannot settle; it needs a manual check with a node selected.
        //
        // ⚠️ The earlier wording — "this whole directory contains no `.focusable()` and no
        // `@FocusState`" — was left in place after this very line was added, so it described the
        // state BEFORE the fix as though it were still true, and `StickyNoteView` has carried a
        // `@FocusState` all along. Corrected 2026-08-17.
        //
        // Deliberately on the canvas ZStack rather than per node: focus here restores the Delete
        // key without introducing a focus model that would compete with the pan, zoom, node-drag
        // and background-tap gestures. Keyboard traversal between nodes is a separate design.
        .focusable()
        // ⚠️ Suppresses the VISUAL only — focus itself remains, so `.onDeleteCommand` still fires.
        // Without this, macOS drew its blue focus ring around the entire canvas pane on every
        // click of the grid or a node: technically correct focus feedback, but a ring around the
        // whole working surface reads as a stray border, and the canvas communicates selection
        // through its own node/edge highlights. The trade-off: a keyboard user loses the one cue
        // that the canvas has focus — acceptable while the canvas has no internal keyboard
        // navigation for the ring to orient; revisit if a real focus model ever lands.
        .focusEffectDisabled()
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
        // ⚠️ Confirmation is not ceremony here. Everything up to this point is NON-destructive: the
        // original bytes survive precisely because writes are refused. This button is the only thing
        // in the app that deliberately throws them away, so it names what is being lost first.
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
            if let node = node {
                showInspectorPanel(for: node)
            } else {
                NodeInspectorPanelManager.shared.close()
            }
        }
    }

    // MARK: - Custom Inspector Panels

    /// Takes the node inspector down with the canvas (WF-CU9).
    ///
    /// ⚠️ The inspector is a SEPARATE always-on-top `NSWindow`, not part of this view's hierarchy,
    /// so nothing carries it away when the canvas is destroyed. Reached from every teardown: the
    /// auto-flip to `.execution` when a run starts, the user clicking the Execution segment, an
    /// interface-mode switch away from Workflow, and the workflow profile being deleted.
    ///
    /// ⚠️ Closed DIRECTLY rather than by nilling `targetConfigNode` and letting the `.onChange` at
    /// the bottom of `body` do it. That observer is a modifier on THIS view, and this view is being
    /// removed inside an animated transition, so the update carrying the change may never be
    /// delivered. Both actions are taken and both are idempotent — `close()` no-ops on a nil
    /// `activePanel`, a second nil write is a no-op — so it does not matter whether the observer
    /// also fires.
    ///
    /// ⚠️ `firingCallback: false`, then clear the state SYNCHRONOUSLY here. The default callback is
    /// `{ canvasState.targetConfigNode = nil }` run from the fade's 0.15 s completion handler, and
    /// `NodeInspectorPanelManager.close()`'s own doc comment records what deferring a shared-state
    /// clear cost last time — an undismissable window.
    private func dismissInspectorForTeardown() {
        let panelWasOnScreen = NodeInspectorPanelManager.shared.isPresented
        NodeInspectorPanelManager.shared.close(firingCallback: false)
        canvasState.canvasDidDisappear(panelWasOnScreen: panelWasOnScreen)
    }

    private func showInspectorPanel(for node: WorkflowNode) {
        NodeInspectorPanelManager.shared.show(
            minSize: NSSize(width: 800, height: 520),
            theme: theme,
            onClose: { canvasState.targetConfigNode = nil }
        ) {
            switch node.kind {
            case .condition:
                ConditionNodeInspectorView(node: bindingForNode(node.id))
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
                .environment(toastManager)
                .environment(router)
                .environment(themeManager)
            default:
                EmptyView()
            }
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
                // ⚠️ Through `replaceNode`, never `nodes[idx] = newValue`. Inspectors edit port
                // LABELS (Condition rules, Gate options) and edges address ports by label, so a
                // direct write strands every edge on a renamed port — the branch stops running
                // while the canvas still draws it connected.
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

            // Dot grid as one GPU-tiled bitmap (WF-CV9). This was a `Canvas` filling one `Path`
            // PER DOT on every pan/zoom frame — ~47,600 dots and 64.3 ms/frame at minimum zoom on a
            // large display, capping panning below 20 fps exactly when the user zooms out to survey
            // a big graph.
            //
            // ⚠️ Measured dead ends, do not resurrect (numbers in `WorkflowGridTile`'s header):
            // batching the dots into one path is 100× SLOWER, and re-blitting a cached tile through
            // `Canvas` per frame stays ~8 ms — CPU compositing is bandwidth-bound however few draw
            // calls issue it. `ImagePaint` tiles on the GPU: panning is now a layer transform with
            // zero per-frame grid CPU, and the only remaining CPU cost is tile REGENERATION
            // (1.19 ms worst case), paid only when zoom or theme changes.
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
                // ⚠️ `.position` (of the CENTER), not `.offset`: offset composes with the enclosing
                // ZStack's alignment, and under the default center alignment a NEGATIVE phase —
                // i.e. panning left/up — left a grid-free strip up to one tile wide on the
                // trailing/bottom edges. Position is alignment-independent: the rect's origin lands
                // at exactly (phase − side), covering both phase signs, and ImagePaint anchors its
                // tiling to that origin, which is what carries the pan phase.
                .position(x: phaseX + size.width / 2, y: phaseY + size.height / 2)
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
        // ⚠️ [WF-CU3] This capture is the whole reason the monitor must be re-armed whenever
        // `canvasState` changes identity (i.e. on a profile switch — see `.onChange(of: profile.id)`).
        // It is deliberately still a capture rather than a live lookup: the closure outlives any
        // single render, and a SwiftUI `View` struct captured into it would be an equally stale
        // snapshot of the same `let`, not a fix.
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

    /// Shown INSTEAD of the empty-state invitation when the stored canvas could not be decoded.
    ///
    /// Tone follows `MCPStatusBanner`: silent when healthy, explicit only when something is actually
    /// down. It states three things the user cannot otherwise learn — that this is a read failure and
    /// not an empty canvas, what the canvas used to hold, and that the original bytes are still there.
    @ViewBuilder
    private func unreadableLayoutOverlay(_ info: UnreadableLayoutInfo) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48)) // Fixed size: matches the empty-state glyph it replaces
                .foregroundColor(theme.warningColor)

            Text("This canvas could not be read")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(theme.primaryText)

            Text(
                info.heldContent
                // The counts live OUTSIDE the blob, written by the last successful save, so they are
                // still trustworthy — which is what makes this message specific instead of vague.
                ? "It last held \(info.summary), but the saved layout can't be decoded by this version.\n\nYour data has not been deleted — edits are being refused so it stays recoverable by a future build."
                : "The saved layout can't be decoded by this version.\n\nYour data has not been deleted — edits are being refused so it stays recoverable by a future build."
            )
            .font(.subheadline)
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420)

            Button(role: .destructive) {
                showingDiscardUnreadableAlert = true
            } label: {
                Label("Discard and Start Over", systemImage: "trash")
                    .font(theme.fontBody.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
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
        // ⚠️ INVARIANT: this canvas edits the state belonging to the profile it is displaying.
        //
        // Everything below assumes it. If they diverge, the dirty-edits guard immediately after
        // reads the WRONG canvas's dirty flag, the user is shown one workflow's graph under
        // another's name, and `saveLayout()` writes those nodes to `profile.id` — silently
        // replacing that profile's stored graph, with no undo. That is exactly what happened while
        // an injected `WorkflowCanvasState` was frozen into `@State`; `canvasState` is now resolved
        // per render, so a mismatch here means a NEW way for the two to drift.
        //
        // `assert` is stripped in release, so it is paired with an error log that names the
        // consequence — a support bundle has to be able to show this.
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

        // ⚠️ WF-PE1 tripwire. Every production mount injects a state from
        // `MainApplicationViewModel.workflowCanvasState(for:)` so a workflow has exactly ONE state
        // object; falling back to `ownedCanvasState` means a second, independent graph now exists
        // for this profile. That is invisible until quit, when both are written to the same
        // `WorkflowLayoutSD` row and the later write destroys the earlier one — so it is reported
        // HERE, at the moment it becomes true, rather than after the data is gone.
        //
        // `assert` is stripped in release, so it is paired with an error log naming the consequence.
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

        // ⚠️ NEVER reload over unsaved edits.
        //
        // The canvas state can outlive this view (it is injected by `WorkflowDedicatedView` so
        // edits survive the Canvas↔Execution flip), so `.onAppear` fires again on a state that is
        // already mid-edit. Reloading from disk there would silently replace the user's work with
        // the last-saved layout AND clear the dirty flag — reintroducing, on the way back, exactly
        // the loss that keeping the state alive was meant to prevent.
        //
        // Correct for a freshly-created state too: it starts clean, so the first load runs.
        // ⚠️ ABOVE the dirty guard, deliberately. Whether the STORED blob decodes is a property of
        // the row on disk, not of the in-memory edits, and this is the only writer on the load path
        // — so leaving it below the early return meant switching onto a workflow with unsaved edits
        // never refreshed it, and the previous workflow's overlay (with its destructive Discard
        // button, aimed at whatever is now displayed) stayed on screen. Profile-scoping the value
        // makes that unrenderable; recomputing here makes it correct rather than merely hidden.
        refreshUnreadableLayoutState()

        guard canvasState.acceptsDiskReload else {
            logger.info(
                "[WF_CANVAS] Skipped reloading the layout for profile \(profile.id) — the canvas has "
                + "unsaved edits in memory. CONSEQUENCE: the on-disk layout is deliberately NOT read; "
                + "the user's in-progress edits stay on screen and the dirty state is preserved."
            )
            registerEditGuardDirtyState()
            return
        }

        let layout = WorkflowLayoutStore.shared.load(for: profile.id)
        // Set profile map BEFORE load — load() calls revalidate() which needs the map
        canvasState.resolvedProfileMap = Dictionary(
            profileService.profiles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        canvasState.load(from: layout)
    }

    /// Re-derives the unreadable-canvas overlay for the DISPLAYED profile.
    ///
    /// Ask BEFORE loading — `load(for:)` returns `.empty` on failure and discards the reason, so by
    /// the time we hold the layout the two cases are indistinguishable.
    ///
    /// ⚠️ Called from `loadLayout()` only, never from `body`: `isLayoutUnreadable(for:)` runs a
    /// SwiftData fetch and primes a JSON decode — see this property's declaration for the
    /// regression that caused at streaming frequency.
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

    /// Deliberately throws away an unreadable canvas so the profile becomes editable again.
    ///
    /// Routes through `repairUnreadableLayout(_:for:reason:)` rather than `save(_:for:)` — that is
    /// the whole point of the two being separate. `save` is refused while the blob is unreadable;
    /// repair is the explicit, logged, user-authorized exception, and the `reason` it takes exists so
    /// the log records WHO authorized it rather than just that it happened.
    private func discardUnreadableLayout() {
        // ⚠️ LAST LINE OF DEFENCE, and it must stay even though the overlay is now profile-scoped.
        // This is the only control in the app that deliberately destroys a user's graph, and it acts
        // on whatever profile is DISPLAYED. Scoping the overlay makes the stale-overlay route to it
        // unrenderable; this makes repairing a healthy row unreachable regardless of how the call
        // was arrived at — a cheaper guarantee than auditing every future path to the button.
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

    /// Installs (or refreshes) this canvas's hooks into the nav guard so Save/Discard
    /// from the navigation prompt operate on THIS canvas's layout.
    ///
    /// ⚠️ BOTH mount sites pass an `editGuard`, and they pass DIFFERENT instances by design: the
    /// main Workflow interface registers into `MainApplicationViewModel.workflowEditGuard`, the
    /// profile editor into `BackendProfileService.canvasEditGuard`. Two guards are required because
    /// both canvases can be mounted at once (`chatArea` stays alive, opacity-toggled, under a
    /// non-chat destination), so a single shared guard would let whichever registered last clear the
    /// other's hooks and dirty flag. (An earlier comment here claimed the profile editor passed no
    /// guard at all — it always did.)
    ///
    /// The profile ID travels with the hooks so an exit point can tell WHICH workflow the installed
    /// `saveHook` writes — see `WorkflowEditGuard.registeredProfileID`.
    private func registerEditGuard() {
        guard let editGuard else { return }
        registerEditGuardDirtyState()
        editGuard.register(
            profileID: profile.id,
            save: { saveLayout() },
            discard: { canvasState.revert() }
        )
    }

    /// Pushes the canvas's current dirty state into the guard.
    ///
    /// Split out because it must also run on the early return in `loadLayout()`: a canvas coming
    /// back with unsaved edits has to re-arm the tab dot and the navigation prompt, which
    /// `unregister()` cleared when the view went away.
    private func registerEditGuardDirtyState() {
        editGuard?.hasUnsavedChanges = canvasState.hasUnsavedChanges
        // ⚠️ Also push the view-model mirror, which is what survives this view's teardown. The guard
        // above is cleared by `unregister()` on `onDisappear`, so it alone cannot keep the dirty
        // badge lit once the canvas is unmounted — which is precisely when the user needs telling.
        mainViewModel?.setWorkflowCanvasDirty(canvasState.hasUnsavedChanges, for: profile.id)
    }

    private func saveLayout() {
        // ⚠️ REFUSE to write one workflow's graph over another's — the guard lives on the state
        // itself (`layout(forProfile:)`), which owns the id being compared. Checked here as well as
        // in `loadLayout()` because this is the call that actually destroys data, and it is
        // reachable from the nav guard's `saveHook` without a load in between.
        guard let layout = canvasState.layout(forProfile: profile.id) else {
            assertionFailure("saveLayout would write \(canvasState.profileID)'s graph to \(profile.id)")
            return
        }

        let outcome = WorkflowLayoutStore.shared.save(layout, for: profile.id)

        // ⚠️ BAIL on a refusal, before touching the profile.
        //
        // Two bugs lived here. The layout write is refused when the stored canvas is unreadable, and
        // this method (a) ignored the outcome and (b) called `markSaved()` unconditionally at the
        // end — so the dirty indicator CLEARED and the user was actively told their edit was saved
        // when it had been discarded. Worse, the `agentProfileIDs` write below still went through,
        // leaving the profile's agent list describing a canvas that was never persisted.
        // A layout saved by a NEWER build is read-only here (WF-PE2): re-encoding on this build
        // would permanently strip every field it does not understand. Distinct from the corruption
        // overlay on purpose — nothing is broken, and steering the user toward the destructive
        // repair would invite exactly the loss the refusal prevents. Dirty stays lit; the notice
        // names the remedy (update the app).
        if case .refusedNewerVersion(let blobVersion, let appVersion) = outcome {
            newerVersionNotice = ProfileScopedNotice(
                profileID: profile.id,
                message: String(localized: "This workflow was saved by a newer version of Devgentic (v\(blobVersion) format; this build writes v\(appVersion)). It's read-only here — update Devgentic to edit it.")
            )
            logger.error(
                "[PERSISTENCE] Canvas edit NOT saved for profile \(profile.id) — the stored layout is "
                + "from a newer build, so the write was refused. CONSEQUENCE: the unsaved-changes "
                + "indicator stays LIT, agentProfileIDs is not updated, and the on-canvas notice "
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
                + "left LIT and the overlay now tells the user; agentProfileIDs is deliberately not "
                + "updated either, so the profile does not describe a canvas that was never written."
            )
            return
        }

        // [WF-PE3] The remaining two non-persisting outcomes — `.failed` (the context save threw:
        // disk full, SwiftData error) and `.notConfigured` (no container) — used to FALL THROUGH
        // here: the profile was rewritten with `agentProfileIDs` recomputed from an in-memory
        // graph that never reached disk, and the user saw no error at all — just the dirty
        // indicator staying lit, indistinguishable from the app being slow. The store now
        // guarantees `.failed` means "not on disk AND nothing left pending on the shared context"
        // (see `WorkflowLayoutStore.save`'s rollback), so bailing here is sufficient: nothing
        // below may run, and unlike the two refusals above this one gets a toast because no
        // overlay or banner exists for it.
        guard outcome.didPersist else {
            let reason: String
            if case .failed(let message) = outcome {
                reason = message
            } else {
                reason = "the persistence store is not available"
            }
            logger.error(
                "[PERSISTENCE] Canvas edit NOT saved for profile \(profile.id) — \(reason). "
                + "CONSEQUENCE: the unsaved-changes indicator stays LIT, agentProfileIDs is not "
                + "rewritten (the profile must not describe a graph that never reached disk), and "
                + "the user sees an error toast. The edits remain in memory for another attempt."
            )
            toastManager.show(
                String(localized: "Couldn't save the workflow — \(reason). Your edits are still here; try saving again."),
                style: .error,
                duration: 5.0
            )
            return
        }

        // [WF-CU4] The write was NOT refused, so this workflow is not read-only after all — clear
        // any standing newer-version notice. Profile-scoping keeps a notice off OTHER workflows;
        // this is the same-profile half (the stored blob was repaired or replaced since the
        // refusal), where the banner would otherwise contradict a save the user just watched
        // succeed.
        if newerVersionNotice?.profileID == profile.id {
            logger.info("[WF_CANVAS] Clearing the newer-version read-only notice for profile \(profile.id) — a save has now succeeded, so the stored layout is no longer from a newer build. CONSEQUENCE: the read-only banner is removed; it would otherwise contradict the successful save.")
            newerVersionNotice = nil
        }

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
            // ⚠️ The profile editor binds `profile` straight to `editBuffer.draft`, so this write
            // IS the draft going to disk — but nothing re-baselined `original`, leaving a
            // just-saved workflow permanently dirty. Switching profiles then demanded "discard
            // unsaved changes?" for work that had been saved seconds earlier, and the canvas has
            // no Save/Revert pill that could clear it: the only exits were a phantom discard or a
            // relaunch. No-ops when the canvas is hosted outside the editor.
            profileService.rebaseEditBuffer(to: profile)
        } catch {
            // [WF-PE3 revalidation] This swallow used to hide BOTH arms. Split, because they are
            // different sentences:
            //  - An EMPTY `referencedIDs` (a canvas of only Router/Code/Gate nodes) is REFUSED by
            //    `ProfileValidator`'s blocking empty-list rule on every update — routine for a
            //    legitimate mid-construction canvas, so no toast: the layout DID persist, only the
            //    agent-list sync is skipped, and it self-heals on the first save after a profile
            //    node is added. (Whether the validator SHOULD block an empty list is register B36's
            //    territory, not this fix's.)
            //  - Anything else is a real failure worth telling the user about: the canvas is on
            //    disk but the profile record now lags it.
            if referencedIDs.isEmpty {
                logger.notice(
                    "[WF_CANVAS] Profile sync SKIPPED for workflow \(profile.id): the canvas "
                    + "references no agent profiles and the validator blocks an empty "
                    + "agentProfileIDs on update (\(error.localizedDescription)). CONSEQUENCE: the "
                    + "LAYOUT is saved; the profile's agent list keeps its previous value until a "
                    + "profile node is added and the next save syncs it."
                )
            } else {
                logger.error(
                    "[WF_CANVAS] Workflow profile record NOT updated for \(profile.id) after a "
                    + "successful layout save: \(error.localizedDescription). CONSEQUENCE: the "
                    + "canvas is on disk but agentProfileIDs still describes the previous graph "
                    + "until a later save succeeds; the user is told via toast."
                )
                toastManager.show(
                    String(localized: "The workflow canvas was saved, but its profile record couldn't be updated — \(error.localizedDescription)"),
                    style: .warning,
                    duration: 5.0
                )
            }
        }

        // Unconditional by construction: every non-persisting outcome returned above — the two
        // refusal arms and the [WF-PE3] guard — so reaching here means the bytes are on disk,
        // which is exactly what `markSaved()` claims.
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
