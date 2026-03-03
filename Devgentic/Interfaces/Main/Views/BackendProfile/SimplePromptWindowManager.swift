//
//  SimplePromptEditor.swift
//  Devgentic
//
//  Created for Bot Instructions Integration.
//

import SwiftUI
import AppKit

// MARK: - Window Manager

/// Manages a floating, detached NSWindow for the simple prompt editor (used by Bots).
class SimplePromptWindowManager {
    static let shared = SimplePromptWindowManager()
    private var window: NSWindow?

    /// Spawns or brings the editor window to the front.
    func showEditor(text: Binding<String>, botName: String, theme: Theme) {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.contentView = NSHostingView(
                rootView: SimplePromptEditorView(text: text, botName: botName)
                    .environment(\.appTheme, theme)
            )
            existingWindow.title = "System Instructions: \(botName)"
            existingWindow.backgroundColor = NSColor(theme.primaryBackground)
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let editorView = SimplePromptEditorView(text: text, botName: botName)
            .environment(\.appTheme, theme)
        
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
}

// MARK: - Editor UI

struct SimplePromptEditorView: View {
    @Binding var text: String
    var botName: String
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
                        .foregroundColor(theme.primaryText)
                    Text("Defines the core persona and behavior for \(botName).")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("\(localText.count) characters")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundColor(theme.primaryText)
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

            // The Core Editor (Standard SwiftUI TextEditor)
            TextEditor(text: $localText)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .disableAutocorrection(true)
                .padding(8)
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
                    SimplePromptWindowManager.shared.closeWindow()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(theme.secondaryBackground)
        }
        .frame(minWidth: 400, minHeight: 300)
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
