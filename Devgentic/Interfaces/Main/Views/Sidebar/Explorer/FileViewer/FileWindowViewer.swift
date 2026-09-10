// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

// The default theme definition has been moved to the shared `CodeEditTheme+Extensions.swift` file.

// MARK: - State Manager
@MainActor
@Observable
class CodeEditFileViewerState {
    // MARK: - Properties
    var content: String = ""
    var language: CodeLanguage
    var errorMessage: String?
    var isLoading: Bool = false
    var fileName: String?

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "codeEditFontSize") }
    }
    
    let fileURL: URL
    private let logger = DGLogger(category: "CodeEditFileViewerState")

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        self.language = CodeLanguage.detectLanguageFrom(url: fileURL)
        let stored = UserDefaults.standard.double(forKey: "codeEditFontSize")
        self.fontSize = stored > 0 ? stored : 14
        loadFileContent()
    }

    func loadFileContent() {
        isLoading = true
        errorMessage = nil
        content = ""
        
        logger.info("Attempting to load file content for: \(self.fileURL.path)")

        guard self.fileURL.startAccessingSecurityScopedResource() else {
            logger.error("Could not gain access to read file: \(self.fileURL.path)")
            self.errorMessage = "Permission denied. Please ensure the app has access to this location."
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
                logger.warning("File \(self.fileName ?? "") is too large: \(fileSize.doubleValue / (1024*1024)) MB.")
                self.errorMessage = "File is too large to display (max 10MB)."
                self.isLoading = false
                return
            }

            self.content = try String(contentsOf: self.fileURL, encoding: .utf8)
            self.isLoading = false
        } catch {
            logger.error("Failed to read content for file \(self.fileURL.path): \(error.localizedDescription)")
            self.errorMessage = "Could not read file content. It might be binary, corrupted, or use an unsupported text encoding.\nError: \(error.localizedDescription)"
            self.isLoading = false
        }
    }
    
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
    
    @State private var state: CodeEditFileViewerState
    @State private var justCopied: Bool = false
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    init(fileURL: URL) {
        _state = State(initialValue: CodeEditFileViewerState(fileURL: fileURL))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.isLoading {
                ProgressView("Loading \(state.fileName ?? "file")...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = state.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40)) // Fixed size: intentional (error state icon)
                        .foregroundColor(theme.errorColor)
                    Text("Error Opening File")
                        .font(.title2.weight(.semibold))
                    Text(error)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                SourceEditor(
                    $state.content,
                    language: state.language,
                    configuration: .init(
                        appearance: .init(
                            theme: themeManager.resolvedCodeViewerSyntaxTheme.editorTheme,
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
                Button(action: state.decreaseFontSize, label: { Image(systemName: "minus.magnifyingglass") })
                    .help("Decrease font size")
                    .disabled(state.isLoading || state.errorMessage != nil)

                Button(action: state.increaseFontSize, label: { Image(systemName: "plus.magnifyingglass") })
                    .help("Increase font size")
                    .disabled(state.isLoading || state.errorMessage != nil)
                
                Spacer()

                Button(action: copyContentToClipboard) {
                    Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundColor(justCopied ? theme.successColor : theme.accentColor)
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
        
        NavigationStack {
            FileWindowViewer(fileURL: swiftFileURL)
                .frame(width: 750, height: 600)
        }
    }
}

// The NSColor extension has been moved to the new shared file `CodeEditTheme+Extensions.swift`
