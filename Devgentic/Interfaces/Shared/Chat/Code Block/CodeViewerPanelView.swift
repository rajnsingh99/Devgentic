//
//  CodeViewerPanelView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages

/// A draggable side panel that displays code using the `CodeEditSourceEditor`.
/// It appears from the right side of the window to show the full content of large code blocks.
struct CodeViewerPanelView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @State private var isHoveringOnDivider = false
    @AppStorage("codeEditFontSize") var fontSize: Double = 14

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
    
    /// The draggable divider for resizing the panel.
    private var resizableDivider: some View {
        Divider()
            .frame(width: 4)
            .background(isHoveringOnDivider ? Color.blue.opacity(0.5) : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1).onChanged { value in
                    let newWidth = viewModel.codeViewerWidth - value.translation.width
                    // Enforce a minimum and maximum width for the panel
                    viewModel.codeViewerWidth = min(max(newWidth, 400), 1200)
                }
            )
            .onHover { hovering in
                isHoveringOnDivider = hovering
                if hovering { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
    }
    
    /// The main content of the panel, including the header and the code editor.
    private var panelContent: some View {
        VStack(spacing: 0) {
            // Panel Header
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

            // We now conditionally create a dedicated editor view ONLY when we have content.
            // This ensures the view is initialized with the correct data from the start.
            if let content = viewModel.codeViewerContent {
                let language = CodeLanguage.allLanguages.first {
                    $0.id.rawValue.lowercased() == content.language?.lowercased()
                } ?? .default
                
                EditorView(
                    code: content.code,
                    language: language,
                    fontSize: fontSize
                )
                .clipped() // FIX: This prevents the view's content from drawing outside its bounds.
            } else {
                // Placeholder view when there is no content to show
                Text("No Content")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: viewModel.codeViewerWidth)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Dedicated Editor View
    
    /// A new, self-contained view that initializes its state directly from its parameters.
    /// This resolves the timing issue by ensuring the code is available at the moment of creation.
    private struct EditorView: View {
        @State private var code: String
        private let language: CodeLanguage
        private let fontSize: Double

        init(code: String, language: CodeLanguage, fontSize: Double) {
            // Initialize the State variable directly from the parameter.
            self._code = State(initialValue: code)
            self.language = language
            self.fontSize = fontSize
        }
        
        var body: some View {
            SourceEditor(
                $code,
                language: language,
                configuration: .init(
                    appearance: .init(
                        theme: .defaultDark,
                        font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
                        lineHeightMultiple: 1.2,
                        wrapLines: true,
                        tabWidth: 4
                    ),
                    peripherals: .init(
                        showGutter: true,
                        showMinimap: true
                    )
                ),
                state: .constant(.init())
            )
        }
    }
}
