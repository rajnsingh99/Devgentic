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
    
    @StateObject var agentManager = AgentManager() // AppDelegate also creates one, decide on single source of truth.
                                                     // For simplicity, let's assume AppDelegate's instance is primary for lifecycle,
                                                     // and this one is for UI if needed. Or better, have AppDelegate expose its instance.
                                                     // For now, we'll pass the callback to the onboarding view model.
    
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
                                // We can still call startAgentIfNeeded here to be sure or if MainUI needs it.
                                // agentManager.startAgentIfNeeded() // Or let MainApplicationView's onAppear handle it.
                            },
                            onAgentReady: { agentURL, agentPID in
                                // This callback is now part of AgentOnboardingViewModel's init.
                                // It's called from AgentOnboardingViewModel.completeOnboarding().
                                // The AgentManager instance in AppDelegate can be notified here,
                                // or the AgentOnboardingViewModel can directly call a method on a shared AgentManager.
                                // For now, AgentManager's init and onboardingDidComplete handle this.
                                // This specific callback to DevgenticApp might be redundant if AgentManager
                                // is robustly handling its state from UserDefaults and its own notifications.
                                // However, explicitly calling onboardingDidComplete on the shared manager is good.
                                agentManager.onboardingDidComplete(agentURL: agentURL, agentPID: agentPID)
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
                                 NSApplication.shared.terminate(nil)
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
