//
//  FileWindowViewer.swift
//  Devgentic
//
//  Created by Raj Singh on 16/07/25.
//

import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import os

// MARK: - Default Theme Definition
// The default dark theme is defined in an extension.
extension CodeEditSourceEditor.EditorTheme {
    public static let defaultDark: Self = .init(
        text: .init(color: .white),
        insertionPoint: .white,
        invisibles: .init(color: .systemGray.withAlphaComponent(0.5)),
        background: NSColor(hex: "#282a36"), // Dracula-like background
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


// MARK: - State Manager
@MainActor
class CodeEditFileViewerState: ObservableObject {
    // MARK: - Published Properties
    @Published var content: String = ""
    @Published var language: CodeLanguage
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false
    @Published var fileName: String?

    // Using @AppStorage to persist font size across app launches
    @AppStorage("codeEditFontSize") var fontSize: Double = 14
    
    // MARK: - Properties
    let fileURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CodeEditFileViewerState")

    // MARK: - Initializer
    init(fileURL: URL) {
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        
        // Detect the language from the file extension.
        self.language = CodeLanguage.detectLanguageFrom(url: fileURL)
        
        loadFileContent()
    }

    // MARK: - File Loading
    func loadFileContent() {
        isLoading = true
        errorMessage = nil
        content = ""
        
        logger.info("Attempting to load file content for: \(self.fileURL.path)")

        // Access security-scoped resources safely, crucial for files from UIDocumentPicker
        guard self.fileURL.startAccessingSecurityScopedResource() else {
            logger.error("Could not gain access to read file: \(self.fileURL.path)")
            self.errorMessage = "Permission denied. Please ensure the app has access to this location."
            self.isLoading = false
            return
        }
        
        // Ensure access is stopped when the function exits
        defer {
            self.fileURL.stopAccessingSecurityScopedResource()
            logger.info("Stopped accessing security-scoped resource for file: \(self.fileURL.path)")
        }

        do {
            // Check file size to avoid loading excessively large files into memory
            let attributes = try FileManager.default.attributesOfItem(atPath: self.fileURL.path)
            if let fileSize = attributes[.size] as? NSNumber, fileSize.doubleValue > (10 * 1024 * 1024) { // 10MB limit
                logger.warning("File \(self.fileName ?? "") is too large: \(fileSize.doubleValue / (1024*1024)) MB.")
                self.errorMessage = "File is too large to display (max 10MB)."
                self.isLoading = false
                return
            }

            // Read file content as a plain string
            self.content = try String(contentsOf: self.fileURL, encoding: .utf8)
            self.isLoading = false
        } catch {
            logger.error("Failed to read content for file \(self.fileURL.path): \(error.localizedDescription)")
            self.errorMessage = "Could not read file content. It might be binary, corrupted, or use an unsupported text encoding.\nError: \(error.localizedDescription)"
            self.isLoading = false
        }
    }
    
    // MARK: - Font Size Controls
    func increaseFontSize() {
        if fontSize < 40 {
            fontSize += 1
        }
    }

    func decreaseFontSize() {
        if fontSize > 8 {
            fontSize -= 1
        }
    }
}


// MARK: - The SwiftUI View
struct FileWindowViewer: View {
    
    @StateObject private var state: CodeEditFileViewerState
    @State private var justCopied: Bool = false
    
    /// Initializes the file viewer with a specific file URL.
    /// This will in turn initialize the state object.
    init(fileURL: URL) {
        _state = StateObject(wrappedValue: CodeEditFileViewerState(fileURL: fileURL))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isLoading {
                ProgressView("Loading \(state.fileName ?? "file")...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = state.errorMessage {
                // Display a user-friendly error message
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.red)
                    Text("Error Opening File")
                        .font(.title2.weight(.semibold))
                    Text(error)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                // The SourceEditor view from the library, now with a hardcoded dark theme.
                SourceEditor(
                    $state.content,
                    language: state.language,
                    configuration: .init(
                        appearance: .init(
                            theme: .defaultDark, // Using the hardcoded dark theme
                            font: .monospacedSystemFont(ofSize: state.fontSize, weight: .regular),
                            lineHeightMultiple: 1.2,
                            wrapLines: true,
                            tabWidth: 4
                        )
                    ),
                    state: .constant(.init())
                )
            }
        }
        .navigationTitle(state.fileName ?? "File Viewer")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // Font size controls
                Button(action: state.decreaseFontSize, label: { Image(systemName: "minus.magnifyingglass") })
                    .help("Decrease font size")
                    .disabled(state.isLoading || state.errorMessage != nil)

                Button(action: state.increaseFontSize, label: { Image(systemName: "plus.magnifyingglass") })
                    .help("Increase font size")
                    .disabled(state.isLoading || state.errorMessage != nil)
                
                Spacer()

                // Copy to clipboard button
                Button(action: copyContentToClipboard) {
                    Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundColor(justCopied ? .green : .accentColor)
                }
                .help(justCopied ? "Copied!" : "Copy content to clipboard")
                .disabled(state.isLoading || state.errorMessage != nil)
            }
        }
    }
    
    private func copyContentToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.content, forType: .string)
        
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            justCopied = false
        }
    }
}

// MARK: - Preview Provider
struct CodeEditFileViewer_Previews: PreviewProvider {
    
    // Helper to create a dummy file for previews
    static func createDummyFile(named name: String, with content: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    
    static var previews: some View {
        let swiftFileURL = createDummyFile(
            named: "Preview.swift",
            with: """
            import SwiftUI
            
            struct PreviewView: View {
                var body: some View {
                    Text("Hello, World!")
                }
            }
            """
        )
        
        // Wrap in a NavigationView for a realistic preview environment.
        NavigationView {
            FileWindowViewer(fileURL: swiftFileURL)
                .frame(width: 750, height: 600)
        }
    }
}


// MARK: - Helpers
extension NSColor {
    /// Helper initializer to create a color from a hex string.
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}
