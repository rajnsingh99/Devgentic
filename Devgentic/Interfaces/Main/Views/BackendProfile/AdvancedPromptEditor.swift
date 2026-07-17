//
//  AdvancedPromptEditor.swift
//  Devgentic
//
//  Created by Agent on 20/02/26.
//

import SwiftUI
import AppKit
import Combine

// MARK: - Window Manager

/// Manages a single floating NSWindow for the advanced prompt editor. One
/// instance per consuming view (NOT a singleton) so multiple call sites
/// can keep their own editor open without trampling each other's
/// unsaved-changes callbacks. `@MainActor` because every NSWindow API
/// must be touched on the main thread.
@MainActor
final class AdvancedPromptWindowManager: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Callbacks to communicate with the SwiftUI view. Set by
    /// `AdvancedPromptEditorView.onAppear` for the editor that owns this
    /// instance — and ONLY that editor, because manager instances aren't
    /// shared.
    var checkChanges: (() -> Bool)?
    var saveChanges: (() -> Void)?
    var discardChanges: (() -> Void)?

    /// Spawns or brings the editor window to the front.
    func showEditor(
        text: Binding<String>,
        agentName: String,
        configuredTools: Binding<[Tool]>,
        themeManager: ThemeManager
    ) {
        let theme = themeManager.currentTheme

        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.contentView = NSHostingView(
                rootView: AdvancedPromptEditorHost(
                    themeManager: themeManager,
                    manager: self,
                    text: text,
                    agentName: agentName,
                    configuredTools: configuredTools
                )
            )
            existingWindow.title = "System Instructions: \(agentName)"
            existingWindow.backgroundColor = NSColor(theme.primaryBackground)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let editorView = AdvancedPromptEditorHost(
            themeManager: themeManager,
            manager: self,
            text: text,
            agentName: agentName,
            configuredTools: configuredTools
        )

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        newWindow.center()
        newWindow.title = "System Instructions: \(agentName)"
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = NSHostingView(rootView: editorView)
        newWindow.level = .floating

        newWindow.isOpaque = false
        newWindow.backgroundColor = NSColor(theme.primaryBackground).withAlphaComponent(0.98)
        newWindow.delegate = self

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        window?.close()
        window = nil
    }

    /// Updates the floating window's title without rebuilding the content
    /// view (so the editor keeps focus). No-op when the window isn't open —
    /// callers can fire this on every name keystroke without checks.
    func updateTitle(agentName: String) {
        guard let window, window.isVisible else { return }
        window.title = "System Instructions: \(agentName)"
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        // NSWindowDelegate calls happen on the main thread but aren't
        // typed @MainActor — hop explicitly so the actor checker is happy.
        MainActor.assumeIsolated {
            if checkChanges?() == true {
                let alert = NSAlert()
                alert.messageText = "Unsaved Changes"
                alert.informativeText = "You have unsaved changes in the system instructions. Would you like to save them before closing?"
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Don't Save")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn { // Save
                    saveChanges?()
                    return true
                } else if response == .alertSecondButtonReturn { // Cancel
                    return false
                } else { // Don't Save
                    discardChanges?()
                    return true
                }
            }
            return true
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            window = nil
            // Reset callbacks
            checkChanges = nil
            saveChanges = nil
            discardChanges = nil
        }
    }
}

// MARK: - Themed Host

/// Wrapper that watches the @Observable ThemeManager and re-applies the
/// `\.appTheme` environment whenever the active theme changes — keeping
/// the floating-window editor in lockstep with the parent app's theme
/// (the host's `body` re-evaluates when `themeManager.currentTheme` flips).
private struct AdvancedPromptEditorHost: View {
    @Bindable var themeManager: ThemeManager
    var manager: AdvancedPromptWindowManager
    @Binding var text: String
    var agentName: String
    @Binding var configuredTools: [Tool]

    var body: some View {
        AdvancedPromptEditorView(
            manager: manager,
            text: $text,
            agentName: agentName,
            configuredTools: $configuredTools
        )
        .environment(\.appTheme, themeManager.currentTheme)
        .preferredColorScheme(themeManager.currentTheme.colorScheme)
    }
}

// MARK: - Models & State

/// Bundles the definition and source so we can easily add it to `configuredTools`.
struct AvailableTool: Identifiable, Equatable {
    var id: String { "\(source.id)-\(definition.name)" }
    let definition: ToolDefinition
    let source: ToolSource
    
    static func == (lhs: AvailableTool, rhs: AvailableTool) -> Bool {
        return lhs.id == rhs.id
    }
}

/// Manages the state of the active tool mention popover for keyboard navigation.
@Observable @MainActor
class MentionState {
    var selectedIndex: Int = 0
    var maxIndex: Int = 0
    var activeTools: [AvailableTool] = []
}

/// Manages the state of the active prompt mention popover for keyboard navigation.
@Observable @MainActor
class PromptMentionState {
    var selectedIndex: Int = 0
    var maxIndex: Int = 0
    var activePrompts: [DevPrompt] = []
}

// MARK: - Editor UI

struct AdvancedPromptEditorView: View {
    /// Manager that owns the floating window — callbacks (checkChanges,
    /// saveChanges, discardChanges) are set on THIS instance so unsaved-
    /// changes prompts target the right document, even when multiple
    /// editors are open across the app.
    var manager: AdvancedPromptWindowManager
    @Binding var text: String
    var agentName: String
    @Binding var configuredTools: [Tool]
    @Environment(\.appTheme) private var theme
    
    // State for supporting components
    @State private var promptLibraryVM = PromptEditViewModel()
    @State private var showingSavePopover: Bool = false
    @State private var showingGuide: Bool = false
    
    // Tracking for unsaved changes
    @State private var localText: String = ""
    @State private var localTools: [Tool] = []
    
    @State private var initialText: String = ""
    @State private var initialTools: [Tool] = []
    
    private var hasUnsavedChanges: Bool {
        localText != initialText || localTools != initialTools
    }

    var body: some View {
        VStack(spacing: 0) {
            
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("System Instructions")
                        .font(theme.fontHeadline)
                    Text("Defines the core persona, logic, and protocols for \(agentName).")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                
                VStack(alignment: .trailing) {
                    VStack(alignment: .trailing) {
                        Text("\(localText.count) characters")
                            .font(theme.fontSubheadline)
                            .monospacedDigit()
                        Text("~ \(localText.count / 4) tokens")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                    }
                }
            }
            .padding()
            .background(theme.primaryBackground)

            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)

            HStack(spacing: 0) {
                // The Core Editor
                ZStack(alignment: .topTrailing) {
                    ZStack(alignment: .topLeading) {
                        TokenizingTextEditor(text: $localText, configuredTools: $localTools, theme: theme, promptLibraryVM: promptLibraryVM)
                            .padding()
                            .scrollContentBackground(.hidden)
                            .background(theme.textBackground)
                        
                        if localText.isEmpty {
                            Text("Define persona, strategy, and guardrails for \(agentName)...")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(theme.secondaryText.opacity(0.5))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 24)
                                .allowsHitTesting(false)
                        }
                    }
                    
                    // Floating Guide Toggle
                    Button(action: { withAnimation { showingGuide.toggle() } }) {
                        Image(systemName: "info.circle.fill")
                            .font(.title3)
                            .foregroundColor(showingGuide ? theme.accentColor : theme.secondaryText)
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(theme.secondaryBackground.opacity(0.8))
                                    .blur(radius: 0.5)
                            )
                            .overlay(
                                Circle()
                                    .stroke(theme.dividerColor, lineWidth: 0.5)
                            )
                            .shadow(color: theme.shadowColor, radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    .padding(.trailing, 32) // Increased padding to avoid scrollbar overlap
                    .help("Explain how to write instructions and use shortcuts")
                    .accessibilityLabel("Explain how to write instructions and use shortcuts")
                }
                
                if showingGuide {
                    Rectangle()
                        .fill(theme.dividerColor)
                        .frame(width: 1)
                    
                    PromptGuideView()
                        .frame(width: 280)
                        .background(theme.secondaryBackground)
                        .transition(.move(edge: .trailing))
                }
            }

            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)

            // Footer
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(theme.successColor)
                    .accessibilityHidden(true)
                Text("Changes sync automatically to the main window.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Button(action: {
                    promptLibraryVM.loadCreateDraft()
                    promptLibraryVM.text = localText
                    showingSavePopover = true
                }) {
                    Label("Save to Library", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 8)
                .popover(isPresented: $showingSavePopover, arrowEdge: .top) {
                    CreateEditPromptView()
                        .environment(promptLibraryVM)
                        .frame(minWidth: 480, idealWidth: 550, minHeight: 450, idealHeight: 500)
                }
                
                if hasUnsavedChanges {
                    Button("Save") {
                        saveAndClose()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding()
            .background(theme.secondaryBackground)
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            // Initialize local state from the binding
            localText = text
            localTools = configuredTools

            initialText = text
            initialTools = configuredTools

            // Wire up unsaved-changes callbacks on the manager that owns
            // THIS editor's window — never the global singleton, so two
            // editors open simultaneously can't trample each other.
            manager.checkChanges = { hasUnsavedChanges }
            manager.saveChanges = { saveAndClose() }
            manager.discardChanges = { [weak manager] in manager?.closeWindow() }
        }
    }

    private func saveAndClose() {
        // Explicitly sync back to parent bindings
        text = localText
        configuredTools = localTools

        manager.closeWindow()
    }
}

// MARK: - AppKit TextEditor & Autocomplete Wrapper

struct TokenizingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var configuredTools: [Tool]
    var theme: Theme
    var promptLibraryVM: PromptEditViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor(theme.primaryText)
        textView.backgroundColor = NSColor(theme.textBackground)
        textView.drawsBackground = true
        
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        
        textView.textContainerInset = NSSize(width: 8, height: 8)

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        if textView.string != text {
            // Block textDidChange delegate from firing during structural SwiftUI update
            context.coordinator.isUpdatingFromSwiftUI = true
            
            let selectedRange = textView.selectedRange()
            textView.string = text
            if selectedRange.location <= text.count {
                textView.setSelectedRange(selectedRange)
            }
            
            context.coordinator.isUpdatingFromSwiftUI = false
        }
        
        // Ensure theme colors are applied on update
        textView.textColor = NSColor(theme.primaryText)
        textView.backgroundColor = NSColor(theme.textBackground)
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: TokenizingTextEditor
        var popover: NSPopover?
        var promptPopover: NSPopover?
        
        var activeMentionRange: NSRange?
        var activePromptRange: NSRange?
        
        // Keyboard state tracking
        var mentionState = MentionState()
        var promptMentionState = PromptMentionState()
        
        // Flag to prevent loop-backs when updating from SwiftUI
        var isUpdatingFromSwiftUI = false

        init(_ parent: TokenizingTextEditor) {
            self.parent = parent
        }

        // MARK: - Phase 3: Dynamic Syntax Highlighting
        
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            
            let text = textStorage.string
            let fullRange = NSRange(location: 0, length: textStorage.length)
            
            let defaultAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(parent.theme.primaryText),
                .backgroundColor: NSColor.clear
            ]
            textStorage.setAttributes(defaultAttributes, range: fullRange)
            
            // To properly highlight, we should highlight ANY configured tool to keep visuals in sync.
            let toolNames = parent.configuredTools.map { $0.name }
            guard !toolNames.isEmpty else { return }
            
            if let regex = try? NSRegularExpression(pattern: "`([^`]+)`") {
                let matches = regex.matches(in: text, range: fullRange)
                
                for match in matches {
                    guard match.numberOfRanges == 2 else { continue }
                    
                    if let swiftRange = Range(match.range(at: 1), in: text) {
                        let extractedName = String(text[swiftRange])
                        
                        if toolNames.contains(extractedName) {
                            let tokenAttributes: [NSAttributedString.Key: Any] = [
                                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                                .foregroundColor: NSColor(parent.theme.accentColor),
                                .backgroundColor: NSColor(parent.theme.accentColor).withAlphaComponent(0.15)
                            ]
                            textStorage.addAttributes(tokenAttributes, range: match.range)
                        }
                    }
                }
            }
        }
        
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            textView.typingAttributes = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(parent.theme.primaryText),
                .backgroundColor: NSColor.clear
            ]
        }

        // MARK: - Phase 2 (Enhancement Step 2): Keyboard Integration
        
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if popover?.isShown == true {
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    mentionState.selectedIndex = max(0, mentionState.selectedIndex - 1)
                    return true
                } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    mentionState.selectedIndex = min(mentionState.maxIndex, mentionState.selectedIndex + 1)
                    return true
                } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if !mentionState.activeTools.isEmpty {
                        let selected = mentionState.activeTools[mentionState.selectedIndex]
                        insertTool(selected, in: textView)
                    }
                    return true
                } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    closePopover()
                    return true
                }
            }
            
            if promptPopover?.isShown == true {
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    promptMentionState.selectedIndex = max(0, promptMentionState.selectedIndex - 1)
                    return true
                } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    promptMentionState.selectedIndex = min(promptMentionState.maxIndex, promptMentionState.selectedIndex + 1)
                    return true
                } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if !promptMentionState.activePrompts.isEmpty {
                        let selected = promptMentionState.activePrompts[promptMentionState.selectedIndex]
                        insertPrompt(selected, in: textView)
                    }
                    return true
                } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    closePromptPopover()
                    return true
                }
            }
            
            return false
        }
        
        // MARK: - Mention Logic
        
        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI else { return }
            guard let textView = notification.object as? NSTextView else { return }
            
            let newText = textView.string
            
            DispatchQueue.main.async {
                // Ensure we only write back if the text actually mutated, preventing circular structural re-renders
                if self.parent.text != newText {
                    self.parent.text = newText
                }
            }

            let selectedRange = textView.selectedRange()
            let textString = textView.string as NSString

            guard selectedRange.location > 0 else {
                closePopover()
                closePromptPopover()
                return
            }

            let textUpToCursor = textString.substring(to: selectedRange.location)
            let components = textUpToCursor.components(separatedBy: .whitespacesAndNewlines)
            guard let lastWord = components.last else {
                closePopover()
                closePromptPopover()
                return
            }

            if lastWord.hasPrefix("@") {
                closePromptPopover()
                let mentionLocation = selectedRange.location - lastWord.count
                activeMentionRange = NSRange(location: mentionLocation, length: lastWord.count)
                let query = String(lastWord.dropFirst())
                showPopover(for: query, in: textView)
            } else if lastWord.hasPrefix("#") {
                closePopover()
                let mentionLocation = selectedRange.location - lastWord.count
                activePromptRange = NSRange(location: mentionLocation, length: lastWord.count)
                let query = String(lastWord.dropFirst())
                showPromptPopover(for: query, in: textView)
            } else {
                closePopover()
                closePromptPopover()
            }
        }

        private func showPopover(for query: String, in textView: NSTextView) {
            // Step 1: Query against ALL available tools globally
            let allTools = UnifiedToolStore.shared.sources.flatMap { source in
                source.tools.map { AvailableTool(definition: $0, source: source) }
            }
            
            let filteredTools = query.isEmpty ? allTools : allTools.filter {
                $0.definition.name.localizedCaseInsensitiveContains(query) ||
                $0.definition.description.localizedCaseInsensitiveContains(query)
            }

            guard !filteredTools.isEmpty else {
                closePopover()
                return
            }
            
            // Sync Keyboard State
            mentionState.activeTools = filteredTools
            mentionState.maxIndex = max(0, filteredTools.count - 1)
            mentionState.selectedIndex = 0

            let listView = ToolMentionListView(state: mentionState) { [weak self] selectedTool in
                self?.insertTool(selectedTool, in: textView)
            }

            let controller = NSHostingController(rootView: listView)
            
            if popover == nil {
                popover = NSPopover()
                popover?.behavior = .transient
                popover?.animates = false
            }
            popover?.contentViewController = controller

            if let range = activeMentionRange,
               let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                
                let rect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer)
                
                var targetRect = rect
                targetRect.origin.x += textView.textContainerOrigin.x
                targetRect.origin.y += textView.textContainerOrigin.y
                
                popover?.show(relativeTo: targetRect, of: textView, preferredEdge: .minY)
            }
        }

        private func closePopover() {
            popover?.close()
            activeMentionRange = nil
        }

        private func insertTool(_ availableTool: AvailableTool, in textView: NSTextView) {
            guard let range = activeMentionRange else { return }
            
            let replacement = "`\(availableTool.definition.name)` "
            
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
            
            // Step 1: Auto-Sync to Library State
            DispatchQueue.main.async {
                let isAlreadyEnabled = self.parent.configuredTools.contains {
                    $0.name == availableTool.definition.name && $0.sourceId == availableTool.source.id
                }
                
                if !isAlreadyEnabled {
                    let newTool = Tool(
                        name: availableTool.definition.name,
                        description: availableTool.definition.description,
                        isEnabled: true,
                        requiresConfirmation: availableTool.definition.requiresConfirmation,
                        sourceId: availableTool.source.id,
                        parameters: availableTool.definition.parameters
                    )
                    self.parent.configuredTools.append(newTool)
                }
            }

            closePopover()
        }

        private func showPromptPopover(for query: String, in textView: NSTextView) {
            let allPrompts = PromptService.shared.getAllPrompts()
            
            let filteredPrompts = query.isEmpty ? allPrompts : allPrompts.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.text.localizedCaseInsensitiveContains(query)
            }

            guard !filteredPrompts.isEmpty else {
                closePromptPopover()
                return
            }
            
            // Sync Keyboard State
            promptMentionState.activePrompts = filteredPrompts
            promptMentionState.maxIndex = max(0, filteredPrompts.count - 1)
            promptMentionState.selectedIndex = 0

            let listView = PromptMentionListView(state: promptMentionState) { [weak self] selectedPrompt in
                self?.insertPrompt(selectedPrompt, in: textView)
            }
            .environment(\.appTheme, parent.theme)

            let controller = NSHostingController(rootView: listView)
            
            if promptPopover == nil {
                promptPopover = NSPopover()
                promptPopover?.behavior = .transient
                promptPopover?.animates = false
            }
            promptPopover?.contentViewController = controller

            if let range = activePromptRange,
               let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                
                let rect = layoutManager.boundingRect(forGlyphRange: range, in: textContainer)
                
                var targetRect = rect
                targetRect.origin.x += textView.textContainerOrigin.x
                targetRect.origin.y += textView.textContainerOrigin.y
                
                promptPopover?.show(relativeTo: targetRect, of: textView, preferredEdge: .minY)
            }
        }

        private func closePromptPopover() {
            promptPopover?.close()
            activePromptRange = nil
        }

        private func insertPrompt(_ prompt: DevPrompt, in textView: NSTextView) {
            guard let range = activePromptRange else { return }
            
            let replacement = prompt.text
            
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
            }
            
            closePromptPopover()
        }
    }
}

// MARK: - Popover UI Components

struct ToolMentionListView: View {
    @Bindable var state: MentionState
    let onSelect: (AvailableTool) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Insert Tool")
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(state.activeTools.enumerated()), id: \.element.id) { index, tool in
                            ToolMentionRow(
                                tool: tool,
                                isSelected: index == state.selectedIndex,
                                action: { onSelect(tool) }
                            )
                            .id(index)
                            Divider()
                        }
                    }
                }
                .onChange(of: state.selectedIndex) { oldValue, newValue in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 320, height: min(CGFloat(state.activeTools.count * 48 + 40), 320))
    }
}

struct ToolMentionRow: View {
    let tool: AvailableTool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                Image(systemName: "wrench.fill")
                    .foregroundColor(isSelected ? .white : theme.accentColor)
                    .font(theme.fontCaption)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.definition.name)
                        .font(theme.fontSubheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isSelected ? .white : theme.primaryText)
                    
                    Text(tool.definition.description.split(separator: "\n").first ?? "")
                        .font(theme.fontCaption)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                
                // Add an indicator showing the source (Local vs MCP)
                Text(tool.source.serverName)
                    .font(.system(size: 9)) // Fixed size: intentional (badge/chip text)
                    .foregroundColor(isSelected ? .white.opacity(0.6) : theme.secondaryText.opacity(0.6))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? theme.accentColor : (isHovered ? theme.accentColor.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.definition.description)
        .onHover { hovered in
            isHovered = hovered
            if hovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct PromptMentionListView: View {
    @Bindable var state: PromptMentionState
    let onSelect: (DevPrompt) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Insert Prompt")
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(state.activePrompts.enumerated()), id: \.element.id) { index, prompt in
                            PromptMentionRow(
                                prompt: prompt,
                                isSelected: index == state.selectedIndex,
                                action: { onSelect(prompt) }
                            )
                            .id(index)
                            Divider()
                        }
                    }
                }
                .onChange(of: state.selectedIndex) { oldValue, newValue in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 320, height: min(CGFloat(state.activePrompts.count * 48 + 40), 320))
    }
}

struct PromptMentionRow: View {
    let prompt: DevPrompt
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                Image(systemName: "text.quote")
                    .foregroundColor(isSelected ? .white : theme.accentColor)
                    .font(theme.fontCaption)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(theme.fontSubheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isSelected ? .white : theme.primaryText)
                    
                    Text(prompt.text.split(separator: "\n").first ?? "")
                        .font(theme.fontCaption)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? theme.accentColor : (isHovered ? theme.accentColor.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            isHovered = hovered
            if hovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Prompt Guide

struct PromptGuideView: View {
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Writing Instructions")
                        .font(theme.fontHeadline)
                    Text("Effective instructions define the boundaries and behavior of your agent.")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }
                
                guideSection(
                    title: "1. Persona",
                    description: "Set the identity and tone. Is the agent a software engineer, a creative writer, or a legal expert?",
                    example: "# PERSONA\nYou are a Principal Swift Engineer specializing in clean architecture..."
                )
                
                guideSection(
                    title: "2. Strategy",
                    description: "Outline the problem-solving steps the agent should follow.",
                    example: "# STRATEGY\n1. Analyze the file system first.\n2. Propose changes before editing."
                )
                
                guideSection(
                    title: "3. Guardrails",
                    description: "Specify what the agent should NEVER do to ensure safety.",
                    example: "# GUARDRAILS\n- Never delete a folder without user confirmation."
                )
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Shortcuts")
                        .font(theme.fontSubheadline)
                        .fontWeight(.bold)
                    
                    shortcutItem(
                        symbol: "@",
                        label: "Mention Tools",
                        description: "Type `@` to see and enable tools from your library. This automatically enables them for the agent."
                    )
                    
                    shortcutItem(
                        symbol: "#",
                        label: "Prompt Templates",
                        description: "Type `#` to search and insert reusable prompt snippets from your Prompt Library."
                    )
                }
                
                Spacer(minLength: 20)
            }
            .padding()
        }
    }
    
    private func guideSection(title: String, description: String, example: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(theme.fontSubheadline)
                .fontWeight(.bold)
            Text(description)
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)

            Text(example)
                .font(.system(size: 11, weight: .regular, design: .monospaced)) // Fixed size: monospaced
                .padding(8)
                .background(theme.primaryBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                        .stroke(theme.dividerColor, lineWidth: 0.5)
                )
        }
    }
    
    private func shortcutItem(symbol: String, label: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(symbol)
                .font(.system(size: 16, weight: .bold, design: .monospaced)) // Fixed size: monospaced
                .foregroundColor(theme.accentColor)
                .frame(width: 24, height: 24)
                .background(theme.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusSmall))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(theme.fontCaption)
                    .fontWeight(.bold)
                Text(description)
                    .font(.system(.caption2))
                    .foregroundColor(theme.secondaryText)
            }
        }
    }
}
