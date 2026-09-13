// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
            // The entity list lives in `DevgenticSchema` so the migration tests reference the
            // SAME list the app opens, rather than a copy that can drift (see G54). Hash-neutral
            // vs. the previous inline literal: `Schema(models)` defaults to Version(1, 0, 0).
            let schema = DevgenticSchema.schema
            let storeURL = try DevgenticSchema.defaultStoreURL()
            let config = ModelConfiguration(DevgenticSchema.configurationName, schema: schema, url: storeURL)
            // A migration plan gives every future schema change a NAMED source version to stage
            // from. Today it declares one version and zero stages, which behaves identically to
            // `migrationPlan: nil` — the point is that the scaffolding exists before the first
            // change that needs it. See DevgenticSchemaVersions.swift.
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
            // ⚠️ Decide ONCE, here, before anything destructive can run — and reuse the same value
            // below. `MCPToolStore.configureContainer` carries a blob-rewriting secrets migration and
            // is called synchronously on this line, i.e. before the `Task` block could have evaluated
            // anything, so the decision has to exist by now or that migration is ungated (G44).
            // Evaluating once also removes a second hazard: `recordSuccessfulOpen()` writes the
            // fingerprint later in that same block, so a second evaluation would not agree with this
            // one.
            let launchSweepDecision = DevgenticSchema.evaluateLaunchSweep()

            // Inject into singleton stores so non-SwiftUI code can access the container.
            BackendProfileStore.shared.configureContainer(container)
            MCPToolStore.shared.configureContainer(
                container,
                migrateLegacySecrets: launchSweepDecision == .run
            )
            PromptStore.shared.configureContainer(container)
            ChatPersistenceStore.shared.configureContainer(container)
            WorkflowLayoutStore.shared.configureContainer(container)
            WorkflowRunHistoryStore.shared.configureContainer(container)
            // Download-history store is configured on the main actor; do it
            // eagerly via Task so reconcileOrphans runs as soon as possible.
            Task { @MainActor in
                DownloadHistoryStore.shared.configureContainer(container)

                // Everything below MUTATES OR DELETES rows, so it runs only when the schema is
                // unchanged since the last clean open. A lightweight migration can succeed
                // STRUCTURALLY while dropping a renamed column's data or defaulting a new
                // non-optional; sweeping such a store writes the degraded state back as
                // authoritative before anyone can look at it (G44).
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
                    DownloadHistoryStore.shared.reconcileOrphans()
                    // Retention: history is otherwise monotonic for the life of the install, and
                    // every row is scanned on each bridge reconcile and sidebar render.
                    DownloadHistoryStore.shared.pruneOldRecords()
                    // Any workflow run still in .running at launch is from a prior
                    // session that ended before the run could finalize. Flip to
                    // .cancelled with "Interrupted" so the history list doesn't
                    // show a phantom spinning record forever.
                    WorkflowRunHistoryStore.shared.reconcileOrphans()
                    // The Code Viewer purge that used to run here is gone: `CodeViewerSessionSD`
                    // was retired 2026-08-04, so lightweight migration drops the whole table on
                    // the first launch after the update — no row-by-row sweep needed.

                case .deferSchemaChanged(let previous, let current):
                    startupLogger.notice(
                        "[STARTUP] Launch sweep DEFERRED — the schema changed since the last clean "
                        + "open (was \(previous?.prefix(12) ?? "never recorded"), now \(current.prefix(12))). "
                        + "CONSEQUENCE: download history is not pruned or reconciled, so a migration "
                        + "that silently degraded it can still be inspected and recovered; interrupted "
                        + "downloads keep their 'running' status until the next launch, which will "
                        + "sweep normally. Workflow-run orphans ARE reconciled below — see that line."
                    )
                    // [WF-RU2] Unlike the download-history sweep above, this one carries none of the
                    // degradation risk the gate exists to guard against: the predicate matches only
                    // rows already stored as `.running`, and it writes back just `statusRaw` /
                    // `errorMessage` — no lightweight migration can PRODUCE a `.running` row (that
                    // only happens while a run is actually executing), so there is nothing here for
                    // a botched migration to have silently degraded. Left un-reconciled instead, an
                    // orphan from a force-quit or crash renders as a LIVE run for the rest of this
                    // session and every session after, on any conversation the user opens, until a
                    // launch happens to take the `.run` branch — the header pill shows "Running" and
                    // the history card ticks a `TimelineView(.periodic(...))` counter climbing from
                    // the original start time, for a run that has been dead for days.
                    startupLogger.info("[STARTUP] Reconciling workflow-run orphans despite the deferral — see the note above for why this one is safe.")
                    WorkflowRunHistoryStore.shared.reconcileOrphans()

                case .skippedByEnvironment:
                    // CONSEQUENCE: download-history retention and workflow-run orphan
                    // reconciliation are skipped for this launch. Phantom "running" workflow rows
                    // and unbounded download history are expected until the next launch without
                    // the override.
                    startupLogger.warning(
                        "[STARTUP] Launch sweep SKIPPED — \(DevgenticSchema.skipLaunchSweepEnvKey) is set. "
                        + "No rows will be pruned, reconciled or purged this launch."
                    )
                }

                // ⚠️ AFTER the sweep, never before. `reconcileOrphans()` is what flips last session's
                // abandoned `.downloading` rows to `.interrupted`; priming first counts those dead
                // rows as in-flight and the badge shows a phantom download for the whole session,
                // because nothing recomputes `activeCount` afterwards. (It regressed to first when
                // `reconcileOrphans` moved inside the gate — it used to run before the prime.)
                //
                // On a deferred/skipped launch the reconcile has NOT run, so the count is knowingly
                // optimistic for one launch; that is the stated cost of the deferral.
                DownloadManager.shared.primeActiveCount()

                // Record AFTER the decision, and regardless of it, so a deferral lasts exactly one
                // launch instead of becoming permanent.
                //
                // ⚠️ EXCEPT under the DEBUG environment override. The test host is the real app and
                // `UserDefaults.standard` is the real `app.devgentic.macos` domain — only the STORE is
                // redirected by `DEVGENTIC_STORE_URL`, not the defaults. Recording here would stamp
                // the current schema's fingerprint on behalf of a temporary store the real app has
                // never opened, so the developer's next real launch would see "unchanged" and sweep a
                // freshly-migrated store — disarming the gate for the one person doing schema work.
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

                // Partial-download residue from cancelled/interrupted MLX pulls.
                // READ-ONLY on purpose: these folders are multi-gigabyte user data, a
                // second app instance could be writing into one, and a user may have
                // hand-placed files there — so we log what is reclaimable and leave the
                // delete to an explicit user action (MLXModelService.reclaimOrphanedPartialDownloads).
                // Until the `partialDownloadFolder` path fix, nothing ever reclaimed these.
                MLXModelService.logOrphanedPartialDownloadsInBackground()

                // Bring enabled MCP servers up now, rather than lazily on the agent's first
                // tool call. That first call used to pay the entire connect cost inside a
                // turn the user was waiting on — a cold `npx -y` fetch can take a minute —
                // and a misconfigured server only revealed itself mid-conversation as a tool
                // failure. Detached from the container setup: a slow or unreachable server
                // must never delay the app becoming usable.
                Task { await MCPConnectionCoordinator.shared.connectEnabledServersAtLaunch() }
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
            let storeURL = try? DevgenticSchema.defaultStoreURL()
            let path = storeURL?.path ?? "Application Support/\(DevgenticSchema.storeFilename)"

            // Correlation id: the user sees it in the alert, support sees it in the log line, and
            // the two can be tied together from a screenshot alone.
            let incidentID = String(UUID().uuidString.prefix(8))
            let logger = DGLogger(category: "DevgenticApp")

            // ── Side channel 1: classify from the store's own metadata ──────────────────────
            // The thrown error is useless — every distinct cause arrives as SwiftDataError code 1
            // with empty userInfo. Core Data's raw metadata API still returns real information.
            let diagnosis = storeURL.map {
                StoreOpenDiagnostics.classify(
                    storeURL: $0,
                    expectedEntityNames: Set(DevgenticSchema.schema.entities.map(\.name))
                )
            } ?? .indeterminate

            // ── Side channel 2: recover Core Data's stderr-only reason ─────────────────────
            // Deliberately re-attempts the open with stderr captured. Safe: the first attempt
            // already failed without mutating anything, and a failed open is side-effect free.
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

            // ⚠️ The stderr reason OUTRANKS the metadata classification when both exist: metadata
            // reports whatever DIFFERS, which is not always what BLOCKED the open. A store can
            // carry a retired entity harmlessly while the real blocker is an attribute elsewhere.
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

            // A bricked launch is not a crash. Without this the sentinel stays false and the NEXT
            // launch reports a phantom crash for a session that exited deliberately.
            CrashDiagnosticsCollector.markCleanExit()

            // ⚠️ DO NOT FLUSH HERE. The flush must be the LAST thing before every `exit()` below,
            // never before the alert.
            //
            // `LogRecorder.prepareForTermination()` cancels the periodic flush task and nils it out,
            // so nothing flushes again afterwards. Flushing at this point therefore threw away every
            // `[RECOVERY]` line the modal loop goes on to emit — including "the store is SPLIT
            // between its original location and the quarantine name — do not create a new store until
            // this is resolved by hand", the single most important sentence the app can produce. The
            // one code path that exists for a catastrophic failure was the one that left no record.
            //
            // Deferring loses nothing: `exit()` is gated behind the blocking `runModal()`, and the
            // recorder's 5 s periodic flush keeps running throughout the modal, so the FATAL line
            // above reaches disk on its own well before any of these exits.

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

            // This alert runs from the App struct's stored-property initializer — BEFORE
            // NSApp.run() and before the app has been activated. Without this, the only failure UI
            // the app has can appear BEHIND whatever the user was looking at, and reads as a hang.
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
            // No AppKit: no alert to present, so exit here — flushing last, as on every other exit
            // from this path. (In the AppKit build this is unreachable, which is why it lives in the
            // `#else` rather than after the `#endif` where it was dead code the compiler warned on.)
            Self.flushDiagnosticsBeforeExit(logger: logger, incidentID: incidentID)
            exit(EXIT_FAILURE)
            #endif
        }
    }()

    #if canImport(AppKit)
    /// Presents the fatal-database alert and services the recovery affordances until the user picks
    /// a terminal action. Always exits.
    ///
    /// Loops on purpose: `NSAlert` dismisses on ANY button, but "Reveal in Finder" and
    /// "Export a Copy…" are not decisions — a user who exports a backup still needs the dialog
    /// afterwards to decide what to do next.
    ///
    /// ⚠️ Every panel here uses `runModal()`, never `begin { }`. This runs before `NSApp.run()`, so
    /// a completion-handler-based panel would never fire its handler — the app would appear to hang
    /// and then exit with nothing done (G42).
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
                    // ⚠️ Flush LAST — `startFresh` has just logged which artifacts moved where, or
                    // that the move failed and the store is split. Those lines are the only record of
                    // what happened to the user's database, and `exit` drops anything unflushed.
                    flushDiagnosticsBeforeExit(logger: logger, incidentID: incidentID)
                    exit(0)  // Recovered deliberately; the relaunch (if any) is already under way.
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

    /// Moves the current database aside so the next launch starts clean. Returns whether it happened.
    ///
    /// ⚠️ Deliberately explicit and reversible — the opposite of the silent wipe the launch path has
    /// always refused to do. Nothing is deleted; the old database keeps its data under a new name.
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

    /// Forces the observability buffers to disk before an `exit()` that bypasses normal teardown.
    ///
    /// `exit(EXIT_FAILURE)` never reaches `applicationShouldTerminate`, which is the only place
    /// `LogRecorder.prepareForTermination()` is normally called. Left alone, the fatal log line
    /// depends on `LogRecorder`'s 5-second flush loop happening to fire while the modal alert is
    /// up — so a user who dismisses the alert quickly loses the one record of what happened.
    ///
    /// ⚠️ Blocks the calling thread on purpose. `LogRecorder` and `TraceRecorder` are plain actors
    /// (not `@MainActor`), so they run on the cooperative pool and cannot be starved by this wait.
    /// The timeout is a hard bound: a wedged recorder must never hold the failure alert hostage,
    /// because the alert is the only thing the user actually sees.
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

        // Cascade a profile delete into the view model's per-profile canvas cache. Without this a
        // deleted workflow's DIRTY canvas survives in memory and the quit-time drain re-creates its
        // layout row as an orphan. `[weak mainVM]` because the service outlives nothing here but the
        // closure is stored for the process lifetime.
        self._backendProfileService.wrappedValue.onProfileDeleted = { [weak mainVM] profileID in
            mainVM?.discardWorkflowCanvasState(for: profileID)
        }

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
            // ⚠️ Catch up HERE, not only on `didBecomeActive` (G52).
            //
            // `rescheduleAll` arms timers for FUTURE dates only — a cron task gets its next
            // occurrence and a past `scheduledAt` gets no timer at all — so anything already overdue
            // depends entirely on this evaluation. The activation hook that used to be its only
            // trigger fires during cold launch and can beat this Task, in which case it iterated an
            // empty list and the overdue task was silently skipped until the user happened to switch
            // away and back. Calling it here makes the catch-up a property of startup rather than of
            // scheduling luck; a duplicate call is harmless (`runningTaskIDs` de-dupes).
            SchedulerService.shared.evaluateAndFireDueTasks()
        }
    }

    var body: some Scene {
        // MARK: - Main Application Window
        WindowGroup {
            MainApplicationView()
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
                    // ⚠️ Register A29: until this runs, `applicationShouldTerminate` has no view of
                    // the profile editor and ⌘Q discards unsaved edits silently. Injected here for
                    // the same reason the QuickAccess graph is — AppDelegate lives outside the
                    // SwiftUI environment.
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
                    // ⚠️ Register A33. This was `profiles.first?.id ?? UUID()` — on a first run, with
                    // no profiles yet, it invented an ID that had never existed and navigated to it,
                    // landing the user on "Profile Not Found" for a profile they never created. The
                    // one state where the menu item most needs to help was the one it broke.
                    // ⚠️ `sharedProfiles`. `profiles` is sorted by `lastSelected` DESCENDING and
                    // `saveProfile` stamps that on every write — including when a workflow node
                    // mints its private row — so the plain `.first` opened whichever node was added
                    // most recently, in the profile editor, outside the workflow that owns it.
                    if let firstProfile = backendProfileService.sharedProfiles.first {
                        mainViewRouter.navigateToProfile(
                            firstProfile.id,
                            activatingBufferOn: backendProfileService
                        )
                    } else {
                        // Show the Profiles sidebar instead, where the empty state offers
                        // "New Profile" — or, if the read FAILED rather than came back empty,
                        // the "Couldn't Load Profiles" state with Retry (register A47).
                        UserDefaults.standard.set(
                            SidebarTab.backendProfiles.rawValue, forKey: SidebarTab.storageKey)
                        mainViewRouter.returnToChat()
                    }
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
                    .environment(\.surfaceStyle, themeManager.surfaceStyle)
                    .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
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
                .environment(\.surfaceStyle, themeManager.surfaceStyle)
                .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
                .frame(minWidth: 760, minHeight: 560)
                .tint(themeManager.currentTheme.accentColor)
        }
        .windowResizability(.contentSize)
    }

    // DELETED 2026-08-04: `cleanupLegacyCoreDataStore()`.
    //
    // It was never called in any revision, and it would not have worked if it had been: it looked
    // for `Application Support/DevgenticDB.sqlite` while the legacy CoreData store actually lives
    // one level down, in `Application Support/Devgentic/DevgenticDB.sqlite` — still present and
    // ~9.9 MB on a real install. It also force-unwrapped the directory lookup and swallowed every
    // error with `try?`, so a failure would have been indistinguishable from success.
    //
    // Not replaced with a working version: silently deleting a user's old database at launch is
    // exactly the behaviour the container-failure path deliberately refuses to do. If that store is
    // ever to be reclaimed it belongs behind an explicit, reversible user action of the kind
    // `StoreRecovery` now provides — not a launch-time sweep. Tracked in SWIFTDATA_GAP_REGISTER.md
    // as G35.
}
