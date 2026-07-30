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


// MARK: - CodeViewerPanelView (Main SwiftUI View)
struct CodeViewerPanelView: View {
    @Environment(ChatHistoryViewModel.self) var chatHistoryViewModel
    @Environment(ThemeManager.self) var themeManager

    @State private var isHoveringOnDivider = false
    /// Panel width captured at the start of a divider drag, so the cumulative gesture
    /// translation is applied to a fixed base rather than the live (already-moved) width.
    @State private var dragStartWidth: Double? = nil
    /// Width while a divider drag is in flight. Written per tick INSTEAD of the
    /// @AppStorage-backed `panelWidth`: a UserDefaults write per mouse move both spams the
    /// preferences daemon and schedules an extra invalidation on top of each layout pass.
    /// The final width is committed to `panelWidth` once, on drag end.
    @State private var liveDragWidth: Double? = nil
    @AppStorage("codeEditFontSize") var fontSize: Double = 13
    @AppStorage("codeViewerPanelWidth") private var panelWidth: Double = 600
    @AppStorage("codeViewerWrapLines") private var wrapLines: Bool = true
    @AppStorage("codeViewerShowMinimap") private var showMinimap: Bool = false
    /// When on, a starting agent write auto-selects its tab — but only ever INSIDE an
    /// already-open panel (badge-only policy: the panel itself is never auto-opened).
    @AppStorage("codeViewerFollowAgent") private var followAgent: Bool = false

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
        return max(400, containerWidth - ChatUIConstants.splitModeMinChatWidth)
    }

    @State private var document: CodeDocument?
    @State private var didCopy: Bool = false
    @State private var currentSnippet: CodeSnippet?
    @State private var saveErrorMessage: String?

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

    /// Shorthand for the current presentation mode (overlay / split / full).
    private var presentation: CodeViewerPresentation { chatHistoryViewModel.codeViewerPresentation }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // No divider in full-width mode — there is nothing left to resize against.
            if presentation != .full {
                resizableDivider
            }
            panelContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            containerWidth = newWidth
        }
        .transition(.move(edge: .trailing))
        // Overlay floats above the chat → drop shadow sells the elevation. In split the
        // panel is a layout NEIGHBOUR of the chat (nothing underneath) — a shadow there
        // reads as a rendering glitch on the seam, so it goes clear.
        .shadow(color: presentation == .split ? .clear : .black.opacity(0.25), radius: 12, x: -4, y: 0)
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
    }

    // MARK: - Snippet Loading

    /// The snippet in the active tab, or nil when there's no (valid) selection. A stale
    /// `activeCodeViewerTabID` that matches no tab simply reads as "no selection" (id lookup,
    /// so no subscript to trap on) and the panel falls back to the empty state.
    private var selectedSnippet: CodeSnippet? {
        chatHistoryViewModel.activeCodeViewerTab?.snippet
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
        let doc = CodeDocument(content: content, language: snippet.language)
        currentSnippet = snippet
        document = doc
        logger.info("[CodeViewer] Loaded tab \(position)/\(total) — lang=\(snippet.language ?? "nil") → resolved=\(doc.language.id.rawValue), \(content.count) chars\(content != snippet.code ? " (draft)" : "").")
    }

    // MARK: - Resizable Divider

    private var resizableDivider: some View {
        Rectangle()
            .fill(isHoveringOnDivider ? accentTint.opacity(0.6) : selectionColor.opacity(0.3))
            .frame(width: ChatUIConstants.codeViewerDividerWidth)
            .contentShape(Rectangle())
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
                        liveDragWidth = Double(min(max(newWidth, 400), maxPanelWidth)).rounded()
                    }
                    .onEnded { _ in
                        if let final = liveDragWidth {
                            panelWidth = final   // persist ONCE per drag, not per tick
                            logger.debug("[CodeViewer] Panel resized to \(Int(final))pt.")
                        }
                        liveDragWidth = nil
                        dragStartWidth = nil
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

    /// The tab a close request is pending on (dirty-close confirmation), if any.
    private var pendingCloseTab: CodeViewerTab? {
        chatHistoryViewModel.pendingCloseTabID.flatMap { id in
            chatHistoryViewModel.codeViewerTabs.first { $0.id == id }
        }
    }

    /// "Save & Close" from the dirty-close alert: run the guarded save, then close ONLY
    /// if it actually cleaned the tab — a failed save (drift, I/O) leaves the tab open
    /// with the error alert instead of discarding the draft behind the failure.
    private func saveAndClosePendingTab(_ tabID: UUID) {
        guard let tab = chatHistoryViewModel.codeViewerTabs.first(where: { $0.id == tabID }) else { return }
        Task { @MainActor in
            await chatHistoryViewModel.performApplyChanges(for: tab.snippet)
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
                        if pending.snippet.sourceFileID != nil {
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
                    HighPerformanceCodeViewRepresentable(
                        document: document,
                        fontSize: fontSize,
                        editorTheme: resolvedSyntax.editorTheme,
                        bracketHighlightColor: resolvedSyntax.bracketHighlight,
                        themeIdentifier: themeIdentifier,
                        wrapLines: wrapLines,
                        showMinimap: showMinimap,
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
        }
        // Overlay/split modes: fixed width, clamped to the container so a width persisted
        // on a bigger window can't push the divider off-screen. Full mode: fill everything
        // the mount gives us (MainApplicationView insets us past the sidebar).
        .frame(width: presentation == .full ? nil : min(CGFloat(displayedWidth), maxPanelWidth))
        .frame(maxWidth: presentation == .full ? .infinity : nil)
        .background(panelBackground)
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
            // GROUP 1: Save. The Diff toggle and per-hunk Apply are gone — a change is
            // shown in the tool row that produced it, not here. `applyChanges` survives as
            // the save engine behind ⌘S.
            if let activeTab = chatHistoryViewModel.activeCodeViewerTab,
               activeTab.snippet.sourceFileID != nil {
                HStack(spacing: 4) {
                    // Save writes the buffer back to the linked source file.
                    do {
                        Button {
                            chatHistoryViewModel.applyChanges(for: activeTab.snippet)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text(String(localized: "Save"))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(Color(nsColor: resolvedSyntax.strings))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: resolvedSyntax.strings).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color(nsColor: resolvedSyntax.strings).opacity(0.4), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Save to the linked source file"))
                        .accessibilityLabel(String(localized: "Save to the linked source file"))
                    }

                }

                Capsule()
                    .fill(secondaryTextColor.opacity(0.2))
                    .frame(width: 1, height: 14)
            }

            // GROUP 2: Code Tools (Copy & Save)
            HStack(spacing: 3) {
                CodeViewerHeaderButton(
                    action: {
                        copyCodeToClipboard()
                        didCopy = true
                        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); didCopy = false }
                    },
                    icon: didCopy ? "checkmark" : "doc.on.doc",
                    helpText: String(localized: "Copy code (right-click for more formats)"),
                    foregroundColor: didCopy ? Color(nsColor: resolvedSyntax.strings) : secondaryTextColor,
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

                // Smart save (⌘S): linked tabs write to their source file; unlinked fall to Save As
                CodeViewerHeaderButton(
                    action: saveActiveTab,
                    icon: "square.and.arrow.down",
                    helpText: String(localized: "Save (⌘S)"),
                    foregroundColor: (chatHistoryViewModel.activeCodeViewerTab?.isDirty == true) ? accentTint : secondaryTextColor,
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
                    hoverBackground: selectionColor
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
                    hoverBackground: selectionColor
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
        VStack(spacing: 16) {
            Image(systemName: "curlybraces.square")
                .font(.system(size: 40, weight: .thin)) // Fixed size: intentional (icon)
                .foregroundColor(secondaryTextColor.opacity(0.4))
            Text("No Code Selected")
                .font(.system(.body, weight: .medium))
                .foregroundColor(secondaryTextColor.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func copyCodeToClipboard() {
        guard let snippet = currentSnippet else { return }
        copyToClipboard(snippet.code)
    }

    private func copyToClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
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
        return "```\(info)\n\(snippet.code)\n```"
    }

    /// The snippet prefixed with a language-appropriate comment line naming the file.
    private func codeWithFilenameComment() -> String {
        guard let snippet = currentSnippet, let fileName = activeTabFileName else {
            return currentSnippet?.code ?? ""
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
        return "\(comment)\n\(snippet.code)"
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
            if result == .OK, let url = savePanel.url {
                do {
                    try buffer.write(to: url, atomically: true, encoding: .utf8)
                    // Save As satisfies an UNLINKED tab's dirty state (it has no source
                    // file — this WAS its save). For a linked tab it's just an exported
                    // copy; the source file still hasn't seen the draft, so it stays dirty.
                    if !isLinked, let tabID {
                        chatHistoryViewModel.markCodeViewerTabSavedAs(
                            tabID: tabID, savedBuffer: buffer, savedTo: url
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
fileprivate func codeViewerLanguageIcon(for languageID: String?) -> String {
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        CodeViewerTabChip(
                            tab: tab,
                            isActive: tab.id == activeTabID,
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
            }
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

// MARK: - Tab Chip

fileprivate struct CodeViewerTabChip: View {
    let tab: CodeViewerTab
    let isActive: Bool
    let textColor: Color
    let secondaryColor: Color
    let accentColor: Color
    let activeBackground: Color
    let hoverColor: Color
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isHoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: codeViewerLanguageIcon(for: tab.snippet.language))
                .font(.system(size: 10, weight: .medium)) // Fixed size: tab affordance
                .foregroundColor(isActive ? accentColor : secondaryColor)

            Text(tab.title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular)) // Fixed size: tab label
                .foregroundColor(isActive ? textColor : secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)

            // Trailing slot, VS Code-style: hover always offers the ✕; a LIVE tab pulses
            // (agent writing) or warns (write rejected); otherwise a DIRTY tab shows its
            // unsaved-dot (even while active — the active tab is the one being edited, so
            // its dirty state matters most); a clean active tab keeps the discoverable ✕;
            // a clean inactive tab reserves the space.
            if !isHovering, tab.liveState == .active {
                LivePulseDot(color: .orange)
                    .frame(width: 15, height: 15)
            } else if !isHovering, tab.liveState == .rejected {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10, weight: .semibold)) // Fixed size: status glyph
                    .foregroundColor(.orange)
                    .frame(width: 15, height: 15)
                    .help(String(localized: "The agent's write was not applied"))
                    .accessibilityLabel(String(localized: "Write not applied"))
            } else if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold)) // Fixed size: close glyph
                        .foregroundColor(isHoveringClose ? textColor : secondaryColor)
                        .frame(width: 15, height: 15)
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
                    .frame(width: 15, height: 15)
                    .help(String(localized: "Unsaved changes"))
                    .accessibilityLabel(String(localized: "Unsaved changes"))
            } else if isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold)) // Fixed size: close glyph
                        .foregroundColor(secondaryColor)
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close tab"))
                .accessibilityLabel(String(localized: "Close tab"))
            } else {
                Color.clear.frame(width: 15, height: 15)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .frame(maxWidth: 200)
        .background(isActive ? activeBackground : (isHovering ? hoverColor.opacity(0.45) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isActive ? accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isEnabled ? (isHovering ? foregroundColor : foregroundColor.opacity(0.75)) : foregroundColor.opacity(0.2))
                .frame(width: 28, height: 28)
                .background(isHovering && isEnabled ? hoverBackground.opacity(0.6) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isHovering && isEnabled ? foregroundColor.opacity(0.25) : Color.clear, lineWidth: 0.5)
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
    var fontSize: Double
    var editorTheme: CodeEditSourceEditor.EditorTheme
    var bracketHighlightColor: NSColor
    var themeIdentifier: String
    var wrapLines: Bool
    var showMinimap: Bool
    var onContentChange: (String) -> Void

    func makeNSViewController(context: Context) -> HighPerformanceCodeViewController {
        let controller = HighPerformanceCodeViewController(
            document: document,
            editorTheme: editorTheme,
            bracketHighlightColor: bracketHighlightColor,
            themeIdentifier: themeIdentifier,
            wrapLines: wrapLines,
            showMinimap: showMinimap
        )
        controller.onContentChange = onContentChange
        return controller
    }

    func updateNSViewController(_ nsViewController: HighPerformanceCodeViewController, context: Context) {
        nsViewController.onContentChange = onContentChange
        nsViewController.update(
            document: document,
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

    init(document: CodeDocument, editorTheme: CodeEditSourceEditor.EditorTheme, bracketHighlightColor: NSColor, themeIdentifier: String, wrapLines: Bool, showMinimap: Bool) {
        self.document = document
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

        let contentBinding = makeContentBinding()

        let newEditorView = SourceEditor(
            contentBinding,
            language: self.document.language,
            configuration: makeConfiguration(font: font),
            state: .constant(.init())
        )
        hostingController?.rootView = newEditorView
    }

    func update(document: CodeDocument, fontSize: Double, editorTheme: CodeEditSourceEditor.EditorTheme, bracketHighlightColor: NSColor, themeIdentifier: String, wrapLines: Bool, showMinimap: Bool) {
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
