// Views/Messages/CodeBlockView.swift
import SwiftUI
import Splash // Import the syntax highlighting library
import AppKit // Needed for NSPasteboard

struct CodeBlockView: View {
    let language: String?
    let code: String

    // Use Foundation.AttributedString for compatibility with Text
    @State private var highlightedCode: Foundation.AttributedString? = nil

    // Explicit type annotation for theme
    private let theme: Splash.Theme = Splash.Theme.wwdc17(withFont: Splash.Font(size: 13))

    // --- Main Body ---
    var body: some View { // <-- Error reported near here (Line 19 approx)
        VStack(alignment: .leading, spacing: 0) {
            // Use computed properties for sub-components
            headerViewComponent
            dividerComponent
            scrollableCodeComponent // <-- Use extracted ScrollView component
        }
        // Apply modifiers to the VStack
        .background(Color(nsColor: theme.backgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SwiftUI.Color.gray.opacity(0.3), lineWidth: 1)
        )
        .onAppear(perform: highlightCode)
        .onChange(of: code) { _ in highlightCode() }
        .onChange(of: language) { _ in highlightCode() }
    }

    // MARK: - Sub Components (Extracted)

    // Header view component
    private var headerViewComponent: some View {
        HStack {
            if let lang = language, !lang.isEmpty {
                Text(lang.uppercased())
                    .font(.caption.bold())
                    .foregroundColor(Color(nsColor: theme.plainTextColor).opacity(0.7))
            } else {
                 Text("CODE")
                    .font(.caption.bold())
                    .foregroundColor(Color(nsColor: theme.plainTextColor).opacity(0.7))
            }
            Spacer()
            Button { copyToClipboard() } label: { Image(systemName: "doc.on.doc").font(.caption) }
            .buttonStyle(.plain)
            .foregroundColor(Color(nsColor: theme.plainTextColor).opacity(0.7))
            .help("Copy code")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // Divider component
    private var dividerComponent: some View {
        Divider().background(Color(nsColor: theme.plainTextColor).opacity(0.2))
    }

    // Scrollable code area component
    private var scrollableCodeComponent: some View {
        ScrollView(.horizontal) {
            Text(highlightedCode ?? Foundation.AttributedString(code))
                .font(.system(size: 13).monospaced())
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    // MARK: - Helper Functions

    // Function to perform syntax highlighting (no change)
    private func highlightCode() {
        let highlighter = SyntaxHighlighter(format: AttributedStringOutputFormat(theme: theme))
        let nsAttrString = highlighter.highlight(code)
        // Convert to Foundation.AttributedString
        self.highlightedCode = Foundation.AttributedString(nsAttrString)
    }

    // Function to copy code to clipboard (no change)
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

// MARK: - Preview Provider (no change needed)
struct CodeBlockView_Previews: PreviewProvider {
    static let sampleCodeSwift = """
    import SwiftUI

    struct ContentView: View {
        var body: some View {
            Text("Hello, world!")
                .padding()
        }
    }
    """
    static let sampleCodePython = """
    def greet(name):
        print(f"Hello, {name}!")

    greet("Developer")
    """
    static let sampleCodeNoLang = """
    Just some plain text
    in a code block format.
    No specific language hint.
    """

    static var previews: some View {
        VStack(spacing: 20) {
            CodeBlockView(language: "swift", code: sampleCodeSwift)
            CodeBlockView(language: "python", code: sampleCodePython)
            CodeBlockView(language: nil, code: sampleCodeNoLang)
        }
        .padding()
        .background(SwiftUI.Color.secondary.opacity(0.1))
        .frame(width: 400)
    }
}
