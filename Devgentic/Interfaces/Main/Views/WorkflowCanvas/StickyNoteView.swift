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
                Text(note.text.isEmpty ? "Double-click to edit..." : note.text)
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
        
        // --- Resize Handle ---
        .overlay(alignment: .bottomTrailing) {
            if isHovering || isSelected {
                resizeHandle
            }
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
