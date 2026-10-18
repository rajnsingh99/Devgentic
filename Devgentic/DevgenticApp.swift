// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DevgenticApp.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import SwiftData
import UserNotifications

/// The application entry point: configures the persistence container and declares the app's windows and commands.
@main
struct DevgenticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(GlobalConstants.isOnboardingComplete) private var isOnboardingComplete: Bool = false
    @Environment(\.openWindow) var openWindow  // Retained for File Viewer window
    /// Sparkle. Touched here so the updater starts at launch (its scheduled checks run from the
    /// moment it exists) and so the menu item below tracks `canCheckForUpdates`.
    @ObservedObject private var softwareUpdater = SoftwareUpdater.shared

    /// Unified SwiftData container for all subsystems (profiles, chat, scheduling, etc.).
    private let swiftDataContainer: ModelContainer = {
        do {
            // The entity list lives in `DevgenticSchema` so tests reference the same list the app opens rather than a drifting copy.
            let schema = DevgenticSchema.schema
            let storeURL = try DevgenticSchema.defaultStoreURL()
            let config = ModelConfiguration(DevgenticSchema.configurationName, schema: schema, url: storeURL)
            // A migration plan gives every future schema change a named source version to stage from;
            // with one version and no stages it behaves like `migrationPlan: nil`.
            let container = try ModelContainer(
                for: schema,
                migrationPlan: DevgenticSchema.migrationPlan,
                configurations: config
            )
            // Success counterpart to the fatal path below — the first launch after a schema
            // change is exactly when someone needs to see that the store opened cleanly.
            DGLogger(category: "DevgenticApp").info(
                "[STARTUP] SwiftData container opened — \(schema.entities.count) entities, store: \(storeURL.path)"
            )
            // Decide once, before anything destructive runs, and reuse the value below:
            // `recordSuccessfulOpen()` later writes the fingerprint, so a second evaluation would disagree.
            let launchSweepDecision = DevgenticSchema.evaluateLaunchSweep()

            // Inject into singleton stores so non-SwiftUI code can access the container.
            BackendProfileStore.shared.configureContainer(container)
            MCPToolStore.shared.configureContainer(container)
            PromptStore.shared.configureContainer(container)
            ChatPersistenceStore.shared.configureContainer(container)
            WorkflowLayoutStore.shared.configureContainer(container)
            WorkflowRunHistoryStore.shared.configureContainer(container)
            // Captured before the skill sweep (which can block on a volume mount) so live work is never flipped to Interrupted.
            let launchInstant = Date()
            Task { @MainActor in
                DownloadHistoryStore.shared.configureContainer(container)

                // Configured synchronously, before anything can ask the library for skills: an earlier ask answers
                // `.containerUnavailable`.
                SkillStore.shared.configureContainer(container)

                // Everything below mutates or deletes rows, so it runs only when the schema is unchanged since the last clean open:
                // a lightweight migration can succeed structurally yet degrade data, and a sweep would persist that.
                let startupLogger = DGLogger(category: "DevgenticApp")
                switch launchSweepDecision {
                case .run:
                    // Counts BEFORE the mutations, so a support log shows what was at stake even if
                    // the app dies mid-sweep. The sweeps themselves log what they actually changed.
                    let historyCount = DownloadHistoryStore.shared.totalRecordCount()
                    startupLogger.info(
                        "[STARTUP] Launch sweep RUNNING — schema unchanged since last clean open. "
                        + "Before: \(historyCount) download-history row(s). Will reconcile download "
                        + "orphans, prune history, reconcile workflow-run orphans."
                    )
                    DownloadHistoryStore.shared.reconcileOrphans(startedBefore: launchInstant)
                    // Retention: history is otherwise monotonic for the life of the install, and
                    // every row is scanned on each bridge reconcile and sidebar render.
                    DownloadHistoryStore.shared.pruneOldRecords()
                    // Any workflow run still `.running` at launch belongs to a session that ended before finalizing; flip it to `.cancelled`
                    // with 'Interrupted' so history does not show a phantom spinning record.
                    WorkflowRunHistoryStore.shared.reconcileOrphans(startedBefore: launchInstant)
                    // Conversation memory whose conversation is gone (a crash between the two deletes, or a write that raced one).
                    // Destructive, so gated; the listing throws rather than answering empty, and the sweep refuses an empty list.
                    do {
                        let liveConversations = try ChatPersistenceStore.shared.liveConversationIDs()
                        Task.detached(priority: .utility) {
                            VectorStoreService.shared.removeOrphanedConversations(liveConversationIDs: liveConversations)
                        }
                        // Same listing and refusal of an empty list: generated images of conversations deleted before eviction or cut short by
                        // a crash.
                        MediaStore.sweepOrphansInBackground(liveConversationIDs: liveConversations)
                    } catch {
                        startupLogger.error("[STARTUP] Conversation list unavailable for the memory orphan sweep: \(error.localizedDescription). CONSEQUENCE: memory of deleted conversations, if any, is not collected this launch.")
                    }
                    // `CodeViewerSessionSD` is retired, so lightweight migration drops its whole table; no row-by-row sweep is needed.

                case .deferSchemaChanged(let previous, let current):
                    startupLogger.notice(
                        "[STARTUP] Launch sweep DEFERRED — the schema changed since the last clean "
                        + "open (was \(previous?.prefix(12) ?? "never recorded"), now \(current.prefix(12))). "
                        + "CONSEQUENCE: download history is not pruned or reconciled, so a migration "
                        + "that silently degraded it can still be inspected and recovered; interrupted "
                        + "downloads keep their 'running' status until the next launch, which will "
                        + "sweep normally. Workflow-run orphans ARE reconciled below — see that line."
                    )
                    // Safe despite the deferral: it matches only rows stored as `.running` and writes back `statusRaw` / `errorMessage`.
                    // Left alone, a crash orphan renders as a live run in every later session.
                    startupLogger.info("[STARTUP] Reconciling workflow-run orphans despite the deferral — see the note above for why this one is safe.")
                    WorkflowRunHistoryStore.shared.reconcileOrphans(startedBefore: launchInstant)

                case .skippedByEnvironment:
                    // CONSEQUENCE: download-history retention and workflow-run orphan reconciliation are skipped for this launch.
                    // Phantom running rows and unbounded download history are expected until the next launch without the override.
                    startupLogger.warning(
                        "[STARTUP] Launch sweep SKIPPED — \(DevgenticSchema.skipLaunchSweepEnvKey) is set. "
                        + "No rows will be pruned, reconciled or purged this launch."
                    )
                }

                // Why: Outside the sweep gate on purpose: no migration can invent a tool name the compiled catalogue lacks.
                // Built-ins only: an absent MCP tool may merely be offline (see `WithdrawnToolSweep`).
                // A profile saved before a built-in tool was withdrawn keeps its name and nothing in the UI can remove it,
                // costing an error and an un-priced tool schema on every send.
                let prunedProfiles = WithdrawnToolSweep.run()
                if prunedProfiles > 0 {
                    startupLogger.notice("[STARTUP] Pruned withdrawn built-in tool(s) from \(prunedProfiles) profile(s).")
                }

                // After the sweep, never before: `reconcileOrphans()` flips last session's `.downloading` rows to `.interrupted`,
                // and priming earlier counts them as in-flight; on a deferred launch the count is knowingly optimistic.
                DownloadManager.shared.primeActiveCount()

                // Why: Skip under the DEBUG override: `UserDefaults.standard` is the real domain, so recording would disarm the gate for
                // the developer.
                // Record after the decision and regardless of it, so a deferral lasts exactly one launch.
                if launchSweepDecision == .skippedByEnvironment {
                    startupLogger.warning(
                        "[STARTUP] Schema fingerprint NOT recorded — \(DevgenticSchema.skipLaunchSweepEnvKey) "
                        + "is set, so this launch does not speak for the real store. CONSEQUENCE: the "
                        + "gate's stored fingerprint is left as-is and the next unsuppressed launch "
                        + "decides on its own merits."
                    )
                } else {
                    DevgenticSchema.recordSuccessfulOpen()
                }

                // Partial downloads left by paused, interrupted, failed or crashed MLX pulls. The scan is read-only: these folders are
                // multi-gigabyte user data another instance may be writing, so it only lists them and, past 1 GB, tells the user once.
                MLXModelService.scanPartialDownloadsAtLaunch()

                // Brings enabled MCP servers up now, not on the agent's first tool call, which would pay the connect cost mid-turn.
                // Detached so a slow or unreachable server never delays the app.
                Task { await MCPConnectionCoordinator.shared.connectEnabledServersAtLaunch() }
            }
            return container
        } catch {
            // A store that will not open is almost always a migration failure after an update; show the cause and location.
            // Never recovers by deleting or moving the store: it holds every conversation.
            let storeURL = try? DevgenticSchema.defaultStoreURL()
            let path = storeURL?.path ?? "Application Support/\(DevgenticSchema.storeFilename)"

            // Correlation id: the user sees it in the alert, support sees it in the log line, and
            // the two can be tied together from a screenshot alone.
            let incidentID = String(UUID().uuidString.prefix(8))
            let logger = DGLogger(category: "DevgenticApp")

            // Side channel 1: classify from the store's own metadata, because the thrown error is always SwiftDataError code 1
            // with empty userInfo while Core Data's raw metadata API still returns real information.
            let diagnosis = storeURL.map {
                StoreOpenDiagnostics.classify(
                    storeURL: $0,
                    expectedEntityNames: Set(DevgenticSchema.schema.entities.map(\.name))
                )
            } ?? .indeterminate

            // Side channel 2: recover Core Data's stderr-only reason by re-attempting the open with stderr captured;
            // safe because a failed open is side-effect free.
            var detailLines: [String] = []
            var primaryReason: String?
            if let storeURL {
                let captured = StoreOpenDiagnostics.captureStandardError {
                    let retryConfig = ModelConfiguration(
                        DevgenticSchema.configurationName,
                        schema: DevgenticSchema.schema,
                        url: storeURL
                    )
                    _ = try? ModelContainer(
                        for: DevgenticSchema.schema,
                        migrationPlan: DevgenticSchema.migrationPlan,
                        configurations: retryConfig
                    )
                }
                if let captured {
                    detailLines = StoreOpenDiagnostics.migrationDetailLines(in: captured)
                    primaryReason = StoreOpenDiagnostics.primaryFailureReason(in: captured)
                }
            }

            // The stderr reason outranks the metadata classification: metadata reports what differs, not always what blocked the
            // open.
            let headline = primaryReason ?? diagnosis.summary
            let detailBlock = detailLines.isEmpty
                ? "(no further detail — Core Data printed nothing identifiable)"
                : detailLines.joined(separator: "\n")

            // Pass the error as `error:` so DGLogger stamps ns_domain/ns_code, rather than
            // interpolating it into the message where that metadata is lost.
            logger.error(
                "[STARTUP] FATAL incident=\(incidentID) cause=\(diagnosis.tag): SwiftData "
                + "ModelContainer could not be opened at \(path). BLOCKER: \(headline). "
                + "Store metadata says: \(diagnosis.summary) "
                + "CONSEQUENCE: the store was left byte-intact and untouched; the app cannot "
                + "continue without it and is exiting now.",
                error: error,
                metadata: [
                    "incident_id": incidentID,
                    "store_path": path,
                    "diagnosis": diagnosis.tag,
                    "captured_detail_lines": "\(detailLines.count)",
                ]
            )

            // A bricked launch is not a crash: without this the sentinel stays false and the next launch reports a phantom crash.
            CrashDiagnosticsCollector.markCleanExit()

            // Why: A flush here stops the periodic flush (`prepareForTermination`) and loses the `[RECOVERY]` lines the modal loop emits.
            // The periodic flush keeps running during `runModal()`, so the FATAL line reaches disk on its own.
            // Do not flush here: the flush must be the last thing before every `exit()` below.

            #if canImport(AppKit)
            guard DevgenticSchema.shouldPresentFatalAlert else {
                // CONSEQUENCE: no user-facing explanation this launch — the diagnosis above is the
                // only record. DEBUG-only, and the process still exits non-zero.
                logger.warning(
                    "[STARTUP] incident=\(incidentID): fatal alert SUPPRESSED — "
                    + "\(DevgenticSchema.suppressFatalAlertEnvKey) is set."
                )
                Self.flushDiagnosticsBeforeExit(logger: logger, incidentID: incidentID)
                exit(EXIT_FAILURE)
            }

            let supportPayload = """
                Devgentic database failure
                Incident: \(incidentID)
                Cause: \(diagnosis.tag) — \(diagnosis.summary)
                Blocker: \(headline)
                Store: \(path)
                Error: \(error)
                CoreData detail:
                \(detailBlock)
                """

            // This alert runs from the App struct's initializer, before `NSApp.run()` and activation; activate so it is not hidden
            // behind other windows.
            NSApplication.shared.activate()

            // `-> Never`: every branch of the alert loop exits, each flushing immediately before it.
            Self.presentFatalStoreAlert(
                storeURL: storeURL,
                path: path,
                headline: headline,
                supportPayload: supportPayload,
                incidentID: incidentID,
                logger: logger
            )
            #else
            // No AppKit: no alert to present, so exit here, flushing last as on every other exit from this path.
            Self.flushDiagnosticsBeforeExit(logger: logger, incidentID: incidentID)
            exit(EXIT_FAILURE)
            #endif
        }
    }()

    #if canImport(AppKit)
    // Why: Panels use `runModal()`, never `begin { }`: this runs before `NSApp.run()`, so a completion handler would never fire.
    /// Presents the fatal-database alert and services the recovery affordances until the user picks a terminal action.
    /// Always exits.
    /// Loops because 'Reveal in Finder' and 'Export a Copy…' dismiss the alert but are not decisions.
    private static func presentFatalStoreAlert(
        storeURL: URL?,
        path: String,
        headline: String,
        supportPayload: String,
        incidentID: String,
        logger: DGLogger
    ) -> Never {
        // Button order: first added is the RIGHTMOST/default. "Quit" is the default and the
        // destructive action sits furthest from it.
        enum Choice: Int { case quit = 1000, copyDetails, reveal, export, startFresh }

        while true {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "Devgentic can't open its database")
            alert.informativeText = String(localized: """
                \(headline)

                Your data has NOT been modified. It's at:
                \(path)

                Include incident \(incidentID) in any report.
                """)
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Copy Details"))
            alert.addButton(withTitle: String(localized: "Reveal in Finder"))
            alert.addButton(withTitle: String(localized: "Export a Copy…"))
            alert.addButton(withTitle: String(localized: "Start Fresh…"))

            switch Choice(rawValue: alert.runModal().rawValue) {
            case .copyDetails:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(supportPayload, forType: .string)
                logger.info("[RECOVERY] incident=\(incidentID): support details copied to the clipboard.")

            case .reveal:
                if let storeURL {
                    NSWorkspace.shared.activateFileViewerSelecting([storeURL])
                    logger.info("[RECOVERY] incident=\(incidentID): revealed \(storeURL.path) in Finder.")
                }

            case .export:
                exportCopy(storeURL: storeURL, incidentID: incidentID, logger: logger)

            case .startFresh:
                if startFresh(storeURL: storeURL, incidentID: incidentID, logger: logger) {
                    // Flush last: `startFresh` has just logged which artifacts moved, the only record of what happened to the database,
                    // and `exit` drops anything unflushed.
                    flushDiagnosticsBeforeExit(logger: logger, incidentID: incidentID)
                    exit(0)  // Recovery was a deliberate choice; any relaunch is already under way.
                }

            case .quit, .none:
                logger.info("[RECOVERY] incident=\(incidentID): user quit without recovering.")
                flushDiagnosticsBeforeExit(logger: logger, incidentID: incidentID)
                exit(EXIT_FAILURE)
            }
        }
    }

    /// Copies the COMPLETE four-artifact set to a location the user picks.
    private static func exportCopy(storeURL: URL?, incidentID: String, logger: DGLogger) {
        guard let storeURL else { return }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export a copy of the database")
        panel.message = String(localized: "The database is several files. They will be saved together in one folder.")
        panel.nameFieldStringValue = "Devgentic-database-\(incidentID)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        do {
            let folder = try StoreRecovery.exportCopy(
                of: storeURL,
                into: chosen.deletingLastPathComponent(),
                folderName: chosen.lastPathComponent
            )
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            showInformation(
                String(localized: "Copy saved"),
                String(localized: "The complete database — including its write-ahead log and stored images — was copied to:\n\n\(folder.path)")
            )
        } catch {
            logger.error(
                "[RECOVERY] incident=\(incidentID): export failed — \(error.localizedDescription). "
                + "CONSEQUENCE: no usable backup was produced; the original store is untouched."
            )
            showWarning(
                String(localized: "Couldn't export a copy"),
                error.localizedDescription
            )
        }
    }

    /// Moves the current database aside so the next launch starts clean; returns whether it happened.
    /// Explicit and reversible: nothing is deleted, the old database keeps its data under a new name.
    private static func startFresh(storeURL: URL?, incidentID: String, logger: DGLogger) -> Bool {
        guard let storeURL else { return false }

        let artifactCount = StoreRecovery.existingArtifacts(for: storeURL).count
        let sizeText = ByteCountFormatter.string(
            fromByteCount: StoreRecovery.totalSize(for: storeURL), countStyle: .file
        )
        // Be honest that a SwiftData reset is not a full reset (G32).
        let companions = StoreRecovery.companionStores(bundleIdentifier: Bundle.main.bundleIdentifier)
        let companionNote = companions.isEmpty ? "" : """


            These are NOT reset and may still reference the old conversations:
            \(companions.map { "• \($0.label)" }.joined(separator: "\n"))
            """

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = String(localized: "Start with an empty database?")
        confirm.informativeText = String(localized: """
            Your current database (\(artifactCount) files, \(sizeText)) will be MOVED ASIDE, not deleted. \
            It stays in the same folder under a new name, so it can be restored by renaming it back.

            Devgentic will then start with no conversations, profiles or prompts.\(companionNote)
            """)
        confirm.addButton(withTitle: String(localized: "Cancel"))
        confirm.addButton(withTitle: String(localized: "Move Aside and Restart"))

        guard confirm.runModal() == .alertSecondButtonReturn else { return false }

        // Deterministic, human-readable, and sortable — the user has to recognise this folder later.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = .current

        do {
            let result = try StoreRecovery.quarantine(
                storeURL: storeURL, suffix: formatter.string(from: Date())
            )
            logger.info(
                "[RECOVERY] incident=\(incidentID): moved \(result.movedArtifacts.count) artifact(s) "
                + "aside to \(result.quarantinedStoreURL.lastPathComponent). CONSEQUENCE: the next "
                + "launch creates an EMPTY store; the previous data is intact under the new name."
            )

            let relaunched = relaunch()
            showInformation(
                String(localized: "Database moved aside"),
                String(localized: """
                    Your old database is safe at:
                    \(result.quarantinedStoreURL.path)

                    \(relaunched ? "Devgentic is restarting with an empty database." : "Please open Devgentic again to start with an empty database.")
                    """)
            )
            return true
        } catch {
            logger.error(
                "[RECOVERY] incident=\(incidentID): move-aside FAILED — \(error.localizedDescription)"
            )
            showWarning(String(localized: "Couldn't move the database aside"), error.localizedDescription)
            return false
        }
    }

    /// Launches a fresh instance. `-n` forces a new one even though this process is still alive for
    /// the moment it takes to exit.
    private static func relaunch() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
            try process.run()
            return true
        } catch {
            // Non-fatal: the message tells the user to reopen manually.
            return false
        }
    }

    private static func showInformation(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private static func showWarning(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
    #endif

    // Why: Blocks the calling thread on purpose: `LogRecorder` and `TraceRecorder` are plain actors, so this cannot starve them.
    // The timeout is a hard bound so a wedged recorder never holds the failure alert hostage.
    /// Forces the observability buffers to disk before an `exit()` that bypasses normal teardown.
    /// `exit(EXIT_FAILURE)` never reaches `applicationShouldTerminate`, so the fatal log line would depend on the periodic
    /// flush.
    private static func flushDiagnosticsBeforeExit(logger: DGLogger, incidentID: String) {
        let timeout = DispatchTime.now() + .seconds(3)
        let finished = DispatchSemaphore(value: 0)

        Task.detached(priority: .userInitiated) {
            await LogRecorder.shared.prepareForTermination()
            await TraceRecorder.shared.prepareForTermination()
            finished.signal()
        }

        if finished.wait(timeout: timeout) == .timedOut {
            // Best effort only — os_log already has the line even if the SQLite sink does not.
            logger.error(
                "[STARTUP] incident=\(incidentID): diagnostics flush timed out after 3s. "
                + "CONSEQUENCE: the FATAL entry may be missing from traces.sqlite and therefore "
                + "from any exported support bundle; it is still present in os_log."
            )
        }
    }

    @State private var themeManager = ThemeManager()

    @State private var mainApplicationViewModel: MainApplicationViewModel
    @State private var chatHistoryViewModel: ChatHistoryViewModel
    @State private var mainViewRouter = MainViewRouter()
    /// Constructed once in `init()` and handed to `State(wrappedValue:)`, never a property default.
    @State private var backendProfileService: BackendProfileService
    @State private var toastManager = ToastManager()
    @State private var codeSessionManager = CodeSessionManager()
    /// The Code interface's Git Changes panel state. Inert until `GitChangesWiringModifier` hands it a
    /// project (Code mode only) — constructing it runs nothing.
    @State private var gitChangesStore = GitChangesStore()
    /// Owns long-lived destination view models (Ollama/MLX stores) so their
    /// state survives the re-creation cascade caused by
    /// `MainApplicationView`'s `if !router.isShowingChat { destinationView }` gate.
    @State private var destinationCoordinator = DestinationCoordinator()
    /// App-scoped so `ChatInputAreaView` recreations do not keep re-running `ChatInputViewModel.init()` (logging, mic
    /// permission, WhisperKit).
    /// `setupMainDelegateObservers()` is idempotent, so repeated `.onAppear` wiring is safe.
    @State private var chatInputViewModel = ChatInputViewModel()

    init() {
        // Enforce overlay scrollers and eliminate scroller track / path backgrounds
        ScrollerCustomizer.install()

        let persistence = ChatPersistenceStore.shared
        let fileProcessor = FileProcessorService()

        let streamManager = ActiveStreamManager(
            persistenceService: persistence,
            fileProcessorService: fileProcessor
        )

        // A background task outlives the stream that started it, so the observer holds the message directly;
        // it can only find it while the run is live, which is why the lookup is handed over here, once.
        MainActor.assumeIsolated {
            BackgroundTaskObserver.shared.start { conversationID in
                streamManager.activeStreams.values.first {
                    $0.conversationId == conversationID && $0.isStreaming
                }
            }
        }

        // The main window owns the Code Viewer (live agent tabs and session persistence); QuickAccess's view model does not.
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

        // Why: Armed with the local `mainVM`: reading a `@State` in `init()` can return an instance SwiftUI discards.
        // A background task whose caller set `notify_on_completion` gets a turn of its own on finish;
        // report-only and unattended (`BackgroundTaskWakeCoordinator`).
        MainActor.assumeIsolated {
            BackgroundTaskWakeCoordinator.shared.start(viewModel: mainVM, persistence: persistence)
        }

        // `CodeSessionManager` is not injected here: reading a `@State` in `init()` can yield an instance SwiftUI discards.
        // It is bound in `body` via `.task`, which reads the instance SwiftUI kept.

        // Built as a local, wired, then installed: reading a `@State` in `init()` can construct a discarded instance.
        // The delete cascade clears the canvas cache so quit does not re-create a layout row; `[weak mainVM]` as it lives long.
        let profileService = BackendProfileService()
        profileService.onProfileDeleted = { [weak mainVM] profileID in
            mainVM?.discardWorkflowCanvasState(for: profileID)
        }
        self._backendProfileService = State(wrappedValue: profileService)

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
            // Catch up here, not only on `didBecomeActive`: `rescheduleAll` arms timers for future dates only.
            // A duplicate call is harmless (`runningTaskIDs` de-dupes).
            SchedulerService.shared.evaluateAndFireDueTasks()
            // Wake, clock and time-zone changes re-decide every task.
            SchedulerService.shared.startObservingSystemChanges()
        }
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            Group {
                if !isOnboardingComplete {
                    OnboardingContainerView(onComplete: { createdProfileID in
                        OnboardingCompletion.apply(
                            createdProfileID: createdProfileID,
                            profileService: backendProfileService,
                            backendConfiguration: mainApplicationViewModel.backendConfiguration
                        )
                        withAnimation(.easeInOut(duration: 0.35)) {
                            isOnboardingComplete = true
                        }
                    })
                } else {
                    MainApplicationView()
                }
            }
                .environment(themeManager)
                .environment(\.appTheme, themeManager.currentTheme)
                .environment(\.surfaceStyle, themeManager.surfaceStyle)
                .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
                .environment(mainApplicationViewModel)
                .environment(mainApplicationViewModel.explorerViewModel)
                .environment(chatHistoryViewModel)
                .environment(mainViewRouter)
                .environment(backendProfileService)
                .environment(toastManager)
                .modifier(LeftoverDownloadNoticeModifier(toastManager: toastManager))
                .environment(codeSessionManager)
                .environment(gitChangesStore)
                // Binds the SAME instance the environment hands the views. See the note in
                // `init()` for why this cannot be done there.
                .task { mainApplicationViewModel.configureCodeSession(codeSessionManager) }
                .environment(destinationCoordinator)
                .environment(chatInputViewModel)
                .modelContainer(swiftDataContainer)
                .tint(themeManager.currentTheme.accentColor)
                .task {
                    // Hands the AppKit-created QuickAccess panel the shared object graph; uses the adaptor property `appDelegate`, the
                    // real AppDelegate instance.
                    appDelegate.configureQuickAccess(
                        mainAppViewModel: mainApplicationViewModel,
                        themeManager: themeManager
                    )
                    // Until this runs `applicationShouldTerminate` cannot see the profile editor and Cmd-Q discards unsaved edits.
                    // Injected here because AppDelegate lives outside the SwiftUI environment.
                    appDelegate.configureTerminationGuard(
                        profileService: backendProfileService,
                        mainAppViewModel: mainApplicationViewModel
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // Catch up any scheduled tasks that fired while the app was in the background.
                    SchedulerService.shared.evaluateAndFireDueTasks()
                }
        }
        .commands {
            // MARK: - File Menu
            CommandMenu("File") {
                Button("New Chat / Session") {
                    NotificationCenter.default.post(name: .newChatSession, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Attach Files...") {
                    NotificationCenter.default.post(name: .openFilePicker, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Rename Conversation...") {
                    NotificationCenter.default.post(name: .renameActiveConversation, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(mainApplicationViewModel.selectedConversationID == nil)

                Button("Pin / Unpin Conversation") {
                    NotificationCenter.default.post(name: .togglePinActiveConversation, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(mainApplicationViewModel.selectedConversationID == nil)

                Button("Export Conversation as Markdown...") {
                    NotificationCenter.default.post(name: .exportActiveConversation, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(mainApplicationViewModel.selectedConversationID == nil)

                Button("Delete Conversation...") {
                    NotificationCenter.default.post(name: .deleteActiveConversation, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(mainApplicationViewModel.selectedConversationID == nil)

                Divider()

                Button("Close Window") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            // MARK: - View Menu
            CommandMenu("View") {
                Button("Command Palette...") {
                    NotificationCenter.default.post(name: .toggleCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)

                Divider()

                Menu("Interface Mode") {
                    Button("Chat Mode") {
                        mainApplicationViewModel.switchInterfaceMode(to: .chat)
                    }
                    .keyboardShortcut("1", modifiers: .control)

                    Button("Workflow Canvas") {
                        mainApplicationViewModel.switchInterfaceMode(to: .workflow)
                    }
                    .keyboardShortcut("2", modifiers: .control)

                    Button("Code Workspace") {
                        mainApplicationViewModel.switchInterfaceMode(to: .code)
                    }
                    .keyboardShortcut("3", modifiers: .control)

                    Divider()

                    Button("Cycle Interface Mode") {
                        let all = MainApplicationViewModel.InterfaceMode.allCases
                        if let cur = all.firstIndex(of: mainApplicationViewModel.interfaceMode) {
                            let next = all[(cur + 1) % all.count]
                            mainApplicationViewModel.switchInterfaceMode(to: next)
                        }
                    }
                    .keyboardShortcut("`", modifiers: .control)
                }

                Divider()

                Menu("Sidebar Tabs") {
                    Button("Chats") {
                        NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.conversations)
                    }
                    .keyboardShortcut("1", modifiers: [.command, .option])

                    Button("Explorer") {
                        NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.explorer)
                    }
                    .keyboardShortcut("2", modifiers: [.command, .option])

                    Button("Prompts") {
                        NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.promptLibrary)
                    }
                    .keyboardShortcut("3", modifiers: [.command, .option])

                    Button("Scheduler") {
                        NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.scheduler)
                    }
                    .keyboardShortcut("4", modifiers: [.command, .option])

                    Button("Profiles") {
                        NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.backendProfiles)
                    }
                    .keyboardShortcut("5", modifiers: [.command, .option])

                    Button("Tools") {
                        NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.tools)
                    }
                    .keyboardShortcut("6", modifiers: [.command, .option])

                    Button("Skills") {
                        NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.skills)
                    }
                    .keyboardShortcut("7", modifiers: [.command, .option])

                    Button("Settings") {
                        NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.settings)
                    }
                    .keyboardShortcut("8", modifiers: [.command, .option])
                }
            }

            // MARK: - Navigate Menu
            CommandMenu("Navigate") {
                Button("Back") {
                    if mainViewRouter.canGoBack {
                        mainViewRouter.goBack()
                    }
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!mainViewRouter.canGoBack)

                Button("Home") {
                    if !mainViewRouter.isShowingChat {
                        mainViewRouter.returnToChat()
                    }
                    mainApplicationViewModel.deselectConversationAndShowWelcome()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                Button("Focus Chat Composer") {
                    NotificationCenter.default.post(name: .focusChatInput, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)

                Divider()

                Button("Next Conversation") {
                    NotificationCenter.default.post(name: .selectNextConversation, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Button("Previous Conversation") {
                    NotificationCenter.default.post(name: .selectPreviousConversation, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            }

            // MARK: - Find Commands (Edit Menu)
            CommandGroup(after: .pasteboard) {
                Button("Find in Chat...") {
                    NotificationCenter.default.post(name: .findInChat, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") {
                    NotificationCenter.default.post(name: .findNextInChat, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    NotificationCenter.default.post(name: .findPreviousInChat, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            // MARK: - Input Menu
            CommandMenu("Input") {
                Button("Toggle Voice Input") {
                    NotificationCenter.default.post(
                        name: GlobalConstants.toggleVoiceInputNotification,
                        object: nil
                    )
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }

            // MARK: - Tools Menu
            CommandMenu("Tools") {
                Button("New Prompt...") {
                    NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.promptLibrary)
                    NotificationCenter.default.post(name: .newPrompt, object: nil)
                }

                Button("New Scheduled Task...") {
                    mainViewRouter.navigateToNewTask()
                }

                Button("New Backend Profile...") {
                    NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.backendProfiles)
                    NotificationCenter.default.post(name: .newProfile, object: nil)
                }

                Divider()

                Button("Add Custom MCP Server...") {
                    mainViewRouter.navigate(to: .addMCPServer)
                }

                Button("Create Skill...") {
                    NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.skills)
                    NotificationCenter.default.post(name: .createSkill, object: nil)
                }

                Button("Import Skills...") {
                    NotificationCenter.default.post(name: .selectSidebarTab, object: SidebarTab.skills)
                    NotificationCenter.default.post(name: .importSkills, object: nil)
                }

                Divider()

                Button("Download Manager") {
                    mainViewRouter.navigateToDownloadManager()
                }
            }

            // MARK: - App Info / Preferences Group
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    softwareUpdater.checkForUpdates()
                }
                .disabled(!softwareUpdater.canCheckForUpdates)

                if let supportLink = GlobalConstants.supportLink {
                    Button("Support Development ♥") { NSWorkspace.shared.open(supportLink) }
                }

                Divider()

                Button("Settings...") {
                    mainViewRouter.navigateToSettings(.general)
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("Backend Profiles...") {
                    // Uses `sharedProfiles`: `profiles` sorts by `lastSelected`, which saves stamp, so `.first` could be a node's row.
                    // With no profiles it must not invent an id and land on 'Profile Not Found'.
                    if let firstProfile = backendProfileService.sharedProfiles.first {
                        mainViewRouter.navigateToProfile(
                            firstProfile.id,
                            activatingBufferOn: backendProfileService
                        )
                    } else {
                        // Shows the Profiles sidebar instead, where the empty state offers 'New Profile' or, if the read failed, a Retry state.
                        UserDefaults.standard.set(
                            SidebarTab.backendProfiles.rawValue, forKey: SidebarTab.storageKey)
                        mainViewRouter.returnToChat()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                // Trends dashboard; requires developer mode (gated by `TrendsView`) and is listed here for discoverability.
                Button("Observability Trends...") {
                    openWindow(id: "trends-window")
                }
                .keyboardShortcut("t", modifiers: [.command, .shift, .option])

                Button("Keyboard Shortcuts...") {
                    openWindow(id: "shortcuts-window")
                }
                .keyboardShortcut("/", modifiers: .command)
            }

            // MARK: - Help Menu
            CommandMenu("Help") {
                Button("Welcome to Devgentic (Setup Assistant)...") {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        isOnboardingComplete = false
                    }
                }

                Divider()

                // Public GitHub issue forms, pre-filled with version / macOS / Mac — no bundle needed.
                Button("Report a Bug…") { GitHubIssueLink.open(.bug) }
                Button("Request a Feature…") { GitHubIssueLink.open(.feature) }

                Divider()

                Button("Privacy Policy") {
                    openWindow(id: BundledDocument.windowGroupID, value: BundledDocument.privacyPolicy)
                }
                Button("License") {
                    openWindow(id: BundledDocument.windowGroupID, value: BundledDocument.license)
                }
                Button("Third-Party Notices") {
                    openWindow(id: BundledDocument.windowGroupID, value: BundledDocument.thirdPartyNotices)
                }
            }
        }

        // MARK: - File Viewer Window
        WindowGroup("File Viewer", id: "file-viewer-window", for: URL.self) { $fileURL in
            if let url = fileURL {
                FileWindowViewer(fileURL: url)
                    .environment(themeManager)
                    .environment(\.appTheme, themeManager.currentTheme)
                    .environment(\.surfaceStyle, themeManager.surfaceStyle)
                    .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
                    .tint(themeManager.currentTheme.accentColor)
            }
        }

        // MARK: - Trends Dashboard (Phase E)
        // Developer-facing window: per-tool reliability, error frequency, per-model outcomes and circuit-breaker stats.
        // Read live from `TraceStore`; gated on developer mode, others see an unlock placeholder.
        Window("Observability Trends", id: "trends-window") {
            TrendsView()
                .environment(themeManager)
                .environment(\.appTheme, themeManager.currentTheme)
                .environment(\.surfaceStyle, themeManager.surfaceStyle)
                .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
                .frame(minWidth: 760, minHeight: 560)
                .tint(themeManager.currentTheme.accentColor)
        }
        .windowResizability(.contentSize)

        // MARK: - Keyboard Shortcuts Reference Window
        Window("Keyboard Shortcuts", id: "shortcuts-window") {
            KeyboardShortcutsReferenceView()
                .environment(themeManager)
                .environment(\.appTheme, themeManager.currentTheme)
                .environment(\.surfaceStyle, themeManager.surfaceStyle)
                .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
                .frame(minWidth: 700, minHeight: 520)
                .tint(themeManager.currentTheme.accentColor)
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // MARK: - Bundled Documents Window (Privacy Policy, License, Third-Party Notices)
        // The bundled copies of PRIVACY.md, LICENSE and THIRD_PARTY_NOTICES.md (see `BundledDocument`); one window per document.
        WindowGroup("Document", id: BundledDocument.windowGroupID, for: BundledDocument.self) { $document in
            BundledDocumentView(document: document ?? .privacyPolicy)
                .environment(themeManager)
                .environment(\.appTheme, themeManager.currentTheme)
                .environment(\.surfaceStyle, themeManager.surfaceStyle)
                .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
                .frame(minWidth: 560, idealWidth: 720, minHeight: 480, idealHeight: 720)
                .tint(themeManager.currentTheme.accentColor)
        }
        // Opened only from the Help menu and the setup assistant — no "New Document Window" item.
        .commandsRemoved()
    }

}
