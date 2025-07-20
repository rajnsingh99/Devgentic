//
//  CodeViewerPanelView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages

/// This extension provides a centralized, reusable definition for the default dark theme
/// used across different code editor instances in the app.
extension CodeEditSourceEditor.EditorTheme {
    public static let defaultDark: Self = .init(
        text: .init(color: .white),
        insertionPoint: .white,
        invisibles: .init(color: .systemGray.withAlphaComponent(0.5)),
        background: NSColor(hex: "#OOOOO"),
        lineHighlight: NSColor(hex: "#44475a").withAlphaComponent(0.5),
        selection: NSColor(hex: "#44475a"),
        keywords: .init(color: NSColor(hex: "#ff79c6")),
        commands: .init(color: NSColor(hex: "#8be9fd")),
        types: .init(color: NSColor(hex: "#8be9fd")),
        attributes: .init(color: NSColor(hex: "#50fa7b")),
        variables: .init(color: .white),
        values: .init(color: NSColor(hex: "#f1fa8c")),
        numbers: .init(color: NSColor(hex: "#bd93f9")),
        strings: .init(color: NSColor(hex: "#f1fa8c")),
        characters: .init(color: NSColor(hex: "#f1fa8c")),
        comments: .init(color: NSColor(hex: "#6272a4"))
    )
}

/// This extension provides a shared helper for creating NSColor instances from hex strings.
extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

/// A draggable side panel that displays code using the `CodeEditSourceEditor`.
/// It appears from the right side of the window to show the full content of large code blocks.
struct CodeViewerPanelView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @State private var isHoveringOnDivider = false
    @AppStorage("codeEditFontSize") var fontSize: Double = 14
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
            // The header background is now transparent to let the VStack's background show through
            .background(Color.clear)

            Divider()
            
            if let content = viewModel.codeViewerContent {
                EditorRepresentable(
                    code: content.code,
                    language: content.language,
                    fontSize: fontSize
                )
                .id(content.code)
            } else {
                Text("No Content")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: panelWidth)
        // Set the background for the entire panel to match the editor's theme
        .background(Color(nsColor: NSColor(hex: "#282a36")))
    }
}

// MARK: - Architectural Change: NSViewControllerRepresentable Wrapper

/// A SwiftUI View that holds the SourceEditor and its state.
private struct EditorWrapperView: View {
    @State var code: String
    let language: CodeLanguage
    let fontSize: Double

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
                    showMinimap: false
                )
            ),
            state: .constant(.init())
        )
        .clipped()
    }
}

/// The `NSViewControllerRepresentable` creates a stable `NSHostingController`
/// to host our editor view.
private struct EditorRepresentable: NSViewControllerRepresentable {
    var code: String
    var language: String?
    var fontSize: Double

    func makeNSViewController(context: Context) -> NSHostingController<EditorWrapperView> {
        let codeLanguage = CodeLanguage.allLanguages.first {
            $0.id.rawValue.lowercased() == language?.lowercased()
        } ?? .default
        
        return NSHostingController(rootView: EditorWrapperView(
            code: code,
            language: codeLanguage,
            fontSize: fontSize
        ))
    }

    func updateNSViewController(_ nsViewController: NSHostingController<EditorWrapperView>, context: Context) {
        let codeLanguage = CodeLanguage.allLanguages.first {
            $0.id.rawValue.lowercased() == language?.lowercased()
        } ?? .default
        
        nsViewController.rootView = EditorWrapperView(
            code: code,
            language: codeLanguage,
            fontSize: fontSize
        )
    }
}
