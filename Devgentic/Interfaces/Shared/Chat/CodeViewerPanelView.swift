//
//  CodeViewerPanelView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import Combine
import UniformTypeIdentifiers

// MARK: - Theme & Color Extensions
extension CodeEditSourceEditor.EditorTheme {
    public static let defaultDark: Self = .init(
        text: .init(color: .white),
        insertionPoint: .white,
        invisibles: .init(color: .systemGray.withAlphaComponent(0.5)),
        background: NSColor(hex: "#000000"),
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

// MARK: - PHASE 2 COMPLETE: GapBuffer Data Structure
/// A data structure optimized for efficient insertion and deletion of text.
/// It uses an array with a "gap" that can be moved to the cursor's position.
/// Edits within the gap are extremely fast (O(1) complexity).
struct GapBuffer {
    private var buffer: [Character]
    private var gapStart: Int
    private var gapEnd: Int
    
    /// The full text content derived from the buffer.
    var string: String {
        return String(buffer[0..<gapStart] + buffer[gapEnd..<buffer.count])
    }
    
    /// Initializes the Gap Buffer with an initial string content.
    init(string: String) {
        self.buffer = Array(string)
        self.gapStart = buffer.count
        self.gapEnd = buffer.count
    }
    
    /// Moves the gap to a specified position in the text.
    /// This is the most expensive operation, but it makes subsequent edits fast.
    mutating func moveGap(to position: Int) {
        guard position != gapStart else { return }
        
        if position < gapStart {
            let distance = gapStart - position
            let gapSize = gapEnd - gapStart
            buffer.replaceSubrange(position..<position+gapSize, with: buffer[position..<gapStart])
            gapStart = position
            gapEnd = position + gapSize
        } else {
            let distance = position - gapStart
            buffer.replaceSubrange(gapStart..<gapStart+distance, with: buffer[gapEnd..<gapEnd+distance])
            gapStart = position
            gapEnd = position + (gapEnd - gapStart)
        }
    }
    
    /// Inserts a character at the current gap position.
    mutating func insert(_ char: Character) {
        ensureGap(ofSize: 1)
        buffer[gapStart] = char
        gapStart += 1
    }
    
    /// Deletes a character from before the current gap position.
    mutating func delete() {
        if gapStart > 0 {
            gapStart -= 1
        }
    }
    
    /// Ensures the gap has at least a certain size, resizing if necessary.
    private mutating func ensureGap(ofSize size: Int) {
        if gapEnd - gapStart < size {
            let newGapSize = max(size, 64) // Ensure a minimum new gap size
            buffer.insert(contentsOf: [Character](repeating: " ", count: newGapSize), at: gapStart)
            gapEnd = gapStart + newGapSize
        }
    }
}

// MARK: - Centralized Data Model
/// The document model now uses a `GapBuffer` for its content,
/// enabling high-performance text manipulations.
class CodeDocument: ObservableObject, Equatable {
    static func == (lhs: CodeDocument, rhs: CodeDocument) -> Bool {
        // Documents are considered equal if they are the same object instance.
        return lhs === rhs
    }
    
    @Published var content: GapBuffer
    @Published var language: CodeLanguage

    init(content: String, language: String?) {
        self.content = GapBuffer(string: content)
        self.language = CodeLanguage.allLanguages.first {
            $0.id.rawValue.lowercased() == language?.lowercased()
        } ?? .default
    }
}


// MARK: - CodeViewerPanelView (Main SwiftUI View)
struct CodeViewerPanelView: View {
    @EnvironmentObject var chatHistoryViewModel: ChatHistoryViewModel
    @State private var isHoveringOnDivider = false
    @AppStorage("codeEditFontSize") var fontSize: Double = 14
    @AppStorage("codeViewerPanelWidth") private var panelWidth: Double = 600

    @State private var document: CodeDocument?
    @State private var didCopy: Bool = false
    
    // NEW: State to hold the current snippet being viewed
    @State private var currentSnippet: CodeSnippet?

    var body: some View {
        HStack(spacing: 0) {
            resizableDivider
            panelContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .transition(.move(edge: .trailing))
        .shadow(radius: 10)
        .onReceive(chatHistoryViewModel.$codeViewerContent) { newContent in
            // MODIFIED: Update the current snippet when the view model changes
            if let content = newContent {
                let snippet = content.snippets[content.currentIndex]
                if currentSnippet != snippet {
                    currentSnippet = snippet
                    document = CodeDocument(content: snippet.code, language: snippet.language)
                }
            } else {
                currentSnippet = nil
                document = nil
            }
        }
    }
    
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
            panelHeader
            ZStack(alignment: .top) {
                if let document = document {
                    HighPerformanceCodeViewRepresentable(
                        document: document,
                        fontSize: fontSize
                    )
                    .id(document.id)
                    .clipped()
                } else {
                    placeholderContent
                }
                Divider()
            }
        }
        .frame(width: panelWidth)
        .background(Color(nsColor: NSColor(hex: "#282a36")))
    }
    
    private var panelHeader: some View {
        ZStack {
            // Left and Right aligned content
            HStack {
                // Left side
                HStack(spacing: 8) {
                    Image(systemName: languageIcon(for: currentSnippet?.language))
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .frame(width: 24, alignment: .center)

                    Text(currentSnippet?.language?.capitalized ?? "Code Viewer")
                        .font(.headline)
                        .fontWeight(.medium)
                }

                Spacer()

                // Right side
                HStack(spacing: 4) {
                    HeaderButton(
                        action: {
                            copyCodeToClipboard()
                            didCopy = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                didCopy = false
                            }
                        },
                        icon: didCopy ? "checkmark" : "doc.on.doc",
                        helpText: "Copy code to clipboard",
                        color: didCopy ? .green : .secondary
                    )
                    .animation(.easeInOut, value: didCopy)
                    .disabled(document == nil)

                    HeaderButton(
                        action: saveCodeToFile,
                        icon: "square.and.arrow.down",
                        helpText: "Save code to a file",
                        color: .secondary
                    )
                    .disabled(document == nil)

                    HeaderButton(
                        action: chatHistoryViewModel.hideCodeViewer,
                        icon: "xmark",
                        helpText: "Close viewer",
                        color: .secondary
                    )
                }
            }

            // Centered content
            if let content = chatHistoryViewModel.codeViewerContent, content.snippets.count > 1 {
                SnippetNavigatorView(
                    currentIndex: content.currentIndex,
                    totalCount: content.snippets.count,
                    onPrevious: chatHistoryViewModel.navigateToPreviousSnippet,
                    onNext: chatHistoryViewModel.navigateToNextSnippet
                )
            }
        }
        .padding(.horizontal)
        .frame(height: 48)
        .background(.ultraThinMaterial)
    }
    
    private var placeholderContent: some View {
        VStack {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 50))
                .foregroundColor(.gray.opacity(0.5))
                .padding(.bottom)
            Text("No Content")
                .font(.title2)
                .foregroundColor(.gray)
            Text("Select a code block to view it here.")
                .foregroundColor(.gray.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyCodeToClipboard() {
        guard let snippet = currentSnippet else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet.code, forType: .string)
    }

    private func saveCodeToFile() {
        guard let snippet = currentSnippet else { return }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false
        
        let language = CodeLanguage.allLanguages.first {
            $0.id.rawValue.lowercased() == snippet.language?.lowercased()
        } ?? .default
        
        savePanel.nameFieldStringValue = "snippet.\(language.extensions.first ?? "txt")"
        savePanel.title = "Save Code Snippet"
        
        if let utType = UTType(tag: language.extensions.first ?? "", tagClass: .filenameExtension, conformingTo: .text) {
            savePanel.allowedContentTypes = [utType]
        } else {
            savePanel.allowedContentTypes = [.text]
        }

        savePanel.begin { (result) in
            if result == .OK, let url = savePanel.url {
                do {
                    try snippet.code.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("Error saving file: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func languageIcon(for languageID: String?) -> String {
        switch languageID?.lowercased() {
        case "swift":
            return "swift"
        case "python":
            return "chevron.left.forwardslash.chevron.right"
        case "javascript", "typescript", "tsx":
            return "curlybraces"
        case "java":
            return "cup.and.saucer.fill"
        case "html":
            return "chevron.left.slash.chevron.right"
        case "css":
            return "number"
        case "ruby":
            return "diamond.fill"
        case "shell":
            return "terminal.fill"
        default:
            return "doc.text"
        }
    }
}

// MARK: - NEW: Modern Snippet Navigator View
fileprivate struct SnippetNavigatorView: View {
    let currentIndex: Int
    let totalCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Previous Button
            NavButton(
                action: onPrevious,
                icon: "chevron.left",
                enabled: currentIndex > 0
            )

            // Page Indicator
            Text("\(currentIndex + 1) of \(totalCount)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)

            // Next Button
            NavButton(
                action: onNext,
                icon: "chevron.right",
                enabled: currentIndex < totalCount - 1
            )
        }
        .padding(4)
        .background(Color.black.opacity(0.2))
        .cornerRadius(8)
    }
}

// MARK: - NEW: Reusable Navigation Button
fileprivate struct NavButton: View {
    let action: () -> Void
    let icon: String
    let enabled: Bool
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(enabled ? .primary : .secondary.opacity(0.5))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isHovering && enabled ? Color.gray.opacity(0.3) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                self.isHovering = hovering
            }
        }
    }
}

// MARK: - NEW: Modern Header Action Button
fileprivate struct HeaderButton: View {
    let action: () -> Void
    let icon: String
    let helpText: String
    let color: Color
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(isEnabled ? color : .secondary.opacity(0.5))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(isHovering && isEnabled ? Color.gray.opacity(0.25) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                self.isHovering = hovering
            }
        }
    }
}


extension CodeDocument: Identifiable {}


// MARK: - High-Performance NSViewControllerRepresentable
private struct HighPerformanceCodeViewRepresentable: NSViewControllerRepresentable {
    @ObservedObject var document: CodeDocument
    var fontSize: Double

    func makeNSViewController(context: Context) -> HighPerformanceCodeViewController {
        return HighPerformanceCodeViewController(document: document)
    }

    func updateNSViewController(_ nsViewController: HighPerformanceCodeViewController, context: Context) {
        nsViewController.update(document: document, fontSize: fontSize)
    }
}

// MARK: - High-Performance NSViewController
class HighPerformanceCodeViewController: NSViewController {
    
    private var document: CodeDocument
    private var cancellables = Set<AnyCancellable>()

    private var hostingController: NSHostingController<SourceEditor>?
    private var currentFontSize: Double = 14

    init(document: CodeDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupEditorView()
    }

    private func setupEditorView() {
        let contentBinding = Binding<String>(
            get: { self.document.content.string },
            set: { newString in
                if self.document.content.string != newString {
                    self.document.content = GapBuffer(string: newString)
                }
            }
        )

        let editorView = SourceEditor(
            contentBinding,
            language: document.language,
            configuration: .init(
                appearance: .init(
                    theme: .defaultDark,
                    font: .monospacedSystemFont(ofSize: currentFontSize, weight: .regular),
                    lineHeightMultiple: 1.2,
                    wrapLines: true
                ),
                peripherals: .init(showGutter: true, showMinimap: false)
            ),
            state: .constant(.init())
        )
        
        let hosting = NSHostingController(rootView: editorView)
        self.hostingController = hosting
        
        addChild(hosting)
        view.addSubview(hosting.view)
        
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    private func updatePresentationView() {
        let font = NSFont.monospacedSystemFont(ofSize: self.currentFontSize, weight: .regular)
        
        let contentBinding = Binding<String>(
            get: { self.document.content.string },
            set: { newString in
                if self.document.content.string != newString {
                    self.document.content = GapBuffer(string: newString)
                }
            }
        )
        
        let newEditorView = SourceEditor(
            contentBinding,
            language: self.document.language,
            configuration: .init(
                appearance: .init(
                    theme: .defaultDark,
                    font: font,
                    lineHeightMultiple: 1.2,
                    wrapLines: true
                ),
                peripherals: .init(showGutter: true, showMinimap: false)
            ),
            state: .constant(.init())
        )
        hostingController?.rootView = newEditorView
    }

    func update(document: CodeDocument, fontSize: Double) {
        var needsViewUpdate = false
        
        if self.document != document {
            self.document = document
            needsViewUpdate = true
        }
        
        if self.currentFontSize != fontSize {
            self.currentFontSize = fontSize
            needsViewUpdate = true
        }
        
        if needsViewUpdate {
            updatePresentationView()
        }
    }
}
