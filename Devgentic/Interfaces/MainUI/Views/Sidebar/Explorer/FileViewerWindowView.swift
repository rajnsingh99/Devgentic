//
//  FileViewerWindowView.swift
//  Devgentic
//
//  Created by Raj Singh on 11/05/25.
//

import SwiftUI
import os
import UniformTypeIdentifiers

// A simple state manager for the FileViewerWindowView
@MainActor
class FileViewerState: ObservableObject {
    @Published var fileName: String?
    @Published var fileContent: String? // This will be the raw string content
    @Published var languageIdentifier: String? // For Splash (e.g., "swift", "python")
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false
    @Published var currentFontSize: CGFloat = 13.0 // Default font size for code

    let fileURL: URL

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "FileViewerState")

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        loadFileContent()
    }

    func loadFileContent() {
        isLoading = true
        errorMessage = nil
        fileContent = nil
        languageIdentifier = nil // Reset language identifier
        
        logger.info("Attempting to load file content for: \(self.fileURL.path)")

        guard self.fileURL.startAccessingSecurityScopedResource() else {
            logger.error("Could not gain access to read file: \(self.fileURL.path)")
            self.errorMessage = "Permission denied to read this file. Please ensure the app has access to this location."
            self.isLoading = false
            return
        }
        defer {
            self.fileURL.stopAccessingSecurityScopedResource()
            logger.info("Stopped accessing security-scoped resource for file: \(self.fileURL.path)")
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: self.fileURL.path)
            if let fileSize = attributes[.size] as? NSNumber, fileSize.doubleValue > (10 * 1024 * 1024) { // 10MB limit
                logger.warning("File \(self.fileName ?? "") is too large: \(fileSize.doubleValue / (1024*1024)) MB. Not loading.")
                self.errorMessage = "File is too large to display (max 10MB)."
                self.isLoading = false
                return
            }

            let content = try String(contentsOf: self.fileURL, encoding: .utf8)
            
            self.fileContent = content
            self.languageIdentifier = determineLanguageIdentifier(for: self.fileURL) // Determine language for Splash
            self.isLoading = false
            logger.info("Successfully read content for file: \(self.fileName ?? "unknown"). Language ID: \(self.languageIdentifier ?? "none")")

        } catch {
            logger.error("Failed to read content for file \(self.fileURL.path): \(error.localizedDescription)")
            self.errorMessage = "Could not read file content. It might be binary, an unsupported text encoding, or corrupted.\nError: \(error.localizedDescription)"
            self.isLoading = false
        }
    }

    private func determineLanguageIdentifier(for url: URL) -> String? {
        // Simple mapping from file extension to Splash language identifier
        // Splash typically uses lowercase language names.
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "python", "py": return "python"
        case "javascript", "js", "jsx": return "javascript"
        case "typescript", "ts", "tsx": return "typescript"
        case "java": return "java"
        case "c", "h", "m", "mm": return "c" // Splash might have more specific C-family grammars
        case "cpp", "hpp", "cxx": return "cpp"
        case "cs": return "c#" // Or "csharp" - check Splash documentation
        case "go": return "go"
        case "ruby", "rb": return "ruby"
        case "php": return "php"
        case "html", "htm": return "html"
        case "css": return "css"
        case "json": return "json"
        case "xml", "plist", "storyboard", "xib": return "xml"
        case "yaml", "yml": return "yaml"
        case "sh", "bash", "zsh": return "shell" // Or "bash" - check Splash
        case "md", "markdown": return "markdown"
        case "sql": return "sql"
        case "dockerfile", "docker": return "dockerfile"
        // Add more mappings as needed based on Splash's supported grammars
        default:
            // For common text files without specific code syntax
            if ext == "txt" || ext == "log" || ext == "ini" || ext == "cfg" || ext == "csv" {
                return nil // Let Splash treat as plain text or auto-detect if possible
            }
            logger.info("No specific language identifier for extension: \(ext). Splash will attempt to auto-detect or use plain text.")
            return nil // Or return a generic like "plaintext" if Splash supports it
        }
    }

    func increaseFontSize() {
        if currentFontSize < 40 { // Max font size increased
            currentFontSize += 1
        }
    }

    func decreaseFontSize() {
        if currentFontSize > 8 { // Min font size
            currentFontSize -= 1
        }
    }
}

struct FileViewerWindowView: View {
    @StateObject private var state: FileViewerState
    @State private var justCopied: Bool = false

    init(fileURL: URL) {
        _state = StateObject(wrappedValue: FileViewerState(fileURL: fileURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isLoading {
                ProgressView("Loading \(state.fileName ?? "file")...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = state.errorMessage {
                // Error Display (same as before)
                VStack(spacing: 12) { /* ... Error UI ... */ }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if let content = state.fileContent {
                // MARK: - Content Display using SyntaxHighlightedFileContentView
                SyntaxHighlightedFileContentView(
                    language: state.languageIdentifier, // Pass the determined language
                    code: content,
                    fontSize: state.currentFontSize,
                    showInternalHeader: false // We use the window's toolbar
                )
                // Ensure it expands to fill available space
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                // Fallback for No Content (same as before)
                VStack { /* ... No Content UI ... */ }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.textBackgroundColor)) // Consistent background
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { state.decreaseFontSize() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Decrease font size")
                .disabled(state.fileContent == nil || state.isLoading)

                Button { state.increaseFontSize() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Increase font size")
                .disabled(state.fileContent == nil || state.isLoading)
                
                // Optional: Display current font size for feedback
                Text("\(Int(state.currentFontSize))pt")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)


                Spacer()

                Button { copyContentToClipboard() } label: {
                    Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundColor(justCopied ? .green : (state.fileContent == nil || state.isLoading ? .gray : .accentColor))
                }
                .help(justCopied ? "Copied!" : "Copy content")
                .disabled(state.fileContent == nil || state.isLoading)
            }
        }
        .navigationTitle(state.fileName ?? "File Viewer")
        .onChange(of: state.fileURL) { oldURL, newURL in
            if oldURL != newURL {
                state.loadFileContent()
            }
        }
    }

    private func copyContentToClipboard() {
        guard let content = state.fileContent else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            justCopied = false
        }
    }
    
    // Error UI and No Content UI (can be extracted into separate views if desired)
    // For brevity, I'll keep them inline here but you can copy them from the previous version.
    // Example for Error UI:
    // private var errorView: some View { ... }
}


// MARK: - Preview Provider
struct FileViewerWindowView_Previews: PreviewProvider {
    static var dummyTextFileURL: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview.txt")
        try? "Plain text content.\nSecond line.".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    
    static var dummySwiftFileURL: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview.swift")
        try? "import SwiftUI\n\nstruct PreviewTest: View {\n    var body: some View {\n        Text(\"Hello, Swift!\")\n    }\n}".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static var previews: some View {
        Group {
            FileViewerWindowView(fileURL: dummySwiftFileURL)
                .previewDisplayName("Swift File")
                .frame(width: 700, height: 600)

            FileViewerWindowView(fileURL: dummyTextFileURL)
                .previewDisplayName("Text File")
                .frame(width: 700, height: 600)
        }
    }
}
