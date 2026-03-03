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

/// Manages a floating, detached NSWindow for the advanced prompt editor.
class AdvancedPromptWindowManager {
    static let shared = AdvancedPromptWindowManager()
    private var window: NSWindow?

    /// Spawns or brings the editor window to the front.
    func showEditor(text: Binding<String>, agentName: String, configuredTools: Binding<[Tool]>, theme: Theme) {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.contentView = NSHostingView(
                rootView: AdvancedPromptEditorView(text: text, agentName: agentName, configuredTools: configuredTools)
                    .environment(\.appTheme, theme)
            )
            existingWindow.title = "System Instructions: \(agentName)"
            existingWindow.backgroundColor = NSColor(theme.primaryBackground)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let editorView = AdvancedPromptEditorView(text: text, agentName: agentName, configuredTools: configuredTools)
            .environment(\.appTheme, theme)
        
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

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
    }
    
    func closeWindow() {
        window?.close()
        window = nil
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

/// An ObservableObject to manage the state of the active popover for keyboard navigation.
@MainActor
class MentionState: ObservableObject {
    @Published var selectedIndex: Int = 0
    @Published var maxIndex: Int = 0
    var activeTools: [AvailableTool] = []
}

// MARK: - Editor UI

struct AdvancedPromptEditorView: View {
    @Binding var text: String
    var agentName: String
    @Binding var configuredTools: [Tool]
    @Environment(\.appTheme) private var theme
    
    // Local state to drive real-time UI updates in the detached window
    @State private var localText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("System Instructions")
                        .font(.headline)
                    Text("Defines the core persona, logic, and protocols for \(agentName).")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("\(localText.count) characters")
                        .font(.subheadline)
                        .monospacedDigit()
                    Text("~ \(localText.count / 4) tokens")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
            }
            .padding()
            .background(theme.primaryBackground)

            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)

            // The Core Editor
            TokenizingTextEditor(text: $localText, configuredTools: $configuredTools, theme: theme)
                .padding()
                .scrollContentBackground(.hidden)
                .background(theme.textBackground)

            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)

            // Footer
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Changes sync automatically to the main window.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                
                Spacer()
                
                Button("Done") {
                    AdvancedPromptWindowManager.shared.closeWindow()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(theme.secondaryBackground)
        }
        .frame(minWidth: 500, minHeight: 400)
        .preferredColorScheme(theme.id == "one_light" ? .light : (theme.id == "midnight" ? .dark : (theme.id == "dracula" ? .dark : nil)))
        .onAppear {
            // Initialize local state from the binding
            localText = text
        }
        .onChange(of: localText) { newValue in
            // Push changes back to the main app binding
            if text != newValue {
                text = newValue
            }
        }
        .onChange(of: text) { newValue in
            // Sync if the text was changed externally while the window is open
            if localText != newValue {
                localText = newValue
            }
        }
    }
}

// MARK: - AppKit TextEditor & Autocomplete Wrapper

struct TokenizingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var configuredTools: [Tool]
    var theme: Theme

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
        textView.allowsUndo = true
        
        textView.textContainerInset = NSSize(width: 8, height: 8)

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            if selectedRange.location <= text.count {
                textView.setSelectedRange(selectedRange)
            }
        }
        
        // Ensure theme colors are applied on update
        textView.textColor = NSColor(theme.primaryText)
        textView.backgroundColor = NSColor(theme.textBackground)
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: TokenizingTextEditor
        var popover: NSPopover?
        var activeMentionRange: NSRange?
        
        // Step 2: Keyboard state tracking
        var mentionState = MentionState()

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
            guard popover?.isShown == true else { return false }
            
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
            
            return false
        }
        
        // MARK: - Mention Logic
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            DispatchQueue.main.async {
                self.parent.text = textView.string
            }

            let selectedRange = textView.selectedRange()
            let textString = textView.string as NSString

            guard selectedRange.location > 0 else {
                closePopover()
                return
            }

            let textUpToCursor = textString.substring(to: selectedRange.location)
            let components = textUpToCursor.components(separatedBy: .whitespacesAndNewlines)

            guard let lastWord = components.last, lastWord.hasPrefix("@") else {
                closePopover()
                return
            }

            let mentionLocation = selectedRange.location - lastWord.count
            activeMentionRange = NSRange(location: mentionLocation, length: lastWord.count)

            let query = String(lastWord.dropFirst())
            showPopover(for: query, in: textView)
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
    }
}

// MARK: - Popover UI Components

struct ToolMentionListView: View {
    @ObservedObject var state: MentionState
    let onSelect: (AvailableTool) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Insert Tool")
                .font(.caption)
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
                .onChange(of: state.selectedIndex) { newIndex in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
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
                    .font(.caption)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.definition.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isSelected ? .white : theme.primaryText)
                    
                    Text(tool.definition.description.split(separator: "\n").first ?? "")
                        .font(.caption)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                
                // Add an indicator showing the source (Local vs MCP)
                Text(tool.source.serverName)
                    .font(.system(size: 9))
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
