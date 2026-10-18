// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeViewerPanelView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import UniformTypeIdentifiers
import os

private let logger = DGLogger(category: "CodeViewerPanel")

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
        selection: NSColor(hex: "#353535"),
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

// MARK: - Centralized Data Model
@Observable
class CodeDocument: Equatable {
    static func == (lhs: CodeDocument, rhs: CodeDocument) -> Bool {
        return lhs.content == rhs.content && lhs.language.id == rhs.language.id
    }

    /// The tab's text as a plain String; `CodeEditSourceEditor` owns editing, this document only carries content in and out.
    var content: String
    var language: CodeLanguage

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
        self.content = content
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

// MARK: - CodeLanguage Display & Selection Extensions

extension CodeLanguage: @retroactive Identifiable {
    var displayName: String {
        switch id {
        case .agda: return "Agda"
        case .bash: return "Bash"
        case .c: return "C"
        case .cpp: return "C++"
        case .cSharp: return "C#"
        case .css: return "CSS"
        case .dart: return "Dart"
        case .dockerfile: return "Dockerfile"
        case .elixir: return "Elixir"
        case .go: return "Go"
        case .goMod: return "Go Module"
        case .haskell: return "Haskell"
        case .html: return "HTML"
        case .java: return "Java"
        case .javascript: return "JavaScript"
        case .jsdoc: return "JSDoc"
        case .json: return "JSON"
        case .jsx: return "JSX"
        case .julia: return "Julia"
        case .kotlin: return "Kotlin"
        case .lua: return "Lua"
        case .markdown: return "Markdown"
        case .markdownInline: return "Markdown (Inline)"
        case .objc: return "Objective-C"
        case .ocaml: return "OCaml"
        case .ocamlInterface: return "OCaml Interface"
        case .perl: return "Perl"
        case .php: return "PHP"
        case .python: return "Python"
        case .regex: return "Regex"
        case .ruby: return "Ruby"
        case .rust: return "Rust"
        case .scala: return "Scala"
        case .sql: return "SQL"
        case .swift: return "Swift"
        case .toml: return "TOML"
        case .tsx: return "TSX"
        case .typescript: return "TypeScript"
        case .verilog: return "Verilog"
        case .yaml: return "YAML"
        case .zig: return "Zig"
        case .plainText: return "Plain Text"
        }
    }

    static let commonLanguages: [CodeLanguage] = [
        .swift,
        .typescript,
        .javascript,
        .python,
        .json,
        .html,
        .css,
        .markdown,
        .bash,
        .rust,
        .go,
        .cpp,
        .default
    ]

    static let allSortedLanguages: [CodeLanguage] = {
        var list = CodeLanguage.allLanguages
        if !list.contains(where: { $0.id == .plainText }) {
            list.append(.default)
        }
        return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }()
}

// MARK: - Code Viewer Status Bar State

@Observable
final class CodeViewerStatusBarState {
    var line: Int = 1
    var column: Int = 1
    var selectionLength: Int = 0

    func update(from state: SourceEditorState) {
        if let cursor = state.cursorPositions?.first {
            if cursor.start.line > 0 {
                self.line = cursor.start.line
            }
            if cursor.start.column > 0 {
                self.column = cursor.start.column
            }
            if cursor.range.location != NSNotFound {
                self.selectionLength = max(0, cursor.range.length)
            } else {
                self.selectionLength = 0
            }
        }
    }

    func reset() {
        line = 1
        column = 1
        selectionLength = 0
    }
}

// MARK: - Syntax theme memo

// Why: deriving the palette runs `NSColor(hex:)` many times and the panel reads it through a dozen accessors,
// so without the cache every keystroke-driven body pass re-derives it dozens of times
/// Caches the resolved Code Viewer `SyntaxTheme` while the tokens it derives from are unchanged.
/// A reference type so a `View` struct's non-mutating computed property can fill it; deliberately not observable,
/// since warming a cache must not invalidate anything.
private final class SyntaxThemeCache {
    var key: String?
    var theme: SyntaxTheme?
}

// MARK: - CodeViewerPanelView (Main SwiftUI View)
struct CodeViewerPanelView: View {
    @Environment(ChatHistoryViewModel.self) var chatHistoryViewModel
    @Environment(ThemeManager.self) var themeManager
    /// Optional: absent wherever the app root's environment does not reach. Its snapshot is non-nil
    /// only in Code mode with a loaded repository (the store follows no project elsewhere).
    @Environment(GitChangesStore.self) private var gitChangesStore: GitChangesStore?
    @Environment(\.appTheme) private var appTheme
    @Environment(\.surfaceStyle) private var surfaceStyle

    @State private var isHoveringOnDivider = false
    /// Panel width captured at the start of a divider drag, so the cumulative gesture
    /// translation is applied to a fixed base rather than the live (already-moved) width.
    @State private var dragStartWidth: Double? = nil
    @AppStorage("codeEditFontSize") var fontSize: Double = 13
    @AppStorage("codeViewerPanelWidth") private var panelWidth: Double = 600
    @AppStorage("codeViewerWrapLines") private var wrapLines: Bool = true
    @AppStorage("codeViewerShowMinimap") private var showMinimap: Bool = false
    /// When on, a starting agent write auto-selects its tab — but only ever INSIDE an
    /// already-open panel (badge-only policy: the panel itself is never auto-opened).
    @AppStorage("codeViewerFollowAgent") private var followAgent: Bool = false

    // Why: held on the view model, not `@State`: in `.split` mode `MainApplicationView` insets the chat by this width, and a
    // UserDefaults write per mouse move spams the preferences daemon
    /// Width while a divider drag is in flight, written per tick instead of the `@AppStorage`-backed `panelWidth`;
    /// the final width is committed to `panelWidth` once, on drag end.
    private var liveDragWidth: Double? { chatHistoryViewModel.codeViewerLiveDragWidth }

    /// The width the panel renders at: the in-flight drag value when dragging, else the
    /// persisted preference.
    private var displayedWidth: Double { liveDragWidth ?? panelWidth }

    // Why: caps both the drag and the rendered width: a persisted width wider than the window would push the divider
    // off-screen and leave the panel unresizable
    /// The width of the container the panel is mounted in (the window's content area), measured via `onGeometryChange`.
    /// `.infinity` until the first geometry pass, so `min(displayedWidth, containerWidth)` is a no-op at startup.
    @State private var containerWidth: CGFloat = .infinity

    /// Widest the panel may render or be dragged to. In split the chat is a real sibling
    /// laying out beside the panel, so the panel must leave it a readable column; in
    /// overlay/full the chat is covered anyway and the container is the only bound.
    private var maxPanelWidth: CGFloat {
        guard chatHistoryViewModel.codeViewerPresentation == .split,
              containerWidth.isFinite else { return containerWidth }
        return max(400, containerWidth - ChatUIConstants.splitModeMinChatWidth - 24)
    }

    private var floatingBorderStroke: some ShapeStyle {
        surfaceStyle == .glassmorphic
            ? AnyShapeStyle(LinearGradient(
                colors: [
                    appTheme.isDark ? Color.white.opacity(0.18) : appTheme.dividerColor,
                    appTheme.dividerColor.opacity(0.6),
                    accentTint.opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            : AnyShapeStyle(LinearGradient(
                colors: [
                    appTheme.isDark ? Color.white.opacity(0.08) : appTheme.dividerColor.opacity(0.7)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
    }

    private var floatingShadowColor: Color {
        surfaceStyle == .glassmorphic
            ? appTheme.shadowColor.opacity(0.6)
            : Color.black.opacity(appTheme.isDark ? 0.35 : 0.12)
    }

    @State private var document: CodeDocument?
    @State private var statusBarState = CodeViewerStatusBarState()
    @State private var didCopy: Bool = false
    @State private var currentSnippet: CodeSnippet?
    @State private var saveErrorMessage: String?
    @State private var backgroundTaskCount: Int = 0
    @State private var backgroundTaskRunningCount: Int = 0

    private func reloadBackgroundTasks() {
        guard let cid = chatHistoryViewModel.viewerOwningConversationID else {
            backgroundTaskCount = 0
            backgroundTaskRunningCount = 0
            return
        }
        let list = BackgroundProcessRegistry.shared.snapshots(conversationID: cid)
        backgroundTaskCount = list.count
        backgroundTaskRunningCount = list.filter { !$0.status.isTerminal }.count
    }

    // MARK: - Resolved Theme Colors (derived from Code Viewer syntax theme)

    @State private var syntaxCache = SyntaxThemeCache()

    // Why: `themeIdentifier` is read first and unconditionally: that read registers the `@Observable` dependency on the
    // theme manager, so the cache skips the derivation, never the observation
    /// The Code Viewer's syntax palette, derived at most once per (theme, code-theme override, accent);
    /// see `SyntaxThemeCache`.
    private var resolvedSyntax: SyntaxTheme {
        let key = themeIdentifier
        if syntaxCache.key == key, let cached = syntaxCache.theme { return cached }
        let resolved = themeManager.resolvedCodeViewerSyntaxTheme
        syntaxCache.key = key
        syntaxCache.theme = resolved
        return resolved
    }

    private var panelBackground: Color { Color(nsColor: resolvedSyntax.background) }
    private var headerBackground: Color { Color(nsColor: resolvedSyntax.lineHighlight) }
    private var textColor: Color { Color(nsColor: resolvedSyntax.text) }
    private var secondaryTextColor: Color { Color(nsColor: resolvedSyntax.comments) }
    private var accentTint: Color { Color(nsColor: resolvedSyntax.keywords) }
    private var selectionColor: Color { Color(nsColor: resolvedSyntax.selection) }

    /// Composite identifier for detecting theme changes in the NSViewController bridge, and the cache key
    /// for `resolvedSyntax`. Must name every input to `ThemeDecorator.syntaxTheme`: base theme, code-viewer override, accent.
    private var themeIdentifier: String {
        "\(themeManager.currentTheme.id)|\(themeManager.codeViewerThemeOverride.rawValue)|\(themeManager.selectedAccentColor.rawValue)"
    }

    /// Shorthand for the current presentation mode (overlay / split / full).
    private var presentation: CodeViewerPresentation { chatHistoryViewModel.codeViewerPresentation }

    // MARK: - Body

    var body: some View {
        panelContent
            .padding(.trailing, 12)
        .padding(.vertical, 12)
        .padding(.leading, presentation == .full ? 12 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            containerWidth = newWidth
        }
        .transition(.move(edge: .trailing))
        // `initial: true` is required: the panel is created once a tab is already active, so a plain `onChange`
        // sees no transition. Keyed on the active snippet id, not the tab id: applying a change replaces a snippet in place.
        .onChange(of: selectedSnippet?.id, initial: true) { _, _ in
            loadSelectedSnippet()
        }
        .alert("Save Error", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? String(localized: "An unknown error occurred."))
        }
        .onAppear {
            reloadBackgroundTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .backgroundTaskChanged)) { _ in
            reloadBackgroundTasks()
        }
    }

    // MARK: - Snippet Loading

    /// The snippet in the active tab, or nil when there's no (valid) selection. A stale
    /// `activeCodeViewerTabID` that matches no tab simply reads as "no selection" (id lookup,
    /// so no subscript to trap on) and the panel falls back to the empty state.
    private var selectedSnippet: CodeSnippet? {
        chatHistoryViewModel.activeCodeViewerTab?.snippet
    }

    /// A binding onto one tab's editor view state (cursor, scroll, find panel).
    /// The store is a plain reference on the view model, so caret-move writes invalidate no body. With no tab, `.constant`
    /// gives the editor a well-formed state whose writes go nowhere.
    private func editorStateBinding(for tabID: UUID?) -> Binding<SourceEditorState> {
        guard let tabID else { return .constant(SourceEditorState()) }
        let store = chatHistoryViewModel.codeViewerEditorStates
        return Binding(
            get: { store.state(for: tabID) },
            set: { newState in
                store.setState(newState, for: tabID)
                statusBarState.update(from: newState)
            }
        )
    }

    /// Syncs `currentSnippet` / `document` to the view model's selection. Idempotent —
    /// safe to call on every selection change and on first appear.
    private func loadSelectedSnippet() {
        guard let snippet = selectedSnippet else {
            if currentSnippet != nil {
                logger.info("[CodeViewer] Cleared — no snippet selected.")
            }
            currentSnippet = nil
            document = nil
            statusBarState.reset()
            return
        }

        guard currentSnippet?.id != snippet.id else {
            logger.debug("[CodeViewer] Snippet already loaded — skipping document rebuild.")
            return
        }

        let total = chatHistoryViewModel.codeViewerTabs.count
        let position = chatHistoryViewModel.codeViewerTabs.firstIndex { $0.id == chatHistoryViewModel.activeCodeViewerTabID }.map { $0 + 1 } ?? 0
        // The buffer resumes from the tab's DRAFT when one exists — switching away and
        // back (or minimize/reopen) must not roll edits back to the chat block.
        let content = chatHistoryViewModel.activeCodeViewerTab?.effectiveCode ?? snippet.code
        let language = chatHistoryViewModel.activeCodeViewerTab?.effectiveLanguage ?? snippet.language
        let doc = CodeDocument(content: content, language: language)
        currentSnippet = snippet
        document = doc
        if let tabID = chatHistoryViewModel.activeCodeViewerTabID {
            statusBarState.update(from: chatHistoryViewModel.codeViewerEditorStates.state(for: tabID))
        } else {
            statusBarState.reset()
        }
        logger.info("[CodeViewer] Loaded tab \(position)/\(total) — lang=\(language ?? "nil") → resolved=\(doc.language.id.rawValue), \(content.count) chars\(content != snippet.code ? " (draft)" : "").")
    }

    /// Updates the syntax highlighting language for the currently loaded document and tab.
    private func handleLanguageSelected(_ newLanguage: CodeLanguage) {
        guard let doc = document else { return }
        guard doc.language.id != newLanguage.id else { return }
        doc.language = newLanguage
        if let activeID = chatHistoryViewModel.activeCodeViewerTabID {
            chatHistoryViewModel.updateCodeViewerTabLanguage(tabID: activeID, language: newLanguage.id.rawValue)
        }
    }

    // MARK: - Resizable Divider

    private var resizableDivider: some View {
        let isDragging = chatHistoryViewModel.codeViewerLiveDragWidth != nil
        let isHighlighted = isHoveringOnDivider || isDragging

        return GeometryReader { geo in
            let handleHeight = min(max(geo.size.height * 0.12, 60), 96)

            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 14, height: geo.size.height)
                    .contentShape(Rectangle())

                Capsule()
                    .fill(isHighlighted ? accentTint : selectionColor.opacity(0.45))
                    .frame(width: isHighlighted ? 2.5 : 1.5, height: handleHeight)
                    .shadow(color: isHighlighted ? accentTint.opacity(0.6) : .clear, radius: 3)
            }
            .frame(width: 14, height: geo.size.height)
        }
        .frame(width: 14)
        .frame(maxHeight: .infinity)
        .offset(x: -7)
        .gesture(
            // Global coordinate space is required: the divider is the panel's leading edge and moves with its own drag,
            // so `.local` translation includes that displacement and the edge oscillates. Global space tracks the cursor alone.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    // `translation.width` is cumulative from the gesture's start, so it is applied to the width captured once at
                    // that start, not to the live width, which compounds as the panel moves.
                    let start = dragStartWidth ?? displayedWidth
                    if dragStartWidth == nil { dragStartWidth = start }
                    let newWidth = CGFloat(start) - value.translation.width
                    // Rounded to whole points to avoid sub-pixel relayout of the editor's wrapped text; the upper clamp is the
                    // measured container width.
                    chatHistoryViewModel.codeViewerLiveDragWidth =
                        Double(min(max(newWidth, 400), maxPanelWidth)).rounded()
                }
                .onEnded { _ in
                    if let final = liveDragWidth {
                        panelWidth = final   // persist ONCE per drag, not per tick
                        logger.debug("[CodeViewer] Panel resized to \(Int(final))pt.")
                    }
                    // Clear AFTER committing: every reader falls back to the persisted
                    // width, which now holds the same number, so nothing snaps back.
                    chatHistoryViewModel.codeViewerLiveDragWidth = nil
                    dragStartWidth = nil
                    if !isHoveringOnDivider {
                        NSCursor.arrow.set()
                    }
                }
        )
        .onHover { hovering in
            isHoveringOnDivider = hovering
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else if chatHistoryViewModel.codeViewerLiveDragWidth == nil {
                NSCursor.arrow.set()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHighlighted)
    }

    // MARK: - Panel Content

    /// The tab a close request is pending on (dirty-close confirmation), if any.
    private var pendingCloseTab: CodeViewerTab? {
        chatHistoryViewModel.pendingCloseTabID.flatMap { id in
            chatHistoryViewModel.codeViewerTabs.first { $0.id == id }
        }
    }

    /// Whether the dirty-close alert can offer "Save & Close": true for any tab ⌘S can save, i.e. an attachment-linked tab
    /// (`sourceFileID`) or a path-linked one (`filePath`, incl. agent live-write and Save-As'd tabs).
    /// `nonisolated static` and pure so it is testable without a view.
    nonisolated static func canSaveAndClose(_ tab: CodeViewerTab) -> Bool {
        tab.snippet.sourceFileID != nil || tab.filePath != nil
    }

    /// "Save & Close" from the dirty-close alert: runs the guarded save, then closes only if it actually cleaned the tab;
    /// a failed save (drift, I/O) leaves the tab open with the error alert instead of discarding the draft.
    /// Routes to the same engine ⌘S picks (`saveActiveTab`): the attachment path for a source file, else the tab's own path.
    private func saveAndClosePendingTab(_ tabID: UUID) {
        guard let tab = chatHistoryViewModel.codeViewerTabs.first(where: { $0.id == tabID }) else { return }
        Task { @MainActor in
            if tab.snippet.sourceFileID != nil {
                await chatHistoryViewModel.performApplyChanges(for: tab.snippet)
            } else if tab.filePath != nil {
                await chatHistoryViewModel.saveTabToItsPath(tabID: tabID)
            } else {
                // Unreachable while the button is gated on `canSaveAndClose`; logged rather
                // than silently closing, because closing here would discard the draft.
                logger.error("[CodeViewer] Save & Close on tab \(tabID.uuidString.prefix(8)) has neither a source file nor a path — nothing was saved and the tab stays open with its draft.")
                chatHistoryViewModel.pendingCloseTabID = nil
                return
            }
            if chatHistoryViewModel.codeViewerTabs.first(where: { $0.id == tabID })?.isDirty == false {
                withAnimation { chatHistoryViewModel.forceCloseCodeViewerTab(id: tabID) }
            } else {
                chatHistoryViewModel.pendingCloseTabID = nil
            }
        }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            panelHeader
                // Dirty-close confirmation for a single tab. On the header so it doesn't
                // contend with the Save-error alert (body) or apply-error alert (below).
                .alert(String(localized: "Unsaved Changes"), isPresented: Binding(
                    get: { chatHistoryViewModel.pendingCloseTabID != nil },
                    set: { if !$0 { chatHistoryViewModel.pendingCloseTabID = nil } }
                )) {
                    if let pending = pendingCloseTab {
                        // Gate on `canSaveAndClose`, not `sourceFileID` alone: a path-linked tab can also be saved by ⌘S.
                        if Self.canSaveAndClose(pending) {
                            Button(String(localized: "Save & Close")) { saveAndClosePendingTab(pending.id) }
                        }
                        Button(String(localized: "Discard Changes"), role: .destructive) {
                            withAnimation { chatHistoryViewModel.forceCloseCodeViewerTab(id: pending.id) }
                        }
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {
                        chatHistoryViewModel.pendingCloseTabID = nil
                    }
                } message: {
                    Text(String(localized: "This tab has edits that haven't been saved."))
                }

            // Breadcrumbs Sub-Bar
            if let activeTab = chatHistoryViewModel.activeCodeViewerTab, document != nil {
                CodeViewerBreadcrumbsBar(
                    tab: activeTab,
                    textColor: textColor,
                    secondaryColor: secondaryTextColor,
                    accentColor: accentTint,
                    backgroundColor: headerBackground
                )
            }

            // Live-write banner: the ACTIVE tab's file is being written by the agent
            // right now (or its last write was rejected).
            if let liveState = chatHistoryViewModel.activeCodeViewerTab?.liveState {
                HStack(spacing: 7) {
                    if liveState == .active {
                        LivePulseDot(color: .orange)
                        Text(String(localized: "Agent is writing this file — the tab updates as writes land"))
                    } else {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 11, weight: .semibold))
                        Text(String(localized: "This write was not applied — the file on disk is unchanged"))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.1))
            }

            Rectangle()
                .fill(selectionColor.opacity(0.4))
                .frame(height: 1)
                // Close-all confirmation when any tab is dirty (the pill hosts the same
                // alert for the minimized state; the two are never mounted together).
                .alert(String(localized: "Discard All Changes?"), isPresented: Binding(
                    get: { chatHistoryViewModel.isPendingCloseAll },
                    set: { if !$0 { chatHistoryViewModel.isPendingCloseAll = false } }
                )) {
                    Button(String(localized: "Discard & Close All"), role: .destructive) {
                        chatHistoryViewModel.forceCloseAllCodeViewerTabs()
                    }
                    Button(String(localized: "Cancel"), role: .cancel) {
                        chatHistoryViewModel.isPendingCloseAll = false
                    }
                } message: {
                    Text(String(localized: "Some tabs have edits that haven't been saved."))
                }

            ZStack(alignment: .top) {
                // The panel shows content; a change is shown where it happened, in the tool output row.
                if let document = document {
                    let editedTabID = chatHistoryViewModel.activeCodeViewerTabID
                    // ONE derivation for both editor tokens: `resolvedSyntax` is memoized,
                    // but binding it here also keeps the two reads provably consistent.
                    let syntax = resolvedSyntax
                    HighPerformanceCodeViewRepresentable(
                        document: document,
                        language: document.language,
                        fontSize: fontSize,
                        editorTheme: syntax.editorTheme,
                        bracketHighlightColor: syntax.bracketHighlight,
                        themeIdentifier: themeIdentifier,
                        wrapLines: wrapLines,
                        showMinimap: showMinimap,
                        // Cursor/scroll live outside the editor, which is rebuilt on every snippet change (`.id(document.id)`) and torn down
                        // when minimized. Keyed by tab, so switching away and back resumes where the user left off.
                        editorState: editorStateBinding(for: editedTabID),
                        // Captures the tab id the document was built for, so a keystroke racing a tab switch lands in the owning tab.
                        onContentChange: { [editedTabID] newContent in
                            guard let editedTabID else { return }
                            chatHistoryViewModel.updateCodeViewerDraft(tabID: editedTabID, content: newContent)
                        }
                    )
                    .id(document.id)
                    .clipped()
                    .transition(.opacity)
                } else {
                    placeholderContent
                }
            }
            .frame(maxHeight: .infinity)

            if let document = document {
                CodeViewerStatusBar(
                    state: statusBarState,
                    document: document,
                    textColor: textColor,
                    secondaryColor: secondaryTextColor,
                    accentColor: accentTint,
                    backgroundColor: headerBackground,
                    onSelectLanguage: { newLanguage in
                        handleLanguageSelected(newLanguage)
                    }
                )
            }
        }
        // Overlay/split: fixed width clamped to the container so a width persisted on a bigger window cannot push the
        // divider off-screen. Full mode fills what the mount gives (`MainApplicationView` insets past the sidebar).
        .frame(width: presentation == .full ? nil : min(CGFloat(displayedWidth), maxPanelWidth))
        .frame(maxWidth: presentation == .full ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panelBackground)
                .shadow(
                    color: floatingShadowColor,
                    radius: surfaceStyle == .glassmorphic ? 20 : 16,
                    x: 0,
                    y: surfaceStyle == .glassmorphic ? 8 : 4
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(floatingBorderStroke, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if presentation != .full {
                resizableDivider
            }
        }
        .background(tabSwitchingShortcuts)
        // Surfaces an Apply-Changes failure (missing file, on-disk drift, I/O error); cleared on the next successful apply.
        // On a subview separate from the Save-error alert so the two alert modifiers do not contend on one view.
        .alert("Couldn't Apply Changes", isPresented: Binding(
            get: { chatHistoryViewModel.codeApplyError != nil },
            set: { if !$0 { chatHistoryViewModel.codeApplyError = nil } }
        )) {
            Button("OK", role: .cancel) { chatHistoryViewModel.codeApplyError = nil }
        } message: {
            Text(chatHistoryViewModel.codeApplyError ?? String(localized: "An unknown error occurred."))
        }
    }

    // MARK: - Panel Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            // Tab strip fills the available width; the action toolbar is pinned right.
            CodeViewerTabStrip(
                tabs: chatHistoryViewModel.codeViewerTabs,
                activeTabID: chatHistoryViewModel.activeCodeViewerTabID,
                textColor: textColor,
                secondaryColor: secondaryTextColor,
                accentColor: accentTint,
                activeBackground: panelBackground,
                hoverColor: selectionColor,
                onSelect: { id in chatHistoryViewModel.selectCodeViewerTab(id: id) },
                onClose: { id in withAnimation { chatHistoryViewModel.closeCodeViewerTab(id: id) } }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            actionButtons
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(
            headerBackground
                .overlay(
                    Rectangle()
                        .fill(secondaryTextColor.opacity(0.12))
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    // MARK: - Action Toolbar

    private var actionButtons: some View {
        HStack(spacing: 6) {
            // GROUP 1: Save CTA. Only visible when the active tab has unsaved changes.
            if let activeTab = chatHistoryViewModel.activeCodeViewerTab, activeTab.isDirty {
                Button(action: saveActiveTab) {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(String(localized: "Save"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        LinearGradient(
                            colors: [Color(nsColor: .systemGreen), Color(nsColor: .systemGreen).opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                    )
                    .shadow(color: Color(nsColor: .systemGreen).opacity(0.35), radius: 4, x: 0, y: 1.5)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Save changes (⌘S)"))
                .accessibilityLabel(String(localized: "Save active tab"))
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.88, anchor: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))

                Capsule()
                    .fill(secondaryTextColor.opacity(0.2))
                    .frame(width: 1, height: 14)
                    .transition(.opacity)
            }

            // GROUP 2: Code Tools (Copy & Find)
            HStack(spacing: 3) {
                CodeViewerHeaderButton(
                    action: {
                        copyCodeToClipboard()
                        didCopy = true
                        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); didCopy = false }
                    },
                    icon: didCopy ? "checkmark" : "doc.on.doc",
                    helpText: String(localized: "Copy code (right-click for more formats)"),
                    foregroundColor: didCopy ? Color(nsColor: .systemGreen) : secondaryTextColor,
                    hoverBackground: selectionColor
                )
                .animation(.easeInOut(duration: 0.2), value: didCopy)
                .disabled(document == nil)
                .contextMenu {
                    Button(String(localized: "Copy as Markdown")) { copyToClipboard(markdownFence()) }
                    if activeTabFileName != nil {
                        Button(String(localized: "Copy with Filename Comment")) {
                            copyToClipboard(codeWithFilenameComment())
                        }
                    }
                }

                // Find in file (⌘F)
                CodeViewerHeaderButton(
                    action: toggleFindPanel,
                    icon: "magnifyingglass",
                    helpText: String(localized: "Find in file (⌘F)"),
                    foregroundColor: secondaryTextColor,
                    hoverBackground: selectionColor
                )
                .disabled(document == nil)
            }

            Capsule()
                .fill(secondaryTextColor.opacity(0.2))
                .frame(width: 1, height: 14)

            // GROUP 3: View Options Menu
            Menu {
                Toggle(String(localized: "Word Wrap"), isOn: $wrapLines)
                Toggle(String(localized: "Minimap"), isOn: $showMinimap)
                Toggle(String(localized: "Follow Agent Edits"), isOn: $followAgent)

                Divider()

                Picker(String(localized: "Syntax Theme"), selection: Binding(
                    get: { themeManager.codeViewerThemeOverride },
                    set: { themeManager.applyCodeViewerTheme($0) }
                )) {
                    ForEach(CodeViewerThemeOverride.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Divider()

                Button(String(localized: "Increase Text Size")) { adjustFontSize(by: 1) }
                Button(String(localized: "Decrease Text Size")) { adjustFontSize(by: -1) }
                Button(String(localized: "Reset Text Size")) { fontSize = ChatUIConstants.codeViewerDefaultFontSize }

                Divider()

                Button(String(localized: "Save As…"), action: saveCodeToFile)
                    .disabled(document == nil)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(secondaryTextColor.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(selectionColor.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "View options"))
            .accessibilityLabel(String(localized: "View options"))

            Capsule()
                .fill(secondaryTextColor.opacity(0.2))
                .frame(width: 1, height: 14)

            // Switch to Background Tasks (when tasks exist)
            if backgroundTaskCount > 0 {
                Button {
                    chatHistoryViewModel.showBackgroundTasks()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: backgroundTaskRunningCount > 0 ? "play.circle" : "terminal")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(backgroundTaskCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                        if backgroundTaskRunningCount > 0 {
                            LivePulseDot(color: .orange)
                        }
                    }
                    .foregroundColor(accentTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(accentTint.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(backgroundTaskRunningCount > 0 ? String(localized: "Switch to Background tasks (\(backgroundTaskRunningCount) running)") : String(localized: "Switch to Background tasks"))

                Capsule()
                    .fill(secondaryTextColor.opacity(0.2))
                    .frame(width: 1, height: 14)
            }

            // Switch to Git Changes (Code mode, repository loaded). "Open in Code Viewer" from the
            // Changes panel closes it via slot exclusion — this is the way back.
            if let snapshot = gitChangesStore?.snapshot {
                let totals = snapshot.totals()
                Button {
                    chatHistoryViewModel.showGitChanges()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .semibold))
                        if !snapshot.files.isEmpty {
                            GitLineCountsLabel(added: totals.added, deleted: totals.deleted, fontSize: 10)
                        }
                    }
                    .foregroundColor(accentTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(accentTint.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Switch to Changes"))

                Capsule()
                    .fill(secondaryTextColor.opacity(0.2))
                    .frame(width: 1, height: 14)
            }

            // GROUP 4: Presentation & Window Controls
            HStack(spacing: 3) {
                // Side-by-side split with the chat
                CodeViewerHeaderButton(
                    action: chatHistoryViewModel.toggleCodeViewerSplit,
                    icon: "rectangle.split.2x1",
                    helpText: presentation == .split
                        ? String(localized: "Overlay the chat")
                        : String(localized: "Split view with chat"),
                    foregroundColor: presentation == .split ? accentTint : secondaryTextColor,
                    hoverBackground: selectionColor,
                    isActive: presentation == .split
                )

                // Full-width toggle
                CodeViewerHeaderButton(
                    action: chatHistoryViewModel.toggleCodeViewerExpansion,
                    icon: presentation == .full
                        ? "arrow.down.forward.and.arrow.up.backward"
                        : "arrow.up.backward.and.arrow.down.forward",
                    helpText: presentation == .full
                        ? String(localized: "Restore previous width")
                        : String(localized: "Expand to full width"),
                    foregroundColor: presentation == .full ? accentTint : secondaryTextColor,
                    hoverBackground: selectionColor,
                    isActive: presentation == .full
                )

                // Minimize
                CodeViewerHeaderButton(
                    action: chatHistoryViewModel.minimizeCodeViewer,
                    icon: "chevron.right",
                    helpText: String(localized: "Minimize (keep tabs open)"),
                    foregroundColor: secondaryTextColor,
                    hoverBackground: selectionColor
                )
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: chatHistoryViewModel.activeCodeViewerTab?.isDirty)
    }

    // MARK: - Keyboard Shortcuts

    /// Editor-parity shortcuts, live only while the panel is mounted (hidden zero-size buttons): ⌘⇧[ / ⌘⇧] previous/next
    /// tab, ⌘W close active tab, ⌘1–9 jump to tab N, ⌘+/⌘− font size, ⌘0 reset.
    /// ⌘W shadows the menu's "Close File Viewer Window" while mounted: key equivalents route through views before the menu.
    private var tabSwitchingShortcuts: some View {
        ZStack {
            Button("", action: chatHistoryViewModel.navigateToPreviousSnippet)
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("", action: chatHistoryViewModel.navigateToNextSnippet)
                .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("") {
                if let id = chatHistoryViewModel.activeCodeViewerTabID {
                    withAnimation { chatHistoryViewModel.closeCodeViewerTab(id: id) }
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            ForEach(1..<10, id: \.self) { ordinal in
                Button("") {
                    let tabs = chatHistoryViewModel.codeViewerTabs
                    guard tabs.indices.contains(ordinal - 1) else {
                        logger.debug("[CodeViewer] ⌘\(ordinal) ignored — only \(tabs.count) tab(s) open.")
                        return
                    }
                    chatHistoryViewModel.selectCodeViewerTab(id: tabs[ordinal - 1].id)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(ordinal)")), modifiers: .command)
            }

            Button("") { adjustFontSize(by: 1) }
                .keyboardShortcut("=", modifiers: .command)   // the +/= key, unshifted
            Button("") { adjustFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { fontSize = ChatUIConstants.codeViewerDefaultFontSize }
                .keyboardShortcut("0", modifiers: .command)

            Button("", action: saveActiveTab)
                .keyboardShortcut("s", modifiers: .command)

            Button("", action: toggleFindPanel)
                .keyboardShortcut("f", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func adjustFontSize(by delta: Double) {
        let range = ChatUIConstants.codeViewerFontSizeRange
        fontSize = min(max(fontSize + delta, range.lowerBound), range.upperBound)
    }

    // MARK: - Placeholder

    private var placeholderContent: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accentTint.opacity(0.12), accentTint.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: "curlybraces.square")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accentTint, accentTint.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 6) {
                Text(String(localized: "No Code Open"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textColor)

                Text(String(localized: "Select a code block from the chat or double-click any file in the Explorer to inspect and edit."))
                    .font(.system(size: 12))
                    .foregroundColor(secondaryTextColor.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .lineSpacing(2)
            }

            HStack(spacing: 10) {
                placeholderShortcutBadge(label: String(localized: "Close Tab"), keys: "⌘W")
                placeholderShortcutBadge(label: String(localized: "Switch Tab"), keys: "⌘1-9")
                placeholderShortcutBadge(label: String(localized: "Save"), keys: "⌘S")
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func placeholderShortcutBadge(label: String, keys: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(secondaryTextColor.opacity(0.75))
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(textColor.opacity(0.9))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(selectionColor.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(secondaryTextColor.opacity(0.2), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Actions

    /// The text the user is actually looking at: `CodeViewerTab.snippet` is immutable, so once the editor writes through
    /// to `editedCode` the snippet's `.code` is stale. Copy actions use this; `saveCodeToFile` does the same.
    private var codeOnScreen: String? {
        guard let snippet = currentSnippet else { return nil }
        return chatHistoryViewModel.activeCodeViewerTab?.effectiveCode ?? snippet.code
    }

    private func copyCodeToClipboard() {
        guard let code = codeOnScreen else { return }
        copyToClipboard(code)
    }

    private func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func toggleFindPanel() {
        let menuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menuItem.tag = 1 // NSFindPanelActionShowFindPanel (Show Find Panel)
        NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: menuItem)
    }

    /// The active tab's linked/inferred filename, when it has one.
    private var activeTabFileName: String? {
        chatHistoryViewModel.activeCodeViewerTab?.fileName
    }

    /// The snippet as a fenced markdown block, with the language and (when known) the
    /// filename in the info string — `\`\`\`java DijkstraSolver.java`. That is the same
    /// shape `CodeFileNameInference` parses, so a paste round-trips with its name intact.
    private func markdownFence() -> String {
        guard let snippet = currentSnippet else { return "" }
        let info = [snippet.language, activeTabFileName].compactMap { $0 }.joined(separator: " ")
        return "```\(info)\n\(codeOnScreen ?? snippet.code)\n```"
    }

    /// The snippet prefixed with a language-appropriate comment line naming the file.
    private func codeWithFilenameComment() -> String {
        guard let snippet = currentSnippet, let fileName = activeTabFileName else {
            return codeOnScreen ?? ""
        }
        let comment: String
        switch snippet.language?.lowercased() {
        case "python", "ruby", "shell", "bash", "zsh", "sh", "fish", "yaml", "yml", "toml", "makefile", "r":
            comment = "# \(fileName)"
        case "html", "xml", "svg", "xhtml", "markdown", "md", "mdx", "vue":
            comment = "<!-- \(fileName) -->"
        case "sql", "lua", "haskell":
            comment = "-- \(fileName)"
        default:
            comment = "// \(fileName)"
        }
        return "\(comment)\n\(codeOnScreen ?? snippet.code)"
    }


    /// ⌘S / header Save: linked tabs write to their source file through the guarded save
    /// engine (draft-aware, drift-checked, atomic); unlinked tabs fall to Save As.
    private func saveActiveTab() {
        guard let snippet = currentSnippet else {
            logger.warning("[CodeViewer] Save (⌘S) ignored — no active snippet loaded in the panel.")
            return
        }
        if snippet.sourceFileID != nil {
            // Attachment-linked: resolve the source file through the message store.
            chatHistoryViewModel.applyChanges(for: snippet)
        } else if let tab = chatHistoryViewModel.activeCodeViewerTab, tab.filePath != nil {
            // Path-linked (Save-As'd, or opened from an agent write): write straight there.
            // Before this, a Save-As'd tab re-opened the panel on every subsequent ⌘S.
            let tabID = tab.id
            Task { await chatHistoryViewModel.saveTabToItsPath(tabID: tabID) }
        } else {
            saveCodeToFile()
        }
    }

    // Why: an unconditional `String(contentsOf:)` of a user-picked file can allocate a multi-GB log in full (a jetsam risk
    // on any thread); one threshold keeps both read paths agreeing on which files the viewer holds in memory
    /// Whether Save As should pre-read an existing destination before writing over it.
    /// The pre-read only copies the destination's leading whitespace and trailing newline, so it is skipped over the size cap
    /// shared with the live-tab pre-read (`handleAgentWriteBegan`). `nonisolated static` and pure so it is testable.
    nonisolated static func shouldPreReadSaveAsDestination(byteSize: Int) -> Bool {
        byteSize <= AgentLiveWriteEvent.liveContentByteLimit
    }

    private func saveCodeToFile() {
        guard let snippet = currentSnippet else { return }
        // Captured BEFORE the async panel: what the user sees now is what gets written,
        // and the completion must credit the tab that initiated the save.
        let buffer = chatHistoryViewModel.activeCodeViewerTab?.effectiveCode ?? snippet.code
        let tabID = chatHistoryViewModel.activeCodeViewerTabID
        let isLinked = snippet.sourceFileID != nil

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false

        let language = CodeLanguage.allLanguages.first {
            $0.id.rawValue.lowercased() == snippet.language?.lowercased()
        } ?? .default

        savePanel.nameFieldStringValue = activeTabFileName ?? "snippet.\(language.extensions.first ?? "txt")"
        savePanel.title = String(localized: "Save Code Snippet")

        if let utType = UTType(tag: language.extensions.first ?? "", tagClass: .filenameExtension, conformingTo: .text) {
            savePanel.allowedContentTypes = [utType]
        } else {
            savePanel.allowedContentTypes = [.text]
        }

        savePanel.begin { (result) in
            guard result == .OK, let rawURL = savePanel.url else { return }
            // Same symlink rule as the other save engines: writing to a symlink path replaces the link with a regular file
            // and leaves the target stale. Cheap (one stat), so kept inline.
            let url = ChatHistoryViewModel.writeTarget(forPath: rawURL.path)
            // One more cheap stat, inline because it decides whether the expensive read below runs at all;
            // absent attributes (a new destination) read as 0.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let destinationBytes = (attributes?[.size] as? Int) ?? 0
            let preReadDestination = Self.shouldPreReadSaveAsDestination(byteSize: destinationBytes)
            if !preReadDestination {
                logger.info("[CodeViewer] Save As: skipping the pre-read of '\(url.lastPathComponent)' — \(destinationBytes) bytes, over the \(AgentLiveWriteEvent.liveContentByteLimit)-byte cap. CONSEQUENCE: that file's leading whitespace and trailing newline are NOT carried over; the editor buffer is written verbatim over it.")
            }
            // The read and the write run off the main actor, and the read is size-capped like the live-tab pre-read.
            // `savePanel.begin`'s completion is `@MainActor`, so this `Task` inherits it and only the two awaited legs leave it.
            Task { @MainActor in
                do {
                    // Baseline for `contentToApply`: the destination's on-disk bytes, so the trimmed buffer does not delete its leading
                    // whitespace and trailing newline. A new file, or one over the cap, has no baseline and the helper is a no-op.
                    var onDisk: String? = nil
                    if preReadDestination {
                        onDisk = await Task.detached(priority: .utility) {
                            try? String(contentsOf: url, encoding: .utf8)
                        }.value
                    }
                    let content = ChatHistoryViewModel.contentToApply(
                        snippetCode: buffer,
                        preservingEdgeWhitespaceOf: onDisk ?? buffer
                    )
                    // No baseline: Save As is an explicit destination choice, so there is nothing to drift-check, unlike the engines
                    // that write back to a tracked path. `atomicallyWrite` verifies the write by reading the temp file back first.
                    try await ChatHistoryViewModel.atomicallyWrite(
                        content, to: url, fileName: url.lastPathComponent
                    )
                    // Save As satisfies an unlinked tab's dirty state (it has no source file); for a linked tab it is just an
                    // exported copy and the tab stays dirty.
                    if !isLinked, let tabID {
                        // `wroteToDisk` is the drift baseline and must be the BYTES, which
                        // differ from the editor buffer whenever edge whitespace was restored.
                        chatHistoryViewModel.markCodeViewerTabSavedAs(
                            tabID: tabID, savedBuffer: buffer, savedTo: url, wroteToDisk: content
                        )
                    }
                } catch {
                    saveErrorMessage = String(localized: "Failed to save file: \(error.localizedDescription)")
                }
            }
        }
    }

}

// MARK: - SF Symbol for a language

/// The SF Symbol representing a code language, shared by the tab strip. A free function, not tied to a view.
func codeViewerLanguageIcon(for languageID: String?) -> String {
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

// MARK: - Tab Strip

/// The horizontal, scrollable strip of open Code Viewer tabs: each open block is its own tab with a close control,
/// and the active tab is highlighted (filled with the editor background) and auto-scrolled into view.
fileprivate struct CodeViewerTabStrip: View {
    let tabs: [CodeViewerTab]
    let activeTabID: UUID?
    let textColor: Color
    let secondaryColor: Color
    let accentColor: Color
    let activeBackground: Color
    let hoverColor: Color
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void

    private var filenameCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for tab in tabs {
            let key = tab.title.lowercased()
            counts[key, default: 0] += 1
        }
        return counts
    }

    private func disambiguationHint(for tab: CodeViewerTab) -> String? {
        let key = tab.title.lowercased()
        guard (filenameCounts[key] ?? 0) > 1, let path = tab.filePath else { return nil }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let grandParent = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty, parent != "/" else { return nil }

        let sameParentCount = tabs.filter {
            $0.title.lowercased() == key &&
            $0.filePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } == parent
        }.count

        if sameParentCount > 1, !grandParent.isEmpty, grandParent != "/" {
            return "\(grandParent)/\(parent)"
        }
        return parent
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        CodeViewerTabChip(
                            tab: tab,
                            isActive: tab.id == activeTabID,
                            isLastTab: index == tabs.count - 1,
                            disambiguationHint: disambiguationHint(for: tab),
                            textColor: textColor,
                            secondaryColor: secondaryColor,
                            accentColor: accentColor,
                            activeBackground: activeBackground,
                            hoverColor: hoverColor,
                            onSelect: { onSelect(tab.id) },
                            onClose: { onClose(tab.id) }
                        )
                        .id(tab.id)
                    }
                }
                .padding(.vertical, 4)
                .padding(.leading, 2)
                .padding(.trailing, 8)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.95),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .onChange(of: activeTabID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

// MARK: - Live Pulse Indicator (Syntax Nexus)

/// The "agent is writing code" indicator: uses the Syntax Nexus indicator.
/// Shared by the tab chip and the floating pill (internal, not fileprivate, for that reason).
struct LivePulseDot: View {
    let color: Color

    var body: some View {
        DevgenticActivityIndicator(style: .syntaxNexus, size: 12, tint: color)
            .accessibilityLabel(String(localized: "Agent is writing code"))
    }
}

// MARK: - Relative Path Formatter Helper
func formatRelativePath(for path: String) -> String {
    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(homePath) {
        var rel = path
        rel.removeFirst(homePath.count)
        if rel.hasPrefix("/") { rel.removeFirst() }
        return "~/" + rel
    }
    return URL(fileURLWithPath: path).lastPathComponent
}

// MARK: - Tab Chip

fileprivate struct CodeViewerTabChip: View {
    let tab: CodeViewerTab
    let isActive: Bool
    let isLastTab: Bool
    let disambiguationHint: String?
    let textColor: Color
    let secondaryColor: Color
    let accentColor: Color
    let activeBackground: Color
    let hoverColor: Color
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @State private var isHovering = false
    @State private var isHoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: codeViewerLanguageIcon(for: tab.snippet.language))
                .font(.system(size: 10, weight: .medium)) // Fixed size: tab affordance
                .foregroundColor(isActive ? accentColor : secondaryColor)

            HStack(spacing: 4) {
                Text(tab.title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular)) // Fixed size: tab label
                    .foregroundColor(isActive ? textColor : secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let disambiguationHint {
                    Text("· \(disambiguationHint)")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(secondaryColor.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // Trailing slot: hover always offers the ✕; a live tab pulses (agent writing) or warns (write rejected); a dirty tab
            // shows its unsaved dot, even while active; a clean active tab keeps the ✕; a clean inactive tab reserves the space.
            if !isHovering, tab.liveState == .active {
                LivePulseDot(color: .orange)
                    .frame(width: 18, height: 18)
            } else if !isHovering, tab.liveState == .rejected {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10, weight: .semibold)) // Fixed size: status glyph
                    .foregroundColor(.orange)
                    .frame(width: 18, height: 18)
                    .help(String(localized: "The agent's write was not applied"))
                    .accessibilityLabel(String(localized: "Write not applied"))
            } else if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold)) // Fixed size: close glyph
                        .foregroundColor(isHoveringClose ? textColor : secondaryColor)
                        .frame(width: 18, height: 18)
                        .background(isHoveringClose ? hoverColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringClose = $0 }
                .help(String(localized: "Close tab"))
                .accessibilityLabel(String(localized: "Close tab"))
            } else if tab.isDirty {
                Circle()
                    .fill(accentColor)
                    .frame(width: 7, height: 7)
                    .frame(width: 18, height: 18)
                    .help(String(localized: "Unsaved changes"))
                    .accessibilityLabel(String(localized: "Unsaved changes"))
            } else if isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold)) // Fixed size: close glyph
                        .foregroundColor(isHoveringClose ? textColor : secondaryColor)
                        .frame(width: 18, height: 18)
                        .background(isHoveringClose ? hoverColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isHoveringClose = $0 }
                .help(String(localized: "Close tab"))
                .accessibilityLabel(String(localized: "Close tab"))
            } else {
                Color.clear.frame(width: 18, height: 18)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .frame(maxWidth: disambiguationHint != nil ? 240 : 200)
        .background(isActive ? activeBackground : (isHovering ? hoverColor.opacity(0.45) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isActive ? accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(disambiguationHint != nil ? "\(tab.title) (\(disambiguationHint!))" : tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .contextMenu {
            Button(String(localized: "Close Tab")) {
                onClose()
            }

            Button(String(localized: "Close Other Tabs")) {
                chatHistoryViewModel.closeOtherCodeViewerTabs(exceptID: tab.id)
            }
            .disabled(chatHistoryViewModel.codeViewerTabs.count <= 1)

            Button(String(localized: "Close Tabs to the Right")) {
                chatHistoryViewModel.closeTabsToTheRight(ofID: tab.id)
            }
            .disabled(isLastTab)

            Button(String(localized: "Close All Tabs")) {
                chatHistoryViewModel.closeAllCodeViewerTabs()
            }

            if let path = tab.filePath {
                Divider()

                Button(String(localized: "Copy File Path")) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(path, forType: .string)
                }

                Button(String(localized: "Copy Relative Path")) {
                    let rel = formatRelativePath(for: path)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(rel, forType: .string)
                }

                Button(String(localized: "Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }

                Button(String(localized: "Open with System App")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
    }
}

// MARK: - Header Button

fileprivate struct CodeViewerHeaderButton: View {
    let action: () -> Void
    let icon: String
    let helpText: String
    let foregroundColor: Color
    let hoverBackground: Color
    var isActive: Bool = false
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isEnabled ? (isActive ? foregroundColor : (isHovering ? foregroundColor : foregroundColor.opacity(0.75))) : foregroundColor.opacity(0.2))
                .frame(width: 28, height: 28)
                .background(
                    isActive
                        ? foregroundColor.opacity(0.18)
                        : (isHovering && isEnabled ? hoverBackground.opacity(0.6) : Color.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isActive
                                ? foregroundColor.opacity(0.4)
                                : (isHovering && isEnabled ? foregroundColor.opacity(0.25) : Color.clear),
                            lineWidth: isActive ? 0.8 : 0.5
                        )
                )
                .scaleEffect(isHovering && isEnabled ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                self.isHovering = hovering
            }
        }
    }
}

extension CodeDocument: Identifiable {}


// MARK: - High-Performance NSViewControllerRepresentable
private struct HighPerformanceCodeViewRepresentable: NSViewControllerRepresentable {
    var document: CodeDocument
    var language: CodeLanguage
    var fontSize: Double
    var editorTheme: CodeEditSourceEditor.EditorTheme
    var bracketHighlightColor: NSColor
    var themeIdentifier: String
    var wrapLines: Bool
    var showMinimap: Bool
    /// Per-tab cursor/scroll/find state. Passed through rather than owned: this
    /// representable is destroyed on every document change, and the state must not be.
    var editorState: Binding<SourceEditorState>
    var onContentChange: (String) -> Void

    func makeNSViewController(context: Context) -> HighPerformanceCodeViewController {
        let controller = HighPerformanceCodeViewController(
            document: document,
            language: language,
            editorTheme: editorTheme,
            bracketHighlightColor: bracketHighlightColor,
            themeIdentifier: themeIdentifier,
            wrapLines: wrapLines,
            showMinimap: showMinimap,
            editorState: editorState
        )
        controller.onContentChange = onContentChange
        return controller
    }

    func updateNSViewController(_ nsViewController: HighPerformanceCodeViewController, context: Context) {
        nsViewController.onContentChange = onContentChange
        nsViewController.editorState = editorState
        nsViewController.update(
            document: document,
            language: language,
            fontSize: fontSize,
            editorTheme: editorTheme,
            bracketHighlightColor: bracketHighlightColor,
            themeIdentifier: themeIdentifier,
            wrapLines: wrapLines,
            showMinimap: showMinimap
        )
    }
}

// MARK: - High-Performance NSViewController
class HighPerformanceCodeViewController: NSViewController {

    private var document: CodeDocument
    private var currentLanguage: CodeLanguage
    private var hostingController: NSHostingController<SourceEditor>?
    private var currentFontSize: Double = 14
    private var currentEditorTheme: CodeEditSourceEditor.EditorTheme
    private var currentBracketColor: NSColor
    private var currentThemeIdentifier: String
    private var currentWrapLines: Bool
    private var currentShowMinimap: Bool
    /// Per-keystroke edit sink (→ the view model's draft state). Assigned by the
    /// representable on make AND update so it always captures the live environment.
    var onContentChange: ((String) -> Void)?

    /// The active tab's cursor/scroll/find state, owned by the view model's store, so it survives tab switches,
    /// live-write refreshes and minimize/reopen.
    var editorState: Binding<SourceEditorState>

    init(document: CodeDocument, language: CodeLanguage, editorTheme: CodeEditSourceEditor.EditorTheme, bracketHighlightColor: NSColor, themeIdentifier: String, wrapLines: Bool, showMinimap: Bool, editorState: Binding<SourceEditorState>) {
        self.document = document
        self.currentLanguage = language
        self.editorState = editorState
        self.currentEditorTheme = editorTheme
        self.currentBracketColor = bracketHighlightColor
        self.currentThemeIdentifier = themeIdentifier
        self.currentWrapLines = wrapLines
        self.currentShowMinimap = showMinimap
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
                wrapLines: currentWrapLines,
                tabWidth: 4,
                bracketPairEmphasis: .bordered(color: currentBracketColor)
            ),
            behavior: .init(
                isEditable: true,
                isSelectable: true,
                indentOption: .spaces(count: 4)
            ),
            layout: .init(
                editorOverscroll: 0.3,
                contentInsets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
            ),
            peripherals: .init(
                showGutter: true,
                showMinimap: currentShowMinimap,
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

    // Why: `[weak self]` is required: the binding lives in the `SourceEditor`, the `hostingController`'s `rootView`, which this
    // controller owns; a strong capture is a cycle that leaks the whole CodeEdit stack on every panel open/close
    /// Two-way binding to the document's text.
    /// Built in one place so `setupEditorView` and `updatePresentationView` share the weak capture.
    private func makeContentBinding() -> Binding<String> {
        Binding<String>(
            get: { [weak self] in self?.document.content ?? "" },
            set: { [weak self] newString in
                guard let self else { return }
                if self.document.content != newString {
                    self.document.content = newString
                    // Write-through to the tab so the draft survives tab switches and minimize: the panel rebuilds documents from the tab.
                    self.onContentChange?(newString)
                }
            }
        )
    }

    private func setupEditorView() {
        let contentBinding = makeContentBinding()

        let font = NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)
        let editorView = SourceEditor(
            contentBinding,
            language: currentLanguage,
            configuration: makeConfiguration(font: font),
            state: editorState
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

        let contentBinding = makeContentBinding()

        let newEditorView = SourceEditor(
            contentBinding,
            language: self.currentLanguage,
            configuration: makeConfiguration(font: font),
            state: editorState
        )
        hostingController?.rootView = newEditorView
    }

    func update(document: CodeDocument, language: CodeLanguage, fontSize: Double, editorTheme: CodeEditSourceEditor.EditorTheme, bracketHighlightColor: NSColor, themeIdentifier: String, wrapLines: Bool, showMinimap: Bool) {
        var needsViewUpdate = false

        if self.document != document {
            self.document = document
            needsViewUpdate = true
        }

        if self.currentLanguage.id != language.id {
            self.currentLanguage = language
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

        if self.currentWrapLines != wrapLines {
            self.currentWrapLines = wrapLines
            needsViewUpdate = true
        }

        if self.currentShowMinimap != showMinimap {
            self.currentShowMinimap = showMinimap
            needsViewUpdate = true
        }

        if needsViewUpdate {
            updatePresentationView()
        }
    }
}

// MARK: - CodeViewerStatusBar

struct CodeViewerStatusBar: View {
    var state: CodeViewerStatusBarState
    var document: CodeDocument
    var textColor: Color
    var secondaryColor: Color
    var accentColor: Color
    var backgroundColor: Color
    var onSelectLanguage: (CodeLanguage) -> Void

    @State private var isHoveringLanguage = false

    private var lineCount: Int {
        let content = document.content
        guard !content.isEmpty else { return 1 }
        var count = 1
        for byte in content.utf8 {
            if byte == 0x0A { count += 1 }
        }
        return count
    }

    private var lineEndings: String {
        document.content.contains("\r\n") ? "CRLF" : "LF"
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left cluster: Cursor position, Line count, Indentation
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    Text("Ln \(state.line), Col \(state.column)")
                        .monospacedDigit()
                    if state.selectionLength > 0 {
                        Text(" (\(state.selectionLength) sel)")
                            .monospacedDigit()
                            .foregroundColor(accentColor)
                    }
                }

                Text("·")
                    .foregroundColor(secondaryColor.opacity(0.4))

                Text("\(lineCount) \(lineCount == 1 ? "line" : "lines")")
                    .monospacedDigit()

                Text("·")
                    .foregroundColor(secondaryColor.opacity(0.4))

                Text("Spaces: 4")
            }

            Spacer(minLength: 8)

            // Right cluster: Encoding, Line endings, Language selector
            HStack(spacing: 6) {
                Text("UTF-8")

                Text("·")
                    .foregroundColor(secondaryColor.opacity(0.4))

                Text(lineEndings)

                Text("·")
                    .foregroundColor(secondaryColor.opacity(0.4))

                Menu {
                    Section(String(localized: "Common Languages")) {
                        ForEach(CodeLanguage.commonLanguages, id: \.id) { lang in
                            Button {
                                onSelectLanguage(lang)
                            } label: {
                                HStack {
                                    Text(lang.displayName)
                                    if lang.id == document.language.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Section(String(localized: "All Languages")) {
                        ForEach(CodeLanguage.allSortedLanguages, id: \.id) { lang in
                            Button {
                                onSelectLanguage(lang)
                            } label: {
                                HStack {
                                    Text(lang.displayName)
                                    if lang.id == document.language.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "curlybraces")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(isHoveringLanguage ? accentColor : secondaryColor)
                        Text(document.language.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(isHoveringLanguage ? textColor : secondaryColor)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(secondaryColor.opacity(0.7))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isHoveringLanguage ? secondaryColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .onHover { hovering in
                    isHoveringLanguage = hovering
                }
                .help(String(localized: "Select Language Mode"))
            }
        }
        .font(.system(size: 11, weight: .regular))
        .foregroundColor(secondaryColor)
        .frame(height: 22)
        .padding(.horizontal, 10)
        .background(backgroundColor)
        .overlay(
            Rectangle()
                .fill(secondaryColor.opacity(0.12))
                .frame(height: 0.5),
            alignment: .top
        )
    }
}
