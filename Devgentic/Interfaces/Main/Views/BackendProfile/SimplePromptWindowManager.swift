//
//  SimplePromptEditor.swift
//  Devgentic
//
//  Floating, detached NSWindow editor for simple prompt text (used by Bots
//  and the scheduler when the selected profile isn't an agent).
//
//  Owned per-call-site as `@State`, NOT a singleton — multiple consumers
//  can keep their own editor open simultaneously and don't trample each
//  other's window state. Theme updates flow live via the injected
//  ThemeManager, so changing the app theme while the window is open
//  re-renders the editor without losing focus.
//

import SwiftUI
import AppKit

// MARK: - Window Manager

/// Manages a single floating NSWindow for the simple prompt editor. One
/// instance per consuming view. The class is `@MainActor` because every
/// AppKit touch must happen on the main thread.
@MainActor
final class SimplePromptWindowManager {
    private var window: NSWindow?

    /// Spawns or brings the editor window to the front.
    func showEditor(
        text: Binding<String>,
        botName: String,
        themeManager: ThemeManager,
        contextWindow: Int? = nil
    ) {
        let theme = themeManager.currentTheme

        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.contentView = NSHostingView(
                rootView: SimplePromptEditorHost(
                    themeManager: themeManager,
                    text: text,
                    botName: botName,
                    contextWindow: contextWindow,
                    onClose: { [weak self] in self?.closeWindow() }
                )
            )
            existingWindow.title = "System Instructions: \(botName)"
            existingWindow.backgroundColor = NSColor(theme.primaryBackground)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let editorView = SimplePromptEditorHost(
            themeManager: themeManager,
            text: text,
            botName: botName,
            contextWindow: contextWindow,
            onClose: { [weak self] in self?.closeWindow() }
        )

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        newWindow.center()
        newWindow.title = "System Instructions: \(botName)"
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

    /// Updates the floating window's title without rebuilding the content
    /// view (so the editor keeps focus). No-op when the window isn't open —
    /// callers can fire this on every name keystroke without checks.
    func updateTitle(botName: String) {
        guard let window, window.isVisible else { return }
        window.title = "System Instructions: \(botName)"
    }
}

// MARK: - Themed Host

/// Wrapper that watches the @Observable ThemeManager and re-applies the
/// `\.appTheme` environment whenever the active theme changes — keeping
/// the floating-window editor in lockstep with the parent app's theme.
private struct SimplePromptEditorHost: View {
    @Bindable var themeManager: ThemeManager
    @Binding var text: String
    var botName: String
    var contextWindow: Int?
    var onClose: () -> Void

    var body: some View {
        SimplePromptEditorView(
            text: $text,
            botName: botName,
            contextWindow: contextWindow,
            onClose: onClose
        )
        .environment(\.appTheme, themeManager.currentTheme)
        .preferredColorScheme(themeManager.currentTheme.colorScheme)
    }
}

// MARK: - Editor UI

struct SimplePromptEditorView: View {
    @Binding var text: String
    var botName: String
    /// Context window size in tokens for the active model. `nil` if unknown.
    var contextWindow: Int?
    var onClose: () -> Void
    @Environment(\.appTheme) private var theme

    // Local state to drive real-time UI updates in the detached window
    @State private var localText: String = ""

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("System Instructions")
                        .font(theme.fontHeadline)
                        .foregroundColor(theme.primaryText)
                    Text("Defines the core persona and behavior for \(botName).")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    let estimatedTokens = max(1, localText.count / 4)
                    Text("~ \(estimatedTokens.formatted()) tokens")
                        .font(theme.fontSubheadline)
                        .monospacedDigit()
                        .foregroundColor(tokenWarningColor(estimatedTokens: estimatedTokens))
                    if let cw = contextWindow {
                        let ratio = Double(estimatedTokens) / Double(cw)
                        Text("\(Int(ratio * 100))% of \(cw.formatted()) context")
                            .font(theme.fontCaption)
                            .foregroundColor(ratio > 0.5 ? theme.errorColor : ratio > 0.25 ? theme.warningColor : theme.secondaryText)
                    }
                }
            }
            .padding()
            .background(theme.primaryBackground)

            Rectangle()
                .fill(theme.dividerColor)
                .frame(height: 1)

            // The Core Editor (Standard SwiftUI TextEditor)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $localText)
                    .font(theme.fontCode)
                    .foregroundColor(theme.primaryText)
                    .disableAutocorrection(true)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(theme.textBackground)

                if localText.isEmpty {
                    Text("Enter system instructions for \(botName) here...")
                        .font(theme.fontCode)
                        .foregroundColor(theme.secondaryText.opacity(0.5))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
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

                Button("Done") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(theme.secondaryBackground)
        }
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            // Initialize local state from the binding
            localText = text
        }
        .onChange(of: localText) { _, newValue in
            // Push changes back to the main app binding
            if text != newValue {
                text = newValue
            }
        }
        .onChange(of: text) { _, newValue in
            // Sync if the text was changed externally while the window is open
            if localText != newValue {
                localText = newValue
            }
        }
    }

    private func tokenWarningColor(estimatedTokens: Int) -> Color {
        guard let cw = contextWindow else { return theme.primaryText }
        let ratio = Double(estimatedTokens) / Double(cw)
        if ratio > 0.5 { return theme.errorColor }
        if ratio > 0.25 { return theme.warningColor }
        return theme.primaryText
    }
}
