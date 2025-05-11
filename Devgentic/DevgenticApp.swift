// DevgenticApp.swift
import SwiftUI

@main
struct DevgenticApp: App {
    // Use NSApplicationDelegateAdaptor to connect AppDelegate
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Use @AppStorage to track onboarding completion status, defaulting to false
    // It reads/writes the value associated with SettingsKeys.isOnboardingComplete in UserDefaults
    @AppStorage(SettingsKeys.isOnboardingComplete) private var isOnboardingComplete: Bool = false

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            // --- Conditional Root View ---
            // Check the onboarding status flag
            if isOnboardingComplete {
                // If onboarding is complete, show the main application view
                MainApplicationView() // Ensure this view is defined correctly
                    // Add necessary environment objects or frame modifiers if needed
                    // Example: .environmentObject(MainApplicationViewModel())
                    // Example: .frame(minWidth: 800, minHeight: 600)

            } else {
                // If onboarding is not complete, show the onboarding flow
                OnboardingRootView {
                    // This closure is passed to OnboardingRootView
                    // It will be called when the onboarding flow signals completion.
                    // Setting this flag to true updates @AppStorage, saves to UserDefaults,
                    // and triggers SwiftUI to re-evaluate the condition above,
                    // replacing OnboardingRootView with MainApplicationView.
                    isOnboardingComplete = true
                }
                // Optional: Set a default/min/max size for the onboarding window
                // .frame(width: 500, height: 400)
            }
            // --- End Conditional Root View ---
        }
        // Keep existing commands if any
        .commands {
            // CommandGroup(replacing: .newItem) { }
            // You can add app-specific commands here, for example, for the file viewer window
            CommandMenu("File") { // Example: Adding a "Close" command to the File menu
                Button("Close File Viewer Window") {
                    // This is a generic way to try and close the key window.
                    // Specific window closing might need more targeted logic if multiple windows are key.
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command) // Standard shortcut for close window
            }
        }

        // MARK: - File Viewer Window
        // This new WindowGroup will handle opening files in a separate, resizable window.
        WindowGroup("File Viewer", id: "file-viewer-window", for: URL.self) { $fileURL in
            // $fileURL is an optional binding to the URL passed when openWindow(id:value:) is called.
            if let url = fileURL {
                // FileViewerWindowView is the new view we will create in Phase 2.
                // It will be responsible for loading and displaying the content of the given URL.
                FileViewerWindowView(fileURL: url)
                    .frame(minWidth: 500, idealWidth: 800, maxWidth: .infinity,
                           minHeight: 400, idealHeight: 700, maxHeight: .infinity)
                    // You might want to set a default title for the window here,
                    // or have FileViewerWindowView set its own title dynamically.
                    // .navigationTitle(url.lastPathComponent) // Example if FileViewerWindowView is in a NavigationView
            } else {
                // Fallback content if for some reason the URL is nil when the window is opened.
                // This case should ideally not be hit if openWindow is called correctly with a valid URL.
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
        // You can customize the default behavior of this window group
        // .defaultSize(width: 800, height: 700)
        // .windowResizability(.automatic) // .automatic or .contentSize
        // .windowStyle(.documentBrowser) // Or .plain, .titleBar, etc. depending on desired look

        // Optional: Settings scene if you have one
        // Settings {
        //     SettingsView() // Use your dedicated SettingsView
        // }
    }
}
