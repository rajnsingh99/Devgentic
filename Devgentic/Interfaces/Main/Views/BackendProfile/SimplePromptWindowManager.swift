// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
import os

private let logger = DGLogger(category: "SimplePromptWindow")

// MARK: - Window Manager

/// Manages a single floating NSWindow for the simple prompt editor. One
/// instance per consuming view. The class is `@MainActor` because every
/// AppKit touch must happen on the main thread.
///
/// ⚠️ An `NSObject` subclass and its own `NSWindowDelegate` (register A71). Closing the window with
/// the red button does NOT route through `closeWindow()`, and `isReleasedWhenClosed` is false, so
/// `window` stayed pointing at a closed `NSWindow` — which retains its `NSHostingView`, which
/// retains the text binding and the `ThemeManager`. Worse, the next `showEditor` found a non-nil
/// but not-visible window, fell through to the "create a new one" path, and abandoned the old one:
/// a leak per red-button close, for the lifetime of the profile editor.
@MainActor
final class SimplePromptWindowManager: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Spawns or brings the editor window to the front.
    /// ⚠️ `botName` is a BINDING, not a `String` (register A75). The editor lives inside an
    /// `NSHostingView` whose root view is built once, so a plain `String` is frozen at open time —
    /// an `.onChange` on it could never fire. A binding into the `@Observable` draft re-renders the
    /// hosted view exactly the way the existing `text` binding already does.
    func showEditor(
        text: Binding<String>,
        botName: Binding<String>,
        themeManager: ThemeManager,
        contextWindow: Int? = nil
    ) {
        let theme = themeManager.currentTheme

        // ⚠️ register B7 — `isVisible` is FALSE while miniaturized, so minimizing this editor
        // and re-opening it orphaned the old window. A71 fixed the red-button leak here and left
        // the minimize one; the identity guard in `windowWillClose` is what makes it safe.
        if let existingWindow = window {
            existingWindow.contentView = NSHostingView(
                rootView: makeHost(text: text, botName: botName,
                                   themeManager: themeManager, contextWindow: contextWindow)
            )
            existingWindow.title = Self.title(for: botName.wrappedValue)
            existingWindow.backgroundColor = NSColor(theme.primaryBackground)
            if existingWindow.isMiniaturized { existingWindow.deminiaturize(nil) }
            existingWindow.makeKeyAndOrderFront(nil)
            logger.info("[PROFILE] Re-presented the floating prompt editor for '\(botName.wrappedValue)'.")
            return
        }

        // ⚠️ register B7 — A71's orphan branch lived here and is GONE, not silenced. It existed
        // because the reuse test above rejected a non-visible window and fell through with a
        // live one still retained; now the reuse path takes every non-nil window, so reaching
        // this point means `window` is genuinely nil and there is nothing to orphan. The canary
        // it provided moved into `windowWillClose`'s identity check, which is where a stray
        // window can actually still show up.

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        newWindow.center()
        newWindow.title = Self.title(for: botName.wrappedValue)
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = NSHostingView(
            rootView: makeHost(text: text, botName: botName,
                               themeManager: themeManager, contextWindow: contextWindow)
        )
        newWindow.level = .floating
        newWindow.delegate = self

        newWindow.isOpaque = false
        newWindow.backgroundColor = NSColor(theme.primaryBackground).withAlphaComponent(0.98)

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        logger.info("[PROFILE] Opened the floating prompt editor for '\(botName.wrappedValue)' "
                    + "(context window: \(contextWindow.map(String.init) ?? "unknown")).")
    }

    private func makeHost(
        text: Binding<String>,
        botName: Binding<String>,
        themeManager: ThemeManager,
        contextWindow: Int?
    ) -> SimplePromptEditorHost {
        SimplePromptEditorHost(
            themeManager: themeManager,
            text: text,
            botName: botName,
            contextWindow: contextWindow,
            onClose: { [weak self] in self?.closeWindow() },
            // ⚠️ Register A75. `updateTitle` was never wrong — it was never CALLED from the bot
            // editor, so renaming a bot left the detached window advertising the old name. (The
            // scheduler does call it, correctly, which is why this only ever broke in one of the
            // two places.) Driving it from the host's own re-render removes the call site that can
            // be forgotten: keeping the title current stops being the caller's job.
            onTitleChange: { [weak self] newName in self?.updateTitle(botName: newName) }
        )
    }

    func closeWindow() {
        // `window?.close()` triggers `windowWillClose`, which clears the reference and logs.
        window?.close()
        window = nil
    }

    /// Updates the floating window's title without rebuilding the content view (so the editor
    /// keeps focus). No-op when the window isn't open — callers can fire it on every keystroke.
    ///
    /// Still `internal`: `CreateScheduledTaskView` drives it explicitly because its title is a
    /// derived string (with an "unnamed task" fallback), not a plain binding into the draft.
    func updateTitle(botName: String) {
        // ⚠️ register B7 — `isVisible` is false while miniaturized; a rename during that time
        // was dropped and the window resurfaced with a stale title.
        guard let window else { return }
        window.title = Self.title(for: botName)
    }

    private static func title(for botName: String) -> String {
        String(localized: "System Instructions: \(botName)")
    }

    // MARK: - NSWindowDelegate

    /// ⚠️ The whole point of A71. Fires for EVERY close — the red button, ⌘W, the Done button, and
    /// a window closed as the app terminates — so the manager stops retaining a dead window and its
    /// hosting view in all of them.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // ⚠️ register B7 — identity check. Clearing unconditionally meant a close from ANY
            // window this object had been the delegate of dropped the LIVE window's reference,
            // after which its own close went untracked and it leaked for good.
            guard let closing = notification.object as? NSWindow, closing === window else {
                logger.error(
                    "[PROFILE] A prompt-editor window closed that is NOT the one currently tracked. "
                    + "CONSEQUENCE: ignored, so the live editor keeps its window reference; if this "
                    + "appears, an orphan survived the reuse path."
                )
                return
            }
            logger.info("[PROFILE] Floating prompt editor closed; releasing its window and hosting view.")
            closing.delegate = nil
            window = nil
        }
    }
}

// MARK: - Themed Host

/// Wrapper that watches the @Observable ThemeManager and re-applies the
/// `\.appTheme` environment whenever the active theme changes — keeping
/// the floating-window editor in lockstep with the parent app's theme.
private struct SimplePromptEditorHost: View {
    @Bindable var themeManager: ThemeManager
    @Binding var text: String
    @Binding var botName: String
    var contextWindow: Int?
    var onClose: () -> Void
    /// Called when the host re-renders under a new name, so the window title can follow (A75).
    var onTitleChange: (String) -> Void

    var body: some View {
        SimplePromptEditorView(
            text: $text,
            botName: $botName,
            contextWindow: contextWindow,
            onClose: onClose
        )
        .environment(\.appTheme, themeManager.currentTheme)
        .preferredColorScheme(themeManager.currentTheme.colorScheme)
        .onChange(of: botName) { _, newName in onTitleChange(newName) }
    }
}

// MARK: - Editor UI

struct SimplePromptEditorView: View {
    @Binding var text: String
    /// A binding so a profile rename reaches the detached window — see `showEditor`.
    @Binding var botName: String
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
