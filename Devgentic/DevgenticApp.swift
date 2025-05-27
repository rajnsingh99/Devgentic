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
    
    // agentManager is also initialized in AppDelegate.
    // For a single source of truth, AppDelegate's instance should ideally be used.
    // One way is for AppDelegate to expose its AgentManager instance,
    // or use a shared singleton pattern if appropriate.
    // For this example, we assume this @StateObject is primary for the views it's passed to,
    // and AppDelegate's instance handles app lifecycle events.
    // The crucial part is that the SAME AgentManager instance receives the onboardingDidComplete call.
    // If AppDelegate.agentManager is the true source, then that instance should be updated.
    // Assuming for now this agentManager instance is the one intended to be updated by onboarding UI.
    @StateObject var agentManager = AgentManager()
    
    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
                    if isOnboardingComplete {
                        MainApplicationView()
                            .environmentObject(agentManager) // Make agentManager available to MainApp
                            .onAppear {
                                // When MainApplicationView appears and onboarding is complete,
                                // ensure agent starts if not already running.
                                // AppDelegate handles initial launch, this is a fallback/re-check.
                                agentManager.startAgentIfNeeded()
                            }
                    } else {
                        AgentOnboardingRootView(
                            onComplete: {
                                // This closure is called by AgentOnboardingViewModel.completeOnboarding()
                                // AFTER it has called its own onAgentReady.
                                isOnboardingComplete = true
                                // AgentManager should have been notified by onAgentReady already.
                            },
                            // The onAgentReady callback signature is changed to 2 arguments
                            // to match the compiler error: "Contextual closure type '(URL, Int32) -> Void' expects 2 arguments"
                            onAgentReady: { agentURL, agentPID in // venvPythonPathString removed from here
                                // This callback is invoked from AgentOnboardingViewModel.completeOnboarding()
                                // after the agent has been successfully launched and reported its details.
                                
                                // TODO: The venvPythonPathString is no longer passed via this closure due to the
                                // AgentOnboardingRootView.onAgentReady expecting only (URL, Int32).
                                // The AgentManager.onboardingDidComplete method requires venvPythonPath.
                                // This data flow needs to be reconciled. For now, passing an empty string.
                                // The ideal fix is to update AgentOnboardingRootView's onAgentReady to accept (URL, Int32, String).
                                let placeholderVenvPath = "" // Placeholder
                                print("WARNING: Using placeholder for venvPythonPath in DevgenticApp.onAgentReady. This needs to be fixed by updating AgentOnboardingRootView's onAgentReady signature.")

                                agentManager.onboardingDidComplete(
                                    agentURL: agentURL,
                                    agentPID: agentPID,
                                    venvPythonPath: placeholderVenvPath // Using placeholder
                                )
                            }
                        )
                        .environmentObject(agentManager) // Onboarding might also want to show agent status
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
            
            CommandGroup(replacing: .appTermination) { // Example placement
                             Button("Stop Agent and Quit") {
                                 agentManager.stopAgent(reason: "Manual Quit Command")
                                 // Allow some time for agent to stop before terminating
                                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                     NSApplication.shared.terminate(nil)
                                 }
                             }
                             .keyboardShortcut("q", modifiers: [.command, .option]) // Example shortcut
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
        WindowGroup(id: "command-centre") {
            CommandCentreView()
                // Ensure MainApplicationViewModel is correctly instantiated or passed if needed by CommandCentreView
                // .environmentObject(MainApplicationViewModel()) // Placeholder
                .environmentObject(agentManager) // Pass agentManager if CommandCentre needs it
                .frame(minWidth: 700, idealWidth: 800, minHeight: 700, idealHeight: 800)
        }
    }
}

// Assuming SettingsKeys is defined elsewhere, e.g., in AgentManager.swift or a shared constants file.
// struct SettingsKeys {
//     static let isOnboardingComplete = "isOnboardingComplete"
//     // Add other keys as needed
// }

// Assuming AppDelegate is defined. It might also have an AgentManager instance.
// Ensure consistency in which AgentManager instance is used and updated.
// class AppDelegate: NSObject, NSApplicationDelegate {
//     var agentManager = AgentManager()
//
//     func applicationDidFinishLaunching(_ notification: Notification) {
//         if UserDefaults.standard.bool(forKey: SettingsKeys.isOnboardingComplete) {
//             agentManager.startAgentIfNeeded()
//         }
//     }
//
//     func applicationWillTerminate(_ notification: Notification) {
//         agentManager.stopAgent(reason: "Application Will Terminate")
//     }
// }
