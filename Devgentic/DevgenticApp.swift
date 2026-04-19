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
import SwiftData
import UserNotifications

@main
struct DevgenticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(GlobalConstants.isOnboardingComplete) private var isOnboardingComplete: Bool = false
    @Environment(\.openWindow) var openWindow  // Retained for File Viewer window

    /// Unified SwiftData container for all subsystems (profiles, chat, scheduling, etc.).
    private let swiftDataContainer: ModelContainer = {
        do {
            let schema = Schema([
                BackendProfile.self,
                MCPToolItem.self,
                MCPToolDefinitionModel.self,
                PromptModel.self,
                ScheduledTaskModel.self,
                // Chat persistence (migrated from CoreData)
                ConversationSD.self,
                ChatMessageSD.self,
                AttachedTextFileSD.self,
                AttachedImageFileSD.self,
            ])
            let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeURL = appSupportURL.appendingPathComponent("DevgenticSD.store")
            let config = ModelConfiguration("DevgenticSD", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            // Inject into singleton stores so non-SwiftUI code can access the container.
            BackendProfileStore.shared.configureContainer(container)
            MCPToolStore.shared.configureContainer(container)
            PromptStore.shared.configureContainer(container)
            ChatPersistenceStore.shared.configureContainer(container)
            return container
        } catch {
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }
    }()

    @State private var themeManager = ThemeManager()

    @State private var mainApplicationViewModel: MainApplicationViewModel
    @State private var chatHistoryViewModel: ChatHistoryViewModel
    @State private var mainViewRouter = MainViewRouter()
    @State private var backendProfileService = BackendProfileService()
    @State private var toastManager = ToastManager()
    @State private var codeSessionManager = CodeSessionManager()

    init() {
        let persistence = ChatPersistenceStore.shared
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

        self._chatHistoryViewModel = State(wrappedValue: chatHistoryVM)
        self._mainApplicationViewModel = State(wrappedValue: mainVM)

        // Late-inject CodeSessionManager so the VM can build ephemeral profiles on send.
        let csm = self._codeSessionManager.wrappedValue
        mainVM.configureCodeSession(csm)

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
        let sdContainer = swiftDataContainer
        Task { @MainActor in
            SchedulerService.shared.configureContainer(sdContainer)
            SchedulerService.shared.mainViewModel = mainVM
            SchedulerService.shared.loadAllTasks()
            SchedulerService.shared.rescheduleAll()
        }
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            MainApplicationView()
                .environment(themeManager)
                .environment(\.appTheme, themeManager.currentTheme)
                .environment(mainApplicationViewModel)
                .environment(mainApplicationViewModel.explorerViewModel)
                .environment(chatHistoryViewModel)
                .environment(mainViewRouter)
                .environment(backendProfileService)
                .environment(toastManager)
                .environment(codeSessionManager)
                .modelContainer(swiftDataContainer)
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
                        backendProfileService.profiles.first?.id ?? UUID(),
                        activatingBufferOn: backendProfileService
                    )
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                // Phase E — Trends dashboard. Requires developer mode (gated internally
                // by TrendsView itself). Listed here so developers can discover it via
                // the app menu; the shortcut avoids collisions with standard macOS ones.
                Button("Observability Trends...") {
                    openWindow(id: "trends-window")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift, .option])
            }
        }

        // MARK: - File Viewer Window
        WindowGroup("File Viewer", id: "file-viewer-window", for: URL.self) { $fileURL in
            if let url = fileURL {
                FileWindowViewer(fileURL: url)
                    .environment(themeManager)
                    .environment(\.appTheme, themeManager.currentTheme)
                    .tint(themeManager.currentTheme.accentColor)
            }
        }

        // MARK: - Trends Dashboard (Phase E)
        // Developer-facing window showing per-tool reliability, per-category error
        // frequency, per-model outcomes, and circuit-breaker stats. Reads from the
        // TraceStore live (no pre-aggregation). Gated internally on developerMode;
        // non-devs see a "turn on developer mode to unlock" placeholder.
        Window("Observability Trends", id: "trends-window") {
            TrendsView()
                .environment(themeManager)
                .environment(\.appTheme, themeManager.currentTheme)
                .frame(minWidth: 760, minHeight: 560)
                .tint(themeManager.currentTheme.accentColor)
        }
        .windowResizability(.contentSize)
    }

    /// Removes legacy CoreData SQLite files (DevgenticDB) from Application Support.
    /// Safe to call multiple times — no-ops if files are already gone.
    private static func cleanupLegacyCoreDataStore() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        for suffix in ["", "-wal", "-shm"] {
            let file = appSupport.appendingPathComponent("DevgenticDB.sqlite\(suffix)")
            try? FileManager.default.removeItem(at: file)
        }
    }
}
