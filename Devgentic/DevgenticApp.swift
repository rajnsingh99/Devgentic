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
    
    // Create the persistent stores as StateObjects first.
    @StateObject private var ollamaProfileStore = OllamaProfileStore()
    @StateObject private var agentStore = AgentStore()
    @StateObject private var agentManager = AgentManager()

    // MARK: - The single, shared MainApplicationViewModel instance
    // It is initialized with the stores, and internally uses the OllamaService.shared singleton.
    @StateObject private var mainApplicationViewModel: MainApplicationViewModel

    init() {
        // Create the stores that will be passed to the view model
        let profileStore = OllamaProfileStore()
        let agStore = AgentStore()
        
        // MARK: - Step 3 Change: Initialize the view model correctly
        // The viewModel now uses OllamaService.shared internally.
        let viewModel = MainApplicationViewModel(
            ollamaProfileStore: profileStore,
            agentStore: agStore
        )
        
        // Initialize the StateObjects
        self._ollamaProfileStore = StateObject(wrappedValue: profileStore)
        self._agentStore = StateObject(wrappedValue: agStore)
        self._mainApplicationViewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            if isOnboardingComplete {
                MainApplicationView()
                    // Inject the main view model, which contains all necessary services and stores.
                    .environmentObject(mainApplicationViewModel)
                    .environmentObject(agentManager)
                    .environmentObject(ollamaProfileStore) // Kept for views that might need it directly
                    .environmentObject(agentStore)       // Kept for views that might need it directly
                    .onAppear {
                        agentManager.startAgentIfNeeded()
                    }
            } else {
                AgentOnboardingRootView(
                    onComplete: { isOnboardingComplete = true },
                    onAgentReady: { agentURL, agentPID in
                        // This placeholder logic remains from the original file.
                        // A more robust solution would pass the correct python path.
                        let placeholderVenvPath = ""
                        agentManager.onboardingDidComplete(
                            agentURL: agentURL,
                            agentPID: agentPID,
                            venvPythonPath: placeholderVenvPath
                        )
                    }
                )
                .environmentObject(agentManager)
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

                Button("Ollama Profiles...") {
                    openWindow(id: "ollama-profiles")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
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
            } else {
                Text("Error: No file URL provided.")
            }
        }
        
        // MARK: - Command Centre (Settings) Window
        WindowGroup(id: "command-centre") {
            CommandCentreView()
                .environmentObject(mainApplicationViewModel)
                .environmentObject(agentManager)
                .environmentObject(ollamaProfileStore)
        }

        // MARK: - Ollama Profiles Window (FIXED)
        // Added the title "Ollama Profiles" to the WindowGroup initializer.
        WindowGroup("Ollama Profiles", id: "ollama-profiles") {
            OllamaProfilesView()
                .environmentObject(mainApplicationViewModel)
                .environmentObject(ollamaProfileStore)
        }
        
        // MARK: - Agent Settings Window
        // Updated to handle nil agentID correctly for direct window opening.
        WindowGroup("Agent Settings", id: "agent-settings", for: UUID.self) { $agentID in
            AgentProfiler(initialAgentID: $agentID.wrappedValue)
               .environmentObject(mainApplicationViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 600)
    }
}
