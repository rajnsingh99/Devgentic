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
    @Published var fileContent: String?
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false
    @Published var currentFontSize: CGFloat = 12.0 // Default font size

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
        
        logger.info("Attempting to load file content for: \(self.fileURL.path)")

        // Ensure security access for the file URL
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
            // Basic check: Limit file size to avoid loading huge files (e.g., 10MB)
            let attributes = try FileManager.default.attributesOfItem(atPath: self.fileURL.path)
            if let fileSize = attributes[.size] as? NSNumber, fileSize.doubleValue > (10 * 1024 * 1024) { // 10MB limit
                logger.warning("File \(self.fileName ?? "") is too large: \(fileSize.doubleValue / (1024*1024)) MB. Not loading.")
                self.errorMessage = "File is too large to display (max 10MB)."
                self.isLoading = false
                return
            }

            // Attempt to read as String (UTF-8).
            // More sophisticated type checking could be done here if needed (e.g., to explicitly disallow certain binary types).
            let content = try String(contentsOf: self.fileURL, encoding: .utf8)
            
            self.fileContent = content
            self.isLoading = false
            logger.info("Successfully read content for file: \(self.fileName ?? "unknown")")

        } catch {
            logger.error("Failed to read content for file \(self.fileURL.path): \(error.localizedDescription)")
            self.errorMessage = "Could not read file content. It might be binary, an unsupported text encoding, or corrupted.\nError: \(error.localizedDescription)"
            self.isLoading = false
        }
    }

    func increaseFontSize() {
        if currentFontSize < 30 { // Max font size
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
    // Use @StateObject because this view owns the FileViewerState
    @StateObject private var state: FileViewerState
    
    // State for copy button feedback
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
                // MARK: - Error Display
                VStack(spacing: 12) {
                    Spacer()
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
                    
                    Button("Retry") {
                        state.loadFileContent()
                    }
                    .padding(.top)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if let content = state.fileContent {
                // MARK: - Content Display
                ScrollView([.horizontal, .vertical]) { // Enable horizontal and vertical scrolling
                    Text(content)
                        .font(.system(size: state.currentFontSize, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading) // Allow text to expand horizontally
                        .padding()
                        .textSelection(.enabled)
                }
                // Ensure the ScrollView takes up available space
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else {
                // MARK: - Fallback for No Content (after loading, if still nil and no error)
                VStack {
                    Spacer()
                    Text("No Content")
                        .font(.title2.weight(.medium))
                        .foregroundColor(.secondary)
                    Text("The file may be empty or could not be loaded.")
                        .font(.body)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Apply a background to the main content area
        .background(Color(NSColor.textBackgroundColor))
        // MARK: - Toolbar for window-specific controls
        .toolbar {
            ToolbarItemGroup(placement: .automatic) { // Or .navigation // Or .principal
                // Zoom Out Button
                Button {
                    state.decreaseFontSize()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Decrease font size")
                .disabled(state.fileContent == nil || state.isLoading)

                // Zoom In Button
                Button {
                    state.increaseFontSize()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Increase font size")
                .disabled(state.fileContent == nil || state.isLoading)

                // Current Font Size Display (Optional)
                // Text("\(Int(state.currentFontSize))pt")
                //    .font(.caption)
                //    .foregroundColor(.secondary)

                Spacer() // Push copy button to the right or group with others

                // Copy Button
                Button {
                    copyContentToClipboard()
                } label: {
                    Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundColor(justCopied ? .green : (state.fileContent == nil || state.isLoading ? .gray : .accentColor))
                }
                .help(justCopied ? "Copied!" : "Copy content")
                .disabled(state.fileContent == nil || state.isLoading)
            }
        }
        // Set the window title dynamically based on the file name
        .navigationTitle(state.fileName ?? "File Viewer")
        // Attempt to refresh content if the URL changes (e.g., if the window is reused)
        .onChange(of: state.fileURL) { oldURL, newURL in
            // This might not be strictly necessary if each openWindow call creates a new window instance.
            // However, if window instances could be reused, this would be important.
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

    // Helper for icon, similar to the one in FileViewerOverlayView
    private func sfSymbolForFileName(_ name: String?) -> String {
        guard let name = name else { return "doc.fill" }
        let fileExtension = name.split(separator: ".").last?.lowercased() ?? ""
        if let type = UTType(filenameExtension: fileExtension) {
            if let markdownUTI = UTType("net.daringfireball.markdown"), type.conforms(to: markdownUTI) {
                 return "doc.richtext.fill"
            }
            if type.conforms(to: .sourceCode) || type.conforms(to: .text) {
                return "doc.text.fill"
            }
            if type.conforms(to: .image) { return "photo.fill" }
            if type.conforms(to: .pdf) { return "doc.richtext.fill.ar" }
            if type.conforms(to: .archive) { return "doc.zipper" }
        }
        switch fileExtension {
            case "md": return "doc.richtext.fill"
            case "swift", "js", "py", "java", "html", "css", "json", "xml", "sh", "yaml", "yml", "txt": return "doc.text.fill"
            default: return "doc.fill"
        }
    }
}

// MARK: - Preview Provider
struct FileViewerWindowView_Previews: PreviewProvider {
    // Create a temporary dummy URL for previewing.
    // In a real scenario, this URL would point to an actual file.
    static var dummyFileURL: URL {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("preview.txt")
        try? "Hello, Preview World!\nThis is a test file.".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    
    static var dummyCodeFileURL: URL {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("preview.swift")
        try? "func hello() {\n    print(\"Hello from Swift preview!\")\n}".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static var previews: some View {
        // Preview the FileViewerWindowView directly.
        // Note: Security-scoped resource access won't work directly in previews
        // in the same way as in a running app. The FileViewerState might show an error
        // or load content if the dummy file is accessible.
        
        FileViewerWindowView(fileURL: dummyFileURL)
            .previewDisplayName("Text File")
            .frame(width: 700, height: 600)

        FileViewerWindowView(fileURL: dummyCodeFileURL)
            .previewDisplayName("Code File")
            .frame(width: 700, height: 600)
            .onAppear {
                // For preview, if FileViewerState has trouble loading,
                // you could manually set its properties for UI testing.
                // Example:
                // let state = FileViewerState(fileURL: dummyCodeFileURL)
                // state.fileContent = "Preview content"
                // state.isLoading = false
                // return FileViewerWindowView(fileURL: dummyCodeFileURL) // and pass state somehow if init allowed
            }
        
        // To preview error state, you'd need to mock FileViewerState or pass a non-existent URL
        // and ensure the error handling in FileViewerState is robust for previews.
    }
}
