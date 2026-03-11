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

// MARK: - SyntaxTheme → EditorTheme Bridge

extension SyntaxTheme {
    /// Converts the app's SyntaxTheme tokens to a CodeEditSourceEditor EditorTheme.
    var editorTheme: CodeEditSourceEditor.EditorTheme {
        .init(
            text: .init(color: text),
            insertionPoint: text,
            invisibles: .init(color: comments.withAlphaComponent(0.5)),
            background: background,
            lineHighlight: lineHighlight,
            selection: selection,
            keywords: .init(color: keywords),
            commands: .init(color: commands),
            types: .init(color: types),
            attributes: .init(color: attributes),
            variables: .init(color: variables),
            values: .init(color: values),
            numbers: .init(color: numbers),
            strings: .init(color: strings),
            characters: .init(color: characters),
            comments: .init(color: comments)
        )
    }
}

// MARK: - Legacy EditorTheme Convenience (used by FileWindowViewer)

extension CodeEditSourceEditor.EditorTheme {
    /// Default dark editor theme, derived from the app's default SyntaxTheme tokens.
    public static let defaultDark: Self = SyntaxTheme(
        background: NSColor(hex: "#1e1e1e"),
        lineHighlight: NSColor(hex: "#2c2c2c"),
        selection: NSColor(hex: "#264f78"),
        text: .white,
        keywords: NSColor(hex: "#569cd6"),
        commands: NSColor(hex: "#dcdcaa"),
        types: NSColor(hex: "#4ec9b0"),
        attributes: NSColor(hex: "#c586c0"),
        variables: .white,
        values: NSColor(hex: "#b5cea8"),
        numbers: NSColor(hex: "#b5cea8"),
        strings: NSColor(hex: "#ce9178"),
        characters: NSColor(hex: "#d7ba7d"),
        comments: NSColor(hex: "#6a9955"),
        bracketHighlight: NSColor(hex: "#569cd6").withAlphaComponent(0.4)
    ).editorTheme
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

// MARK: - GapBuffer Data Structure
struct GapBuffer {
    private var buffer: [Character]
    private var gapStart: Int
    private var gapEnd: Int

    var string: String {
        return String(buffer[0..<gapStart] + buffer[gapEnd..<buffer.count])
    }

    init(string: String) {
        self.buffer = Array(string)
        self.gapStart = buffer.count
        self.gapEnd = buffer.count
    }

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

    mutating func insert(_ char: Character) {
        ensureGap(ofSize: 1)
        buffer[gapStart] = char
        gapStart += 1
    }

    mutating func delete() {
        if gapStart > 0 {
            gapStart -= 1
        }
    }

    private mutating func ensureGap(ofSize size: Int) {
        if gapEnd - gapStart < size {
            let newGapSize = max(size, 64)
            buffer.insert(contentsOf: [Character](repeating: " ", count: newGapSize), at: gapStart)
            gapEnd = gapStart + newGapSize
        }
    }
}

// MARK: - Centralized Data Model
class CodeDocument: ObservableObject, Equatable {
    static func == (lhs: CodeDocument, rhs: CodeDocument) -> Bool {
        return lhs === rhs
    }

    @Published var content: GapBuffer
    @Published var language: CodeLanguage

    /// Maps language identifiers not natively supported by CodeEditLanguages
    /// to their closest supported equivalent for syntax highlighting.
    private static let languageFallbacks: [String: String] = [
        "xml": "html",
        "xhtml": "html",
        "svg": "html",
        "xaml": "html",
        "xsl": "html",
        "xslt": "html",
        "plist": "html",
        "jsp": "html",
        "erb": "html",
        "vue": "html",
        "sh": "bash",
        "zsh": "bash",
        "fish": "bash",
        "makefile": "bash",
        "cmake": "bash",
        "cs": "cSharp",
        "objcpp": "cpp",
        "h": "c",
        "hpp": "cpp",
        "jsonc": "json",
        "yml": "yaml",
        "md": "markdown",
        "mdx": "markdown",
        "mkd": "markdown",
        "mdown": "markdown",
    ]

    init(content: String, language: String?) {
        self.content = GapBuffer(string: content)
        let key = language?.lowercased()
        self.language = CodeLanguage.allLanguages.first {
            $0.id.rawValue.lowercased() == key
        } ?? key.flatMap({ fallbackKey in
            CodeDocument.languageFallbacks[fallbackKey]
        }).flatMap({ resolvedID in
            CodeLanguage.allLanguages.first { $0.id.rawValue.lowercased() == resolvedID }
        }) ?? .default
    }
}


// MARK: - CodeViewerPanelView (Main SwiftUI View)
struct CodeViewerPanelView: View {
    @EnvironmentObject var chatHistoryViewModel: ChatHistoryViewModel
    @EnvironmentObject var themeManager: ThemeManager

    @State private var isHoveringOnDivider = false
    @AppStorage("codeEditFontSize") var fontSize: Double = 13
    @AppStorage("codeViewerPanelWidth") private var panelWidth: Double = 600

    @State private var document: CodeDocument?
    @State private var didCopy: Bool = false
    @State private var currentSnippet: CodeSnippet?

    // MARK: - Resolved Theme Colors (derived from Code Viewer syntax theme)

    private var resolvedSyntax: SyntaxTheme {
        themeManager.resolvedCodeViewerSyntaxTheme
    }

    private var panelBackground: Color { Color(nsColor: resolvedSyntax.background) }
    private var headerBackground: Color { Color(nsColor: resolvedSyntax.lineHighlight) }
    private var textColor: Color { Color(nsColor: resolvedSyntax.text) }
    private var secondaryTextColor: Color { Color(nsColor: resolvedSyntax.comments) }
    private var accentTint: Color { Color(nsColor: resolvedSyntax.keywords) }
    private var selectionColor: Color { Color(nsColor: resolvedSyntax.selection) }

    /// Composite identifier for detecting theme changes in the NSViewController bridge.
    private var themeIdentifier: String {
        "\(themeManager.currentTheme.id)|\(themeManager.codeViewerThemeOverride.rawValue)"
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            resizableDivider
            panelContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .transition(.move(edge: .trailing))
        .shadow(color: .black.opacity(0.25), radius: 12, x: -4, y: 0)
        .onReceive(chatHistoryViewModel.$codeViewerContent) { newContent in
            if let content = newContent {
                let snippet = content.snippets[content.currentIndex]
                if currentSnippet?.id != snippet.id {
                    currentSnippet = snippet
                    document = CodeDocument(content: snippet.code, language: snippet.language)
                }
            } else {
                currentSnippet = nil
                document = nil
            }
        }
    }

    // MARK: - Resizable Divider

    private var resizableDivider: some View {
        Rectangle()
            .fill(isHoveringOnDivider ? accentTint.opacity(0.6) : selectionColor.opacity(0.3))
            .frame(width: 4)
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
            .animation(.easeInOut(duration: 0.15), value: isHoveringOnDivider)
    }

    // MARK: - Panel Content

    private var panelContent: some View {
        VStack(spacing: 0) {
            panelHeader

            Rectangle()
                .fill(selectionColor.opacity(0.4))
                .frame(height: 1)

            ZStack(alignment: .top) {
                if chatHistoryViewModel.isShowingDiff,
                   let originalCode = chatHistoryViewModel.originalCodeForDiff,
                   let modifiedCode = currentSnippet?.code {
                    CodeDiffView(originalCode: originalCode, modifiedCode: modifiedCode)
                        .transition(.opacity)
                } else if let document = document {
                    HighPerformanceCodeViewRepresentable(
                        document: document,
                        fontSize: fontSize,
                        editorTheme: resolvedSyntax.editorTheme,
                        bracketHighlightColor: resolvedSyntax.bracketHighlight,
                        themeIdentifier: themeIdentifier
                    )
                    .id(document.id)
                    .clipped()
                    .transition(.opacity)
                } else {
                    placeholderContent
                }
            }
        }
        .frame(width: panelWidth)
        .background(panelBackground)
    }

    // MARK: - Panel Header

    private var panelHeader: some View {
        ZStack {
            HStack {
                // Language badge
                HStack(spacing: 6) {
                    Image(systemName: languageIcon(for: currentSnippet?.language))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(accentTint)

                    Text(currentSnippet?.language?.capitalized ?? "Code Viewer")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(textColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selectionColor.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Spacer()

                // Action buttons
                HStack(spacing: 4) {
                    if chatHistoryViewModel.isShowingDiff, let snippet = currentSnippet {
                        CodeViewerHeaderButton(
                            action: { chatHistoryViewModel.applyChanges(for: snippet) },
                            icon: "checkmark.circle.fill",
                            helpText: "Apply Changes to File",
                            foregroundColor: Color(nsColor: resolvedSyntax.strings),
                            hoverBackground: selectionColor
                        )
                    }

                    if let snippet = currentSnippet, snippet.sourceFileID != nil {
                        CodeViewerHeaderButton(
                            action: {
                                withAnimation { chatHistoryViewModel.toggleDiffView(for: snippet) }
                            },
                            icon: chatHistoryViewModel.isShowingDiff ? "doc.text.fill" : "arrow.left.arrow.right",
                            helpText: chatHistoryViewModel.isShowingDiff ? "Show Final Code" : "Show Changes",
                            foregroundColor: chatHistoryViewModel.isShowingDiff ? accentTint : secondaryTextColor,
                            hoverBackground: selectionColor
                        )
                    }

                    CodeViewerHeaderButton(
                        action: {
                            copyCodeToClipboard()
                            didCopy = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { didCopy = false }
                        },
                        icon: didCopy ? "checkmark" : "doc.on.doc",
                        helpText: "Copy code to clipboard",
                        foregroundColor: didCopy ? Color(nsColor: resolvedSyntax.strings) : secondaryTextColor,
                        hoverBackground: selectionColor
                    )
                    .animation(.easeInOut(duration: 0.2), value: didCopy)
                    .disabled(document == nil)

                    CodeViewerHeaderButton(
                        action: saveCodeToFile,
                        icon: "square.and.arrow.down",
                        helpText: "Save code to a file",
                        foregroundColor: secondaryTextColor,
                        hoverBackground: selectionColor
                    )
                    .disabled(document == nil)

                    CodeViewerHeaderButton(
                        action: chatHistoryViewModel.hideCodeViewer,
                        icon: "xmark",
                        helpText: "Close viewer",
                        foregroundColor: secondaryTextColor,
                        hoverBackground: selectionColor
                    )
                }
            }

            // Centered snippet navigator
            if let content = chatHistoryViewModel.codeViewerContent, content.snippets.count > 1 {
                CodeViewerSnippetNavigator(
                    currentIndex: content.currentIndex,
                    totalCount: content.snippets.count,
                    onPrevious: chatHistoryViewModel.navigateToPreviousSnippet,
                    onNext: chatHistoryViewModel.navigateToNextSnippet,
                    textColor: textColor,
                    secondaryColor: secondaryTextColor,
                    hoverColor: selectionColor
                )
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(headerBackground)
    }

    // MARK: - Placeholder

    private var placeholderContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "curlybraces.square")
                .font(.system(size: 40, weight: .thin))
                .foregroundColor(secondaryTextColor.opacity(0.4))
            Text("No Code Selected")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(secondaryTextColor.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

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
        case "swift": return "swift"
        case "python": return "chevron.left.forwardslash.chevron.right"
        case "javascript", "typescript", "tsx": return "curlybraces"
        case "java": return "cup.and.saucer.fill"
        case "html", "xml", "svg", "xhtml": return "chevron.left.slash.chevron.right"
        case "css": return "number"
        case "ruby": return "diamond.fill"
        case "shell", "bash", "zsh": return "terminal.fill"
        case "json", "yaml", "yml", "toml": return "doc.badge.gearshape"
        case "rust": return "gearshape.2"
        case "go": return "arrow.right.arrow.left"
        case "c", "cpp", "objc": return "memorychip"
        case "markdown", "md", "mdx": return "text.document"
        default: return "doc.text"
        }
    }
}

// MARK: - Snippet Navigator

fileprivate struct CodeViewerSnippetNavigator: View {
    let currentIndex: Int
    let totalCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let textColor: Color
    let secondaryColor: Color
    let hoverColor: Color

    var body: some View {
        HStack(spacing: 2) {
            CodeViewerNavButton(action: onPrevious, icon: "chevron.left", enabled: currentIndex > 0, textColor: textColor, hoverColor: hoverColor)

            Text("\(currentIndex + 1) / \(totalCount)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(secondaryColor)
                .frame(width: 46)

            CodeViewerNavButton(action: onNext, icon: "chevron.right", enabled: currentIndex < totalCount - 1, textColor: textColor, hoverColor: hoverColor)
        }
        .padding(3)
        .background(hoverColor.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Nav Button

fileprivate struct CodeViewerNavButton: View {
    let action: () -> Void
    let icon: String
    let enabled: Bool
    let textColor: Color
    let hoverColor: Color
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(enabled ? textColor : textColor.opacity(0.2))
                .frame(width: 20, height: 20)
                .background(isHovering && enabled ? hoverColor : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { self.isHovering = $0 }
    }
}

// MARK: - Header Button

fileprivate struct CodeViewerHeaderButton: View {
    let action: () -> Void
    let icon: String
    let helpText: String
    let foregroundColor: Color
    let hoverBackground: Color
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isEnabled ? (isHovering ? foregroundColor : foregroundColor.opacity(0.7)) : foregroundColor.opacity(0.2))
                .frame(width: 28, height: 28)
                .background(isHovering && isEnabled ? hoverBackground : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { self.isHovering = $0 }
    }
}

extension CodeDocument: Identifiable {}


// MARK: - High-Performance NSViewControllerRepresentable
private struct HighPerformanceCodeViewRepresentable: NSViewControllerRepresentable {
    @ObservedObject var document: CodeDocument
    var fontSize: Double
    var editorTheme: CodeEditSourceEditor.EditorTheme
    var bracketHighlightColor: NSColor
    var themeIdentifier: String

    func makeNSViewController(context: Context) -> HighPerformanceCodeViewController {
        return HighPerformanceCodeViewController(
            document: document,
            editorTheme: editorTheme,
            bracketHighlightColor: bracketHighlightColor,
            themeIdentifier: themeIdentifier
        )
    }

    func updateNSViewController(_ nsViewController: HighPerformanceCodeViewController, context: Context) {
        nsViewController.update(
            document: document,
            fontSize: fontSize,
            editorTheme: editorTheme,
            bracketHighlightColor: bracketHighlightColor,
            themeIdentifier: themeIdentifier
        )
    }
}

// MARK: - High-Performance NSViewController
class HighPerformanceCodeViewController: NSViewController {

    private var document: CodeDocument
    private var cancellables = Set<AnyCancellable>()

    private var hostingController: NSHostingController<SourceEditor>?
    private var currentFontSize: Double = 14
    private var currentEditorTheme: CodeEditSourceEditor.EditorTheme
    private var currentBracketColor: NSColor
    private var currentThemeIdentifier: String

    init(document: CodeDocument, editorTheme: CodeEditSourceEditor.EditorTheme, bracketHighlightColor: NSColor, themeIdentifier: String) {
        self.document = document
        self.currentEditorTheme = editorTheme
        self.currentBracketColor = bracketHighlightColor
        self.currentThemeIdentifier = themeIdentifier
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupEditorView()
    }

    /// Builds the full SourceEditor configuration using the current theme.
    private func makeConfiguration(font: NSFont) -> SourceEditorConfiguration {
        .init(
            appearance: .init(
                theme: currentEditorTheme,
                useThemeBackground: true,
                font: font,
                lineHeightMultiple: 1.2,
                letterSpacing: 1.0,
                wrapLines: true,
                tabWidth: 4,
                bracketPairEmphasis: .bordered(color: currentBracketColor)
            ),
            behavior: .init(
                isEditable: false,
                isSelectable: true,
                indentOption: .spaces(count: 4)
            ),
            layout: .init(
                editorOverscroll: 0.3,
                contentInsets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
            ),
            peripherals: .init(
                showGutter: true,
                showMinimap: false,
                showReformattingGuide: false,
                showFoldingRibbon: true,
                invisibleCharactersConfiguration: .init(
                    showSpaces: false,
                    showTabs: false,
                    showLineEndings: false
                ),
                warningCharacters: [0x200B, 0x200C, 0x200D, 0xFEFF]
            )
        )
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

        let font = NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)
        let editorView = SourceEditor(
            contentBinding,
            language: document.language,
            configuration: makeConfiguration(font: font),
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
            configuration: makeConfiguration(font: font),
            state: .constant(.init())
        )
        hostingController?.rootView = newEditorView
    }

    func update(document: CodeDocument, fontSize: Double, editorTheme: CodeEditSourceEditor.EditorTheme, bracketHighlightColor: NSColor, themeIdentifier: String) {
        var needsViewUpdate = false

        if self.document != document {
            self.document = document
            needsViewUpdate = true
        }

        if self.currentFontSize != fontSize {
            self.currentFontSize = fontSize
            needsViewUpdate = true
        }

        if self.currentThemeIdentifier != themeIdentifier {
            self.currentThemeIdentifier = themeIdentifier
            self.currentEditorTheme = editorTheme
            self.currentBracketColor = bracketHighlightColor
            needsViewUpdate = true
        }

        if needsViewUpdate {
            updatePresentationView()
        }
    }
}
