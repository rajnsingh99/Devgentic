//
//  MainApplicationView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import CoreData

@main
struct DevgenticApp: App {
    // Use NSApplicationDelegateAdaptor to connect AppDelegate
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Use @AppStorage to track onboarding completion status, defaulting to false
    @AppStorage(GlobalConstants.isOnboardingComplete) private var isOnboardingComplete: Bool = false
    
    // Environment variable to open new windows
    @Environment(\.openWindow) var openWindow
    
    // Get the Core Data service singleton.
    private let coreDataService = CoreDataPersistenceService.shared
    
    // Create the persistent stores as StateObjects first.
    @StateObject private var llmIntegrationStore: LLMIntegrationStore
    @StateObject private var agentStore = AgentStore()
    @StateObject private var agentManager = AgentManager()
    @StateObject private var toolStore = ToolStore()

    // MARK: - The single, shared MainApplicationViewModel instance
    @StateObject private var mainApplicationViewModel: MainApplicationViewModel

    init() {
        // Create the stores that will be passed to the view model
        let integrationStore = LLMIntegrationStore()
        let agStore = AgentStore()
        
        let viewModel = MainApplicationViewModel(
            llmIntegrationStore: integrationStore,
            agentStore: agStore
        )
        
        // Initialize the StateObjects
        self._llmIntegrationStore = StateObject(wrappedValue: integrationStore)
        self._agentStore = StateObject(wrappedValue: agStore)
        self._mainApplicationViewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            if isOnboardingComplete {
                MainApplicationView()
                    // --- FIX: Inject all the necessary environment objects ---
                    .environmentObject(mainApplicationViewModel)
                    // This is the crucial line that makes the *same* explorerViewModel
                    // available to all child views.
                    .environmentObject(mainApplicationViewModel.explorerViewModel)
                    .environmentObject(agentManager)
                    .environmentObject(llmIntegrationStore)
                    .environmentObject(agentStore)
                    .environmentObject(toolStore)
                    .environment(\.managedObjectContext, coreDataService.persistentContainer.viewContext)
                    .onAppear {
                        agentManager.startAgentIfNeeded()
                    }
            } else {
                AgentOnboardingRootView(
                    onComplete: { isOnboardingComplete = true },
                    onAgentReady: { agentURL, agentPID in
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
        // ... The rest of your file remains the same ...
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

                Button("LLM Integrations...") {
                    openWindow(id: "llm-integrations")
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

        // MARK: - Window Groups (Unchanged)
        WindowGroup("File Viewer", id: "file-viewer-window", for: URL.self) { $fileURL in
            if let url = fileURL {
                FileWindowViewer(fileURL: url)
            }
        }
        WindowGroup("LLM Provider", id: "llm-integrations") {
            LLMIntegrationsView()
                .environmentObject(mainApplicationViewModel)
                .environmentObject(llmIntegrationStore)
        }.defaultSize(width: 850, height: 700)
        WindowGroup("Agent Configuration", id: "agent-config", for: UUID.self) { $agentID in
            AgentProfilerView()
               .environmentObject(mainApplicationViewModel)
               .environmentObject(toolStore)
        }.defaultSize(width: 850, height: 700)
    }
}
