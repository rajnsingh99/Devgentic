// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatHistoryViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "ChatHistoryViewModel")

/// Why `applyChanges` could not write a snippet back to its source file; surfaced via `codeApplyError`.
enum CodeApplyError: LocalizedError, Sendable {
    case sourceFileMissing
    case diskDrift(fileName: String)
    case writeFailed(fileName: String, underlying: String)
    /// A per-hunk operation received a diff snapshot older than the file's current contents.
    case staleDiff

    var errorDescription: String? {
        switch self {
        case .sourceFileMissing:
            return String(localized: "Couldn't find the file these changes belong to — it may have been detached.")
        case .diskDrift(let name):
            return String(localized: "\"\(name)\" changed on disk since it was attached, so applying now would overwrite those edits. Re-attach the file and try again.")
        case .writeFailed(let name, let underlying):
            return String(localized: "Couldn't save changes to \"\(name)\": \(underlying)")
        case .staleDiff:
            return String(localized: "The comparison went out of date. Reopen Show Changes and try again.")
        }
    }
}

@Observable @MainActor
final class ChatHistoryViewModel {

    // MARK: - Dependencies
    @ObservationIgnored private let persistenceService: ChatPersistenceProtocol
    @ObservationIgnored private let activeStreamManager: ActiveStreamManager
    /// Code Viewer tabs per conversation, kept for the current app session only.
    /// Switching conversations keeps the tabs; quitting discards them.
    /// This stash holds the only copy of unsaved drafts, so it is never evicted.
    @ObservationIgnored private var tabsByConversation: [UUID: ConversationViewerState] = [:]

    /// A conversation's viewer state while it is not on screen.
    struct ConversationViewerState {
        var tabs: [CodeViewerTab]
        var activeTabID: UUID?
        var isVisible: Bool
        var presentation: CodeViewerPresentation
    }
    /// The conversation the CURRENT viewer state belongs to. Maintained by
    /// `loadConversation` — NOT derived from `currentChatMessages` at persist time,
    /// because an empty conversation still deserves its session saved.
    @ObservationIgnored private var loadedConversationID: UUID?

    // MARK: - State Properties for Code Viewer
    // Tabs survive the panel being minimized and each owns its diff state; `isCodeViewerVisible` is separate
    // from whether tabs exist, so minimizing keeps the tabs alive.
    var codeViewerTabs: [CodeViewerTab] = [] {
        didSet {
            // Guarded so the mirror is written on the transition only, without relying on Observation
            // suppressing same-value writes.
            let nonEmpty = !codeViewerTabs.isEmpty
            if hasCodeViewerTabs != nonEmpty { hasCodeViewerTabs = nonEmpty }
        }
    }
    // Why: reading `codeViewerTabs` in a view body observes every editor keystroke; read this flag instead.
    /// Mirror of `!codeViewerTabs.isEmpty`, kept in sync by that array's `didSet`.
    /// Lets the derived presentation flags answer without reading the array.
    private(set) var hasCodeViewerTabs: Bool = false
    var activeCodeViewerTabID: UUID? = nil
    /// Whether the panel is on screen. The panel shows when this is `true` AND there is at
    /// least one tab; when `false` with tabs open, the UI shows the floating reopen button.
    var isCodeViewerVisible: Bool = false {
        // Mutual exclusion lives here, not at call sites: three panels share the trailing slot, so showing one hides the others.
        // The `if` stops recursion: the other panels' `didSet`s see false and do nothing.
        didSet {
            if isCodeViewerVisible {
                isBackgroundTasksVisible = false
                isGitChangesVisible = false
            }
        }
    }

    /// Whether the Background Tasks panel is on screen.
    /// Not gated on having tasks, so an empty list stays visible instead of the panel vanishing.
    var isBackgroundTasksVisible: Bool = false {
        didSet {
            if isBackgroundTasksVisible {
                isCodeViewerVisible = false
                isGitChangesVisible = false
            }
        }
    }

    /// Whether the Git Changes panel (Code interface only) is on screen; not gated on content.
    /// The Code-mode gate lives at the mount site and in `FloatingPillStack`.
    var isGitChangesVisible: Bool = false {
        didSet {
            if isGitChangesVisible {
                isCodeViewerVisible = false
                isBackgroundTasksVisible = false
            }
        }
    }
    /// How the panel occupies the window (overlay / split / full, see `CodeViewerPresentation`).
    /// A mode rather than a stored width so it keeps tracking window resizes.
    /// Survives minimize and reopen; cleared with the tabs. Defaults to `.split`.
    var codeViewerPresentation: CodeViewerPresentation = .split
    /// Where the full-width toggle returns to: entering `.full` from `.split` and toggling
    /// back should land in `.split`, not silently forget it.
    @ObservationIgnored private var lastNonFullPresentation: CodeViewerPresentation = .split

    /// How the background tasks panel occupies the window (overlay / split / full).
    /// Defaults to `.split`.
    var backgroundTasksPresentation: CodeViewerPresentation = .split
    @ObservationIgnored private var lastNonFullBackgroundTasksPresentation: CodeViewerPresentation = .split

    /// How the Git Changes panel occupies the window. Defaults to `.split`.
    var gitChangesPresentation: CodeViewerPresentation = .split
    @ObservationIgnored private var lastNonFullGitChangesPresentation: CodeViewerPresentation = .split
    /// The panel's All / Staged / Unstaged filter. Kept here (not in the panel's `@State`) so it
    /// survives closing and reopening the panel.
    var gitChangesFilter: GitChangesFilter = .all

    /// The panel's width while a divider drag is in flight; nil when no drag is running.
    /// Observed on purpose: the chat's trailing inset reads it so the chat tracks the divider during the drag.
    var codeViewerLiveDragWidth: Double? = nil

    /// Per-tab editor view state (cursor, scroll, find). Not observed — see
    /// `CodeViewerEditorStateStore`, which explains why a caret move must not invalidate
    /// any SwiftUI body.
    @ObservationIgnored let codeViewerEditorStates = CodeViewerEditorStateStore()

    /// Set when `applyChanges` cannot write (missing source file, on-disk drift, I/O error) so the panel can show it.
    var codeApplyError: String? = nil

    /// A close request that hit a DIRTY tab and is awaiting the user's decision. The VM
    /// never presents UI — the panel (or floating pill) alerts on these and calls the
    /// `force*` variants to proceed. Close requests on clean tabs never pend.
    var pendingCloseTabID: UUID? = nil
    var isPendingCloseAll: Bool = false

    // MARK: Code Viewer — derived state
    /// The tab currently shown in the panel, or nil when there is no (valid) selection.
    var activeCodeViewerTab: CodeViewerTab? {
        guard let id = activeCodeViewerTabID else { return nil }
        return codeViewerTabs.first { $0.id == id }
    }
    // Why: reads `hasCodeViewerTabs`, not the array, so callers do not observe the editor's per-keystroke writes.
    /// Whether the panel is presented: it is marked visible and at least one tab is open.
    var isCodeViewerPanelPresented: Bool { isCodeViewerVisible && hasCodeViewerTabs }

    /// The Background Tasks panel is presented purely on its own flag — see the property.
    var isBackgroundTasksPanelPresented: Bool { isBackgroundTasksVisible }

    /// The task a card asked the panel to reveal, so opening from a specific row lands on that row
    /// rather than at the top of a list of twenty. Cleared when the panel closes: a stale focus
    /// would re-expand an unrelated task the next time the panel is opened from elsewhere.
    var backgroundTasksFocusTaskID: String? = nil

    /// Opens the task list, closing the Code Viewer. The `didSet` does the closing; this exists so
    /// callers say what they MEAN rather than assigning a flag and relying on a side effect.
    func showBackgroundTasks(focus taskID: String? = nil) {
        backgroundTasksFocusTaskID = taskID
        isBackgroundTasksVisible = true
    }

    func hideBackgroundTasks() {
        isBackgroundTasksVisible = false
        backgroundTasksFocusTaskID = nil
    }

    /// The Git Changes panel is presented purely on its own flag — see the property.
    var isGitChangesPanelPresented: Bool { isGitChangesVisible }

    /// Opens the Git Changes panel, closing the other two (the `didSet` does the closing).
    func showGitChanges() {
        isGitChangesVisible = true
    }

    func hideGitChanges() {
        isGitChangesVisible = false
    }

    /// Task cards saved in ONE conversation's timeline — the task list's history across launches
    /// (see `BackgroundTaskHistory`). Holds only the most recently refreshed conversation: the pill
    /// and the panel both follow `viewerOwningConversationID`, so no second one is ever read.
    private(set) var savedBackgroundTasks: (conversationID: UUID, rows: [BackgroundTaskData])?

    func refreshSavedBackgroundTasks(for conversationID: UUID) async {
        let rows = await persistenceService.fetchBackgroundTaskRows(for: conversationID)
        savedBackgroundTasks = (conversationID, rows)
    }

    /// The task list for a conversation: this launch's live tasks plus its saved history.
    func backgroundTaskItems(for conversationID: UUID) -> [BackgroundTaskListItem] {
        let saved = savedBackgroundTasks?.conversationID == conversationID ? savedBackgroundTasks?.rows ?? [] : []
        return BackgroundTaskHistory.items(
            live: BackgroundProcessRegistry.shared.snapshots(conversationID: conversationID),
            saved: saved,
            clearedBefore: BackgroundTaskHistory.clearedBefore(conversationID))
    }
    /// The floating reopen button shows when the panel was minimized but tabs remain.
    /// Same `hasCodeViewerTabs` reasoning as above.
    var isCodeViewerMinimized: Bool { !isCodeViewerVisible && hasCodeViewerTabs }

    /// Diff state of the ACTIVE tab, as read-only proxies. Per-tab diff is the source of
    /// truth (see `CodeViewerTab`); views and tests read the "current" status through these
    /// so a single shared flag can't leak one tab's diff onto another.

    // MARK: - State Properties for Chat History
    // OPTIMIZATION: Stores messages in Descending order (Newest -> Oldest).
    // This allows O(1) appending of history pages instead of O(n) insertion at index 0.
    var currentChatMessages: [ChatMessage] = []

    // Why: the settled question row stays in: omitting the whole unfinished turn makes the gauge ring fall at send.
    /// The history the next request would carry, oldest-first, resolved through `BackendHistoryResolver`.
    /// Sized from the store rather than the paginated `currentChatMessages`; omits only the live reply (`liveReplyIDs`).
    func resolveContextHistory(for conversationID: UUID) async -> [ChatMessage] {
        // Image bytes omitted: the gauge COUNTS history images (`estimatedHistoryImageTokens`) and
        // never ships them, so loading every screenshot's external blob for it was pure cost.
        let resolved = await BackendHistoryResolver.resolve(
            conversationID: conversationID,
            inMemory: currentChatMessages,
            persistence: persistenceService,
            omittingImageBytes: true
        )
        // Replies only — see the note above on why this is NOT the request path's turn-level set.
        let omitting = activeStreamManager.liveReplyIDs()
        let sized = omitting.isEmpty ? resolved.history
                                     : resolved.history.filter { !omitting.contains($0.id) }
        logger.debug("[CTXGAUGE] Resolved \(sized.count) message(s) for sizing (stored \(resolved.storedCount), resident window \(currentChatMessages.count), omitted \(resolved.history.count - sized.count) in-flight repl\(resolved.history.count - sized.count == 1 ? "y" : "ies"))\(resolved.capHit ? ", CAP HIT" : "") — conv \(conversationID.uuidString.prefix(8))")
        return sized
    }

    // Why: the next turn's history comes from this array; without the splice compaction re-summarizes the same turns.
    /// Splices a history-compaction checkpoint into the live conversation, idempotent by id.
    /// `currentChatMessages` is newest-first, so the checkpoint goes in the middle; ignored for another conversation.
    func insertCheckpoint(_ checkpoint: ChatMessage) {
        guard let loadedConversation = currentChatMessages.first?.conversationId else {
            // Nothing loaded (fresh "new chat" or mid-reload) — a splice here would leave an
            // orphan card floating in an empty transcript. The persisted copy is the truth.
            logger.info("[COMPACTION] Checkpoint \(checkpoint.id.uuidString.prefix(8)) arrived with no conversation loaded — splice skipped (persisted copy loads on open).")
            return
        }
        guard loadedConversation == checkpoint.conversationId else {
            logger.info("[COMPACTION] Checkpoint \(checkpoint.id.uuidString.prefix(8)) is for conversation \(checkpoint.conversationId.uuidString.prefix(8)) but \(loadedConversation.uuidString.prefix(8)) is open — splice skipped (persisted copy loads on reopen).")
            return
        }
        guard !currentChatMessages.contains(where: { $0.id == checkpoint.id }) else {
            logger.info("[COMPACTION] Checkpoint \(checkpoint.id.uuidString.prefix(8)) already present in live history — duplicate insert skipped.")
            return
        }
        let index = Self.descendingInsertionIndex(for: checkpoint.timestamp, in: currentChatMessages)
        currentChatMessages.insert(checkpoint, at: index)
        logger.info("[COMPACTION] Checkpoint \(checkpoint.id.uuidString.prefix(8)) spliced into live history at index \(index) (now \(self.currentChatMessages.count) messages).")
    }

    /// Insertion index for `timestamp` in an array sorted DESCENDING by timestamp.
    /// Pure + internal so the ordering contract is unit-testable without a view model.
    static func descendingInsertionIndex(for timestamp: Date, in messages: [ChatMessage]) -> Int {
        messages.firstIndex { $0.timestamp <= timestamp } ?? messages.count
    }

    var isInitiallyLoadingConversation = false

    var isLoadingPage = false
    /// Whether the store holds messages older than those loaded.
    /// A UI paging concern, read by the scroll-back trigger and `loadMoreMessages`.
    var canLoadMorePages = true

    /// Rows appended by scroll-back pagination since the conversation was loaded.
    /// Used only by `contextGaugeTurnKey`, so paging in older rows does not retrigger the gauge.
    private(set) var olderPagesLoadedCount = 0

    /// Changes when a turn is added, removed or spliced in, but not when scroll-back pages in older rows.
    /// The context gauge recomputes on this rather than on `currentChatMessages.count`.
    var contextGaugeTurnKey: Int { currentChatMessages.count - olderPagesLoadedCount }

    /// How long a gauge recompute waits for a burst of triggers to settle before resolving.
    /// A send fires several triggers within a few milliseconds; the resolve then runs once.
    static let contextGaugeSettle: Duration = .milliseconds(120)

    /// Set when scroll-back stopped because the resident window hit `maxResidentMessages`,
    /// NOT because the store ran out. Kept separate from `canLoadMorePages` precisely so
    /// the history resolver still consults the store (see above).
    var hasReachedResidencyCap = false

    // Why: eviction is unsafe without cursor-based paging: the store offset is derived from the array count.
    /// Ceiling on resident messages; matches `MessagingCoordinator.backendHistoryMessageLimit`.
    /// Bounds growth rather than evicting; `loadMoreMessages` only appends.
    @ObservationIgnored static let maxResidentMessages = 300


    /// Messages outside this many entries of EITHER end keep no parsed-markdown cache.
    /// The cache is derived data rebuilt on demand by `getOrCreateMarkdownBlocks`, so
    /// dropping it is free of behaviour change — only recompute cost when scrolled back to.
    @ObservationIgnored static let markdownCacheWindow = 60
    @ObservationIgnored private let initialPageSize = 20
    @ObservationIgnored private let subsequentPageSize = 10

    // Bumped on every `loadConversation` entry; a load captures its epoch and drops its results
    // if a newer load started while it awaited persistence.
    @ObservationIgnored private var loadEpoch: UInt64 = 0


    var isSending: Bool = false

    // MARK: - Initialization
    /// Whether this instance drives the Code Viewer; exactly one view model may own it.
    /// QuickAccess mounts no Code Viewer UI, so it must not own it. Defaults to `false` so a new view model is inert.
    @ObservationIgnored private let ownsCodeViewer: Bool

    init(
        persistenceService: ChatPersistenceProtocol = ChatPersistenceStore.shared,
        activeStreamManager: ActiveStreamManager,
        ownsCodeViewer: Bool = false
    ) {
        self.persistenceService = persistenceService
        self.activeStreamManager = activeStreamManager
        self.ownsCodeViewer = ownsCodeViewer
        if ownsCodeViewer {
            observeAgentLiveWrites()
        }
        logger.info("ChatHistoryViewModel initialized (ownsCodeViewer: \(ownsCodeViewer)).")
    }

    // Why: QuickAccess's view model is built in `State(wrappedValue:)`, which can run for discarded view structs.
    /// Removes the live-write observers, which otherwise outlive the instance.
    deinit {
        liveWriteObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Live agent tabs (badge-only)

    /// `nonisolated(unsafe)` so `deinit` can remove these; appended only in `init` and read only in `deinit`,
    /// both of which have exclusive access to the instance.
    @ObservationIgnored private nonisolated(unsafe) var liveWriteObservers: [NSObjectProtocol] = []

    private func observeAgentLiveWrites() {
        liveWriteObservers.append(NotificationCenter.default.addObserver(
            forName: AgentLiveWriteEvent.began, object: nil, queue: .main
        ) { [weak self] note in
            guard let payload = note.userInfo?[AgentLiveWriteEvent.payloadKey] as? AgentLiveWriteEvent.Began else { return }
            Task { @MainActor [weak self] in self?.handleAgentWriteBegan(payload) }
        })
        liveWriteObservers.append(NotificationCenter.default.addObserver(
            forName: AgentLiveWriteEvent.completed, object: nil, queue: .main
        ) { [weak self] note in
            guard let payload = note.userInfo?[AgentLiveWriteEvent.payloadKey] as? AgentLiveWriteEvent.Completed else { return }
            Task { @MainActor [weak self] in self?.handleAgentWriteCompleted(payload) }
        })
    }

    /// Any tab with an in-flight agent write — drives the pill's pulse and the chip dots.
    var hasLiveAgentTabs: Bool { codeViewerTabs.contains { $0.liveState == .active } }

    /// A file write is starting: opens or updates its tab in the background.
    /// Never shows the panel, never changes the active tab (unless follow is on and the panel is visible),
    /// and never touches a tab holding unsaved user edits.
    func handleAgentWriteBegan(_ payload: AgentLiveWriteEvent.Began) {
        // Compare against the destination conversation, not the displayed one: during a switch
        // `currentChatMessages` still holds the outgoing conversation until the fetch returns.
        guard payload.conversationID == destinationConversationID else {
            logger.info("[CodeViewer] Live write for '\(payload.fileName)' ignored — it belongs to conversation \(payload.conversationID.uuidString.prefix(8)) but \(self.destinationConversationID?.uuidString.prefix(8) ?? "none") is \(self.loadingConversationID == nil ? "loaded" : "loading"). No live tab; the timeline chip still appears when that conversation is open.")
            return
        }

        // Plant no tab while a load is in flight: `restoreCodeViewerSession` only restores into an empty viewer,
        // so a planted tab would skip the incoming restore and later overwrite its stashed drafts.
        guard loadingConversationID == nil else {
            logger.info("[CodeViewer] Live write for '\(payload.fileName)' NOT given a tab — a conversation load is in flight (\(self.loadingConversationID?.uuidString.prefix(8) ?? "none")). CONSEQUENCE: no tab is planted, which is deliberate — planting one here would suppress that conversation's own tab restore and the next switch would overwrite its stash, losing unsaved drafts. The write proceeds and its timeline chip is unaffected.")
            return
        }

        let snippet = CodeSnippet(
            codeBlock: CodeSnippet.languageHint(forFileName: payload.fileName),
            content: payload.proposedContent
        )
        guard !snippet.code.isEmpty else { return }

        if let index = codeViewerTabs.firstIndex(where: { $0.filePath == payload.path }) {
            guard !codeViewerTabs[index].isDirty else {
                // The user has a draft in this file's tab — a live replacement would
                // destroy it. The completion chip on the timeline remains the manual path.
                logger.warning("[CodeViewer] Live write for '\(payload.fileName)' SKIPPED — its tab holds unsaved user edits (draft preserved; open via the timeline chip instead).")
                return
            }
            // Successive writes to the same file reuse its tab; replacing content needs a new snippet (code is `let`).
            codeViewerTabs[index].snippet = snippet
            codeViewerTabs[index].liveState = .active
            // Clear `editedCode` too: a saved tab is clean (`isDirty` false), so a stale buffer would override the agent's
            // new content and a later ⌘S would write it back.
            codeViewerTabs[index].editedCode = nil
            codeViewerTabs[index].lastSavedBuffer = nil
            codeViewerTabs[index].lastSavedDisk = nil
            // Cleared too: the previous write's snapshot is stale, and the async pre-read below could otherwise
            // promote stale bytes as the baseline.
            codeViewerTabs[index].preWriteDisk = nil
            logger.info("[CodeViewer] Live write updating tab '\(payload.fileName)' (\(snippet.code.count) chars).")
        } else {
            var tab = CodeViewerTab(snippet: snippet, fileName: payload.fileName, filePath: payload.path)
            tab.liveState = .active
            codeViewerTabs.append(tab)
            // Background by design: no visibility change, no activation — unless this is
            // the only tab, where SOME selection is needed for the panel/pill to open onto.
            if activeCodeViewerTabID == nil { activeCodeViewerTabID = tab.id }
            logger.info("[CodeViewer] Live write opened background tab '\(payload.fileName)' (\(snippet.code.count) chars) — panel not auto-opened (badge-only policy).")
        }

        // Follow toggle: only ever switches tabs INSIDE an already-open panel.
        if UserDefaults.standard.bool(forKey: "codeViewerFollowAgent"), isCodeViewerPanelPresented,
           let liveID = codeViewerTabs.first(where: { $0.filePath == payload.path })?.id {
            activeCodeViewerTabID = liveID
        }

        // Pre-reads the on-disk state and parks it on the tab as `preWriteDisk`; if the write is denied or fails
        // it is the drift baseline. A user denial carries no executor snapshot, so this size-capped read is the only one.
        let path = payload.path
        let preRead = Task { [weak self] in
            let pre = await Task.detached(priority: .utility) { () -> String? in
                guard FileManager.default.fileExists(atPath: path) else { return "" }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      (attributes[.size] as? Int ?? .max) <= AgentLiveWriteEvent.liveContentByteLimit,
                      let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                return content
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let pre else {
                    logger.info("[CodeViewer] No pre-write snapshot for '\((path as NSString).lastPathComponent)' — unreadable or over the \(AgentLiveWriteEvent.liveContentByteLimit)-byte cap. CONSEQUENCE: if this write is denied or fails, ⌘S on its tab is refused as on-disk drift and Save As is the only route.")
                    return
                }
                guard let index = self.codeViewerTabs.firstIndex(where: { $0.filePath == path }),
                      !self.codeViewerTabs[index].isDirty else { return }
                switch self.codeViewerTabs[index].liveState {
                case .active:
                    // The ordinary case: the write is still in flight, park the baseline for it.
                    self.codeViewerTabs[index].preWriteDisk = pre
                case .rejected where self.codeViewerTabs[index].lastSavedDisk == nil:
                    // If the write was already settled as rejected while this read was in flight, promote the bytes to the
                    // baseline now; otherwise `lastSavedDisk` stays nil and ⌘S is refused as drift.
                    self.codeViewerTabs[index].lastSavedDisk = pre
                    self.codeViewerTabs[index].preWriteDisk = nil
                    logger.info("[CodeViewer] Pre-write snapshot for '\((path as NSString).lastPathComponent)' landed AFTER the write was already settled as rejected — promoted it straight to the drift baseline. CONSEQUENCE: ⌘S on that tab writes the proposal instead of being refused as drift for the rest of the session.")
                default:
                    // Settled successfully, or the badge was cleared — the baseline is moot.
                    return
                }
            }
        }
        #if DEBUG
        preWriteReadTaskForTesting = preRead
        #else
        _ = preRead
        #endif
    }

    #if DEBUG
    /// Test seam: the most recent pre-read fired by `handleAgentWriteBegan`.
    /// The read runs off the main actor, so tests await this task instead of polling.
    @ObservationIgnored private(set) var preWriteReadTaskForTesting: Task<Void, Never>?
    #endif

    /// Settles the tab on success, or marks it rejected when the write was denied or failed.
    /// On rejection the drift baseline is the pre-write bytes: the executor's snapshot if present,
    /// otherwise the pre-read parked by `handleAgentWriteBegan`.
    func handleAgentWriteCompleted(_ payload: AgentLiveWriteEvent.Completed) {
        // Settle against the payload's own conversation, live or stashed, not the displayed one: a switch
        // moves the still-active tab into `tabsByConversation`, and it must be settled there.
        guard let location = residence(ofLiveWritePath: payload.path, in: payload.conversationID) else {
            logger.debug("[CodeViewer] Live-write completion for '\(payload.fileName)' has no active live tab in conversation \(payload.conversationID.uuidString.prefix(8)) — settled earlier, never given a tab (a load was in flight), or the tab was closed.")
            return
        }

        var settledMessage = ""
        mutateTab(at: location) { tab in
            if payload.isSuccess {
                tab.liveState = nil
                // The proposal is on disk, so the pre-write bytes must not become the drift baseline:
                // `lastSavedDisk` stays nil and the guard falls back to `snippet.code`.
                tab.preWriteDisk = nil
                settledMessage = "[CodeViewer] Live tab '\(payload.fileName)' settled — write landed."
            } else {
                tab.liveState = .rejected
                let baseline = payload.preWriteContent ?? tab.preWriteDisk
                tab.lastSavedDisk = baseline
                tab.preWriteDisk = nil
                if baseline == nil {
                    settledMessage = "[CodeViewer] Live tab '\(payload.fileName)' marked rejected with NO pre-write snapshot (the completion carried none and the pre-read failed or was over the cap). CONSEQUENCE: the save guard falls back to the proposal, so ⌘S on this tab is refused as on-disk drift; Save As is the only route."
                } else {
                    let source = payload.preWriteContent != nil ? "the executor's snapshot" : "the UI pre-read"
                    settledMessage = "[CodeViewer] Live tab '\(payload.fileName)' marked rejected — the write was denied or failed; its content never reached disk. Drift baseline set from \(source) (\(baseline?.count ?? 0) chars) so ⌘S can still write the proposal."
                }
            }
        }

        switch location {
        case .live:
            logger.info("\(settledMessage)")
        case .stashed(let conversationID, _):
            logger.info("\(settledMessage) Settled on the STASHED copy for conversation \(conversationID.uuidString.prefix(8)) — the user switched away while the write was in flight, so the state is correct when that conversation is reopened.")
        }
    }

    // MARK: - Code Viewer Panel Control

    /// Index of the active tab in `codeViewerTabs`, or nil if there's no valid selection.
    private var activeCodeViewerTabIndex: Int? {
        guard let id = activeCodeViewerTabID else { return nil }
        return codeViewerTabs.firstIndex { $0.id == id }
    }

    /// Finds the open tab a snippet belongs to. Matches on CONTENT + source link (via
    /// `denotesSameBlock`), not tab id — the panel hands us the snippet it's displaying, not
    /// the tab. Dedup at open time guarantees at most one match.
    private func tabIndex(for snippet: CodeSnippet) -> Int? {
        codeViewerTabs.firstIndex {
            $0.snippet.denotesSameBlock(as: snippet) && $0.snippet.sourceFileID == snippet.sourceFileID
        }
    }

    // MARK: - Tab residence (live viewer OR conversation stash)

    /// Where a tab lives right now: in the live array or in a conversation's stash.
    /// Save bookkeeping that resumes after an await must check both, since the user can switch conversations mid-save.
    private enum TabResidence {
        case live(index: Int)
        case stashed(conversationID: UUID, index: Int)
    }

    /// Finds a tab by id in the live viewer, else in any conversation's stash. Ids are
    /// UUIDs, so at most one entry can match and the dictionary's order does not matter.
    private func residence(ofTabID id: UUID) -> TabResidence? {
        if let index = codeViewerTabs.firstIndex(where: { $0.id == id }) { return .live(index: index) }
        for (conversationID, state) in tabsByConversation {
            if let index = state.tabs.firstIndex(where: { $0.id == id }) {
                return .stashed(conversationID: conversationID, index: index)
            }
        }
        return nil
    }

    /// Finds the tab with an in-flight agent write for `path`, scoped to one conversation (live viewer or its stash).
    /// Scoped because a path is not unique across conversations; only `.active` tabs match,
    /// so a repeated completion is a no-op.
    private func residence(ofLiveWritePath path: String, in conversationID: UUID) -> TabResidence? {
        let isLiveWriteTab: (CodeViewerTab) -> Bool = { $0.filePath == path && $0.liveState == .active }
        // The live array belongs to `conversationID` only when that conversation owns the viewer;
        // mid-load it is empty and the stash answers.
        if viewerOwningConversationID == conversationID,
           let index = codeViewerTabs.firstIndex(where: isLiveWriteTab) {
            return .live(index: index)
        }
        if let state = tabsByConversation[conversationID],
           let index = state.tabs.firstIndex(where: isLiveWriteTab) {
            return .stashed(conversationID: conversationID, index: index)
        }
        return nil
    }

    /// The same lookup keyed on a SNIPPET (content + source link), for `performApplyChanges`,
    /// which is handed the snippet the panel displays rather than a tab id.
    private func residence(ofSnippet snippet: CodeSnippet) -> TabResidence? {
        if let index = tabIndex(for: snippet) { return .live(index: index) }
        for (conversationID, state) in tabsByConversation {
            if let index = state.tabs.firstIndex(where: {
                $0.snippet.denotesSameBlock(as: snippet) && $0.snippet.sourceFileID == snippet.sourceFileID
            }) {
                return .stashed(conversationID: conversationID, index: index)
            }
        }
        return nil
    }

    /// Applies a mutation wherever the tab currently lives. Re-validates the index because
    /// the caller may have awaited since resolving it.
    private func mutateTab(at residence: TabResidence, _ body: (inout CodeViewerTab) -> Void) {
        switch residence {
        case .live(let index):
            guard codeViewerTabs.indices.contains(index) else { return }
            body(&codeViewerTabs[index])
        case .stashed(let conversationID, let index):
            guard var state = tabsByConversation[conversationID],
                  state.tabs.indices.contains(index) else { return }
            body(&state.tabs[index])
            tabsByConversation[conversationID] = state
        }
    }

    /// Opens a code block in a tab: focuses the existing tab if this exact block is open, otherwise appends one.
    /// Always makes the panel visible and the tab active.
    /// Dedup is by content plus source link, tolerating a nil link because linking is stamped on open tabs asynchronously.
    @discardableResult
    func openTab(for snippet: CodeSnippet, fileName: String? = nil, filePath: String? = nil,
                 originMessageID: UUID? = nil, originBlockIndex: Int? = nil) -> UUID {
        // A file-backed tab is identified by its PATH. Matching on `fileName` alone merges
        // `src/Main.java` and `test/Main.java` into a single tab.
        if let filePath, let index = codeViewerTabs.firstIndex(where: { $0.filePath == filePath }) {
            // Refresh the content unless the user has unsaved edits. The `!= snippet.code` test keeps a saved tab
            // from reverting to the chip's stale inline content on reopen.
            if !codeViewerTabs[index].isDirty, codeViewerTabs[index].snippet.code != snippet.code {
                codeViewerTabs[index].snippet = snippet
                // Same reset as `handleAgentWriteBegan`: clear the edit buffer and save baseline so the tab
                // genuinely adopts the new snippet.
                codeViewerTabs[index].editedCode = nil
                codeViewerTabs[index].lastSavedBuffer = nil
                codeViewerTabs[index].lastSavedDisk = nil
                logger.info("[CodeViewer] Reopen of '\(filePath)' adopted \(snippet.code.count) fresh chars and reset the tab's save baseline — the file changed since this tab last read it.")
            } else if codeViewerTabs[index].isDirty {
                logger.info("[CodeViewer] Reopen of '\(filePath)' kept the tab's unsaved draft — content not refreshed.")
            }
            activeCodeViewerTabID = codeViewerTabs[index].id
            isCodeViewerVisible = true
            return codeViewerTabs[index].id
        }
        // A chat block is identified by its origin, not its text: reopening a message whose stream advanced
        // refreshes that tab instead of appending a second one with a truncated fragment.
        if let originMessageID, let originBlockIndex,
           let index = codeViewerTabs.firstIndex(where: {
               $0.originMessageID == originMessageID && $0.originBlockIndex == originBlockIndex
           }) {
            if codeViewerTabs[index].isDirty {
                logger.info("[CodeViewer] Reopen of block \(originBlockIndex) from message \(originMessageID.uuidString.prefix(8)) kept the tab's unsaved draft — content not refreshed.")
            } else if codeViewerTabs[index].snippet.code != snippet.code {
                codeViewerTabs[index].snippet = snippet
                if let fileName { codeViewerTabs[index].fileName = fileName }
                // Clear the save/draft baseline with the snippet so a saved or reverted tab shows the reopened block.
                codeViewerTabs[index].editedCode = nil
                codeViewerTabs[index].lastSavedBuffer = nil
                codeViewerTabs[index].lastSavedDisk = nil
                logger.info("[CodeViewer] Refreshed tab \(self.codeViewerTabs[index].id.uuidString.prefix(8)) in place — the block grew to \(snippet.code.count) chars since it was opened (message was still streaming). No duplicate tab.")
            }
            activeCodeViewerTabID = codeViewerTabs[index].id
            isCodeViewerVisible = true
                return codeViewerTabs[index].id
        }
        if let existing = codeViewerTabs.first(where: {
            $0.snippet.denotesSameBlock(as: snippet)
                && ($0.snippet.sourceFileID == snippet.sourceFileID
                    || $0.snippet.sourceFileID == nil || snippet.sourceFileID == nil)
        }) {
            // Adopt a link the tab is missing in place. Mutate the field, not the snippet:
            // a new snippet id would rebuild the editor under the user.
            if existing.snippet.sourceFileID == nil, snippet.sourceFileID != nil,
               let index = codeViewerTabs.firstIndex(where: { $0.id == existing.id }) {
                codeViewerTabs[index].snippet.sourceMessageID = snippet.sourceMessageID
                codeViewerTabs[index].snippet.sourceFileID = snippet.sourceFileID
                logger.info("[CodeViewer] Adopted source link onto existing tab \(existing.id.uuidString.prefix(8)).")
            }
            activeCodeViewerTabID = existing.id
            isCodeViewerVisible = true
            logger.debug("[CodeViewer] Focused existing tab \(existing.id.uuidString.prefix(8)) — \(self.codeViewerTabs.count) tab(s) open.")
            return existing.id
        }
        let tab = CodeViewerTab(snippet: snippet, fileName: fileName, filePath: filePath,
                                originMessageID: originMessageID, originBlockIndex: originBlockIndex)
        codeViewerTabs.append(tab)
        activeCodeViewerTabID = tab.id
        isCodeViewerVisible = true
        logger.info("[CodeViewer] Opened tab \(tab.id.uuidString.prefix(8)) (\(fileName ?? snippet.language ?? "untitled")) — \(self.codeViewerTabs.count) tab(s) open.")
        return tab.id
    }

    /// Ad-hoc single-block open with no source link (speech read-aloud, user-file card).
    func showCodeInViewer(language: String?, code: String) {
        openTab(for: CodeSnippet(language: language, code: code), fileName: nil)
        logger.info("Code viewer tab opened for language: \(language ?? "nil").")
    }

    /// Whether this view model has a Code Viewer to open into at all.
    /// QuickAccess mounts none, so surfaces there must not offer an "open in viewer" affordance.
    var canPresentCodeViewer: Bool { ownsCodeViewer }

    /// Opens a file from an agent-timeline tool row in the Code Viewer, with its language inferred from the extension.
    /// When a pre-write snapshot exists the tab opens into a read-only diff of what the agent changed; Apply stays off.
    func openTimelineFileInCodeViewer(fileName: String, filePath: String? = nil, content: String) {
        let snippet = CodeSnippet(
            codeBlock: CodeSnippet.languageHint(forFileName: fileName),
            content: content
        )
        guard !snippet.code.isEmpty else {
            logger.warning("[CodeViewer] Timeline open for '\(fileName)' skipped — empty content.")
            return
        }
        openTab(for: snippet, fileName: fileName, filePath: filePath)
        logger.info("[CodeViewer] Timeline opened '\(fileName)' (\(snippet.code.count) chars).")
    }

    // MARK: - Tab management

    func selectCodeViewerTab(id: UUID) {
        guard codeViewerTabs.contains(where: { $0.id == id }) else { return }
        activeCodeViewerTabID = id
    }

    // Why: no boundary syncing: one missed boundary is silent data loss; dirtiness is decided by comparison, not by nil.
    /// Writes the editor buffer through to the tab on every keystroke.
    /// Always stores the content, even when it equals the restore point, so `editedCode == nil` only means no draft.
    /// Skips the write when the buffer already holds this text, so a rebuilt editor does not invalidate readers.
    func updateCodeViewerDraft(tabID: UUID, content: String) {
        guard let index = codeViewerTabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard codeViewerTabs[index].editedCode != content else { return }
        codeViewerTabs[index].editedCode = content
    }

    /// Updates the syntax language override for a specific tab.
    func updateCodeViewerTabLanguage(tabID: UUID, language: String) {
        guard let index = codeViewerTabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard codeViewerTabs[index].customLanguage != language else { return }
        codeViewerTabs[index].customLanguage = language
        logger.info("[CodeViewer] Language for tab \(tabID.uuidString.prefix(8)) updated to '\(language)'.")
    }

    /// Closes one tab, pending a confirmation first when it holds unsaved edits.
    func closeCodeViewerTab(id: UUID) {
        if let tab = codeViewerTabs.first(where: { $0.id == id }), tab.isDirty {
            pendingCloseTabID = id
            logger.info("[CodeViewer] Close requested on dirty tab \(id.uuidString.prefix(8)) — awaiting confirmation.")
            return
        }
        forceCloseCodeViewerTab(id: id)
    }

    /// Closes one tab unconditionally (the user confirmed discarding, or it was clean).
    /// If it was active, focuses a neighbour; if it was the last tab, the viewer is fully
    /// dismissed (no tabs ⇒ nothing to reopen).
    func forceCloseCodeViewerTab(id: UUID) {
        pendingCloseTabID = nil
        guard let index = codeViewerTabs.firstIndex(where: { $0.id == id }) else { return }
        if codeViewerTabs[index].isDirty {
            logger.warning("[CodeViewer] Discarding unsaved edits in tab \(id.uuidString.prefix(8)) (user-confirmed).")
        }
        let wasActive = (activeCodeViewerTabID == id)
        codeViewerTabs.remove(at: index)
        // CLOSED, not stashed — its cursor/scroll are gone with it, so nothing should keep
        // holding them. (A conversation switch must NOT do this: those tabs come back.)
        codeViewerEditorStates.forget(tabIDs: [id])

        if codeViewerTabs.isEmpty {
            activeCodeViewerTabID = nil
            isCodeViewerVisible = false
            codeViewerPresentation = .split
            lastNonFullPresentation = .split
            codeApplyError = nil
            dropStashedTabs(reason: "the last tab was closed")
            logger.info("[CodeViewer] Last tab closed — viewer dismissed.")
                return
        }
        if wasActive {
            // Focus the tab that shifted into this slot, else the new last tab.
            let neighbour = codeViewerTabs.indices.contains(index) ? index : codeViewerTabs.count - 1
            activeCodeViewerTabID = codeViewerTabs[neighbour].id
        }
        logger.info("[CodeViewer] Closed tab \(id.uuidString.prefix(8)) — \(self.codeViewerTabs.count) tab(s) remain.")
    }

    /// Closes all tabs except the specified one, prompting for confirmation if any holds unsaved edits.
    func closeOtherCodeViewerTabs(exceptID: UUID) {
        let otherTabs = codeViewerTabs.filter { $0.id != exceptID }
        guard !otherTabs.isEmpty else { return }

        if let dirtyTab = otherTabs.first(where: \.isDirty) {
            pendingCloseTabID = dirtyTab.id
            logger.info("[CodeViewer] Close-others requested with dirty tab \(dirtyTab.id.uuidString.prefix(8)) — awaiting confirmation.")
            return
        }

        forceCloseOtherCodeViewerTabs(exceptID: exceptID)
    }

    /// Closes all tabs except the specified one unconditionally.
    func forceCloseOtherCodeViewerTabs(exceptID: UUID) {
        guard let retained = codeViewerTabs.first(where: { $0.id == exceptID }) else { return }
        let toRemove = codeViewerTabs.filter { $0.id != exceptID }
        guard !toRemove.isEmpty else { return }
        codeViewerEditorStates.forget(tabIDs: toRemove.map(\.id))
        codeViewerTabs = [retained]
        activeCodeViewerTabID = retained.id
        logger.info("[CodeViewer] Closed \(toRemove.count) other tab(s) — retained \(retained.id.uuidString.prefix(8)).")
    }

    /// Closes all tabs situated to the right of the given tab ID, prompting if any holds unsaved edits.
    func closeTabsToTheRight(ofID: UUID) {
        guard let index = codeViewerTabs.firstIndex(where: { $0.id == ofID }) else { return }
        let rightIndices = (index + 1)..<codeViewerTabs.count
        guard !rightIndices.isEmpty else { return }
        let rightTabs = Array(codeViewerTabs[rightIndices])

        if let dirtyTab = rightTabs.first(where: \.isDirty) {
            pendingCloseTabID = dirtyTab.id
            logger.info("[CodeViewer] Close-tabs-to-right requested with dirty tab \(dirtyTab.id.uuidString.prefix(8)) — awaiting confirmation.")
            return
        }

        forceCloseTabsToTheRight(ofID: ofID)
    }

    /// Closes all tabs situated to the right of the given tab ID unconditionally.
    func forceCloseTabsToTheRight(ofID: UUID) {
        guard let index = codeViewerTabs.firstIndex(where: { $0.id == ofID }) else { return }
        let rightIndices = (index + 1)..<codeViewerTabs.count
        guard !rightIndices.isEmpty else { return }
        let toRemove = Array(codeViewerTabs[rightIndices])
        codeViewerEditorStates.forget(tabIDs: toRemove.map(\.id))
        codeViewerTabs.removeSubrange(rightIndices)
        if let activeID = activeCodeViewerTabID, toRemove.contains(where: { $0.id == activeID }) {
            activeCodeViewerTabID = ofID
        }
        logger.info("[CodeViewer] Closed \(toRemove.count) tab(s) to the right of \(ofID.uuidString.prefix(8)).")
    }

    /// Closes every tab and dismisses the viewer, pending a confirmation first when any
    /// tab holds unsaved edits.
    func closeAllCodeViewerTabs() {
        // Any unsaved edits pend a confirmation; the panel/pill alerts and calls the
        // force variant on "Discard".
        if codeViewerTabs.contains(where: \.isDirty) {
            isPendingCloseAll = true
            logger.info("[CodeViewer] Close-all requested with dirty tab(s) — awaiting confirmation.")
            return
        }
        forceCloseAllCodeViewerTabs()
    }

    /// Closes every tab unconditionally (the user confirmed discarding, or all were clean).
    func forceCloseAllCodeViewerTabs() {
        isPendingCloseAll = false
        pendingCloseTabID = nil
        guard !codeViewerTabs.isEmpty || isCodeViewerVisible else { return }
        let dirtyCount = codeViewerTabs.filter(\.isDirty).count
        if dirtyCount > 0 {
            logger.warning("[CodeViewer] Discarding unsaved edits in \(dirtyCount) tab(s) (user-confirmed close-all).")
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            let count = codeViewerTabs.count
            // Same rule as the single close: these tabs are gone, so their editor state
            // goes with them. Other conversations' STASHED tabs keep theirs.
            codeViewerEditorStates.forget(tabIDs: codeViewerTabs.map(\.id))
            codeViewerTabs.removeAll()
            activeCodeViewerTabID = nil
            isCodeViewerVisible = false
            codeViewerPresentation = .split
            lastNonFullPresentation = .split
            codeApplyError = nil
            dropStashedTabs(reason: "the user closed all tabs")
            logger.info("[CodeViewer] All tabs closed (\(count) dismissed).")
        }
    }

    /// Toggles full-width presentation. Restores the mode it was entered FROM (overlay or
    /// split), so full is a temporary zoom rather than a mode-destroying jump.
    func toggleCodeViewerExpansion() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if codeViewerPresentation == .full {
                codeViewerPresentation = lastNonFullPresentation
            } else {
                lastNonFullPresentation = codeViewerPresentation
                codeViewerPresentation = .full
            }
        }
        logger.info("[CodeViewer] Presentation → \(self.codeViewerPresentation.rawValue).")
    }

    /// Toggles the side-by-side split with the chat. From full-width it goes
    /// straight to split (the user asked for split — routing through overlay first would
    /// just add a flicker).
    func toggleCodeViewerSplit() {
        withAnimation(.easeInOut(duration: 0.25)) {
            codeViewerPresentation = (codeViewerPresentation == .split) ? .overlay : .split
            lastNonFullPresentation = codeViewerPresentation
        }
        logger.info("[CodeViewer] Presentation → \(self.codeViewerPresentation.rawValue).")
    }

    /// Toggles full-width presentation for the background tasks panel.
    func toggleBackgroundTasksExpansion() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if backgroundTasksPresentation == .full {
                backgroundTasksPresentation = lastNonFullBackgroundTasksPresentation
            } else {
                lastNonFullBackgroundTasksPresentation = backgroundTasksPresentation
                backgroundTasksPresentation = .full
            }
        }
        logger.info("[BackgroundTasks] Presentation → \(self.backgroundTasksPresentation.rawValue).")
    }

    /// Toggles side-by-side split with the chat for the background tasks panel. From full-width it goes straight to split.
    func toggleBackgroundTasksSplit() {
        withAnimation(.easeInOut(duration: 0.25)) {
            backgroundTasksPresentation = (backgroundTasksPresentation == .split) ? .overlay : .split
            lastNonFullBackgroundTasksPresentation = backgroundTasksPresentation
        }
        logger.info("[BackgroundTasks] Presentation → \(self.backgroundTasksPresentation.rawValue).")
    }

    /// Toggles full-width presentation for the Git Changes panel.
    func toggleGitChangesExpansion() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if gitChangesPresentation == .full {
                gitChangesPresentation = lastNonFullGitChangesPresentation
            } else {
                lastNonFullGitChangesPresentation = gitChangesPresentation
                gitChangesPresentation = .full
            }
        }
        logger.info("[GitUI] Presentation → \(self.gitChangesPresentation.rawValue).")
    }

    /// Toggles side-by-side split with the chat for the Git Changes panel. From full-width it goes straight to split.
    func toggleGitChangesSplit() {
        withAnimation(.easeInOut(duration: 0.25)) {
            gitChangesPresentation = (gitChangesPresentation == .split) ? .overlay : .split
            lastNonFullGitChangesPresentation = gitChangesPresentation
        }
        logger.info("[GitUI] Presentation → \(self.gitChangesPresentation.rawValue).")
    }

    /// Hides the panel but KEEPS the tabs — the floating reopen button takes over.
    func minimizeCodeViewer() {
        guard !codeViewerTabs.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) { isCodeViewerVisible = false }
        logger.info("[CodeViewer] Panel minimized — \(self.codeViewerTabs.count) tab(s) retained.")
    }

    /// Brings the panel back after a minimize.
    func reopenCodeViewer() {
        guard !codeViewerTabs.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) { isCodeViewerVisible = true }
        logger.info("[CodeViewer] Panel reopened — \(self.codeViewerTabs.count) tab(s).")
    }

    // MARK: - Session persistence (tabs survive conversation switches; NOT app relaunch)

    // Why: the reset decision and the stash key must share this one expression, or tabs clear under an unresolvable key.
    /// The conversation the currently open tabs belong to.
    /// Reads `loadedConversationID` first because callers clear `currentChatMessages` before a load runs;
    /// the messages are the fallback before the first load.
    var viewerOwningConversationID: UUID? {
        loadedConversationID ?? currentChatMessages.first?.conversationId
    }

    // Why: keep this as viewer identity; folding a pending destination into it dropped completions and misfiled tabs.
    /// The conversation an event arriving right now belongs to: the incoming one during a load, else the one on screen.
    /// Mid-switch consumers must ask this, not `currentChatMessages`, which still holds the outgoing rows.
    /// Code that cannot tolerate the incoming answer during a load must also check `isInitiallyLoadingConversation`.
    var destinationConversationID: UUID? {
        loadingConversationID ?? viewerOwningConversationID
    }

    /// Destination of the in-flight `loadConversation`, nil when no load is in flight.
    /// Written only by `loadConversation`; see `destinationConversationID`.
    private var loadingConversationID: UUID?

    /// Brings back this conversation's tabs from the in-session store. No-op on a
    /// same-conversation reload — tabs weren't cleared, so the tabs-empty guard skips it.
    func restoreCodeViewerSession(for conversationID: UUID) {
        guard ownsCodeViewer, codeViewerTabs.isEmpty,
              let state = tabsByConversation[conversationID], !state.tabs.isEmpty else { return }
        codeViewerTabs = state.tabs
        activeCodeViewerTabID = state.activeTabID ?? state.tabs.first?.id
        isCodeViewerVisible = state.isVisible
        codeViewerPresentation = state.presentation
        if state.presentation != .full { lastNonFullPresentation = state.presentation }
        let drafts = state.tabs.filter(\.isDirty).count
        logger.info("[CodeViewer] Restored \(state.tabs.count) tab(s) for \(conversationID.uuidString.prefix(8)) (visible: \(state.isVisible), \(drafts) with drafts).")
    }

    /// Forgets this conversation's stashed tabs because the user emptied the viewer.
    /// Called from the close paths rather than inferred from an empty viewer, since only a close knows it was intentional.
    private func dropStashedTabs(reason: String) {
        guard ownsCodeViewer else { return }
        // Never drop during a load: the identity still names the outgoing conversation, so this would delete its stash.
        // A backstop with no current caller; keep it, since it protects unsaved drafts if a mid-load path appears.
        guard loadingConversationID == nil else {
            logger.warning("[CodeViewer] Deferred dropping stashed tabs (\(reason)) — a conversation switch is still in flight, and the resolvable identity is the OUTGOING conversation whose tabs and drafts are already stashed. CONSEQUENCE: nothing was dropped; tabs closed during the switch may reappear when that conversation is reopened.")
            return
        }
        guard let conversationID = viewerOwningConversationID else {
            logger.warning("[CodeViewer] Could not drop stashed tabs (\(reason)) — no conversation identity is resolvable; any stale entry is left in place and may be restored on the next open.")
            return
        }
        guard tabsByConversation.removeValue(forKey: conversationID) != nil else { return }
        logger.info("[CodeViewer] Dropped in-session tabs for \(conversationID.uuidString.prefix(8)) — \(reason).")
    }

    /// Hands the current conversation's tabs to the in-session store before the viewer is
    /// cleared. Must run BEFORE `loadedConversationID` moves, or the tabs get filed under
    /// the INCOMING conversation.
    @discardableResult
    private func stashCurrentCodeViewerTabs() -> Bool {
        guard ownsCodeViewer else { return false }
        // Empties are checked before identity: with nothing open there is nothing to lose, and identity is unresolved
        // on first launch.
        guard !codeViewerTabs.isEmpty else {
            // Nothing is dropped here: an empty viewer can also mean an in-flight switch cleared it, so the close paths
            // drop entries explicitly via `dropStashedTabs`.
            logger.debug("[CodeViewer] Nothing to stash for \(self.viewerOwningConversationID?.uuidString.prefix(8) ?? "no loaded conversation") — viewer already empty; any existing entry is left intact.")
            return true
        }
        guard let conversationID = viewerOwningConversationID else {
            // Logged as an error: this path discards unsaved drafts that exist nowhere else.
            let drafts = codeViewerTabs.filter(\.isDirty).count
            logger.error("[CodeViewer] CANNOT stash \(self.codeViewerTabs.count) open tab(s) (\(drafts) with unsaved draft(s)) — no conversation identity is resolvable, so they cannot be filed for restore. They are about to be cleared and any unsaved draft is LOST.")
            return false
        }
        tabsByConversation[conversationID] = ConversationViewerState(
            tabs: codeViewerTabs,
            activeTabID: activeCodeViewerTabID,
            isVisible: isCodeViewerVisible,
            presentation: codeViewerPresentation
        )
        logger.info("[CodeViewer] Stashed \(self.codeViewerTabs.count) tab(s) for \(conversationID.uuidString.prefix(8)) until the conversation is reopened (this app session only).")
        return true
    }

    /// Clears the viewer wholesale (no animation) when the loaded conversation changes —
    /// PERSISTING the outgoing conversation's session first, so tabs (drafts included)
    /// follow their conversation instead of being discarded.
    private func resetCodeViewer() {
        // Stash first and unconditionally, before `loadedConversationID` moves, or the tabs are filed
        // under the incoming conversation.
        let stashed = stashCurrentCodeViewerTabs()
        guard !codeViewerTabs.isEmpty || isCodeViewerVisible else { return }
        let lostDrafts = stashed ? 0 : codeViewerTabs.filter(\.isDirty).count
        codeViewerTabs.removeAll()
        activeCodeViewerTabID = nil
        isCodeViewerVisible = false
        codeViewerPresentation = .split
        lastNonFullPresentation = .split
        codeApplyError = nil
        pendingCloseTabID = nil
        isPendingCloseAll = false
        if stashed {
            logger.info("[CodeViewer] Cleared for conversation switch (outgoing tabs stashed in memory).")
        } else {
            logger.error("[CodeViewer] Cleared for conversation switch WITHOUT stashing — \(lostDrafts) unsaved draft(s) discarded and no tabs will be restored for the outgoing conversation.")
        }
    }

    // MARK: - Tab navigation (previous/next across the strip)

    func navigateToNextSnippet() {
        guard let index = activeCodeViewerTabIndex, index < codeViewerTabs.count - 1 else { return }
        activeCodeViewerTabID = codeViewerTabs[index + 1].id
    }

    func navigateToPreviousSnippet() {
        guard let index = activeCodeViewerTabIndex, index > 0 else { return }
        activeCodeViewerTabID = codeViewerTabs[index - 1].id
    }

    // MARK: - Source resolution (window fast-path + store fallback)

    /// Resolves a snippet's source attachment: the loaded messages first, then the persistence store.
    /// Returns nil when the message or file is gone, not merely unloaded.
    private func resolveSourceFile(sourceMessageID: UUID, sourceFileID: UUID) async -> AttachedTextFile? {
        if let message = currentChatMessages.first(where: { $0.id == sourceMessageID }),
           let file = message.attachedTextFiles?.first(where: { $0.id == sourceFileID }) {
            return file
        }

        logger.info("[CodeViewer] Source message \(sourceMessageID.uuidString.prefix(8)) not in the loaded window — falling back to the store.")
        guard let fetched = await persistenceService.fetchMessage(withId: sourceMessageID),
              let file = fetched.attachedTextFiles?.first(where: { $0.id == sourceFileID }) else {
            logger.warning("[CodeViewer] Source file \(sourceFileID.uuidString.prefix(8)) unresolvable — absent from the window AND the store.")
            return nil
        }
        return file
    }

    // MARK: - Diff



    // MARK: - Message Actions

    // Why: `CodeSnippet.normalizedCode` trims both edges on open; without restoring them a save deletes blank lines unnoticed.
    /// Returns the exact bytes to write when applying `snippetCode`, with the original file's edge whitespace re-attached.
    /// `baseline` should be the on-disk bytes; an already-trimmed baseline makes this a no-op. Pure.
    static func contentToApply(snippetCode: String, preservingEdgeWhitespaceOf baseline: String) -> String {
        var out = snippetCode
        let lead = String(baseline.prefix(while: \.isWhitespace))
        // Restore only when the buffer has no edge whitespace of its own; a `hasPrefix` match is not idempotent
        // and grows the file on every save. `lead.count != baseline.count` skips an all-whitespace baseline.
        if !lead.isEmpty, lead.count != baseline.count, out.first?.isWhitespace != true {
            out = lead + out
        }
        // Capture the whole trailing whitespace run, not a single newline: a CRLF is one Character, so `hasSuffix` misses it.
        // `trail.count != baseline.count` stops an all-whitespace baseline splicing the file into itself.
        let trail = String(baseline.reversed().prefix(while: \.isWhitespace).reversed())
        if !trail.isEmpty, trail.count != baseline.count, out.last?.isWhitespace != true {
            out += trail
        }
        return out
    }

    /// Fire-and-forget entry point for the Apply button. Delegates to the awaitable
    /// `performApplyChanges` (which tests can drive deterministically).
    func applyChanges(for snippet: CodeSnippet) {
        Task { await performApplyChanges(for: snippet) }
    }

    // Why: the drift baseline advances with each own write; never replace `tab.snippet`, which rebuilds the editor.
    /// The single save engine: writes the tab buffer (the user's draft, else the block) back to the linked source file.
    /// Used by the diff-mode Apply button and ⌘S; reports every failure via `codeApplyError` and guards against drift.
    func performApplyChanges(for snippet: CodeSnippet) async {
        guard let sourceMessageID = snippet.sourceMessageID,
              let sourceFileID = snippet.sourceFileID else {
            logger.warning("Attempted to apply changes for a snippet with no source file link.")
            return
        }

        guard let sourceFile = await resolveSourceFile(sourceMessageID: sourceMessageID, sourceFileID: sourceFileID) else {
            logger.error("Could not find the source file to apply changes — absent from the window AND the store.")
            self.codeApplyError = CodeApplyError.sourceFileMissing.errorDescription
            return
        }

        // Buffer + baseline come from the tab when one is open. Tab-less calls (no open
        // tab for this snippet) still write the snippet itself — the pre-tabs contract.
        let preIndex = tabIndex(for: snippet)
        let buffer = preIndex.map { codeViewerTabs[$0].effectiveCode } ?? snippet.code

        if let preIndex, codeViewerTabs[preIndex].lastSavedBuffer == buffer,
           codeViewerTabs[preIndex].lastSavedDisk != nil {
            logger.debug("[CodeViewer] Save no-op — buffer unchanged since last save.")
            return
        }

        let fileURL = sourceFile.url
        let baseline = preIndex.flatMap { codeViewerTabs[$0].lastSavedDisk } ?? sourceFile.content
        let newContent = Self.contentToApply(snippetCode: buffer, preservingEdgeWhitespaceOf: baseline)
        let fileName = sourceFile.name

        // The write/verify/replace is blocking file I/O on a `@MainActor` class; it runs off-main inside
        // `atomicallyWrite`, and the state update after the await is back on the main actor.
        do {
            try await Self.atomicallyWrite(newContent, to: fileURL, expectingBaseline: baseline, fileName: fileName)

            logger.info("✅ Saved \(buffer.count) chars to file: \(fileURL.path)")
            withAnimation {
                self.codeApplyError = nil
                // Re-resolve the tab after the await: it may have been closed, or stashed by a conversation switch,
                // while the write was in flight.
                if let location = self.residence(ofSnippet: snippet) {
                    // Set inside the mutation when the buffer moved mid-write; logged after
                    // it returns, so the log line isn't emitted from inside a tab mutation.
                    var bufferMovedNote: String? = nil
                    self.mutateTab(at: location) { tab in
                        // The bytes are on disk, so the saved-state bookkeeping always advances: `lastSavedDisk` is the next
                        // drift baseline and `lastSavedBuffer` records which buffer produced it.
                        tab.lastSavedBuffer = buffer
                        tab.lastSavedDisk = newContent
                        Self.clearRejectedLiveState(&tab, savedTo: fileName)

                        // Adopt `buffer` only if it did not move during the write; keystrokes landing mid-save are unsaved edits.
                        // Keep the buffer rather than clearing it, which would revert the tab to the pristine block.
                        let live = tab.effectiveCode
                        if live == buffer {
                            tab.editedCode = buffer
                        } else {
                            // Report the state reached: `handleAgentWriteBegan` can clear the dirty state mid-write
                            // if an agent rewrites the same file.
                            let stillDirty = tab.isDirty
                            bufferMovedNote = "[CodeViewer] Saved \(buffer.count) chars of '\(fileName)', but the tab's buffer moved to \(live.count) chars during the write — kept the newer text; tab is now \(stillDirty ? "DIRTY (the next save writes it)" : "CLEAN (its buffer was reset mid-write, e.g. by an agent rewrite)")."
                        }
                    }
                    if let bufferMovedNote { logger.info(bufferMovedNote) }
                    if case .stashed(let conversationID, _) = location {
                        logger.info("[CodeViewer] Save bookkeeping for '\(fileName)' was applied to the STASHED copy — the conversation was switched away from (\(conversationID.uuidString.prefix(8))) while the write was in flight. Reopening it shows the tab clean and linked.")
                    }
                } else {
                    // Was a silent skip. The file IS written; only the tab's saved-state
                    // bookkeeping is lost, and only if it is neither open nor stashed.
                    logger.warning("[CodeViewer] Saved \(buffer.count) chars of '\(fileName)', but its tab is neither open nor stashed — it was closed while the write was in flight. CONSEQUENCE: no drift baseline is recorded for it; reopening the block starts a fresh tab whose first save drift-checks against the block, not against these bytes.")
                }
            }
        } catch let error as CodeApplyError {
            logger.error("❌ Apply changes aborted for \(fileURL.path): \(error.localizedDescription)")
            self.codeApplyError = error.errorDescription
        } catch {
            logger.error("❌ Failed to write changes to file: \(fileURL.path). Error: \(error.localizedDescription)")
            self.codeApplyError = CodeApplyError.writeFailed(fileName: fileName, underlying: error.localizedDescription).errorDescription
        }
    }
    /// The outcomes of reading a save destination to drift-check against, carried across the actor hop as plain values.
    /// `.absent` (the save may create) and `.unreadable` (the save must be refused) must never be merged.
    /// Failures carry Strings rather than the `Error` so the value is trivially `Sendable`.
    private enum DriftRead: Sendable {
        case content(String)
        case absent
        case unreadable(reason: String, description: String)
    }

    /// Writes a path-linked tab's buffer back to its file.
    /// Unlike `applyChanges`, which resolves an attachment, this covers tabs linked to a real file with no attachment behind them.
    func saveTabToItsPath(tabID: UUID) async {
        guard let index = codeViewerTabs.firstIndex(where: { $0.id == tabID }),
              let path = codeViewerTabs[index].filePath else { return }
        // Write through a symlink to its target: `write(to:atomically:)` on a symlink replaces the link with a regular file,
        // while the drift check reads through the link.
        let url = Self.writeTarget(forPath: path)
        let buffer = codeViewerTabs[index].effectiveCode

        // The baseline falls back to the content the tab was opened with, mirroring `applyChanges`:
        // timeline-opened and live-write tabs start with `lastSavedDisk == nil` and would skip the drift check.
        let baseline = codeViewerTabs[index].lastSavedDisk ?? codeViewerTabs[index].snippet.code

        // Read once off the main actor: the same bytes answer "did it drift?" and "did it end in a newline?".
        // Not size-capped: here the read is the drift guard, and skipping it could overwrite an external edit.
        let read = await Task.detached(priority: .userInitiated) { () -> DriftRead in
            do { return .content(try String(contentsOf: url, encoding: .utf8)) }
            catch let error as CocoaError where Self.meansFileAbsent(error) { return .absent }
            catch {
                return .unreadable(reason: Self.readFailureReason(error),
                                   description: error.localizedDescription)
            }
        }.value

        var onDiskContent: String? = nil
        switch read {
        case .content(let onDisk):
            onDiskContent = onDisk
            // Compare on the trimmed form: the tab's content went through `CodeSnippet.normalizedCode`, so a pristine
            // file differs by its trailing newline and would otherwise read as drift.
            if onDisk.trimmingCharacters(in: .whitespacesAndNewlines)
                != baseline.trimmingCharacters(in: .whitespacesAndNewlines) {
                logger.warning("[CodeViewer] Save refused for \(url.lastPathComponent) — the file changed on disk since this tab last read or wrote it. Nothing was written.")
                codeApplyError = CodeApplyError.diskDrift(fileName: url.lastPathComponent).errorDescription
                return
            }
        case .absent:
            // Missing file is fine — a Save-As target may legitimately not exist yet.
            logger.info("[CodeViewer] No existing file at \(url.path) to drift-check; treating the save as a create.")
        case .unreadable(let reason, let description):
            // Unreadable is not absent: non-UTF-8 content and permission or mount failures also throw here, and the
            // save must be refused rather than skipping the drift guard and overwriting.
            logger.error("[CodeViewer] Save refused for \(url.lastPathComponent) — its current contents could not be read to drift-check against: \(reason). Its absence was NOT established, so overwriting could discard work; nothing was written.")
            codeApplyError = CodeApplyError.writeFailed(
                fileName: url.lastPathComponent,
                underlying: String(localized: "its current contents could not be read to compare against (\(description))")
            ).errorDescription
            return
        }

        // Preserve the file's edge whitespace, which `normalizedCode` trimmed on open. The reference must be the
        // on-disk bytes: `baseline` may be the already-trimmed snippet, with nothing to restore.
        let content = Self.contentToApply(
            snippetCode: buffer,
            preservingEdgeWhitespaceOf: onDiskContent ?? baseline
        )
        do {
            // `atomicallyWrite` runs the write off the main actor via temp file, verify and atomic replace. `expectingBaseline`
            // is nil: the drift check above compares trimmed text, and the helper's exact-equality guard would misfire.
            try await Self.atomicallyWrite(content, to: url, fileName: url.lastPathComponent)
            guard let i = codeViewerTabs.firstIndex(where: { $0.id == tabID }) else {
                // Was a silent return. The bytes ARE on disk; only the tab's saved-state
                // bookkeeping is lost.
                logger.warning("[CodeViewer] Saved \(buffer.count) chars to \(url.path), but tab \(tabID.uuidString.prefix(8)) is no longer open — it was closed during the write. CONSEQUENCE: no drift baseline is recorded, so a tab reopened on this file drift-checks its next save against the block rather than these bytes.")
                return
            }
            // Adopt the buffer only if it is still the one that was written: the user can type during the awaits,
            // and an unconditional assignment would discard those keystrokes.
            if codeViewerTabs[i].effectiveCode == buffer {
                codeViewerTabs[i].editedCode = buffer
            } else {
                logger.info("[CodeViewer] \(url.lastPathComponent) was edited while its save was in flight — the \(buffer.count) chars that were written are recorded as the baseline and the newer text is kept, so the tab stays dirty. CONSEQUENCE: the newer edit is preserved and needs one more save.")
            }
            codeViewerTabs[i].lastSavedBuffer = buffer
            codeViewerTabs[i].lastSavedDisk = content
            Self.clearRejectedLiveState(&codeViewerTabs[i], savedTo: url.lastPathComponent)
            logger.info("[CodeViewer] Saved \(buffer.count) chars to \(url.path).")
        } catch {
            logger.error("[CodeViewer] Save failed for \(url.path): \(error.localizedDescription)")
            codeApplyError = CodeApplyError.writeFailed(fileName: url.lastPathComponent, underlying: error.localizedDescription).errorDescription
        }
    }

    // Why: the panel is modeless: an unconditional `editedCode` assignment drops newer keystrokes and clears the dirty dot.
    /// Bookkeeping after a successful Save-As: the tab adopts the chosen file and arms the drift guard via `lastSavedDisk`.
    /// `wroteToDisk` is the bytes that landed (default `savedBuffer`); the drift baseline, which may differ from the buffer.
    /// `editedCode` is adopted only when the editor still shows `savedBuffer`, so keystrokes typed meanwhile stay dirty.
    func markCodeViewerTabSavedAs(tabID: UUID, savedBuffer: String, savedTo url: URL, wroteToDisk: String? = nil) {
        guard let location = residence(ofTabID: tabID) else {
            logger.warning("[CodeViewer] Save-As bookkeeping skipped — tab \(tabID.uuidString.prefix(8)) is neither open nor stashed, so it was closed while the save panel was open; the file WAS written to \(url.path).")
            return
        }
        var keptNewerDraft = false
        mutateTab(at: location) { tab in
            if tab.effectiveCode == savedBuffer {
                tab.editedCode = savedBuffer
            } else {
                // Materialise the newer text rather than just flagging it: `effectiveCode` falls back to `snippet.code`
                // when `editedCode` is nil, which would report the tab clean and let ⌘W close it without confirmation.
                tab.editedCode = tab.effectiveCode
                keptNewerDraft = true
            }
            tab.filePath = url.path
            tab.fileName = url.lastPathComponent
            tab.lastSavedDisk = wroteToDisk ?? savedBuffer
            tab.lastSavedBuffer = savedBuffer
            Self.clearRejectedLiveState(&tab, savedTo: url.lastPathComponent)
        }
        if keptNewerDraft {
            let stillDirty = residence(ofTabID: tabID).map { loc -> Bool in
                switch loc {
                case .live(let i): return codeViewerTabs.indices.contains(i) && codeViewerTabs[i].isDirty
                case .stashed(let c, let i):
                    guard let tabs = tabsByConversation[c]?.tabs, tabs.indices.contains(i) else { return false }
                    return tabs[i].isDirty
                }
            } ?? false
            logger.info("[CodeViewer] \(url.lastPathComponent) was edited while its Save-As was in flight — the \(savedBuffer.count) chars that were written are recorded as the baseline and the newer text is kept. CONSEQUENCE: the newer edit is preserved and the tab is \(stillDirty ? "DIRTY, so ⌘S writes it to \(url.path)" : "CLEAN — the newer text equals the bytes just written").")
        }
        switch location {
        case .live:
            logger.info("[CodeViewer] Tab \(tabID.uuidString.prefix(8)) saved as \(url.path) (\(savedBuffer.count) chars) — the tab is now linked to that file and ⌘S writes there\(keptNewerDraft ? ", and it stays DIRTY because the buffer moved during the save" : "").")
        case .stashed(let conversationID, _):
            // The save panel is modeless, so a conversation switch can stash the tab mid-panel;
            // patching the stashed copy keeps the link across the switch.
            logger.info("[CodeViewer] Tab \(tabID.uuidString.prefix(8)) saved as \(url.path) (\(savedBuffer.count) chars) while stashed for conversation \(conversationID.uuidString.prefix(8)) — the STASHED copy was linked, so reopening that conversation shows it \(keptNewerDraft ? "DIRTY (the buffer moved during the save, and the newer text was kept)" : "clean") and ⌘S writes there.")
        }
    }

    /// Clears a `.rejected` live-write badge once the user's own save puts that content on disk.
    /// `.active` is left alone: an agent write still in flight stays in flight.
    private static func clearRejectedLiveState(_ tab: inout CodeViewerTab, savedTo fileName: String) {
        guard tab.liveState == .rejected else { return }
        tab.liveState = nil
        logger.info("[CodeViewer] Cleared the 'not applied' badge on '\(fileName)' — the user's save wrote the rejected proposal to disk, so the banner's claim no longer holds.")
    }

    /// Returns the URL a save must write to, resolving symlinks so the real file is replaced rather than the link.
    /// Shared by both save engines so they cannot diverge.
    nonisolated static func writeTarget(forPath path: String) -> URL {
        let raw = URL(fileURLWithPath: path)
        let resolved = raw.resolvingSymlinksInPath()
        if resolved.path != raw.path {
            logger.info("[CodeViewer] '\(raw.lastPathComponent)' resolves through a symlink — writing to \(resolved.path) so the link is preserved and the real file is updated.")
        }
        return resolved
    }

    /// True only for "the file isn't there", the one read failure a save may ignore.
    /// Any other failure (undecodable bytes, permissions, I/O) means the file could not be compared, so the save is refused.
    nonisolated static func meansFileAbsent(_ error: CocoaError) -> Bool {
        error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    }

    /// Returns a short name for why a read failed, so a refusal log states the classified reason instead of asserting one.
    nonisolated static func readFailureReason(_ error: Error) -> String {
        guard let cocoa = error as? CocoaError else {
            return "the read failed (\(error.localizedDescription))"
        }
        switch cocoa.code {
        case .fileReadInapplicableStringEncoding: return "it is not UTF-8 text"
        case .fileReadNoPermission:               return "Devgentic does not have permission to read it"
        case .fileReadCorruptFile:                return "its contents could not be decoded"
        case .fileReadTooLarge:                   return "it is too large to read"
        default:                                  return "the read failed (\(error.localizedDescription))"
        }
    }

    /// Writes a file transactionally off the main actor: temp file in the same directory, read-back verify, atomic replace.
    /// A crash or full disk mid-write cannot corrupt the original; security-scoped access is balanced around the transaction.
    /// Internal rather than private so the temp-file lifecycle can be tested directly.
    nonisolated static func atomicallyWrite(
        _ content: String,
        to fileURL: URL,
        expectingBaseline baseline: String? = nil,
        fileName: String = ""
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let shouldAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if shouldAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            // Same symlink rule as `saveTabToItsPath`: write to the link's target.
            let target = Self.writeTarget(forPath: fileURL.path)
            let displayName = fileName.isEmpty ? target.lastPathComponent : fileName

            // Disk-drift guard: `baseline` is the file's content when attached, which the on-screen diff was computed against.
            // If the file on disk differs it was edited externally; refuse rather than discard those edits.
            if let baseline {
                do {
                    let onDisk = try String(contentsOf: target, encoding: .utf8)
                    if onDisk != baseline {
                        throw CodeApplyError.diskDrift(fileName: displayName)
                    }
                } catch let error as CocoaError where Self.meansFileAbsent(error) {
                    // Genuinely absent — the write below recreates it, which is the same
                    // outcome the pre-guard code produced.
                } catch let error as CodeApplyError {
                    throw error
                } catch {
                    // Was `try?`, which made an UNDECODABLE or unreadable file compare as
                    // "no drift" and let the write proceed over content we never inspected.
                    logger.error("[CodeViewer] Apply refused for \(displayName) — its current contents could not be read to drift-check against: \(Self.readFailureReason(error)). Its absence was NOT established, so overwriting could discard work; nothing was written.")
                    throw CodeApplyError.writeFailed(
                        fileName: displayName,
                        underlying: String(localized: "its current contents could not be read to compare against (\(error.localizedDescription))")
                    )
                }
            }

            let tempURL = target.deletingLastPathComponent()
                .appendingPathComponent(".devgentic_tmp_\(UUID().uuidString)")
            try content.write(to: tempURL, atomically: true, encoding: .utf8)

            // Every exit path must remove the temp file, or a hidden `.devgentic_tmp_<uuid>` holding the proposed contents
            // is left beside the user's file. A no-op on success, since `replaceItemAt` moves the temp into place.
            defer {
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    do {
                        try FileManager.default.removeItem(at: tempURL)
                        logger.warning("[CodeViewer] Save of \(displayName) did not complete — its temp file was removed. Nothing was written to the target.")
                    } catch {
                        logger.error("[CodeViewer] Save of \(displayName) did not complete AND its temp file could not be removed (\(error.localizedDescription)). CONSEQUENCE: a hidden '\(tempURL.lastPathComponent)' holding the proposed content is left in \(tempURL.deletingLastPathComponent().path) — it is safe to delete.")
                    }
                }
            }

            // Verify the temp file was written correctly before replacing
            let verifyContent = try String(contentsOf: tempURL, encoding: .utf8)
            guard verifyContent == content else {
                throw NSError(domain: "ChatHistoryViewModel", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Write verification failed — content mismatch"])
            }

            // Atomic replace: original is only removed after temp is in place
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tempURL)
        }.value
        // The single write path shared by ⌘S, Apply and Save As, so one post tells disk-state observers of every user save.
        // Reached only on success.
        await WorkspaceActivity.post(reason: "saved \(fileURL.lastPathComponent)")
    }

    func copyMessageContentToClipboard(message: ChatMessage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Prefer the selected agent variant so Copy matches what is on screen for a regenerated response.
        if let content = (message.currentAgentContent ?? message.content).textContent {
            pasteboard.setString(content, forType: .string)
            logger.info("Copied message \(message.id.uuidString) content to clipboard.")
        }
    }
    
    func openMessageInCodeViewer(message: ChatMessage, selectedSnippet: CodeSnippet? = nil) {
        // Extract this message's blocks, each paired with the filename to title its tab.
        var blocks: [(snippet: CodeSnippet, fileName: String?)] = []

        // Use `displayedContent`, not `content`: for a regenerated response `content` holds the original text, and the
        // ordinals must match `ContentBlockView.codeBlockOrdinal` so origin keys line up.
        switch message.displayedContent {
        case .codeBlock(let lang, let codeContent):
            blocks = [(CodeSnippet(codeBlock: lang, content: codeContent), nil)]

        case .markdownText(let text):
            blocks = CodeSnippetExtractor.extract(from: text).map { info in
                var snippet = CodeSnippet(language: info.language, code: info.code)
                var fileName: String? = info.potentialFileName

                if let name = info.potentialFileName {
                    if let sourceMessage = self.findMessageWithSourceFile(named: name),
                       let sourceFile = sourceMessage.attachedTextFiles?.first(where: { $0.name == name }) {
                        snippet.sourceMessageID = sourceMessage.id
                        snippet.sourceFileID = sourceFile.id
                        fileName = sourceFile.name
                        logger.info("✅ Successfully linked snippet for '\(name)' to source file ID \(sourceFile.id.uuidString).")
                    } else {
                        // Keep the name as the tab title even when it matches no attached file (no diff/apply). Logged at info, not warning:
                        // model-generated code, the common case, never has a matching attachment.
                        logger.info("[CodeViewer] Block named '\(name)' has no matching attached file — the tab keeps the name as its title but stays unlinked (no diff/apply). Expected for model-generated code.")
                    }
                }
                return (snippet, fileName)
            }

        default:
            blocks = []
        }

        guard !blocks.isEmpty else {
            logger.info("No code snippets found in the message to open in viewer.")
            return
        }

        // Same large-block filter as the renderer: offer the large blocks, else all of them.
        // The index is captured before filtering: it is the tab's stable identity, and a streaming block can cross `isLarge`.
        let indexed = blocks.enumerated().map { (blockIndex: $0.offset, block: $0.element) }
        let largeBlocks = indexed.filter(\.block.snippet.isLarge)
        let toOpen = largeBlocks.isEmpty ? indexed : largeBlocks

        // Open every block from this message as a tab (accumulating with any already open),
        // then focus the clicked one — or the first when nothing specific was clicked.
        var focusID: UUID? = nil
        var pendingLinks: [(tabID: UUID, fileName: String)] = []
        for entry in toOpen {
            let block = entry.block
            let id = openTab(for: block.snippet, fileName: block.fileName,
                             originMessageID: message.id, originBlockIndex: entry.blockIndex)
            if let selected = selectedSnippet, block.snippet.denotesSameBlock(as: selected) {
                focusID = id
            }
            // Named block whose window-linking missed: queue a store-backed re-link.
            if block.snippet.sourceFileID == nil, let name = block.fileName {
                pendingLinks.append((tabID: id, fileName: name))
            }
        }
        if let focusID { activeCodeViewerTabID = focusID }

        logger.info("Opened message in code viewer: \(toOpen.count) block(s) as tabs, \(self.codeViewerTabs.count) total open.")

        if !pendingLinks.isEmpty {
            let conversationID = message.conversationId
            let links = pendingLinks
            Task { await resolvePendingSourceLinks(links, conversationID: conversationID) }
        }
    }

    /// Store-backed second pass for filename-to-attachment linking when the loaded window missed.
    /// Matches are stamped onto open tabs in place, never via a new snippet, which would rebuild the editor.
    /// Awaitable so tests can drive it deterministically.
    func resolvePendingSourceLinks(_ links: [(tabID: UUID, fileName: String)], conversationID: UUID) async {
        let sources = await persistenceService.fetchUserMessagesWithAttachedTextFiles(for: conversationID)
        guard !sources.isEmpty else {
            logger.info("[CodeViewer] Deferred linking: store has no attachment-bearing user messages for \(conversationID.uuidString.prefix(8)) — \(links.count) block(s) stay unlinked.")
            return
        }

        var linked = 0
        for link in links {
            // Re-resolve per link AFTER the await — tabs may have closed or the
            // conversation switched (which clears them) while the fetch ran.
            guard let index = codeViewerTabs.firstIndex(where: { $0.id == link.tabID }),
                  codeViewerTabs[index].snippet.sourceFileID == nil else { continue }

            guard let source = sources.first(where: { message in
                message.attachedTextFiles?.contains(where: { $0.name == link.fileName }) ?? false
            }), let file = source.attachedTextFiles?.first(where: { $0.name == link.fileName }) else {
                logger.info("[CodeViewer] Deferred linking: '\(link.fileName)' not in the store either — tab stays unlinked (no diff/apply).")
                continue
            }

            codeViewerTabs[index].snippet.sourceMessageID = source.id
            codeViewerTabs[index].snippet.sourceFileID = file.id
            linked += 1
            logger.info("✅ [CodeViewer] Deferred-linked '\(link.fileName)' to source file \(file.id.uuidString.prefix(8)) via the store.")
        }
        if linked > 0 {
            logger.info("[CodeViewer] Deferred linking complete: \(linked)/\(links.count) block(s) linked from persistence.")
        }
    }
    
    private func findMessageWithSourceFile(named fileName: String) -> ChatMessage? {
        // Ambiguity fails closed: resolving by bare name can match two same-named attached files (e.g. two `page.tsx`),
        // and stamping the first would let a save overwrite the wrong file; a missing badge is visible, an overwrite is not.
        let matches = currentChatMessages
            .filter { $0.sender == .user }
            .flatMap { message in
                (message.attachedTextFiles ?? [])
                    .filter { $0.name == fileName }
                    .map { (message: message, file: $0) }
            }
        if matches.count > 1 {
            let paths = matches.map { $0.file.url.path }.joined(separator: ", ")
            logger.warning("[CodeViewer] '\(fileName)' names \(matches.count) different attached files in this conversation (\(paths)) — refusing to link the snippet to any of them. CONSEQUENCE: the tab keeps the name as its title but stays unlinked, so there is no diff and no Apply Changes; linking would have picked one by attachment order and could overwrite the wrong file.")
            return nil
        }
        if let single = matches.first {
            return single.message
        }
        // Info, not warning — see the caller: an unmatched name is the normal outcome for
        // model-generated code, and the caller states the consequence.
        logger.info("[CodeViewer] No user message in the loaded window attaches a file named '\(fileName)'.")
        return nil
    }


    // MARK: - Paginated Message Loading

    func loadConversation(id: UUID?) async {
        loadEpoch &+= 1
        let myEpoch = loadEpoch

        // Clear the viewer only for a different conversation, since source links go stale; identity must come from
        // `viewerOwningConversationID` because callers pre-clear `currentChatMessages` before loading.
        if id != viewerOwningConversationID {
            resetCodeViewer()
        }

        guard let selectedID = id else {
            currentChatMessages = []
            olderPagesLoadedCount = 0
            loadedConversationID = nil
            return
        }

        logger.debug("Loading conversation \(selectedID.uuidString), merging with active streams.")

        // Publish the destination for the load: until the assignments below, displayed state names the outgoing conversation.
        // Cleared under the epoch check so a stale load cannot erase a newer load's destination.
        loadingConversationID = selectedID
        defer { if myEpoch == loadEpoch { loadingConversationID = nil } }

        isInitiallyLoadingConversation = true
        await Task.yield()

        do {
            try Task.checkCancellation()

            // Fetch persisted messages (returns newest-to-oldest).
            let persistedMessages = await persistenceService.fetchMessages(for: selectedID, offset: 0, limit: initialPageSize)

            try Task.checkCancellation()

            // A newer load started while we awaited persistence — discard our
            // result so we don't overwrite the newer task's UI state.
            guard myEpoch == loadEpoch else {
                logger.info("Stale load discarded for \(selectedID.uuidString) (epoch \(myEpoch), current: \(self.loadEpoch)).")
                return
            }

            // Persisted rows only: a stored `.running` status is always stale after a relaunch, so it is reconciled
            // against the registry. Live streaming messages are excluded; the observer maintains them.
            let reconciled = BackgroundTaskObserver.reconciledMessages(persistedMessages)
            if reconciled.rows > 0 {
                logger.info("[BGTASK] Reconciled \(reconciled.rows) background-task row(s) that loaded as 'running'. CONSEQUENCE: they now show their real outcome, or 'ended when the app restarted' — instead of a spinner and an elapsed time counting up from whenever they started.")
                // Persist the corrected rows, detached so the load does not wait: an outcome recovered from the registry
                // exists only in memory, and would be reported as interrupted after the next relaunch.
                let corrected = reconciled.messages
                let persistence = persistenceService
                Task { @MainActor in
                    await persistence.addMessages(corrected, toConversation: selectedID)
                    logger.info("[BGTASK] Saved \(corrected.count) reconciled message(s) in conversation \(selectedID.uuidString.prefix(8)). CONSEQUENCE: their background-task rows reload as corrected, including after a relaunch.")
                }
            }

            let activeStreamingMessages = activeStreamManager.activeStreams.values
                .filter { $0.conversationId == selectedID }

            var combinedMessages = activeStreamingMessages + persistedMessages
            let uniqueMessageIDs = Set(combinedMessages.map { $0.id })
            combinedMessages = uniqueMessageIDs.compactMap { id in
                combinedMessages.first { $0.id == id }
            }

            // Sort the combined list descending to ensure order.
            let sortedDescending = combinedMessages.sorted { $0.timestamp > $1.timestamp }

            // OPTIMIZATION: Keep messages in Descending Order (Newest -> Oldest).
            // We REMOVED .reversed() here. This aligns with the View's .reversed() loop.
            self.currentChatMessages = sortedDescending
            self.olderPagesLoadedCount = 0
            self.loadedConversationID = selectedID
            // The corpus belongs to the previous conversation (or a stale snapshot of this
            // one); drop it so search re-fetches against what is actually loaded.
            self.invalidateSearchCorpus()

            // Restores this conversation's Code Viewer session (tabs, drafts, layout);
            // a no-op on same-conversation reloads, where the tabs were not cleared.
            restoreCodeViewerSession(for: selectedID)

            self.canLoadMorePages = persistedMessages.count >= initialPageSize
            self.hasReachedResidencyCap = false

            logger.info("Successfully loaded and merged \(persistedMessages.count) persisted and \(activeStreamingMessages.count) active messages.")
        } catch {
            logger.info("Conversation load for \(selectedID.uuidString) was cancelled.")
        }

        // Only the latest load clears the loading flag, so a stale load cannot hide the spinner while a newer one runs.
        if myEpoch == loadEpoch {
            self.isInitiallyLoadingConversation = false
        }
    }


    /// Test seam: advances the load epoch as `loadConversation` does, without running a full load.
    /// Lets a test place a conversation switch inside a store fetch. Not called from app code.
    func bumpLoadEpochForTesting() {
        loadEpoch &+= 1
    }

    func loadMoreMessages() async {
        guard !isLoadingPage, canLoadMorePages, let selectedID = currentChatMessages.first?.conversationId else {
            return
        }

        // Residency ceiling: `canLoadMorePages` stays true because the store really has more,
        // and the history resolver relies on that distinction.
        guard currentChatMessages.count < Self.maxResidentMessages else {
            if !hasReachedResidencyCap {
                hasReachedResidencyCap = true
                logger.warning("[PAGINATION] Resident message cap reached (\(Self.maxResidentMessages)) for \(selectedID.uuidString.prefix(8)) — scroll-back stops here to bound memory. Older turns remain in the store, reachable via search; the model's history is unaffected (resolved from the store, not this window).")
            }
            return
        }

        isLoadingPage = true

        let offset = currentChatMessages.count
        logger.debug("Loading page with offset \(offset) for conversation \(selectedID.uuidString).")

        // Claim the epoch before the fetch, as `loadConversation` does: a switch landing during this await would
        // otherwise append another conversation's older messages onto the rendered array.
        let myEpoch = loadEpoch

        // Fetches the next page of older messages, sorted newest-to-oldest.
        let olderMessages = await persistenceService.fetchMessages(for: selectedID, offset: offset, limit: subsequentPageSize)

        guard myEpoch == loadEpoch else {
            // `isLoadingPage` is reset unconditionally below — leaving it true would wedge
            // pagination for the conversation the user actually switched TO.
            logger.info("[PAGINATION] Discarded a page of \(olderMessages.count) message(s) for \(selectedID.uuidString.prefix(8)) — the conversation changed while the store was reading (epoch \(myEpoch), current: \(self.loadEpoch)). CONSEQUENCE: nothing is appended; the scroll-back is re-issued if the user returns and scrolls again.")
            isLoadingPage = false
            return
        }

        if olderMessages.isEmpty {
            canLoadMorePages = false
        } else {
            // OPTIMIZATION: Append to the end of the array (Newest...Oldest -> Append Older).
            // Since we are storing Descending, older messages go to the end (Index N).
            self.currentChatMessages.append(contentsOf: olderMessages)
            self.olderPagesLoadedCount += olderMessages.count

            trimMarkdownCachesOutsideWindow()
        }

        isLoadingPage = false
    }

    /// Drops the parsed-markdown cache for messages far from both ends of the loaded window.
    /// Purely derived state that `getOrCreateMarkdownBlocks` rebuilds lazily, so only memory changes.
    /// Streaming messages are skipped: their incremental parser owns the cache.
    private func trimMarkdownCachesOutsideWindow() {
        let window = Self.markdownCacheWindow
        guard currentChatMessages.count > window * 2 else { return }

        var trimmed = 0
        for index in window ..< (currentChatMessages.count - window) {
            let message = currentChatMessages[index]
            guard !message.isStreaming else { continue }
            message.invalidateMarkdownCache()
            trimmed += 1
        }
        if trimmed > 0 {
            logger.debug("[PAGINATION] Released parsed-markdown cache for \(trimmed) off-screen message(s); they re-parse on demand if scrolled back to.")
        }
    }

    // MARK: - Search corpus (store-backed, so scroll position can't change what is findable)

    /// Newest-first store snapshot used as the search corpus, cached per conversation.
    /// Holds lightweight projections rather than decoded `ChatMessage`s, so attached image data is not kept resident.
    @ObservationIgnored private var searchCorpusCache: [SearchDocument] = []

    /// Per-message memo of search units, keyed on a hash of the displayed text.
    /// Resident messages are projected at read time so in-place mutations show; the hash avoids re-decomposing per keystroke.
    @ObservationIgnored private var residentUnitsCache: [UUID: (textHash: Int, wasStreaming: Bool, units: [SearchUnit])] = [:]
    @ObservationIgnored private var searchCorpusConversationID: UUID?

    /// How far back search reaches. Larger than `maxResidentMessages`: finding a match is
    /// cheap (text scan), holding a message resident is not.
    @ObservationIgnored static let searchCorpusLimit = 1_000

    /// Everything search should look at: the cached store snapshot with the live resident messages merged over it.
    /// Merging reaches messages beyond the pagination window while keeping streaming and just-sent messages fresh.
    var searchCorpus: [SearchDocument] {
        #if DEBUG
        searchCorpusBuildsForTesting += 1
        #endif
        guard searchCorpusConversationID == loadedConversationID, !searchCorpusCache.isEmpty else {
            return currentChatMessages.map(projectedResidentDocument)
        }
        var byID: [UUID: SearchDocument] = [:]
        for document in searchCorpusCache { byID[document.id] = document }
        // Resident messages override the stored projection and are re-projected HERE rather
        // than cached whole: a streaming message's text changes without any membership change.
        for message in currentChatMessages { byID[message.id] = projectedResidentDocument(message) }
        // Newest-first, matching `currentChatMessages` — `performSearch` reverses it to
        // emit matches in display order.
        return byID.values.sorted { $0.timestamp > $1.timestamp }
    }

    #if DEBUG
    /// Test seam [vm-5]: how many times a memoized resident projection was SERVED. The defect is
    /// that a streaming-era projection was served after the message settled, so the pin is "no
    /// hit across the settle boundary" — which a test can only see by counting hits.
    @ObservationIgnored private(set) var residentUnitsCacheHitsForTesting = 0
    #endif

    #if DEBUG
    /// Test seam [vm-3]: how many times `searchCorpus` has been built. One search run must cost
    /// exactly ONE build, and reading the search view model's stored `unreachableMatchCount` must
    /// cost NONE — that is the whole of the fix, and the counter is what a test can pin it with.
    @ObservationIgnored private(set) var searchCorpusBuildsForTesting = 0
    #endif

    /// Runs the chat search: one corpus snapshot feeds both the match list and the unreachable count.
    /// All call sites go through here; calling `performSearch` directly would leave the count at 0.
    func runSearch(_ searchViewModel: ChatSearchViewModel) {
        let corpus = searchCorpus
        searchViewModel.performSearch(in: corpus)
        searchViewModel.unreachableMatchCount = unreachableMatchCount(in: searchViewModel.matches, corpus: corpus)
    }

    /// A resident message's projection, memoized on its displayed text.
    private func projectedResidentDocument(_ message: ChatMessage) -> SearchDocument {
        let hash = message.displayedContent.textContent?.hashValue ?? 0
        // The streaming flag is part of the cache key: a streaming decomposition can use different block ids,
        // and the text hash alone cannot detect the settle, so a mid-stream entry would be served forever.
        if let cached = residentUnitsCache[message.id], cached.textHash == hash,
           cached.wasStreaming == message.isStreaming {
            #if DEBUG
            residentUnitsCacheHitsForTesting += 1
            #endif
            return SearchDocument(id: message.id, timestamp: message.timestamp, units: cached.units)
        }
        let units = ChatSearchDecomposition.units(for: message)
        residentUnitsCache[message.id] = (hash, message.isStreaming, units)
        return SearchDocument(id: message.id, timestamp: message.timestamp, units: units)
    }

    // Why: the release that accompanies cancellation runs first; publishing afterwards resurrects a freed projection.
    /// Loads the store snapshot once per conversation when search opens, not per keystroke (each fetch is costly).
    /// Publishes nothing once its task is cancelled.
    func prepareSearchCorpus() async {
        guard let conversationID = loadedConversationID else { return }
        guard searchCorpusConversationID != conversationID || searchCorpusCache.isEmpty else { return }

        let stored = await persistenceService.fetchSearchDocuments(
            for: conversationID,
            limit: Self.searchCorpusLimit
        )
        guard conversationID == loadedConversationID else {
            logger.info("[SEARCH] Corpus fetch for \(conversationID.uuidString.prefix(8)) discarded — the conversation changed while it was in flight.")
            return
        }
        guard !Task.isCancelled else {
            logger.info("[SEARCH] Corpus fetch for \(conversationID.uuidString.prefix(8)) discarded — search closed or the chat view was torn down while it was in flight; \(stored.count) document(s) dropped rather than published behind the release.")
            return
        }
        searchCorpusCache = stored
        searchCorpusConversationID = conversationID
        logger.info("[SEARCH] Corpus ready for \(conversationID.uuidString.prefix(8)): \(stored.count) stored message(s) vs \(self.currentChatMessages.count) resident — search now reaches beyond the scroll window.")
    }

    private func invalidateSearchCorpus() {
        searchCorpusCache = []
        searchCorpusConversationID = nil
        residentUnitsCache = [:]
    }

    /// Drops the corpus when search closes or the chat view goes away.
    func releaseSearchCorpus() {
        let freed = searchCorpusCache.count
        let memoized = residentUnitsCache.count
        guard freed > 0 || memoized > 0 else { return }
        invalidateSearchCorpus()
        logger.info("[SEARCH] Corpus released — \(freed) stored document(s) and \(memoized) memoized resident projection(s) freed; the next search re-fetches.")
    }

    /// Returns where `messageID` sits in the search corpus (0 = newest), or nil when the corpus does not hold it.
    /// The corpus is newest-first, so the index is also the resident slots needed before paging could reach the message.
    func searchCorpusIndex(of messageID: UUID) -> Int? {
        searchCorpus.firstIndex { $0.id == messageID }
    }

    /// Whether a search match can be brought on screen at all, decided from its corpus position without paging.
    /// Scroll-back stops at `maxResidentMessages`, so a match beyond it (or missing from the corpus) is unreachable.
    func isMatchReachable(messageID: UUID) -> Bool {
        isMatchReachable(messageID: messageID, corpusIndex: searchCorpusIndex(of: messageID))
    }

    /// The same answer from a corpus position the caller already has.
    /// `searchCorpusIndex` reads the computed `searchCorpus`, rebuilt on every access; pass the index to avoid a rebuild.
    func isMatchReachable(messageID: UUID, corpusIndex: Int?) -> Bool {
        if currentChatMessages.contains(where: { $0.id == messageID }) { return true }
        guard let corpusIndex else { return false }
        return corpusIndex < Self.maxResidentMessages
    }

    /// Pages older messages in until `messageID` is rendered; returns false when it cannot be reached.
    /// Unreachable targets are refused before the first page (see `isMatchReachable`); the loop yields between pages.
    @discardableResult
    func ensureMessageIsResident(_ messageID: UUID) async -> Bool {
        await ensureMessageIsResident(messageID, corpusIndex: searchCorpusIndex(of: messageID))
    }

    /// As above, with the corpus position supplied by a caller that just computed it.
    /// The `loadEpoch` check inside the loop, not this index, stops an orphaned walk.
    @discardableResult
    func ensureMessageIsResident(_ messageID: UUID, corpusIndex: Int?) async -> Bool {
        if currentChatMessages.contains(where: { $0.id == messageID }) { return true }

        guard let corpusIndex else {
            logger.info("[SEARCH] Match \(messageID.uuidString.prefix(8)) is not in the search corpus (stale after a conversation change or corpus release) — not paging for it; the jump is skipped.")
            return false
        }
        guard corpusIndex < Self.maxResidentMessages else {
            logger.info("[SEARCH] Match \(messageID.uuidString.prefix(8)) is beyond the residency cap (\(Self.maxResidentMessages)) at corpus position \(corpusIndex) — found but not scrollable; no pages fetched on its behalf.")
            return false
        }

        // Bounded by the residency cap; the extra guard is a backstop against a store that keeps returning pages.
        // Not bounded per attempt: a smaller budget made "Next" fail to reach a deep match in one press.
        var pagesLoaded = 0
        let maxPages = (Self.maxResidentMessages / subsequentPageSize) + 2
        // Abandon the walk as soon as any load starts: `Task.yield()` is a suspension point, and an orphaned walk would
        // page the newly opened conversation to the residency cap. Keyed on `loadEpoch` so a same-conversation reload stops it.
        let myEpoch = loadEpoch
        while canLoadMorePages, !hasReachedResidencyCap, pagesLoaded < maxPages, myEpoch == loadEpoch {
            let countBefore = currentChatMessages.count
            await loadMoreMessages()
            pagesLoaded += 1
            guard myEpoch == loadEpoch else {
                logger.info("[SEARCH] Abandoned the page-in walk for match \(messageID.uuidString.prefix(8)) after \(pagesLoaded) page(s) — a conversation load started while it was running (epoch \(myEpoch), current: \(self.loadEpoch)). CONSEQUENCE: this jump does not scroll, and the newly opened conversation is left at its own pagination state instead of being force-paged to the residency cap on its behalf.")
                return false
            }
            if currentChatMessages.contains(where: { $0.id == messageID }) {
                logger.info("[SEARCH] Paged in \(pagesLoaded) page(s) to reach match \(messageID.uuidString.prefix(8)).")
                return true
            }
            if currentChatMessages.count == countBefore { break }   // no progress
            // Each page is a synchronous main-actor fetch + decode; give queued input and
            // rendering a turn before the next one so a multi-page walk doesn't read as a hang.
            await Task.yield()
        }

        logger.info("[SEARCH] Match \(messageID.uuidString.prefix(8)) at corpus position \(corpusIndex) could not be paged in after \(pagesLoaded) page(s) — the store stopped returning rows, or the residency cap was reached first. CONSEQUENCE: this jump does not scroll and the search bar reports the match as older than the loaded history.")
        return false
    }

    // Why: `searchCorpus` is computed (rebuilt and sorted per access); snapshot it once rather than per match.
    /// Counts search matches (not messages) whose message cannot be brought on screen.
    /// Uses the same reachability predicate as `ensureMessageIsResident`, from a single corpus snapshot.
    /// Counts matches, not messages, because the badge prints it beside a match count.
    func unreachableMatchCount(in matches: [SearchMatch]) -> Int {
        guard !matches.isEmpty else { return 0 }
        return unreachableMatchCount(in: matches, corpus: searchCorpus)
    }

    /// [vm-3] The same count over a corpus snapshot the caller ALREADY holds — `runSearch` hands
    /// in the one it just searched, so the count costs no second corpus build.
    func unreachableMatchCount(in matches: [SearchMatch], corpus: [SearchDocument]) -> Int {
        guard !matches.isEmpty else { return 0 }
        let resident = Set(currentChatMessages.map(\.id))
        var positionByID: [UUID: Int] = [:]
        for (position, document) in corpus.enumerated() { positionByID[document.id] = position }
        return matches.reduce(into: 0) { unreachable, match in
            if resident.contains(match.messageID) { return }
            // Absent from the corpus (conversation changed, or the corpus was released) is
            // unreachable, matching `isMatchReachable`.
            guard let position = positionByID[match.messageID],
                  position < Self.maxResidentMessages else {
                unreachable += 1
                return
            }
        }
    }

    func resetSendingState() async {
        self.isSending = false
        logger.info("✅ [Request Finished] Sending state has been reset.")
    }
}
