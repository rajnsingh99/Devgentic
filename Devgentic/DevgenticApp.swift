//
//  DevgenticApp.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import CoreData

@main
struct DevgenticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(GlobalConstants.isOnboardingComplete) private var isOnboardingComplete: Bool = false
    @Environment(\.openWindow) var openWindow
    
    private let coreDataService = CoreDataPersistenceService.shared
    
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var llmIntegrationStore: LLMIntegrationStore
    @StateObject private var agentManager = AgentManager()

    @StateObject private var mainApplicationViewModel: MainApplicationViewModel
    @StateObject private var chatHistoryViewModel: ChatHistoryViewModel

    init() {
        let integrationStore = LLMIntegrationStore()
        let persistence = CoreDataPersistenceService.shared
        let fileProcessor = FileProcessorService()

        let streamManager = ActiveStreamManager(
            persistenceService: persistence,
            fileProcessorService: fileProcessor
        )

        let chatHistoryVM = ChatHistoryViewModel(
            persistenceService: persistence,
            activeStreamManager: streamManager
        )

        let mainVM = MainApplicationViewModel(
            persistenceService: persistence,
            llmIntegrationStore: integrationStore,
            fileProcessorService: fileProcessor,
            activeStreamManager: streamManager,
            chatHistoryViewModel: chatHistoryVM
        )

        self._llmIntegrationStore = StateObject(wrappedValue: integrationStore)
        self._chatHistoryViewModel = StateObject(wrappedValue: chatHistoryVM)
        self._mainApplicationViewModel = StateObject(wrappedValue: mainVM)
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            if isOnboardingComplete {
                MainApplicationView()
                    .environmentObject(themeManager)
                    .environmentObject(mainApplicationViewModel)
                    .environmentObject(mainApplicationViewModel.explorerViewModel)
                    .environmentObject(agentManager)
                    .environmentObject(llmIntegrationStore)
                    .environmentObject(chatHistoryViewModel)
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
                .environmentObject(themeManager)
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
                    .environmentObject(themeManager)
            }
        }
        WindowGroup("Profile Configuration", id: "llm-integrations") {
            BackendProfilePanelView()
                .environmentObject(mainApplicationViewModel)
                .environmentObject(llmIntegrationStore)
                .environmentObject(themeManager)
        }.defaultSize(width: 850, height: 700)    }
}
