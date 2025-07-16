////
////  CodeEditorFileViewer.swift
////  Devgentic
////
////  Created by Raj Singh on 15/07/25.
////
//
//import SwiftUI
//import CodeEditorView
//import LanguageSupport // Crucial import for pre-defined language configurations
//import os
//
//// NOTE: This enum is a good local replacement for the library's `ThemeName`.
//enum EditorTheme: String, CaseIterable, Identifiable {
//    case light, dark
//
//    var id: String { self.rawValue }
//
//    /// Generates a `Theme` object based on the enum case.
//    /// - Parameter fontSize: The font size to apply to the theme.
//    /// - Returns: A configured `Theme` object.
//    func theme(withFontSize fontSize: CGFloat) -> Theme {
//        // NOTE: The initializer for `Theme` has been corrected to match the one from your `Theme.swift` file.
//        switch self {
//        case .light:
//            let plainColor = OSColor.black
//            let typeColor = OSColor(red: 0.38, green: 0.28, blue: 0.62, alpha: 1.0)
//            return Theme(
//                colourScheme: .light,
//                fontName: "SFMono-Regular",
//                fontSize: fontSize,
//                textColour: plainColor,
//                commentColour: OSColor(red: 0.0, green: 0.45, blue: 0.0, alpha: 1.0),
//                stringColour: OSColor(red: 0.78, green: 0.15, blue: 0.18, alpha: 1.0),
//                characterColour: OSColor(red: 0.78, green: 0.15, blue: 0.18, alpha: 1.0), // Fallback
//                numberColour: OSColor(red: 0.17, green: 0.22, blue: 0.82, alpha: 1.0),
//                identifierColour: plainColor,
//                operatorColour: plainColor, // Fallback
//                keywordColour: OSColor(red: 0.63, green: 0.28, blue: 0.62, alpha: 1.0),
//                symbolColour: plainColor, // Fallback
//                typeColour: typeColor,
//                fieldColour: typeColor, // Fallback
//                caseColour: typeColor, // Fallback
//                backgroundColour: .white,
//                currentLineColour: OSColor(red: 0.92, green: 0.95, blue: 1.0, alpha: 1.0),
//                selectionColour: OSColor(red: 0.82, green: 0.87, blue: 0.98, alpha: 1.0),
//                cursorColour: .black,
//                invisiblesColour: .lightGray
//            )
//        case .dark:
//            let plainColor = OSColor.white
//            let typeColor = OSColor(red: 0.63, green: 0.85, blue: 0.79, alpha: 1.0)
//            return Theme(
//                colourScheme: .dark,
//                fontName: "SFMono-Regular",
//                fontSize: fontSize,
//                textColour: plainColor,
//                commentColour: OSColor(red: 0.47, green: 0.53, blue: 0.59, alpha: 1.0),
//                stringColour: OSColor(red: 1.0, green: 0.54, blue: 0.53, alpha: 1.0),
//                characterColour: OSColor(red: 1.0, green: 0.54, blue: 0.53, alpha: 1.0), // Fallback
//                numberColour: OSColor(red: 0.81, green: 0.79, blue: 0.69, alpha: 1.0),
//                identifierColour: plainColor,
//                operatorColour: plainColor, // Fallback
//                keywordColour: OSColor(red: 0.99, green: 0.53, blue: 0.99, alpha: 1.0),
//                symbolColour: plainColor, // Fallback
//                typeColour: typeColor,
//                fieldColour: typeColor, // Fallback
//                caseColour: typeColor, // Fallback
//                backgroundColour: OSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0),
//                currentLineColour: OSColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1.0),
//                selectionColour: OSColor(red: 0.29, green: 0.44, blue: 0.64, alpha: 1.0),
//                cursorColour: .white,
//                invisiblesColour: .darkGray
//            )
//        }
//    }
//}
//
//
//// A state manager for the CodeEditorView-based file viewer.
//// It handles loading file content, managing view state, and determining language for syntax highlighting.
//@MainActor
//class CodeEditorFileViewerState: ObservableObject {
//    // MARK: - Published Properties
//    @Published var content: String = ""
//    @Published var errorMessage: String?
//    @Published var isLoading: Bool = false
//    @Published var fileName: String?
//    @Published var language: LanguageConfiguration
//    
//    // NOTE: Added missing state properties required by the CodeEditor initializer.
//    @Published var position = CodeEditor.Position()
//    @Published var messages = Set<TextLocated<Message>>()
//    
//    // Using @AppStorage to persist theme and font size across app launches
//    @AppStorage("codeEditorTheme") var selectedTheme: EditorTheme = .light
//    @AppStorage("codeEditorFontSize") var fontSize: Double = 14.0
//
//    // MARK: - Properties
//    let fileURL: URL
//    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CodeEditorFileViewerState")
//
//    // MARK: - Initializer
//    init(fileURL: URL) {
//        self.fileURL = fileURL
//        self.fileName = fileURL.lastPathComponent
//        // FIX: Determine language using the new, correct helper that maps extensions
//        // to the standard language configurations from the LanguageSupport module.
//        self.language = LanguageConfiguration.from(fileExtension: fileURL.pathExtension)
//        loadFileContent()
//    }
//
//    // MARK: - File Loading
//    func loadFileContent() {
//        isLoading = true
//        errorMessage = nil
//        content = ""
//        
//        logger.info("Attempting to load file content for: \(self.fileURL.path)")
//
//        // Access security-scoped resources safely, which is crucial for files opened via UIDocumentPicker
//        guard self.fileURL.startAccessingSecurityScopedResource() else {
//            logger.error("Could not gain access to read file: \(self.fileURL.path)")
//            self.errorMessage = "Permission denied. Please ensure the app has access to this location."
//            self.isLoading = false
//            return
//        }
//        
//        // Ensure access is stopped when the function exits
//        defer {
//            self.fileURL.stopAccessingSecurityScopedResource()
//            logger.info("Stopped accessing security-scoped resource for file: \(self.fileURL.path)")
//        }
//
//        do {
//            // Check file size to avoid loading excessively large files into memory
//            let attributes = try FileManager.default.attributesOfItem(atPath: self.fileURL.path)
//            if let fileSize = attributes[.size] as? NSNumber, fileSize.doubleValue > (10 * 1024 * 1024) { // 10MB limit
//                logger.warning("File \(self.fileName ?? "") is too large: \(fileSize.doubleValue / (1024*1024)) MB.")
//                self.errorMessage = "File is too large to display (max 10MB)."
//                self.isLoading = false
//                return
//            }
//
//            // Read file content as a plain string, which is what CodeEditorView requires
//            self.content = try String(contentsOf: self.fileURL, encoding: .utf8)
//            self.isLoading = false
//            logger.info("Successfully read content for file: \(self.fileName ?? "unknown").")
//
//        } catch {
//            logger.error("Failed to read content for file \(self.fileURL.path): \(error.localizedDescription)")
//            self.errorMessage = "Could not read file content. It might be binary, corrupted, or use an unsupported text encoding.\nError: \(error.localizedDescription)"
//            self.isLoading = false
//        }
//    }
//
//    // MARK: - Font Size Controls
//    func increaseFontSize() {
//        if fontSize < 40 {
//            fontSize += 1
//        }
//    }
//
//    func decreaseFontSize() {
//        if fontSize > 8 {
//            fontSize -= 1
//        }
//    }
//}
//
//
//// MARK: - The SwiftUI View
//struct CodeEditorFileViewer: View {
//    @StateObject private var state: CodeEditorFileViewerState
//    @State private var justCopied: Bool = false
//
//    init(fileURL: URL) {
//        _state = StateObject(wrappedValue: CodeEditorFileViewerState(fileURL: fileURL))
//    }
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 0) {
//            if state.isLoading {
//                ProgressView("Loading \(state.fileName ?? "file")...")
//                    .frame(maxWidth: .infinity, maxHeight: .infinity)
//            } else if let error = state.errorMessage {
//                // Display a user-friendly error message
//                VStack(spacing: 12) {
//                    Image(systemName: "exclamationmark.triangle.fill")
//                        .font(.system(size: 40))
//                        .foregroundColor(.red)
//                    Text("Error Opening File")
//                        .font(.title2.weight(.semibold))
//                    Text(error)
//                        .font(.body)
//                        .multilineTextAlignment(.center)
//                        .foregroundColor(.secondary)
//                        .padding(.horizontal)
//                }
//                .frame(maxWidth: .infinity, maxHeight: .infinity)
//                .padding()
//            } else {
//                // NOTE: Corrected the CodeEditor initialization to match the library version.
//                // The theme and font size are passed via environment modifiers.
//                CodeEditor(text: $state.content,
//                           position: $state.position,
//                           messages: $state.messages,
//                           language: state.language)
//                    .environment(\.codeEditorTheme, state.selectedTheme.theme(withFontSize: state.fontSize))
//                    .frame(maxWidth: .infinity, maxHeight: .infinity)
//            }
//        }
//        .navigationTitle(state.fileName ?? "File Viewer")
//        .toolbar {
//            ToolbarItemGroup(placement: .automatic) {
//                // Font size controls
//                Button(action: state.decreaseFontSize, label: { Image(systemName: "minus.magnifyingglass") })
//                    .help("Decrease font size")
//                    .disabled(state.isLoading || state.errorMessage != nil)
//
//                Button(action: state.increaseFontSize, label: { Image(systemName: "plus.magnifyingglass") })
//                    .help("Increase font size")
//                    .disabled(state.isLoading || state.errorMessage != nil)
//
//                // Theme picker
//                Picker("Theme", selection: $state.selectedTheme) {
//                    ForEach(EditorTheme.allCases) { theme in
//                        Text(theme.rawValue.capitalized).tag(theme)
//                    }
//                }
//                .pickerStyle(.menu)
//                .disabled(state.isLoading || state.errorMessage != nil)
//                
//                Spacer()
//
//                // Copy to clipboard button
//                Button(action: copyContentToClipboard) {
//                    Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
//                        .foregroundColor(justCopied ? .green : .accentColor)
//                }
//                .help(justCopied ? "Copied!" : "Copy content to clipboard")
//                .disabled(state.isLoading || state.errorMessage != nil)
//            }
//        }
//        // Use the .id() modifier on the view that *creates* this one to ensure it reloads
//        // when a new file is selected. For example: `CodeEditorFileViewer(fileURL: url).id(url)`
//    }
//    
//    private func copyContentToClipboard() {
//        #if os(macOS)
//        NSPasteboard.general.clearContents()
//        NSPasteboard.general.setString(state.content, forType: .string)
//        #elseif os(iOS)
//        UIPasteboard.general.string = state.content
//        #endif
//        
//        justCopied = true
//        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
//            justCopied = false
//        }
//    }
//}
//
//// MARK: - Language Detection Helper
//// FIX: This extension now correctly maps file extensions to the built-in language
//// configurations provided by the `LanguageSupport` module. The old, broken,
//// manually-defined languages have been removed.
//extension LanguageConfiguration {
//    
//    /// Determines the `LanguageConfiguration` based on a file extension.
//    ///
//    /// This function maps common file extensions to the pre-defined language configurations
//    /// that are included with the `LanguageSupport` module.
//    ///
//    /// - Parameter fileExtension: The file extension (e.g., "swift", "py", "js").
//    /// - Returns: The corresponding `LanguageConfiguration` or `.plaintext` if no match is found.
//    static func from(fileExtension: String) -> LanguageConfiguration {
//        // FIX: The compiler error "Member '...' is a function... did you mean to call it?"
//        // indicates that the language configurations from the library are functions, not
//        // static properties. They must be called with `()`.
//        switch fileExtension.lowercased() {
//        case "swift":
//            return .swift()
//
//        default:
//            // Use .none for plain text as it's the designed fallback.
//            // .none is a static property, so it doesn't need to be called.
//            return .none
//        }
//    }
//}
//
//
//// MARK: - Preview Provider
//struct CodeEditorFileViewer_Previews: PreviewProvider {
//    // Helper to create a dummy file for previews
//    static func createDummyFile(named name: String, with content: String) -> URL {
//        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
//        try? content.write(to: url, atomically: true, encoding: .utf8)
//        return url
//    }
//    
//    static var previews: some View {
//        let swiftFileURL = createDummyFile(
//            named: "Preview.swift",
//            with: """
//            import SwiftUI
//            
//            // A classic example
//            struct PreviewTest: View {
//                @State private var name = "World"
//            
//                var body: some View {
//                    Text("Hello, \\(name)!")
//                        .padding()
//                }
//            }
//            """
//        )
//        
//        // To see the preview, wrap it in a NavigationView
//        NavigationView {
//            CodeEditorFileViewer(fileURL: swiftFileURL)
//                .frame(width: 750, height: 600)
//        }
//    }
//}
