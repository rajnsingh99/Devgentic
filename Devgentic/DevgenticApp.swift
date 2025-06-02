// DevgenticApp.swift
import SwiftUI

@main
struct DevgenticApp: App {
    // Use NSApplicationDelegateAdaptor to connect AppDelegate
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Use @AppStorage to track onboarding completion status, defaulting to false
    @AppStorage(SettingsKeys.isOnboardingComplete) private var isOnboardingComplete: Bool = false
    
    // Environment variable to open new windows
    @Environment(\.openWindow) var openWindow
    
    @StateObject var agentManager = AgentManager()
    // Create MainApplicationViewModel as a StateObject to be shared
    // This will use the convenience init() of MainApplicationViewModel
    @StateObject var mainApplicationViewModel = MainApplicationViewModel()

    // MARK: - New: OllamaProfileStore as a StateObject
    @StateObject var ollamaProfileStore = OllamaProfileStore()

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            if isOnboardingComplete {
                MainApplicationView()
                    .environmentObject(agentManager) // Make agentManager available to MainApp
                    .environmentObject(mainApplicationViewModel) // Inject MainApplicationViewModel
                    .environmentObject(ollamaProfileStore) // Inject OllamaProfileStore
                    .onAppear {
                        // When MainApplicationView appears and onboarding is complete,
                        // ensure agent starts if not already running.
                        // AppDelegate handles initial launch, this is a fallback/re-check.
                        agentManager.startAgentIfNeeded()
                    }
            } else {
                AgentOnboardingRootView(
                    onComplete: {
                        isOnboardingComplete = true
                    },
                    onAgentReady: { agentURL, agentPID in
                        // TODO: Reconcile venvPythonPath data flow as noted in the original code.
                        let placeholderVenvPath = ""
                        print("WARNING: Using placeholder for venvPythonPath in DevgenticApp.onAgentReady. This needs to be fixed by updating AgentOnboardingRootView's onAgentReady signature.")
                        agentManager.onboardingDidComplete(
                            agentURL: agentURL,
                            agentPID: agentPID,
                            venvPythonPath: placeholderVenvPath
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
            CommandGroup(after: .appInfo) {
                Button("Command Centre...") {
                    openWindow(id: "command-centre")
                }
                .keyboardShortcut(",", modifiers: .command)

                // MARK: - New: Menu item to open Ollama Profiles window
                Button("Ollama Profiles...") {
                    openWindow(id: "ollama-profiles")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift]) // Example shortcut
            }
            CommandGroup(replacing: .appTermination) {
                Button("Stop Agent and Quit") {
                    agentManager.stopAgent(reason: "Manual Quit Command")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApplication.shared.terminate(nil)
                    }
                }
                .keyboardShortcut("q", modifiers: [.command, .option])
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
                .environmentObject(mainApplicationViewModel) // Inject the shared MainApplicationViewModel
                .environmentObject(agentManager) // agentManager is already correctly passed
                .environmentObject(ollamaProfileStore) // Inject OllamaProfileStore
                .frame(minWidth: 700, idealWidth: 800, minHeight: 700, idealHeight: 800)
        }

        // MARK: - New: Ollama Profiles Window
        WindowGroup(id: "ollama-profiles") {
            OllamaProfilesView()
                .environmentObject(ollamaProfileStore) // Inject OllamaProfileStore
                .environmentObject(mainApplicationViewModel) // Still needed for OllamaService in LocalAISettingsView for now
                .frame(minWidth: 700, idealWidth: 900, minHeight: 700, idealHeight: 800)
        }
    }
}
