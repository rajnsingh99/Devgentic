// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeViewerPanelView.swift
//  Devgentic
//
//  Created by Raj Singh
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

    /// Plain String. This was a `GapBuffer` — a real gap-buffer implementation whose
    /// editing mechanics (`moveGap`/`insert`/`delete`) had ZERO callers: every live use
    /// constructed it whole from a String and read `.string` back, so it was a String
    /// with extra steps (and an untested one — the never-run `moveGap` else-branch
    /// computed its new gap end from an already-mutated `gapStart`). CodeEditSourceEditor
    /// owns actual text editing; this document just carries content in and out.
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

/// Caches the resolved Code Viewer `SyntaxTheme` for as long as the tokens it derives from
/// are unchanged.
///
/// `themeManager.resolvedCodeViewerSyntaxTheme` is a chain of COMPUTED properties —
/// `ThemeDecorator.syntaxTheme` → `effectiveCodeTheme.syntaxTheme.patched(...)` — and every
/// theme spells its palette as hex literals, so each derivation runs `NSColor(hex:)`
/// (a `Scanner`) fifteen times and then rebuilds the `EditorTheme` on top. The panel reads
/// it through a dozen accessors (`panelBackground`, `textColor`, `resolvedSyntax.editorTheme`,
/// the per-chip colours, …), so ONE body pass re-derived the palette dozens of times — and
/// every keystroke causes a pass, because the draft write-through mutates the observed
/// `codeViewerTabs` array.
///
/// A reference type so a `View` struct's (non-mutating) computed property can fill it, and
/// deliberately NOT observable: warming a cache must not invalidate anything.
private final class SyntaxThemeCache {
    var key: String?
    var theme: SyntaxTheme?
}

// MARK: - CodeViewerPanelView (Main SwiftUI View)
struct CodeViewerPanelView: View {
    @Environment(ChatHistoryViewModel.self) var chatHistoryViewModel
    @Environment(ThemeManager.self) var themeManager
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

    /// Width while a divider drag is in flight. Written per tick INSTEAD of the
    /// @AppStorage-backed `panelWidth`: a UserDefaults write per mouse move both spams the
    /// preferences daemon and schedules an extra invalidation on top of each layout pass.
    /// The final width is committed to `panelWidth` once, on drag end.
    ///
    /// Held on the VIEW MODEL, not in `@State`, because the panel is not the only view that
    /// has to follow the divider: in `.split` mode `MainApplicationView` insets the chat by
    /// the panel's width, and reading only the persisted value left the chat a full drag
    /// behind (panel over chat during the drag, chat jumping on release).
    private var liveDragWidth: Double? { chatHistoryViewModel.codeViewerLiveDragWidth }

    /// The width the panel renders at: the in-flight drag value when dragging, else the
    /// persisted preference.
    private var displayedWidth: Double { liveDragWidth ?? panelWidth }

    /// The width of the container the panel is mounted in (the app window's content
    /// area), measured via `onGeometryChange`. Caps both the drag and the rendered
    /// width — a persisted width wider than the current window would otherwise push the
    /// divider off-screen and leave the panel unresizable. `.infinity` until the first
    /// geometry pass so `min(displayedWidth, containerWidth)` is a no-op at startup.
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

    /// The Code Viewer's syntax palette, derived at most ONCE per (theme, code-theme
    /// override, accent) rather than once per accessor — see `SyntaxThemeCache`.
    ///
    /// `themeIdentifier` is read first and unconditionally: that read is what registers the
    /// `@Observable` dependency on the theme manager, so a theme change still invalidates
    /// this body. The cache skips the DERIVATION, never the observation.
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

    /// Composite identifier for detecting theme changes in the NSViewController bridge, and
    /// the cache key for `resolvedSyntax`.
    ///
    /// It must name EVERY input to `ThemeDecorator.syntaxTheme`, which is
    /// `effectiveCodeTheme.syntaxTheme.patched(with: accentColorOverride.nsColor)` — base
    /// theme, code-viewer override AND accent. The accent was missing, so changing the
    /// accent left the editor rendering its previous palette until something else forced a
    /// rebuild; it also has to be here now that a cache keys off this string.
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
        // `initial: true` is REQUIRED, not cosmetic. This panel is only created once a tab
        // is ALREADY active, so a plain `onChange` has no transition to observe on first
        // appear — `document` stayed nil and the panel rendered "No Code Selected" until the
        // user switched tabs. This is the sole assignment to `document` (no onAppear/.task).
        //
        // Keyed on the ACTIVE SNIPPET'S id rather than the active tab id: applying a change
        // replaces a tab's snippet in place (same tab id, new snippet id), and that must
        // reload the document to show the applied content — a tab-id-keyed observer misses it.
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

    /// A binding onto ONE tab's editor view state (cursor, scroll, find panel).
    ///
    /// The store is a plain reference held by the view model, so writes from the editor's
    /// coordinator — one per caret move — reach no `@Observable` property and invalidate no
    /// body. With no tab there is nothing to remember, and `.constant` gives the editor a
    /// well-formed state whose writes go nowhere, which is the correct behaviour for a
    /// panel showing the empty state.
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
            // GLOBAL coordinate space is load-bearing. The divider is the panel's
            // leading edge, so it MOVES as a result of its own drag — and in `.local`
            // space `translation.width` then includes the divider's own (one-frame-
            // stale) displacement on top of the cursor's. Subtracting that contaminated
            // translation from the start width overshoots, the next frame compensates
            // back, and the edge oscillates violently under the cursor. Global space
            // measures the CURSOR alone, which is the only thing a resize should track.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    // `translation.width` is cumulative from the gesture's START, so it
                    // must be applied to the width AT THAT START — not to the live
                    // width, which we're already moving. Subtracting the cumulative
                    // translation from an already-moved width compounds quadratically and
                    // the panel races to the clamp on a small drag. Capture the start once.
                    let start = dragStartWidth ?? displayedWidth
                    if dragStartWidth == nil { dragStartWidth = start }
                    let newWidth = CGFloat(start) - value.translation.width
                    // Rounded to whole points: fractional widths force the editor's
                    // wrapped-text layout to re-solve on sub-pixel deltas for no
                    // visible gain. Upper clamp is the measured container — the user
                    // can drag the panel to the full window width, not an arbitrary
                    // 1200pt cap.
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

    /// Whether the dirty-close alert can offer "Save & Close" for this tab: it can save
    /// anything ⌘S can save, which is an ATTACHMENT-linked tab (`sourceFileID`) or a
    /// PATH-linked one (`filePath` — every agent live-write tab and every Save-As'd tab).
    ///
    /// Only the first was offered, so the tabs the viewer opens most often — agent writes —
    /// were given Discard or Cancel and nothing else, although ⌘S saves them fine.
    /// `nonisolated static` and pure so the decision is testable without a view.
    nonisolated static func canSaveAndClose(_ tab: CodeViewerTab) -> Bool {
        tab.snippet.sourceFileID != nil || tab.filePath != nil
    }

    /// "Save & Close" from the dirty-close alert: run the guarded save, then close ONLY
    /// if it actually cleaned the tab — a failed save (drift, I/O) leaves the tab open
    /// with the error alert instead of discarding the draft behind the failure.
    ///
    /// Routes to the SAME engine ⌘S would pick (`saveActiveTab`): the attachment path when
    /// there's a source file, else the tab's own path. `performApplyChanges` returns early
    /// without a source link, so sending a path-linked tab there closed nothing and just
    /// logged — which is why the button was hidden for them rather than fixed.
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
                        // [CF-11] Gate on `canSaveAndClose`, not on `sourceFileID` alone — a
                        // PATH-linked tab (every agent live-write, every Save-As'd tab) can be
                        // saved by ⌘S, so offering it only Discard/Cancel here threw away edits
                        // the viewer could perfectly well have written.
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
                // The panel shows CONTENT. A change is shown where it happened — in the
                // tool output row — so this no longer branches on a diff mode.
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
                        // Cursor/scroll live OUTSIDE the editor because the editor is
                        // rebuilt on every snippet change (`.id(document.id)` below) and
                        // torn down entirely when the panel is minimized. Keyed by TAB, so
                        // a switch away and back resumes where the user left off.
                        editorState: editorStateBinding(for: editedTabID),
                        // Captures the tab id the document was built FOR: a keystroke
                        // racing a tab switch must land in the tab that owns this editor,
                        // not whatever is active by the time the callback runs.
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
        // Overlay/split modes: fixed width, clamped to the container so a width persisted
        // on a bigger window can't push the divider off-screen. Full mode: fill everything
        // the mount gives us (MainApplicationView insets us past the sidebar).
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
        // Surfaces an Apply-Changes failure (missing file, on-disk drift, I/O error).
        // On a subview separate from the Save-error alert on `body` so the two alert
        // modifiers don't contend on the same view. Cleared by the VM on the next
        // successful apply.
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

    /// Editor-parity shortcuts, live only while the panel is mounted (hidden zero-size
    /// buttons): ⌘⇧[ / ⌘⇧] previous/next tab, ⌘W close active tab, ⌘1–9 jump to tab N,
    /// ⌘+/⌘− font size, ⌘0 reset.
    ///
    /// ⌘W deliberately shadows the app menu's "Close File Viewer Window": key equivalents
    /// route through the view hierarchy BEFORE the menu bar, so while the panel is open
    /// ⌘W closes a tab; once the last tab closes the panel unmounts and ⌘W falls back to
    /// the menu — the editor convention, scoped exactly to when it makes sense.
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

    /// The text the user is actually looking at.
    ///
    /// `CodeViewerTab.snippet` is IMMUTABLE for the life of the tab, so once the editor has
    /// written through to `editedCode` its `.code` is stale. Every copy action used it, so
    /// after any edit the clipboard silently held the pre-edit version. Mirrors what
    /// `saveCodeToFile` already does.
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

    /// Whether Save As should pre-read an existing destination before writing over it.
    ///
    /// [CF-17] That pre-read exists only so `contentToApply` can copy the destination's
    /// leading whitespace run and its trailing newline. The destination is whatever file the
    /// user picked in the save panel, so an unconditional `String(contentsOf:)` allocates a
    /// multi-GB log or DB dump in full for two edge characters — a jetsam risk on ANY
    /// thread, which is why moving the read off the main actor did not settle this row.
    /// Deliberately the SAME constant the live-tab pre-read gates on
    /// (`handleAgentWriteBegan`): a second private threshold here would let the two read
    /// paths disagree about which files the viewer will hold in memory.
    /// `nonisolated static` and pure so the decision is testable without a view.
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
            // Third save engine, same symlink rule as the other two: writing to a symlink
            // path replaces the link with a regular file and leaves the target stale.
            // Cheap (one stat), unlike the read/write below — kept inline like the other
            // two engines do.
            let url = ChatHistoryViewModel.writeTarget(forPath: rawURL.path)
            // One more cheap stat beside `writeTarget`'s, and inline for the same reason:
            // it decides whether the EXPENSIVE read below runs at all. Absent attributes
            // (a genuinely new destination) read as 0 — there is nothing to slurp.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let destinationBytes = (attributes?[.size] as? Int) ?? 0
            let preReadDestination = Self.shouldPreReadSaveAsDestination(byteSize: destinationBytes)
            if !preReadDestination {
                logger.info("[CodeViewer] Save As: skipping the pre-read of '\(url.lastPathComponent)' — \(destinationBytes) bytes, over the \(AgentLiveWriteEvent.liveContentByteLimit)-byte cap. CONSEQUENCE: that file's leading whitespace and trailing newline are NOT carried over; the editor buffer is written verbatim over it.")
            }
            // [CF-17] The read AND the write now run off the main actor, and the read is
            // SIZE-CAPPED like the live-tab pre-read (`handleAgentWriteBegan`). This is the only
            // engine that reads whatever destination the USER chose, which is why it was fixed
            // first — it is the one that can be pointed at an arbitrarily large file.
            // ⚠️ Half of this note is now out of date and half is still true.
            // `ChatHistoryViewModel.saveTabToItsPath` (the ⌘S path for a path-linked tab) NO
            // LONGER reads or writes on the main actor — its drift read runs in a
            // `Task.detached` and its write goes through `atomicallyWrite`. What it still lacks
            // is this engine's SIZE CAP: that read is an uncapped `String(contentsOf:)`, so a
            // very large agent-written file opened from a timeline row still allocates whole
            // into memory on save. Off-main, so no beachball — a memory spike, not a freeze.
            // `savePanel.begin`'s completion is @MainActor (this method already touched
            // `chatHistoryViewModel` here synchronously before this fix), so the `Task`
            // below inherits that and only the two `await`ed legs leave it.
            Task { @MainActor in
                do {
                    // Save As is the THIRD save engine and was the only one still writing the
                    // raw buffer. Every tab's content came through `CodeSnippet.normalizedCode`,
                    // which trims BOTH edges, so writing it verbatim over an existing file
                    // silently deleted that file's leading blank line/indentation and its POSIX
                    // trailing newline — the exact loss `contentToApply` exists to prevent (see
                    // its doc comment). The baseline MUST be the destination's on-disk bytes;
                    // for a genuinely new file — or one over the cap above — there is no
                    // baseline to restore from and the helper degrades to a no-op.
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
                    // No baseline: Save As is the user explicitly choosing a destination, not
                    // reconciling with a file the tab already claims to represent, so there is
                    // nothing to drift-check against — the other two engines refuse on drift
                    // because they write BACK to a path already tracked; this one has no such
                    // history. `atomicallyWrite` also verifies the write by reading the temp
                    // back before the atomic replace, which the old plain `write(to:atomically:)`
                    // did not.
                    try await ChatHistoryViewModel.atomicallyWrite(
                        content, to: url, fileName: url.lastPathComponent
                    )
                    // Save As satisfies an UNLINKED tab's dirty state (it has no source
                    // file — this WAS its save). For a linked tab it's just an exported
                    // copy; the source file still hasn't seen the draft, so it stays dirty.
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

/// The SF Symbol used to represent a code language, shared by the tab strip (and formerly the
/// header badge). Free function so it isn't tied to a view instance.
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

/// The horizontal, scrollable strip of open Code Viewer tabs. Replaces the single-selection
/// `< 1/N >` navigator: each open block is its own tab with a close control, and the active
/// tab is highlighted (filled with the editor background so it reads as "connected" to the
/// code below). Auto-scrolls to keep the active tab visible.
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

// MARK: - Live Pulse Dot

/// The "agent is writing" indicator: a small dot pulsing its opacity. Shared by the tab
/// chip and the floating pill (internal, not fileprivate, for that reason).
struct LivePulseDot: View {
    let color: Color
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(dimmed ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .accessibilityLabel(String(localized: "Agent is writing"))
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

            // Trailing slot, VS Code-style: hover always offers the ✕; a LIVE tab pulses
            // (agent writing) or warns (write rejected); otherwise a DIRTY tab shows its
            // unsaved-dot (even while active — the active tab is the one being edited, so
            // its dirty state matters most); a clean active tab keeps the discoverable ✕;
            // a clean inactive tab reserves the space.
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

    /// The ACTIVE TAB's cursor/scroll/find state, owned by the view model's store.
    ///
    /// Was `.constant(.init())` at both `SourceEditor` call sites, i.e. a binding whose
    /// setter discards: the coordinator dutifully wrote the caret and scroll position back
    /// on every move, into a value nothing could read. Combined with the `.id(document.id)`
    /// teardown, every tab switch, live-write refresh and minimize→reopen therefore
    /// restarted the editor at line 1.
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

    /// Two-way binding to the document's text.
    ///
    /// `[weak self]` is REQUIRED, not stylistic. The binding is stored in the
    /// `SourceEditor`, which is the `hostingController`'s `rootView`, and this
    /// controller OWNS `hostingController` — so a strong capture closes the loop
    ///
    ///     self ─▶ hostingController ─▶ rootView ─▶ contentBinding ─▶ self
    ///
    /// and the controller can never deallocate, leaking the whole CodeEdit stack
    /// (editor, text storage, highlighting state, document) on every panel
    /// open/close. Factored into one place so `setupEditorView` and
    /// `updatePresentationView` can't drift back to a strong capture.
    private func makeContentBinding() -> Binding<String> {
        Binding<String>(
            get: { [weak self] in self?.document.content ?? "" },
            set: { [weak self] newString in
                guard let self else { return }
                if self.document.content != newString {
                    self.document.content = newString
                    // Write-through to the tab so the draft survives tab switches and
                    // minimize — the panel rebuilds documents from the tab, and edits
                    // held only in this document would die with it.
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
