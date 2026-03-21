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
import UserNotifications

@main
struct DevgenticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(GlobalConstants.isOnboardingComplete) private var isOnboardingComplete: Bool = false
    @Environment(\.openWindow) var openWindow  // Retained for File Viewer window
    
    private let coreDataService = CoreDataPersistenceService.shared
    
    @StateObject private var themeManager = ThemeManager()

    @StateObject private var mainApplicationViewModel: MainApplicationViewModel
    @StateObject private var chatHistoryViewModel: ChatHistoryViewModel
    @StateObject private var mainViewRouter = MainViewRouter()
    @StateObject private var backendProfileService = BackendProfileService()

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

        // MARK: - Notification system bootstrap
        // Register the local delivery channel with the dispatcher so tasks can
        // fire macOS system notifications on completion.
        Task {
            let channel = LocalNotificationChannel()
            await NotificationDispatcher.shared.register(channel)
        }

        // MARK: - Scheduler bootstrap
        // Load persisted tasks and arm their timers so recurring / one-shot tasks
        // survive an app restart without needing any user interaction.
        Task { @MainActor in
            SchedulerService.shared.mainViewModel = mainVM
            SchedulerService.shared.loadAllTasks()
            SchedulerService.shared.rescheduleAll()
        }
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            MainApplicationView()
                .environmentObject(themeManager)
                .environment(\.appTheme, themeManager.currentTheme)
                .environmentObject(mainApplicationViewModel)
                .environmentObject(mainApplicationViewModel.explorerViewModel)
                .environmentObject(chatHistoryViewModel)
                .environmentObject(mainViewRouter)
                .environmentObject(backendProfileService)
                .environment(\.managedObjectContext, coreDataService.persistentContainer.viewContext)
                .tint(themeManager.currentTheme.accentColor)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Catch up any scheduled tasks that fired while the app was in the background.
                    SchedulerService.shared.evaluateAndFireDueTasks()
                }
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
                    mainViewRouter.navigateToSettings(.general)
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("Backend Profiles...") {
                    mainViewRouter.navigateToProfile(
                        backendProfileService.profiles.first?.id ?? UUID()
                    )
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        // MARK: - File Viewer Window
        WindowGroup("File Viewer", id: "file-viewer-window", for: URL.self) { $fileURL in
            if let url = fileURL {
                FileWindowViewer(fileURL: url)
                    .environmentObject(themeManager)
                    .environment(\.appTheme, themeManager.currentTheme)
                    .tint(themeManager.currentTheme.accentColor)
            }
        }
    }
}
