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
    func showEditor(text: Binding<String>, botName: String) {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.contentView = NSHostingView(rootView: SimplePromptEditorView(text: text, botName: botName))
            existingWindow.title = "System Instructions: \(botName)"
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let editorView = SimplePromptEditorView(text: text, botName: botName)
        
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
        newWindow.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98)

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
    
    // Local state to drive real-time UI updates in the detached window
    @State private var localText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("System Instructions")
                        .font(.headline)
                    Text("Defines the core persona and behavior for \(botName).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text("\(localText.count) characters")
                        .font(.subheadline)
                        .monospacedDigit()
                    Text("~ \(localText.count / 4) tokens")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // The Core Editor (Standard SwiftUI TextEditor)
            TextEditor(text: $localText)
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Footer
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Changes sync automatically to the main window.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Done") {
                    SimplePromptWindowManager.shared.closeWindow()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 400, minHeight: 300)
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
