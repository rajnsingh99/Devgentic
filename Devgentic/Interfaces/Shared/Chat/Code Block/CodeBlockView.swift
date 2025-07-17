// Views/Messages/CodeBlockView.swift
import SwiftUI
import Splash
import AppKit

struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var highlightedCode: Foundation.AttributedString

    private static let theme: Splash.Theme = .sundellsColors(withFont: .init(size: 14))
    
    init(language: String?, code: String) {
        self.language = language
        self.code = code
        
        var container = AttributeContainer()
        container.font = .monospacedSystemFont(ofSize: Self.theme.font.size, weight: .regular)
        container.foregroundColor = Self.theme.plainTextColor
        
        self._highlightedCode = State(initialValue: Foundation.AttributedString(code, attributes: container))
    }

    private var codeBackgroundColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: Self.theme.backgroundColor)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The header view has been removed.
            scrollableCodeComponent
        }
        .background(codeBackgroundColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SwiftUI.Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .task(id: code) {
            self.highlightedCode = await SyntaxHighlighterService.shared.highlight(
                code: code,
                language: language
            )
        }
    }

    // MARK: - Sub Components

    private var scrollableCodeComponent: some View {
        ScrollView(.horizontal) {
            Text(highlightedCode)
                .padding(12)
                .textSelection(.enabled)
        }
        // The copy button is now an overlay on the code view itself.
        .overlay(alignment: .topTrailing) {
            Button(action: copyToClipboard) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundColor(Color(nsColor: Self.theme.plainTextColor).opacity(0.7))
            .padding(12)
            .help("Copy code")
        }
    }
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

// MARK: - Preview Provider
struct CodeBlockView_Previews: PreviewProvider {
    static let sampleCodeSwift = """
    import SwiftUI

    struct ContentView: View {
        var body: some View {
            Text("Hello, world!")
        }
    }
    """

    static var previews: some View {
        VStack(spacing: 20) {
            CodeBlockView(language: "swift", code: sampleCodeSwift)
        }
        .padding()
        .background(Color.black.opacity(0.8))
        .frame(width: 500)
    }
}
