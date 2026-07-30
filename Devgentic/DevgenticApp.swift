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
                // Cross-launch download history (Ollama / MLX / Whisper)
                DownloadRecord.self,
                // Workflow persistence (migrated from UserDefaults)
                WorkflowLayoutSD.self,
                WorkflowRunRecordSD.self,
                // Code Viewer per-conversation tab sessions
                CodeViewerSessionSD.self,
            ])
            let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let storeURL = appSupportURL.appendingPathComponent("DevgenticSD.store")
            let config = ModelConfiguration("DevgenticSD", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            // Success counterpart to the fatal path below — the first launch after a schema
            // change is exactly when someone needs to see that the store opened cleanly.
            DGLogger(category: "DevgenticApp").info(
                "[STARTUP] SwiftData container opened — \(schema.entities.count) entities, store: \(storeURL.path)"
            )
            // Inject into singleton stores so non-SwiftUI code can access the container.
            BackendProfileStore.shared.configureContainer(container)
            MCPToolStore.shared.configureContainer(container)
            PromptStore.shared.configureContainer(container)
            ChatPersistenceStore.shared.configureContainer(container)
            WorkflowLayoutStore.shared.configureContainer(container)
            WorkflowRunHistoryStore.shared.configureContainer(container)
            CodeViewerSessionStore.shared.configureContainer(container)
            // Download-history store is configured on the main actor; do it
            // eagerly via Task so reconcileOrphans runs as soon as possible.
            Task { @MainActor in
                DownloadHistoryStore.shared.configureContainer(container)
                DownloadHistoryStore.shared.reconcileOrphans()
                // Any workflow run still in .running at launch is from a prior
                // session that ended before the run could finalize. Flip to
                // .cancelled with "Interrupted" so the history list doesn't
                // show a phantom spinning record forever.
                WorkflowRunHistoryStore.shared.reconcileOrphans()
                // Retired Code Viewer session rows — tabs are in-memory only now.
                CodeViewerSessionStore.shared.purgePersistedSessions()
            }
            return container
        } catch {
            // A store that won't open is almost always a migration failure after an update.
            // The old behaviour — a bare fatalError — gave the user a crash dialog with no
            // cause, no location, and no path forward, and gave support nothing to act on.
            //
            // Deliberately NOT recovering by deleting or moving the store: the file holds
            // every conversation the user has, and silently starting fresh would look
            // exactly like "the app ate my data". Tell them where it is and stop.
            let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("DevgenticSD.store")
            let path = storeURL?.path ?? "Application Support/DevgenticSD.store"
            DGLogger(category: "DevgenticApp").error(
                "[STARTUP] FATAL: SwiftData ModelContainer could not be opened at \(path) — \(error). "
                + "Most likely a schema migration failure after an update. The store was left untouched; "
                + "the app cannot continue without it."
            )
            #if canImport(AppKit)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "Devgentic can't open its database")
            alert.informativeText = String(localized: """
                This usually means the data store couldn't be upgraded after an update.

                Your data has NOT been modified. It's at:
                \(path)

                Please report this with the details below.

                \(error.localizedDescription)
                """)
            alert.addButton(withTitle: String(localized: "Copy Details & Quit"))
            alert.addButton(withTitle: String(localized: "Quit"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("Store: \(path)\nError: \(error)", forType: .string)
            }
            #endif
            exit(EXIT_FAILURE)
        }
    }()

    @State private var themeManager = ThemeManager()

    @State private var mainApplicationViewModel: MainApplicationViewModel
    @State private var chatHistoryViewModel: ChatHistoryViewModel
    @State private var mainViewRouter = MainViewRouter()
    @State private var backendProfileService = BackendProfileService()
    @State private var toastManager = ToastManager()
    @State private var codeSessionManager = CodeSessionManager()
    /// Owns long-lived destination view models (Ollama/MLX stores) so their
    /// state survives the re-creation cascade caused by
    /// `MainApplicationView`'s `if !router.isShowingChat { destinationView }` gate.
    @State private var destinationCoordinator = DestinationCoordinator()
    /// App-scoped so `ChatInputAreaView` recreations (driven by outer SwiftUI
    /// identity churn that isn't trivial to fully eliminate) don't keep firing
    /// `ChatInputViewModel.init()` — which logs, requests mic permission, and
    /// re-subscribes WhisperKit. See `setupMainDelegateObservers()`'s idempotency
    /// guard which makes repeated `.onAppear` wiring safe.
    @State private var chatInputViewModel = ChatInputViewModel()

    init() {
        let persistence = ChatPersistenceStore.shared
        let fileProcessor = FileProcessorService()

        let streamManager = ActiveStreamManager(
            persistenceService: persistence,
            fileProcessorService: fileProcessor
        )

        // The main window owns the Code Viewer: live agent tabs + session persistence.
        // QuickAccess's view model deliberately does not (it mounts no viewer UI).
        let chatHistoryVM = ChatHistoryViewModel(
            persistenceService: persistence,
            activeStreamManager: streamManager,
            ownsCodeViewer: true
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
                .environment(destinationCoordinator)
                .environment(chatInputViewModel)
                .modelContainer(swiftDataContainer)
                .tint(themeManager.currentTheme.accentColor)
                .task {
                    // [QA revival P1a] Hand the AppKit-created QuickAccess panel the shared
                    // object graph so it can stream through the real backend. Use the adaptor
                    // property `appDelegate` — the REAL devgentic.AppDelegate instance. (Do NOT
                    // use AppDelegate.shared here: under @NSApplicationDelegateAdaptor,
                    // NSApplication.shared.delegate is SwiftUI's forwarding wrapper, not our
                    // class, so a cast would trap.)
                    appDelegate.configureQuickAccess(
                        mainAppViewModel: mainApplicationViewModel,
                        themeManager: themeManager
                    )
                }
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
