//
//  StickyNoteView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Draggable, resizable annotation on the workflow canvas.
//  No ports, no execution — purely visual documentation.
//

import SwiftUI

struct StickyNoteView: View {
    let note: StickyNote
    let isSelected: Bool
    var canvasState: WorkflowCanvasState

    @Environment(\.appTheme) private var theme
    @State private var isEditing = false

    /// Drives the commit-on-focus-loss path.
    ///
    /// ⚠️ Before this, `commitText()` had exactly two callers: `.onSubmit` on a `TextEditor`, which
    /// never fires (Return inserts a newline in multi-line text), and a tap on the note itself. So
    /// typing a note and then clicking ANYWHERE ELSE — the most natural next action — left the text
    /// stranded in this view's `@State` and destroyed it the moment the canvas unmounted, which a
    /// run does automatically by flipping to the Execution view. The toolbar said "All changes
    /// saved" throughout, so it was false reassurance rather than merely silence.
    @FocusState private var isTextFocused: Bool
    @State private var editText: String = ""
    @State private var isHovering = false
    
    // Tracks localized size during an active resize gesture to prevent global canvas layout thrashing.
    @State private var localResizeSize: CGSize?
    
    // Calculates the effective real-time size
    private var currentSize: CGSize {
        localResizeSize ?? note.size
    }
    
    // Retrieves node drag offset synchronously from the canvas state
    private var dragOffset: CGSize {
        canvasState.nodeDragOffset(for: note.id) // It's mapped in the same dictionary for unified drag logic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Header bar with drag handle and colors ---
            HStack(spacing: 4) {
                // Dim down the standard drag handle unless hovered
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(note.color.swiftUIColor.opacity(0.6))
                    .opacity(isHovering || isSelected ? 1 : 0)

                Spacer()

                // Color picker
                if isHovering || isSelected {
                    HStack(spacing: 4) {
                        ForEach(StickyNoteColor.allCases, id: \.self) { color in
                            Circle()
                                .fill(color.swiftUIColor)
                                .frame(width: 10, height: 10)
                                .overlay(
                                    Circle().stroke(Color.white.opacity(color == note.color ? 0.9 : 0.2), lineWidth: 1.5)
                                )
                                .onTapGesture {
                                    canvasState.updateStickyNoteColor(note.id, color: color)
                                }
                        }
                    }
                    // Small offset to not clash with the dog-ear fold on the right
                    .padding(.trailing, 16)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            // Header is draggable 
            .contentShape(Rectangle())

            // --- Text content ---
            if isEditing {
                TextEditor(text: $editText)
                    .focused($isTextFocused)
                    .onAppear { isTextFocused = true }
                    .onChange(of: isTextFocused) { _, focused in
                        // Clicking away is a commit, not a discard.
                        if !focused && isEditing { commitText() }
                    }
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .onSubmit {
                        commitText()
                    }
            } else {
                // ⚠️ `String(localized:)` on the placeholder (WF-CU8 class). The `note.text` branch
                // types the whole ternary as `String`, which binds `Text`'s verbatim init — so this
                // literal never reached the String Catalog and would have shipped untranslated.
                // Visible wording is byte-identical, and it stays ONE `Text(_: String)` call, so no
                // view identity changes.
                Text(note.text.isEmpty ? String(localized: "Double-click to edit...") : note.text)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundColor(note.text.isEmpty ? theme.secondaryText.opacity(0.6) : theme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(
            ZStack {
                // Main paper body
                StickyNoteShape()
                    .fill(note.color.swiftUIColor.opacity(0.2))
                
                // Dog-ear folded corner
                StickyNoteFold()
                    .fill(note.color.swiftUIColor.opacity(0.35))
                    .shadow(color: Color.black.opacity(0.1), radius: 1, x: -1, y: 1)
            }
            .clipShape(StickyNoteShape())
        )
        .overlay(
            StickyNoteShape()
                .stroke(
                    isSelected ? theme.accentColor : note.color.swiftUIColor.opacity(0.5),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(
            color: note.color.swiftUIColor.opacity(isHovering ? 0.3 : 0.15),
            radius: isHovering ? 6 : 3, x: 0, y: isHovering ? 4 : 2
        )
        .onTapGesture(count: 2) {
            editText = note.text
            isEditing = true
        }
        .onTapGesture {
            if isEditing {
                commitText()
            } else {
                canvasState.select(annotationID: note.id)
            }
        }
        .gesture(isEditing ? nil : dragGesture)
        .onHover { isHovering = $0 }
        // Backstop for the unmount path, which no focus change accompanies: switching to the
        // Execution view (a run does this automatically) tears this view down mid-edit.
        .onDisappear { if isEditing { commitText() } }
        
        // --- Resize Handle ---
        .overlay(alignment: .bottomTrailing) {
            if isHovering || isSelected {
                resizeHandle
            }
        }
        
        // MARK: Accessibility (WF-CU7)
        //
        // ⚠️ The note was the ONE canvas object with no accessibility at all — `grep -c accessibility`
        // on this file returned 0 — while `WorkflowNodeView` and `WorkflowEdgeView` both carry a
        // full label + actions treatment. Selecting, editing, deleting and recolouring a note
        // existed ONLY as pointer gestures, so any documentation the author put on the canvas was
        // inert for a VoiceOver user.
        //
        // Every action below calls the SAME `canvasState` method its pointer gesture calls, so this
        // is a second route to existing behaviour, not a new interaction model. Move and resize are
        // deliberately ABSENT, for the same reason they are absent on nodes: keyboard nudge-to-move
        // is a real interaction design competing with three live gesture recognizers, not an
        // accessibility patch. ⚠️ This brings notes to PARITY with nodes; it does not make them
        // movable, and the register row must not claim otherwise.
        //
        // ⚠️ PLACEMENT IS LOAD-BEARING, three ways:
        //   1. AFTER the resize-handle overlay, so the handle folds into this one element instead of
        //      surfacing as a stray unlabelled Image beside every note.
        //   2. BEFORE `.position`, mirroring the node, whose a11y block sits on its card while
        //      `.position` is applied outside.
        //   3. BELOW the gestures, and NEVER between the two `.onTapGesture`s — that pair must stay
        //      adjacent for double-tap to win over single-tap.
        //
        // POINTER BEHAVIOUR IS UNCHANGED: accessibility modifiers neither hit-test nor affect
        // layout; nothing is inserted between the gestures; no `.contentShape` is added (the note's
        // hit region comes from its clipped background shape and must keep that shape, dog-ear and
        // all); and no `.focusable()` is introduced to compete with the canvas's single focus stop.
        //
        // ⚠️ `children:` is CONDITIONAL, and the condition is the whole point. A flat `.ignore`
        // would delete the TextEditor from the accessibility tree, so the "Edit text" action below
        // would lead a VoiceOver user into a field they cannot see. `.contain` while editing keeps
        // it reachable. Only the ARGUMENT varies — an `if isEditing` at chain level would give the
        // note two view identities and tear the editor down on every toggle.
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(canvasState.accessibilityDescription(for: note))
        .accessibilityValue(isSelected ? Text("Selected") : Text(""))
        .accessibilityAddTraits(isEditing ? [] : (isSelected ? [.isButton, .isSelected] : .isButton))
        .accessibilityAction(named: Text("Select")) {
            canvasState.select(annotationID: note.id)
        }
        .accessibilityAction(named: Text("Edit text")) {
            // The same two lines the double-tap runs.
            editText = note.text
            isEditing = true
        }
        .accessibilityAction(named: Text("Delete note")) {
            // ⚠️ Direct, not via the canvas's `.onDeleteCommand`. The node does the same, which
            // sidesteps the focus stop entirely. `removeStickyNote` already pushes an undo snapshot.
            canvasState.removeStickyNote(note.id)
        }
        // ⚠️ Recolouring CANNOT be exposed by labelling the swatches. That row renders only when
        // `isHovering || isSelected`, and `isHovering` is written solely by `.onHover` — a
        // pointer-only signal VoiceOver never fires — so labels there would be affordances absent
        // from the tree for exactly the users they are for. They are also bare `Circle()` shapes,
        // which produce no element to label. Actions on the note's own element are the only route
        // that survives `children: .ignore`.
        .accessibilityActions {
            Button("Make yellow") { canvasState.updateStickyNoteColor(note.id, color: .yellow) }
            Button("Make blue")   { canvasState.updateStickyNoteColor(note.id, color: .blue) }
            Button("Make green")  { canvasState.updateStickyNoteColor(note.id, color: .green) }
            Button("Make pink")   { canvasState.updateStickyNoteColor(note.id, color: .pink) }
            Button("Make purple") { canvasState.updateStickyNoteColor(note.id, color: .purple) }
        }

        // --- Apply Positions & Offsets Here, instead of parent! ---
        .position(
            x: note.position.x + currentSize.width / 2,
            y: note.position.y + currentSize.height / 2
        )
        .offset(dragOffset)
    }

    private func commitText() {
        if editText != note.text {
            canvasState.updateStickyNoteText(note.id, text: editText)
        }
        isEditing = false
    }

    // MARK: - Drag to Move

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("canvasContent"))
            .onChanged { value in
                if canvasState.activeNodeDrag == nil {
                    canvasState.select(annotationID: note.id)
                }
                // Reuse activeNodeDrag for smooth offsetting locally
                canvasState.activeNodeDrag = (nodeID: note.id, offset: value.translation)
            }
            .onEnded { value in
                let newPos = CGPoint(
                    x: max(0, note.position.x + value.translation.width),
                    y: max(0, note.position.y + value.translation.height)
                )
                canvasState.activeNodeDrag = nil
                canvasState.moveStickyNote(note.id, to: newPos)
            }
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(note.color.swiftUIColor.opacity(0.8))
            .frame(width: 24, height: 24)
            // ⚠️ Hidden, NOT unlabelled (WF-CU7). It is a drag-only affordance with nothing to say,
            // and while the note is being edited — when the element is `children: .contain` — it
            // would otherwise surface as a stray unlabelled Image beside every note.
            .accessibilityHidden(true)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasContent"))
                    .onChanged { value in
                        // Locally compute the bounds to avoid causing the ENTIRE canvas state 
                        // to evaluate and rerender `WorkflowCanvasState.annotations`.
                        let newSize = CGSize(
                            width: max(100, note.size.width + value.translation.width),
                            height: max(60, note.size.height + value.translation.height)
                        )
                        localResizeSize = newSize
                    }
                    .onEnded { value in
                        // Send the mutation up to the brain exactly once on release
                        let finalSize = CGSize(
                            width: max(100, note.size.width + value.translation.width),
                            height: max(60, note.size.height + value.translation.height)
                        )
                        localResizeSize = nil
                        canvasState.resizeStickyNote(note.id, to: finalSize)
                    }
            )
            .padding(2)
            .background(
                Color.clear.frame(width: 32, height: 32)
            )
    }
}

// MARK: - Custom Shapes

/// A rectangle with a diagonally cut top-right corner.
private struct StickyNoteShape: Shape {
    let foldSize: CGFloat = 16
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width - foldSize, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: foldSize))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

/// The folded dog-ear triangle in the top right corner.
private struct StickyNoteFold: Shape {
    let foldSize: CGFloat = 16
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width - foldSize, y: 0))
        path.addLine(to: CGPoint(x: rect.width - foldSize, y: foldSize))
        path.addLine(to: CGPoint(x: rect.width, y: foldSize))
        path.closeSubpath()
        return path
    }
}
