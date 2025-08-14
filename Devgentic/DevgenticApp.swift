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
    
    // --- THEME MANAGER ---
    // Create the ThemeManager as a StateObject to keep it alive for the app's lifecycle.
    @StateObject private var themeManager = ThemeManager()
    
    // Create the persistent stores as StateObjects first.
    @StateObject private var llmIntegrationStore: LLMIntegrationStore
    @StateObject private var agentStore = AgentStore()
    @StateObject private var agentManager = AgentManager()
    @StateObject private var toolStore = ToolStore()

    // MARK: - The single, shared MainApplicationViewModel instance
    @StateObject private var mainApplicationViewModel: MainApplicationViewModel
    @StateObject private var chatHistoryViewModel: ChatHistoryViewModel // NEW: Add ChatHistoryViewModel as StateObject

    init() {
        // Create the stores that will be passed to the view model
        let integrationStore = LLMIntegrationStore()
        let agStore = AgentStore()
        let chatHistoryVM = ChatHistoryViewModel() // Initialize ChatHistoryViewModel here

        let viewModel = MainApplicationViewModel(
            llmIntegrationStore: integrationStore,
            agentStore: agStore,
            chatHistoryViewModel: chatHistoryVM // Pass chatHistoryVM to MainApplicationViewModel
        )
        
        // Initialize the StateObjects
        self._llmIntegrationStore = StateObject(wrappedValue: integrationStore)
        self._agentStore = StateObject(wrappedValue: agStore)
        self._chatHistoryViewModel = StateObject(wrappedValue: chatHistoryVM) // Initialize _chatHistoryViewModel
        self._mainApplicationViewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            if isOnboardingComplete {
                MainApplicationView()
                    // --- Inject all the necessary environment objects ---
                    .environmentObject(themeManager) // Inject the theme manager
                    .environmentObject(mainApplicationViewModel)
                    .environmentObject(mainApplicationViewModel.explorerViewModel)
                    .environmentObject(agentManager)
                    .environmentObject(llmIntegrationStore)
                    .environmentObject(agentStore)
                    .environmentObject(toolStore)
                    .environmentObject(chatHistoryViewModel) // NEW: Inject chatHistoryViewModel
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
                .environmentObject(themeManager) // Also inject into onboarding
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
                Button("Settings...") {
                    if let settingsWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
                        settingsWindow.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "settings")
                    }
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

        // MARK: - Settings Window
        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(mainApplicationViewModel)
                .environmentObject(themeManager)
        }.defaultSize(width: 1000, height: 850)

        // MARK: - Window Groups (Unchanged)
        WindowGroup("File Viewer", id: "file-viewer-window", for: URL.self) { $fileURL in
            if let url = fileURL {
                FileWindowViewer(fileURL: url)
                    .environmentObject(themeManager) // Inject theme manager into separate windows
            }
        }
        WindowGroup("LLM Provider", id: "llm-integrations") {
            LLMIntegrationsView()
                .environmentObject(mainApplicationViewModel)
                .environmentObject(llmIntegrationStore)
                .environmentObject(themeManager) // Inject theme manager
        }.defaultSize(width: 850, height: 700)
        
        WindowGroup("Agent Configuration", id: "agent-config", for: UUID.self) { $agentID in
            AgentProfilerView()
               .environmentObject(mainApplicationViewModel)
               .environmentObject(toolStore)
               .environmentObject(themeManager) // Inject theme manager
        }.defaultSize(width: 850, height: 700)
    }
}
