//
//  DevgenticApp.swift
//  Devgentic
//
//  Created by Raj Singh on 15/04/25.
//

import SwiftUI

@main
struct DevgenticApp: App {
    // Use NSApplicationDelegateAdaptor to connect AppDelegate
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Use @AppStorage to track onboarding completion status, defaulting to false
    @AppStorage(SettingsKeys.isOnboardingComplete) private var isOnboardingComplete: Bool = false
    
    // Environment variable to open new windows
    @Environment(\.openWindow) var openWindow

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            if isOnboardingComplete {
                MainApplicationView()
            } else {
                OnboardingRootView {
                    isOnboardingComplete = true
                }
            }
        }
        .commands {
            CommandMenu("File") {
                Button("Close File Viewer Window") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            // Add a command to open Settings/Command Centre
            CommandGroup(after: .appInfo) { // Or another appropriate placement
                Button("Command Centre...") {
                    openWindow(id: "command-centre")
                }
                .keyboardShortcut(",", modifiers: .command) // Standard shortcut for settings/preferences
            }
        }

        // MARK: - File Viewer Window
        WindowGroup("File Viewer", id: "file-viewer-window", for: URL.self) { $fileURL in
            if let url = fileURL {
                FileViewerWindowView(fileURL: url)
                    .frame(minWidth: 500, idealWidth: 800, maxWidth: .infinity,
                           minHeight: 400, idealHeight: 700, maxHeight: .infinity)
            } else {
                VStack {
                    Text("Error: No file URL provided.")
                        .font(.title)
                    Text("This window cannot display a file without a valid path.")
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(minWidth: 400, minHeight: 200)
            }
        }
        
        // MARK: - Command Centre (Settings) Window
        // Define a new WindowGroup for the Command Centre.
        // It does not take a 'for:' parameter if it doesn't need to be opened with specific data.
        WindowGroup(id: "command-centre") {
            // This is where our new CommandCentreView will go.
            // We'll pass the MainApplicationViewModel as an EnvironmentObject
            // or create/pass a dedicated settings view model if preferred.
            // For now, let's assume MainApplicationViewModel is accessible.
            CommandCentreView()
                .environmentObject(MainApplicationViewModel()) // Or retrieve from where MainApplicationView gets it
                .frame(minWidth: 700, idealWidth: 800, minHeight: 700, idealHeight: 800) // Set a suitable default size
        }
    }
}
