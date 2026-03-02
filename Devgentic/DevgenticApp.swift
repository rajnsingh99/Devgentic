//
//  DevgenticApp.swift
//  Devgentic
//
//  Created by Raj Singh.
//
//  Refactored on 27/08/25 to remove LLM Integration window and commands.
//  Refactored on 27/08/25 to add Backend Profiles window and commands.
//  Updated on 21/02/26 to fix multi-window spawning bug (WindowGroup -> Window).
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

    @StateObject private var mainApplicationViewModel: MainApplicationViewModel
    @StateObject private var chatHistoryViewModel: ChatHistoryViewModel

    init() {
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
            fileProcessorService: fileProcessor,
            activeStreamManager: streamManager,
            chatHistoryViewModel: chatHistoryVM
        )

        self._chatHistoryViewModel = StateObject(wrappedValue: chatHistoryVM)
        self._mainApplicationViewModel = StateObject(wrappedValue: mainVM)

        // Start background RAG indexing service (processes chat messages into vector embeddings)
        // Skip during unit tests to prevent ObjectBox/CoreData initialization crashes
//        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
//            RAGIndexingService.shared.start()
//        }
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            MainApplicationView()
                .environmentObject(themeManager)
                .environmentObject(mainApplicationViewModel)
                .environmentObject(mainApplicationViewModel.explorerViewModel)
                .environmentObject(chatHistoryViewModel)
                .environment(\.managedObjectContext, coreDataService.persistentContainer.viewContext)
        }
        .commands {
            CommandMenu("File") {
                Button("Close File Viewer Window") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Input") {
                Button("Toggle Voice Input") {
                    NotificationCenter.default.post(
                        name: GlobalConstants.toggleVoiceInputNotification,
                        object: nil
                    )
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
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
                
                Button("Backend Profiles...") {
                    // Safe AppKit check to bring to front if already open
                    if let profileWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "backend-profiles" }) {
                        profileWindow.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "backend-profiles")
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        // MARK: - Settings Window
        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(mainApplicationViewModel)
                .environmentObject(themeManager)
        }.defaultSize(width: 1000, height: 850)

        // MARK: - Window Groups
        WindowGroup("File Viewer", id: "file-viewer-window", for: URL.self) { $fileURL in
            if let url = fileURL {
                FileWindowViewer(fileURL: url)
                    .environmentObject(themeManager)
            }
        }
        
        // MARK: - AI Blueprints Window
        // CHANGED: From `WindowGroup` to `Window` to enforce a single-instance lifecycle
        Window("AI Blueprints", id: "backend-profiles") {
            BackendProfilePanelView()
                .environmentObject(mainApplicationViewModel)
                .environmentObject(themeManager)
        }.defaultSize(width: 850, height: 700)
    }
}
