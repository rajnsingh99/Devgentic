//
//  HighlightrCodeViewerPanelView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/07/25.
//

import SwiftUI
import Highlightr

/// An alternative, lightweight code viewer panel that uses `Highlightr` for syntax highlighting.
/// This view is designed to be a more performant replacement for `CodeViewerPanelView`
/// for displaying static code, as it avoids the overhead of the full `CodeEditSourceEditor`.
struct HighlightrCodeViewerPanelView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @State private var isHoveringOnDivider = false
    @AppStorage("codeViewerPanelWidth") private var panelWidth: Double = 600

    var body: some View {
        HStack(spacing: 0) {
            resizableDivider
            panelContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .transition(.move(edge: .trailing))
        .shadow(radius: 10)
    }

    // MARK: - Subviews

    private var resizableDivider: some View {
        Divider()
            .frame(width: 4)
            .background(isHoveringOnDivider ? Color.blue.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1).onChanged { value in
                    let currentWidth = CGFloat(self.panelWidth)
                    let newWidth = currentWidth - value.translation.width
                    self.panelWidth = Double(min(max(newWidth, 400), 1200))
                }
            )
            .onHover { hovering in
                isHoveringOnDivider = hovering
                if hovering { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            // Panel Header (identical to the original)
            HStack {
                Text(viewModel.codeViewerContent?.language?.capitalized ?? "Code Viewer")
                    .font(.headline)
                    .padding(.leading)

                Spacer()

                Button(action: viewModel.hideCodeViewer) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .padding(.trailing)
            }
            .frame(height: 44)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))

            Divider()

            // Content area now uses HighlightedCodeView
            if let content = viewModel.codeViewerContent {
                // Wrap the lightweight HighlightedCodeView in a ScrollView
                // to handle code blocks of any length.
                ScrollView {
                    HighlightedCodeView(
                        language: content.language ?? "plaintext",
                        code: content.code
                    )
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: NSColor(hex: "#282a36"))) // Use a dark background consistent with the theme
                .id(content.code) // Use ID to ensure it redraws for new content

            } else {
                Text("No Content")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: panelWidth)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
