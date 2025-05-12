//
//  SyntaxHighlightedFileContentView.swift
//  Devgentic
//
//  Created by Raj Singh on 12/05/25.
//

import SwiftUI
import Splash // Import the syntax highlighting library
import AppKit // Needed for NSPasteboard

struct SyntaxHighlightedFileContentView: View {
    let language: String? // Language hint for Splash (e.g., "swift", "python")
    let code: String
    let fontSize: CGFloat
    let showInternalHeader: Bool // To control visibility of its own header (usually false when embedded)

    @State private var highlightedCode: Foundation.AttributedString? = nil
    @State private var internalTheme: Splash.Theme

    // --- Custom Colors for Backgrounds (if internal header is shown) ---
    private var headerBackgroundColor: SwiftUI.Color {
        SwiftUI.Color(red: 32/255, green: 33/255, blue: 35/255)
    }

    private var codeBackgroundColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: internalTheme.backgroundColor)
    }
    
    private var headerForegroundColor: SwiftUI.Color {
        SwiftUI.Color(nsColor: internalTheme.plainTextColor).opacity(0.7)
    }

    init(language: String?, code: String, fontSize: CGFloat, showInternalHeader: Bool = false) {
        self.language = language
        self.code = code
        self.fontSize = fontSize
        self.showInternalHeader = showInternalHeader
        self._internalTheme = State(initialValue: .sundellsColors(withFont: Splash.Font(size: fontSize)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showInternalHeader {
                internalHeaderView
            }
            scrollableCodeView
        }
        .background(codeBackgroundColor)
        .cornerRadius(showInternalHeader ? 8 : 0)
        .overlay(
            RoundedRectangle(cornerRadius: showInternalHeader ? 8 : 0)
                .stroke(SwiftUI.Color.white.opacity(0.1), lineWidth: showInternalHeader ? 0.5 : 0)
        )
        .onAppear(perform: setupAndHighlightCode)
        .onChange(of: code) { _ in setupAndHighlightCode() }
        .onChange(of: language) { _ in setupAndHighlightCode() }
        .onChange(of: fontSize) { newSize in
            self.internalTheme = .sundellsColors(withFont: Splash.Font(size: newSize))
            highlightCodeWithCurrentTheme()
        }
    }

    private var internalHeaderView: some View {
        HStack {
            if let lang = language, !lang.isEmpty {
                Text(lang.lowercased())
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(headerForegroundColor)
            } else {
                Text("code")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(headerForegroundColor)
            }
            Spacer()
            Button {
                copyToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(headerForegroundColor)
            .help("Copy code")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(headerBackgroundColor)
    }

    private var scrollableCodeView: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(highlightedCode ?? Foundation.AttributedString(code))
                .font(.system(size: fontSize, design: .monospaced))
                .padding(12)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Helper Functions

    private func setupAndHighlightCode() {
        self.internalTheme = .sundellsColors(withFont: Splash.Font(size: fontSize))
        highlightCodeWithCurrentTheme()
    }

    // Helper function to select a Splash Grammar based on a language string
    private func grammar(for language: String?) -> Grammar {
        guard let lang = language?.lowercased(), !lang.isEmpty else {
            return SwiftGrammar() // Default grammar
        }
        // Ensure these Grammar types exist in your Splash version
        switch lang {
        case "swift":
            return SwiftGrammar()
        // Add other cases for grammars available in your Splash library
        // Example:
        // case "python":
        //    if let pythonGrammar = PythonGrammar() { // If PythonGrammar() is failable or needs specific init
        //        return pythonGrammar
        //    }
        //    return SwiftGrammar() // Fallback if PythonGrammar isn't available/initializable
        // case "javascript": return JavaScriptGrammar()
        default:
            return SwiftGrammar() // Fallback grammar
        }
    }

    private func highlightCodeWithCurrentTheme() {
        let selectedGrammar = grammar(for: self.language)
        
        let highlighter = SyntaxHighlighter(
            format: AttributedStringOutputFormat(theme: internalTheme),
            grammar: selectedGrammar
        )
        
        // Splash's AttributedStringOutputFormat.Builder.Output is NSAttributedString
        let nsAttributedStringFromSplash = highlighter.highlight(code)
        
        // Explicitly initialize Foundation.AttributedString (the struct) from NSAttributedString (the class)
        self.highlightedCode = Foundation.AttributedString(nsAttributedStringFromSplash) // CORRECTED LINE
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}

// MARK: - Preview Provider
struct SyntaxHighlightedFileContentView_Previews: PreviewProvider {
    static let sampleCodeSwift = """
    import SwiftUI

    struct ContentView: View {
        var body: some View {
            Text("Hello, world!") // A swift example
        }
    }
    """
    static let sampleCodePython = """
    def greet(name):
        print(f"Hello, {name}!") # A python example
    """

    static var previews: some View {
        VStack(spacing: 20) {
            Text("Swift (fontSize: 12):")
            SyntaxHighlightedFileContentView(language: "swift", code: sampleCodeSwift, fontSize: 12, showInternalHeader: true)
                .frame(height: 150)
                .border(Color.blue)

            Text("Python (fontSize: 16, Grammar Fallback to Swift):")
            SyntaxHighlightedFileContentView(language: "python", code: sampleCodePython, fontSize: 16, showInternalHeader: false)
                .frame(height: 150)
                .border(Color.green)
            
            Text("No Language (Defaults to Swift Grammar, fontSize: 14):")
            SyntaxHighlightedFileContentView(language: nil, code: "var noLangVar = \"Should highlight as Swift by default.\";", fontSize: 14, showInternalHeader: false)
                .frame(height: 100)
                .border(Color.orange)
        }
        .padding()
        .frame(width: 500)
    }
}
