// DevgenticApp.swift
import SwiftUI

@main
struct DevgenticApp: App {
    // Use NSApplicationDelegateAdaptor to connect AppDelegate
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            // Your existing MainApplicationView setup
            MainApplicationView()
                // Add frame modifiers if needed here
        }
        // Remove .windowStyle(.hiddenTitleBar) if you haven't already
        // Add any commands or other scene modifiers here
        .commands {
            // Example: Keep existing commands if any
            // CommandGroup(replacing: .newItem) { }
        }

        // --- Add Settings Scene (Optional but good practice) ---
        // If you want a dedicated settings window accessible via Cmd+,
        // Settings {
        //     SettingsView() // You'd create a dedicated SettingsView
        // }
    }
}
