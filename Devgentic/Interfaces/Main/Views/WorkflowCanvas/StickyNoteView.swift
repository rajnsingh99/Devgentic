// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StickyNoteView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A draggable, resizable annotation on the workflow canvas.
/// Has no ports and no execution; purely visual documentation.
struct StickyNoteView: View {
    let note: StickyNote
    let isSelected: Bool
    var canvasState: WorkflowCanvasState

    @Environment(\.appTheme) private var theme
    @State private var isEditing = false

    /// Drives the commit-on-focus-loss path, so text typed into a note is saved when focus moves elsewhere.
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

    // MARK: - Subviews

    @ViewBuilder
    private var headerBar: some View {
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
                            .pointingHandCursor()
                    }
                }
                // Small offset to not clash with the dog-ear fold on the right
                .padding(.trailing, 16)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var textContent: some View {
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
            // `String(localized:)` keeps the placeholder in the String Catalog; the ternary would otherwise bind the verbatim init.
            Text(note.text.isEmpty ? String(localized: "Double-click to edit") : note.text)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundColor(note.text.isEmpty ? theme.placeholderText : theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var notePaperBackground: some View {
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
    }

    @ViewBuilder
    private var noteCardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            textContent
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(notePaperBackground)
        .overlay(
            StickyNoteShape()
                .stroke(
                    isSelected ? theme.accentColor : note.color.swiftUIColor.opacity(0.4),
                    lineWidth: isSelected ? 1.75 : 1.0
                )
        )
    }

    var body: some View {
        noteCardContent
            .shadow(
                color: theme.shadowColor.opacity(isSelected ? 0.20 : (isHovering ? 0.12 : 0.06)),
                radius: isSelected ? 8 : (isHovering ? 5 : 2.5),
                x: 0, y: isSelected ? 4 : 2
            )
            .shadow(
                color: isSelected ? theme.accentColor.opacity(0.16) : (isHovering ? note.color.swiftUIColor.opacity(0.15) : Color.clear),
                radius: 6,
                x: 0, y: 0
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
        // Why: placement is load-bearing: after the resize overlay, before `.position`, never between the two `.onTapGesture`s
        // Accessibility: each action calls the same `canvasState` method as its pointer gesture; move and resize are omitted.
        // `children:` is `.contain` while editing so the editor stays reachable; only the argument varies, keeping one identity.
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
            // Deletes directly rather than via the canvas's `.onDeleteCommand`, as the node does; the call pushes an undo snapshot.
            canvasState.removeStickyNote(note.id)
        }
        // Why: the swatch row renders only on pointer hover, which VoiceOver never triggers
        // Recolouring is exposed as actions on the note's element, not swatch labels.
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
                // Same unbounded rule as a node drag, through the same function — see
                // `committedDragPosition` for why notes and nodes must not grow separate ones.
                let newPos = WorkflowCanvasState.committedDragPosition(
                    origin: note.position,
                    translation: value.translation
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
            // Hidden from accessibility: a drag-only affordance that would otherwise surface as an unlabelled image while editing.
            .accessibilityHidden(true)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasContent"))
                    .onChanged { value in
                        // Computes the bounds locally to avoid re-evaluating `WorkflowCanvasState.annotations`.
                        // The floor is `StickyNote.minimumSize`, the same constant `resizeStickyNote` clamps to.
                        localResizeSize = StickyNote.resizedSize(
                            from: note.size,
                            translation: value.translation
                        )
                    }
                    .onEnded { value in
                        // Send the mutation up to the brain exactly once on release
                        let finalSize = StickyNote.resizedSize(
                            from: note.size,
                            translation: value.translation
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
