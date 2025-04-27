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
        }

        // Optional: Settings scene if you have one
        // Settings {
        //     SettingsView() // Use your dedicated SettingsView
        // }
    }
}

