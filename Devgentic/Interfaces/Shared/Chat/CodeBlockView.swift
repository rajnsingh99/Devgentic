// Views/Messages/CodeBlockView.swift
import SwiftUI
import Splash // Import the syntax highlighting library
import AppKit // Needed for NSPasteboard

struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var highlightedCode: Foundation.AttributedString? = nil

    // --- Theme Configuration ---
    // Using Sundell's Colors theme with a slightly larger font.
    private let theme: Splash.Theme = .sundellsColors(withFont: Splash.Font(size: 16)) // Increased font size

    // --- Custom Colors for Backgrounds ---
    // Define a slightly darker background for the header.
    private var headerBackgroundColor: SwiftUI.Color {
        SwiftUI.Color(red: 32/255, green: 33/255, blue: 35/255) // A dark gray
    }

    // The code area will use the theme's background color.
    private var codeBackgroundColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: theme.backgroundColor) // Convert NSColor from theme to SwiftUI.Color
    }
    
    // Text color for the header (language name, copy button)
    private var headerForegroundColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: theme.plainTextColor).opacity(0.7) // Convert NSColor and apply opacity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { // No spacing between header and code area
            headerViewComponent
            scrollableCodeComponent
        }
        .background(codeBackgroundColor) // Set the background for the entire code block
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SwiftUI.Color.white.opacity(0.1), lineWidth: 0.5) // Subtle border
        )
        .onAppear(perform: highlightCode)
        .onChange(of: code) { _ in highlightCode() } // Updated for newer Swift versions
        .onChange(of: language) { _ in highlightCode() } // Updated for newer Swift versions
    }

    // MARK: - Sub Components

    private var headerViewComponent: some View {
        HStack {
            if let lang = language, !lang.isEmpty {
                Text(lang.lowercased()) // Display language in lowercase
                    .font(.system(size: 14, weight: .medium, design: .monospaced)) // Increased font size
                    .foregroundColor(headerForegroundColor)
            } else {
                Text("code") // Fallback if no language is specified
                    .font(.system(size: 14, weight: .medium, design: .monospaced)) // Increased font size
                    .foregroundColor(headerForegroundColor)
            }
            Spacer() // Pushes the copy button to the right
            Button {
                copyToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14)) // Increased icon size
            }
            .buttonStyle(.plain) // Use plain button style for a cleaner look
            .foregroundColor(headerForegroundColor)
            .help("Copy code")
        }
        .padding(.horizontal, 12) // Padding for the header content
        .padding(.vertical, 8)
        .background(headerBackgroundColor) // Distinct background for the header
    }

    private var scrollableCodeComponent: some View {
        ScrollView(.horizontal) { // Enable horizontal scrolling
            Text(highlightedCode ?? Foundation.AttributedString(code))
                // The font is primarily set by the Splash theme.
                .padding(12) // Padding around the actual code text
                // REMOVED: .frame(maxWidth: .infinity, alignment: .leading)
                // This removal is the key fix: it allows the Text view to determine its own ideal width
                // based on its content (the longest line of code), rather than being forced to wrap.
                // The ScrollView will then handle the horizontal scrolling if the Text's width exceeds
                // the CodeBlockView's available width.
                .textSelection(.enabled) // Allow users to select and copy text
        }
        // The background for the code area itself is effectively the `codeBackgroundColor`
        // set on the parent VStack.
    }

    // MARK: - Helper Functions

    private func highlightCode() {
        // Uses AttributedStringOutputFormat to apply the theme during highlighting
        let highlighter = SyntaxHighlighter(format: AttributedStringOutputFormat(theme: theme))
        // highlight() returns a Splash.AttributedString
        let splashAttributedString = highlighter.highlight(code)
        // Convert Splash.AttributedString to Foundation.AttributedString for SwiftUI's Text view
        self.highlightedCode = Foundation.AttributedString(splashAttributedString)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        // Optionally, provide user feedback here (e.g., show a temporary "Copied!" message)
    }
}

// MARK: - Preview Provider
struct CodeBlockView_Previews: PreviewProvider {
    static let sampleCodeSwift = """
    import SwiftUI

    struct ContentView: View {
        var body: some View {
            Text("Hello, world! This is a particularly long line of Swift code to test horizontal scrolling functionality effectively, ensuring it doesn't wrap prematurely.")
                .padding() // Another long line to ensure scrolling is needed, and to see how padding interacts.
        }
    }
    """
    static let sampleCodePython = """
    def greet(name):
        print(f"Hello, {name}! This Python function also has a very long line that should definitely cause the ScrollView to activate its horizontal scrollbar, demonstrating the fix for the wrapping issue.")

    greet("Developer With A Very Very Very Extremely Long Name Indeed Just To Make Sure This Line Overflows")
    """
    static let sampleCodeNoLang = """
    This is a line of plain text within a code block that is intentionally made very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very, very very long line to ensure that horizontal scrolling is absolutely necessary.
    """

    static var previews: some View {
        VStack(spacing: 20) {
            CodeBlockView(language: "swift", code: sampleCodeSwift)
            CodeBlockView(language: "python", code: sampleCodePython)
            CodeBlockView(language: "javascript", code: "console.log('Hello from JavaScript!');\nconst x = 100;")
            CodeBlockView(language: nil, code: sampleCodeNoLang)
        }
        .padding()
        .background(SwiftUI.Color.black.opacity(0.8)) // Simulate a darker chat window background
        .frame(width: 500) // Wider preview
    }
}
