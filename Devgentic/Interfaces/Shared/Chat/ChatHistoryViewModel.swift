// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatHistoryViewModel.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import os

private let logger = DGLogger(category: "ChatHistoryViewModel")

/// Why `applyChanges` couldn't write a snippet back to its source file. Surfaced to the
/// user via `ChatHistoryViewModel.codeApplyError` — previously these were log-only, so a
/// failed apply was indistinguishable from a successful one.
enum CodeApplyError: LocalizedError, Sendable {
    case sourceFileMissing
    case diskDrift(fileName: String)
    case writeFailed(fileName: String, underlying: String)
    /// A per-hunk operation arrived with a diff snapshot whose baseline no longer matches
    /// the file as we know it — the comparison on screen predates a newer write.
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
    /// Code Viewer tabs per conversation, for THIS APP SESSION only.
    ///
    /// A tab is a view onto content that already lives in the conversation — a message's
    /// code block, or a tool row's output — so re-opening it is one click and persisting it
    /// cached something free to rebuild. Switching conversations keeps tabs (an unsaved
    /// draft is the one thing that exists nowhere else); quitting does not.
    /// See `Docs/codeviewer-rescope-design.md` §6.
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
    //
    // The Code Viewer is a set of persistent TABS, not a single selection. Opening a code
    // block adds/focuses a tab; tabs survive the panel being minimized (the floating reopen
    // button); each tab owns its own diff state. `isCodeViewerVisible` is deliberately
    // SEPARATE from "are there tabs" so closing the panel (minimize) can keep the tabs alive.
    var codeViewerTabs: [CodeViewerTab] = [] {
        didSet {
            // Guarded so the mirror is written on the TRANSITION only. Belt-and-braces
            // today — measured on Swift 6.2, Observation already suppresses a same-VALUE
            // assignment of an Equatable property — but the mirror's entire job is to
            // publish on the transition, and it must not depend on that suppression
            // surviving a toolchain change to keep the keystroke off its readers.
            let nonEmpty = !codeViewerTabs.isEmpty
            if hasCodeViewerTabs != nonEmpty { hasCodeViewerTabs = nonEmpty }
        }
    }
    /// [CF-14] Mirror of `!codeViewerTabs.isEmpty`, maintained by that array's `didSet` —
    /// which fires for element writes too, so it cannot drift (including from tests that
    /// assign `codeViewerTabs` wholesale).
    ///
    /// Exists so the derived presentation flags below can answer WITHOUT reading the array:
    /// every keystroke in the editor writes through to `codeViewerTabs[i].editedCode`, and
    /// under `@Observable` that mutation invalidates every body that touched the array —
    /// including `MainApplicationView.body`, the root window, which only ever wanted to know
    /// whether the panel is on screen. That answer changes when a tab opens or closes, not
    /// when a character is typed.
    private(set) var hasCodeViewerTabs: Bool = false
    var activeCodeViewerTabID: UUID? = nil
    /// Whether the panel is on screen. The panel shows when this is `true` AND there is at
    /// least one tab; when `false` with tabs open, the UI shows the floating reopen button.
    var isCodeViewerVisible: Bool = false {
        // ⚠️ MUTUAL EXCLUSION, enforced here rather than at the call sites. `isCodeViewerVisible`
        // is assigned true from four different places; a rule spread across them is a rule that
        // gets missed by the fifth. Both panels occupy the same trailing slot, so showing one has
        // to hide the other or they overlap.
        //
        // The `if` is what stops this recursing: setting this true assigns the other false, whose
        // own `didSet` then sees false and does nothing.
        didSet { if isCodeViewerVisible { isBackgroundTasksVisible = false } }
    }

    /// Whether the Background Tasks panel is on screen. Deliberately NOT gated on having tasks —
    /// unlike the Code Viewer, which hides itself when its last tab closes. An empty list that
    /// says "nothing has run yet" is a useful answer; a panel that vanishes when the last task is
    /// discarded looks broken.
    var isBackgroundTasksVisible: Bool = false {
        didSet { if isBackgroundTasksVisible { isCodeViewerVisible = false } }
    }
    /// How the panel occupies the window (overlay / split / full — see
    /// `CodeViewerPresentation`). A MODE rather than a stored width so the panel keeps
    /// tracking the window through resizes — a "full" captured as points would stop being
    /// full the moment the window grew. Survives minimize/reopen; cleared with the tabs.
    /// Defaults to `.split`.
    var codeViewerPresentation: CodeViewerPresentation = .split
    /// Where the full-width toggle returns to: entering `.full` from `.split` and toggling
    /// back should land in `.split`, not silently forget it.
    @ObservationIgnored private var lastNonFullPresentation: CodeViewerPresentation = .split

    /// How the background tasks panel occupies the window (overlay / split / full).
    /// Defaults to `.split`.
    var backgroundTasksPresentation: CodeViewerPresentation = .split
    @ObservationIgnored private var lastNonFullBackgroundTasksPresentation: CodeViewerPresentation = .split

    /// The panel's width WHILE a divider drag is in flight; nil when no drag is running.
    ///
    /// Published here rather than kept in the panel's `@State` because the panel is not the
    /// only consumer: in `.split` mode the chat's trailing inset is applied by
    /// `MainApplicationView`, which reads the PERSISTED `codeViewerPanelWidth` — committed
    /// once, on drag end — so the panel used to slide over the chat for the whole drag and
    /// the chat jumped to its new column on release.
    ///
    /// Observed on purpose: a write per drag tick is exactly what makes the chat track the
    /// divider. It is nil except during a drag, so it costs nothing at rest.
    var codeViewerLiveDragWidth: Double? = nil

    /// Per-tab editor view state (cursor, scroll, find). Not observed — see
    /// `CodeViewerEditorStateStore`, which explains why a caret move must not invalidate
    /// any SwiftUI body.
    @ObservationIgnored let codeViewerEditorStates = CodeViewerEditorStateStore()

    /// Set when `applyChanges` can't write (missing source file, on-disk drift, or an
    /// I/O error) so the panel can surface it. These failures were previously log-only,
    /// leaving the user believing the change had applied.
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
    /// The panel is presented when it's marked visible AND at least one tab is open.
    ///
    /// ⚠️ [CF-14] Reads `hasCodeViewerTabs`, NOT `codeViewerTabs` — same answer, but reading
    /// the array here made every body that asks this question (`MainApplicationView.body`
    /// among them) a per-keystroke observer of the editor's draft write-through.
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

    /// The history the NEXT request would actually carry, OLDEST-FIRST — resolved through the same
    /// `BackendHistoryResolver` the request path uses.
    ///
    /// ⚠️ "Exactly the way `MessagingCoordinator` resolves it" is what this used to say, and it is
    /// false twice over: the request path resolves in `ActiveStreamManager.deriveHistory`, not in
    /// `MessagingCoordinator` (whose own resolver survives only for `resumeRun`), and it passes
    /// `inMemory: [userMessage]` where this passes `currentChatMessages`. The two are the same
    /// FUNCTION with different in-memory inputs, which the resolver treats differently — it keeps
    /// in-memory-only rows unconditionally. Sharing the resolver is what makes them comparable;
    /// it is not what makes them equal.
    ///
    /// The context gauge must size the REQUEST, not this view model's `currentChatMessages`,
    /// which is a pagination window (20 on open, +10 per scroll, cap 300). Sizing from the
    /// window made the ring climb as the user scrolled while the prompt never changed, and
    /// made a freshly-opened long conversation under-read its own history by up to 15×.
    /// ⚠️ Sharing the resolver is NECESSARY BUT NOT SUFFICIENT for the two to agree, and the
    /// omission is where they legitimately differ by one row. The request path omits the whole
    /// unfinished TURN (`incompleteTurnIDs`) because a half-written turn makes `pairTurns` report
    /// the question as answered with nothing. The gauge prices tokens rather than building a
    /// transcript, so it omits only the live REPLY (`liveReplyIDs`): the question is a settled,
    /// persisted row the next request certainly carries, and subtracting it made the ring FALL at
    /// the moment of send and jump back at completion. Omitting the reply is still right — the
    /// store holds its partial text (`flushInFlight`), so counting it makes the ring climb
    /// through a run and drop when the row is replaced by the final answer.
    func resolveContextHistory(for conversationID: UUID) async -> [ChatMessage] {
        let resolved = await BackendHistoryResolver.resolve(
            conversationID: conversationID,
            inMemory: currentChatMessages,
            persistence: persistenceService
        )
        // Replies only — see the note above on why this is NOT the request path's turn-level set.
        let omitting = activeStreamManager.liveReplyIDs()
        let sized = omitting.isEmpty ? resolved.history
                                     : resolved.history.filter { !omitting.contains($0.id) }
        logger.debug("[CTXGAUGE] Resolved \(sized.count) message(s) for sizing (stored \(resolved.storedCount), resident window \(currentChatMessages.count), omitted \(resolved.history.count - sized.count) in-flight repl\(resolved.history.count - sized.count == 1 ? "y" : "ies"))\(resolved.capHit ? ", CAP HIT" : "") — conv \(conversationID.uuidString.prefix(8))")
        return sized
    }

    /// Splices a history-compaction checkpoint into the live conversation.
    ///
    /// Not an append: `currentChatMessages` is DESCENDING (newest first) and a checkpoint is
    /// timestamped just after the turns it summarized, so it belongs in the MIDDLE of the
    /// array. Doing this matters beyond display — the next turn's history is taken from this
    /// array, so without the splice compaction would keep re-summarizing the same turns
    /// (a full IC load + inference every request) until the conversation was reloaded.
    ///
    /// Idempotent by id, mirroring the persistence-side upsert. Also guards against the
    /// wrong conversation being open: compaction completes in the background now, so its
    /// checkpoint can arrive after the user has switched chats — splicing it into whatever
    /// happens to be loaded would inject a foreign message into another transcript. The
    /// store already has it; reopening the right conversation loads it from there.
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
    /// Whether the STORE holds messages older than what is loaded — a pure UI paging concern
    /// now, read only by the scroll-back trigger and `loadMoreMessages`.
    ///
    /// It used to be load-bearing for model memory: `MessagingCoordinator.resolveBackendHistory`
    /// short-circuited on `false` to "the window IS the conversation" and handed
    /// `currentChatMessages` over as the entire history. That short-circuit was removed (see
    /// that method's doc) — backend history is now unconditionally resolved from the store
    /// through `BackendHistoryResolver`, so this flag can be flipped for paging reasons alone.
    var canLoadMorePages = true

    /// Set when scroll-back stopped because the resident window hit `maxResidentMessages`,
    /// NOT because the store ran out. Kept separate from `canLoadMorePages` precisely so
    /// the history resolver still consults the store (see above).
    var hasReachedResidencyCap = false

    /// Ceiling on resident messages. `loadMoreMessages` only ever appends — pagination
    /// defers loading but never caps residency, so scrolling back through a long
    /// conversation made every message permanently resident along with its decoded
    /// timeline and cached markdown.
    ///
    /// This BOUNDS growth rather than evicting: eviction is not safe here without
    /// cursor-based paging and viewport awareness (`offset` is derived from the array
    /// count, regeneration indexes into the array, and the history resolver can treat the
    /// array as authoritative). Matches `MessagingCoordinator.backendHistoryMessageLimit`,
    /// so the user can always scroll across everything the model can actually see.
    @ObservationIgnored static let maxResidentMessages = 300


    /// Messages outside this many entries of EITHER end keep no parsed-markdown cache.
    /// The cache is derived data rebuilt on demand by `getOrCreateMarkdownBlocks`, so
    /// dropping it is free of behaviour change — only recompute cost when scrolled back to.
    @ObservationIgnored static let markdownCacheWindow = 60
    @ObservationIgnored private let initialPageSize = 20
    @ObservationIgnored private let subsequentPageSize = 10

    // Monotonic counter bumped on every `loadConversation` entry. Each in-flight
    // load captures its own epoch and refuses to write results if a newer load
    // has started while it was awaiting persistence — guards against any caller
    // that doesn't cancel the previous task (e.g. fire-and-forget Task closures).
    @ObservationIgnored private var loadEpoch: UInt64 = 0


    var isSending: Bool = false

    // [vm-9] The "my messages only" filter is GONE — flag, toggle, reload task, the view that
    // drove it (`ChatHeaderView`, referenced by nothing but its own preview) and the five reset
    // sites. It had no production entry point in any build: no menu item, no command, no button
    // outside that preview. Behind it sat a real corruption — `applyUserMessagesFilter` mutated
    // `currentChatMessages` IN PLACE, and `loadMoreMessages` derives its store offset from
    // `currentChatMessages.count` and appends with no dedup, so one page load after a filter
    // pass fetched from the wrong offset and appended rows the array already held. `ForEach`
    // over a duplicated `ChatMessage.id` is undefined behaviour in SwiftUI. Deleted rather than
    // repaired because nothing could reach it to be repaired for.

    // MARK: - Initialization
    /// Whether THIS instance drives the Code Viewer. Exactly one view model may own it.
    ///
    /// More than one instance exists: the main window's (DevgenticApp) and QuickAccess's
    /// (`QuickAccessSessionViewModel`). QuickAccess mounts no Code Viewer UI at all, so an
    /// owning QuickAccess instance would react to every agent write by opening invisible
    /// tabs and pre-reading files, and would stash/restore tabs nobody can see. Defaults to
    /// `false` so a newly-added view model is inert until it deliberately claims ownership.
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

    /// Observers are process-lifetime by default, so an instance that goes away without
    /// this leaves live registrations behind. That matters concretely: QuickAccess's view
    /// model is built inside a SwiftUI `State(wrappedValue:)` initializer, which can run on
    /// discarded view-struct constructions — each one previously leaked a registration.
    deinit {
        liveWriteObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Live agent tabs (badge-only)

    /// `nonisolated(unsafe)` so `deinit` (which is nonisolated) can remove these without the
    /// Swift 6 isolation error the rest of the codebase's observer teardowns currently hit.
    /// Safe by construction: appended only during `init` and read only in `deinit`, both of
    /// which have exclusive access to the instance.
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

    /// A file write is STARTING: open or update its tab in the background. Badge-only
    /// guarantees, in order: the panel is never shown, the active tab is never changed
    /// (unless the user's follow toggle is on AND the panel is visible), and a tab
    /// holding unsaved user edits is never touched.
    func handleAgentWriteBegan(_ payload: AgentLiveWriteEvent.Began) {
        // Compare against the DESTINATION, not the displayed conversation. During a switch
        // `currentChatMessages` still holds the OUTGOING conversation until the fetch returns,
        // so a write for the conversation being LEFT passed this guard and appended its tab to
        // the incoming conversation's just-cleared viewer — and `restoreCodeViewerSession`
        // only fires on an empty viewer, so the incoming conversation's stashed tabs were then
        // silently never restored, and the orphaned tab got stashed under the WRONG
        // conversation on the next switch.
        guard payload.conversationID == destinationConversationID else {
            logger.info("[CodeViewer] Live write for '\(payload.fileName)' ignored — it belongs to conversation \(payload.conversationID.uuidString.prefix(8)) but \(self.destinationConversationID?.uuidString.prefix(8) ?? "none") is \(self.loadingConversationID == nil ? "loaded" : "loading"). No live tab; the timeline chip still appears when that conversation is open.")
            return
        }

        // ⚠️ NOTHING may be planted while a load is in flight, not even for the conversation
        // being loaded. `resetCodeViewer()` runs at the TOP of `loadConversation` — it has
        // already stashed the outgoing tabs and emptied the viewer — and
        // `restoreCodeViewerSession` only restores INTO AN EMPTY viewer. A tab appended here
        // makes the viewer non-empty, so the incoming conversation's own restore is skipped
        // SILENTLY, and the next switch then stashes this single live tab OVER that
        // conversation's entry, destroying the drafts `CodeViewerTab.editedCode` documents as
        // existing nowhere else.
        //
        // This is the same refusal `AgentTimelineView.shouldDeliverOpen(origin:current:
        // isLoadInFlight:)` already makes for the timeline's own open path, and its doc states
        // the reasoning we are copying: a tab planted in this window also suppresses the
        // incoming conversation's restore. The two paths must not disagree about this window.
        //
        // The write is NOT lost: it still runs, the timeline chip still appears, and the
        // completion is settled by `handleAgentWriteCompleted`, which resolves against the
        // payload's own conversation and finds no tab to settle here.
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
            // Successive writes to the same file reuse its tab. Content replacement needs
            // a NEW snippet (code is let); the id change only rebuilds the editor if this
            // tab is the active one — where showing the fresh content is the point.
            codeViewerTabs[index].snippet = snippet
            codeViewerTabs[index].liveState = .active
            // `editedCode` MUST be cleared with the rest. `isDirty` is false whenever
            // `editedCode == (lastSavedBuffer ?? snippet.code)`, which is exactly the state a
            // SUCCESSFUL SAVE leaves behind — so a saved-then-rewritten tab passed the
            // !isDirty guard above while still holding the user's old buffer. Leaving it set
            // meant `effectiveCode` kept returning that stale text over the agent's new
            // content, the tab showed an unsaved-changes dot it never earned, and a ⌘S wrote
            // the stale buffer back over the agent's write — with the drift guard satisfied,
            // because `lastSavedDisk` was reset on the line below. Clearing it is what makes
            // the tab genuinely adopt the incoming snippet.
            codeViewerTabs[index].editedCode = nil
            codeViewerTabs[index].lastSavedBuffer = nil
            codeViewerTabs[index].lastSavedDisk = nil
            // Cleared with the rest: a snapshot from the PREVIOUS write to this file no
            // longer describes disk (that write landed), and the pre-read below is async —
            // so a completion racing it would otherwise promote stale bytes as the baseline.
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

        // Pre-read the on-disk state and PARK it on the tab as `preWriteDisk`. If this write
        // is denied or fails, those are the bytes still on disk, and the rejected tab needs
        // them as its drift baseline or ⌘S is refused forever (the tab holds the proposal,
        // which by definition is not what the file contains).
        //
        // The completion's `preWriteContent` is authoritative and overwrites this when it
        // carries one — but the USER-DENIED path builds its `ToolOutput` before the
        // executor's snapshot is taken (`ToolExecutionLoop`, the `!approved` branch), so a
        // denial always arrives with nil and this best-effort read is the only baseline
        // there is. Size-capped like every snapshot.
        //
        // Was a read whose result was DISCARDED by an empty `MainActor.run` body, under a
        // comment claiming it fed a diff in the pending tab. The panel carries no diff.
        let path = payload.path
        Task { [weak self] in
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
                    // ⚠️ The write was ALREADY settled as rejected while this read was in flight,
                    // so the rejection branch ran with nothing to use and left `lastSavedDisk`
                    // nil — which refuses ⌘S on that tab forever as on-disk drift, the exact
                    // outcome this read exists to prevent. This became reachable when the
                    // workflow close paths started posting completions MID-RUN (node failure and
                    // user skip fire milliseconds after `.toolCall`, unlike the end-of-run CF-9
                    // loop they mirror), so the settle can easily beat a detached `.utility` read
                    // of a large file. Promote the bytes straight to the baseline — exactly what
                    // the rejection branch would have done had they arrived in time.
                    self.codeViewerTabs[index].lastSavedDisk = pre
                    self.codeViewerTabs[index].preWriteDisk = nil
                    logger.info("[CodeViewer] Pre-write snapshot for '\((path as NSString).lastPathComponent)' landed AFTER the write was already settled as rejected — promoted it straight to the drift baseline. CONSEQUENCE: ⌘S on that tab writes the proposal instead of being refused as drift for the rest of the session.")
                default:
                    // Settled successfully, or the badge was cleared — the baseline is moot.
                    return
                }
            }
        }
    }

    /// The write finished: settle the tab (success) or mark it rejected (denied/failed —
    /// the tab shows a proposal that never reached disk).
    ///
    /// On rejection the tab's drift baseline is set to the pre-write bytes, because those
    /// are what the file still contains — the executor's authoritative snapshot when the
    /// payload carries one (a failed write), otherwise the UI's best-effort pre-read parked
    /// by `handleAgentWriteBegan` (a user DENIAL never carries one: `ToolExecutionLoop`
    /// builds the denial `ToolOutput` before `preWriteSnapshot` runs). Without a baseline
    /// the guard falls back to the proposal and refuses every save on the tab as drift.
    func handleAgentWriteCompleted(_ payload: AgentLiveWriteEvent.Completed) {
        // ⚠️ This deliberately does NOT share `handleAgentWriteBegan`'s destination guard, and
        // the two are no longer "the same expression" — an earlier comment here said they must
        // be, which was right only while this handler could see nothing but the live array.
        //
        // `began` decides where a tab may be CREATED, so it is rightly about the displayed
        // (destination) conversation. Settling is a different question: the tab already exists,
        // and it must be settled wherever it now lives. A conversation switch moves it — still
        // `.active` — into `tabsByConversation` via `resetCodeViewer` → `stashCurrentCodeViewerTabs`,
        // and the old guard then dropped its completion for belonging to a conversation that is
        // no longer displayed. Re-opening that conversation restored a tab stuck `.active`
        // forever: the orange "Agent is writing this file" banner never cleared, the minimized
        // pill kept pulsing via `hasLiveAgentTabs`, and because the rejection branch never ran,
        // `lastSavedDisk` stayed nil so ⌘S was refused with an on-disk-drift claim that is FALSE.
        // The CF-9 backstop in `ActiveStreamManager.finalizeMessage` posts the same event and was
        // filtered by the same guard, so it could not recover it either.
        //
        // Resolving against the payload's OWN conversation, live-or-stashed, is the same shape
        // the save bookkeeping already uses (`residence(ofTabID:)` / `mutateTab(at:)`) and for
        // the same stated reason: work that resumes after an await must look in both places.
        guard let location = residence(ofLiveWritePath: payload.path, in: payload.conversationID) else {
            logger.debug("[CodeViewer] Live-write completion for '\(payload.fileName)' has no active live tab in conversation \(payload.conversationID.uuidString.prefix(8)) — settled earlier, never given a tab (a load was in flight), or the tab was closed.")
            return
        }

        var settledMessage = ""
        mutateTab(at: location) { tab in
            if payload.isSuccess {
                tab.liveState = nil
                // The proposal IS on disk now, so the pre-write bytes must NOT become the drift
                // baseline: `lastSavedDisk` stays nil and the guard falls back to `snippet.code`,
                // which is what landed.
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

    /// Where a tab lives right now.
    ///
    /// Save bookkeeping that resumes AFTER an await must look in both places. The Save-As
    /// panel is `begin`-presented, i.e. MODELESS, so the sidebar stays clickable, and
    /// `performApplyChanges` awaits an off-main write — either way the user can switch
    /// conversations mid-save, which runs `resetCodeViewer` → `stashCurrentCodeViewerTabs`
    /// → `codeViewerTabs.removeAll()`. A lookup that searches only the live array then
    /// misses a tab that was never closed: the file was written, but the restored copy kept
    /// no link and stayed dirty, and the log said the tab had been closed.
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

    /// Finds the tab with an IN-FLIGHT agent write for `path`, scoped to one conversation and
    /// searching the live viewer or that conversation's stash.
    ///
    /// Scoped rather than global (unlike `residence(ofTabID:)`, where a UUID can match at most
    /// one entry) because a path is NOT unique across conversations: two conversations can each
    /// hold a live tab for the same file, and settling the wrong one would clear a banner for a
    /// write that is still running while leaving the finished one pulsing forever.
    ///
    /// The `liveState == .active` filter is part of the key: a completion may only settle a tab
    /// that is actually mid-write, so a second completion for the same path (the CF-9 backstop
    /// in `finalizeMessage` re-posting one the handler already processed) finds nothing and is
    /// a no-op instead of resurrecting a settled tab's baseline.
    private func residence(ofLiveWritePath path: String, in conversationID: UUID) -> TabResidence? {
        let isLiveWriteTab: (CodeViewerTab) -> Bool = { $0.filePath == path && $0.liveState == .active }
        // The live array belongs to `conversationID` only when that conversation owns the viewer.
        // Mid-load it is empty (`resetCodeViewer` cleared it), so this simply misses and the
        // stash below answers — which is exactly the case this lookup exists for.
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

    /// Opens a code block in a tab: focuses the existing tab if this exact block is already
    /// open, otherwise appends a new one. Always makes the panel visible and the tab active.
    /// Dedup is by content + source link — NIL-TOLERANT on the link, because deferred
    /// linking stamps `sourceFileID` onto open tabs asynchronously: a re-click of the same
    /// card (whose own window-linking may still miss) must match the now-linked tab
    /// instead of stacking a duplicate.
    @discardableResult
    func openTab(for snippet: CodeSnippet, fileName: String? = nil, filePath: String? = nil,
                 originMessageID: UUID? = nil, originBlockIndex: Int? = nil) -> UUID {
        // A file-backed tab is identified by its PATH. Matching on `fileName` alone merges
        // `src/Main.java` and `test/Main.java` into a single tab.
        if let filePath, let index = codeViewerTabs.firstIndex(where: { $0.filePath == filePath }) {
            // Refresh the content unless the user has unsaved edits in this tab.
            //
            // ⚠️ The `!= snippet.code` test is load-bearing, and mirrors the origin branch below.
            // Without it, re-opening a tab from the SAME timeline chip adopted that chip's now-
            // stale inline content and wiped the baseline: a tab the user had edited and SAVED
            // (clean, because `editedCode == lastSavedBuffer`) would silently revert to the
            // agent's original proposal, and with `lastSavedDisk` nil the next ⌘S drift-checked
            // the reverted text against the file holding the user's saved work and refused it.
            // Re-clicking a chip is not a request to discard what you saved.
            if !codeViewerTabs[index].isDirty, codeViewerTabs[index].snippet.code != snippet.code {
                codeViewerTabs[index].snippet = snippet
                // Same three-field reset as `handleAgentWriteBegan`, for the reason its comment
                // gives: a SAVED tab is clean-but-`editedCode`-set, so replacing the snippet
                // alone left `effectiveCode` returning the user's old buffer over the fresh
                // content, and `lastSavedDisk` (the OLD bytes) as the drift baseline — the
                // next ⌘S was then refused as on-disk drift against a file the agent had
                // legitimately rewritten (CF-8). The tab must genuinely adopt the snippet.
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
        // A chat block is identified by WHERE it came from, not by its text. Re-opening a
        // message whose stream has advanced since the first open must refresh that tab, not
        // append a second one holding the truncated fragment.
        if let originMessageID, let originBlockIndex,
           let index = codeViewerTabs.firstIndex(where: {
               $0.originMessageID == originMessageID && $0.originBlockIndex == originBlockIndex
           }) {
            if codeViewerTabs[index].isDirty {
                logger.info("[CodeViewer] Reopen of block \(originBlockIndex) from message \(originMessageID.uuidString.prefix(8)) kept the tab's unsaved draft — content not refreshed.")
            } else if codeViewerTabs[index].snippet.code != snippet.code {
                codeViewerTabs[index].snippet = snippet
                if let fileName { codeViewerTabs[index].fileName = fileName }
                // Clear the save/draft baseline with the snippet — see the filePath branch
                // above and `handleAgentWriteBegan`. An edited-then-reverted (or saved) tab is
                // clean with `editedCode` still set, and would otherwise keep showing that
                // stale buffer instead of the block it was just reopened from (CF-8).
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
            // The incoming snippet may carry a link the tab is missing (window resolved
            // this time) — adopt it in place. Var-field mutation, NOT a new snippet: a
            // fresh snippet id would rebuild the editor under the user.
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

    /// Opens a FILE from an agent-timeline tool row: named by the file, language inferred
    /// from its extension. When a pre-write snapshot exists the tab opens straight into an
    /// informational diff (what the agent changed); the baseline is kept on the tab so the
    /// diff can be closed and reopened. No attachment link — Apply/hunk operations stay off.
    /// Whether this view model has a Code Viewer to open into at all.
    ///
    /// QuickAccess mounts none, so surfaces that would otherwise offer an "open in viewer"
    /// affordance must not advertise one there. Exposed because a tappable file reference
    /// that opens nothing is worse than plain text.
    var canPresentCodeViewer: Bool { ownsCodeViewer }

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

    /// Per-keystroke write-through from the editor buffer. Deliberately NOT synced "at
    /// boundaries" (tab switch, close, minimize, …) — one missed boundary is silent data
    /// loss; write-through is correct by construction.
    ///
    /// ⚠️ ALWAYS stores the content, even when it equals the restore point. It used to store
    /// `nil` in that case as a way to clear the dirty dot — but that made `editedCode == nil`
    /// mean TWO different things ("the editor has no draft" and "the draft happens to equal the
    /// restore point"), and `effectiveCode` (`editedCode ?? snippet.code`) therefore reported
    /// the PRISTINE CHAT BLOCK for a tab whose editor was showing the user's text. Anything
    /// that read `effectiveCode` as "what the editor is showing" was silently wrong in that
    /// state — including the save path, which then wrote the original block over the user's
    /// file. The dirty dot still clears, because `isDirty` decides by COMPARISON, not by nil.
    ///
    /// [CF-14] The write is skipped when the buffer ALREADY holds this exact text — not an
    /// optimisation of the store (the state is identical either way) but of the publish.
    /// Observation's same-value suppression covers whole-property assignment only, NOT an
    /// element write through the array's subscript (measured, Swift 6.2), so a re-delivery
    /// of unchanged content — the editor emits one whenever its document is rebuilt — would
    /// invalidate every reader of the tabs for nothing. The keystroke that DOES change the
    /// text still publishes; the panel's dirty dot depends on it.
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
    //
    // [vm-7] The header used to say "and relaunches", which the type's own doc two hundred
    // lines up contradicts ("Switching conversations keeps tabs …; quitting does not") —
    // `tabsByConversation` is a plain in-memory dictionary and there is no persistence layer
    // under any of this. A `private static let persistedTabLimit = 20` sat here too, with a
    // comment calling itself "a runaway accumulation guard": it had exactly one occurrence in
    // the repo, its own declaration, so it guarded nothing. Both are gone rather than made
    // true — and deliberately NOT replaced with a real cap on `tabsByConversation`, which is
    // the ONLY place an unsaved Code Viewer draft exists. Evicting an entry to bound memory
    // would delete the user's unsaved work with no prompt, which is strictly worse than the
    // growth it would close. If a bound is ever wanted, it belongs on the LIVE tab array and
    // must skip any tab that is dirty, active, or receiving a live write.

    /// The conversation the CURRENTLY OPEN tabs belong to.
    ///
    /// ONE expression, deliberately, because the reset DECISION and the stash KEY must agree:
    /// deriving them separately is what let the viewer be cleared under an identity the stash
    /// could not resolve, destroying tabs and unsaved drafts.
    ///
    /// `loadedConversationID` leads, and that ordering is the fix. It is written in exactly two
    /// places, both inside `loadConversation`, whereas `currentChatMessages` is ALSO pre-cleared
    /// by callers before they trigger a load — `deselectConversationAndShowWelcome`
    /// (ConversationManagementCoordinator) and `performInterfaceSwitch`
    /// (MainApplicationViewModel) both set it to `[]` and only then let the debounced
    /// `loadConversation` run. Reading identity from the messages therefore returned nil for a
    /// conversation that was still loaded. The message fallback stays for the pre-load window,
    /// where `loadedConversationID` is not yet set.
    ///
    /// ⚠️ Internal since 2026-09-22: the Background Tasks panel needs the same identity, and the
    /// paragraph above is precisely why it must READ this rather than derive its own. A second
    /// expression would drift from this one in exactly the pre-load window described.
    var viewerOwningConversationID: UUID? {
        loadedConversationID ?? currentChatMessages.first?.conversationId
    }

    /// The conversation the viewer will belong to once any in-flight load settles.
    ///
    /// `loadConversation` only assigns `currentChatMessages`/`loadedConversationID` AFTER its
    /// fetch returns, so for the whole duration of a switch both still name the OUTGOING
    /// conversation. Anything reacting to an event mid-load — a live agent write landing while
    /// the user navigates away — must ask THIS, not the displayed state, or it attributes the
    /// event to the conversation being left and drops a tab into the incoming conversation's
    /// freshly cleared viewer (which then suppresses that conversation's restore, because
    /// `restoreCodeViewerSession` only fires on an empty viewer).
    /// ⚠️ NOT `private` any more, and not a Code-Viewer concept. The question it answers —
    /// "which conversation does an event arriving right now belong to?" — is the one every
    /// consumer of a mid-switch event has to ask. `ConversationSyncService` was answering it with
    /// `currentChatMessages.first?.conversationId`, i.e. by POSITION, which is the weakest
    /// definition in the codebase and gated a live stream insert on it.
    ///
    /// ⚠️ THIS IS VIEWER IDENTITY, AND IT MUST STAY THAT WAY. It deliberately does NOT lead the
    /// selection. `ConversationSwitchCoordinator` debounces 250 ms and may await an MLX + Ollama
    /// `unloadModel()` before `loadConversation` runs, so for that whole span this still names the
    /// OUTGOING conversation — which is CORRECT, because the rows and Code Viewer tabs on screen
    /// are still that conversation's.
    ///
    /// ⚠️ IT IS NOT CONSTANT ACROSS A SWITCH, so do not read the sentence above as "it is always
    /// the outgoing conversation until the swap". `loadingConversationID` is the first operand and
    /// is assigned at the TOP of `loadConversation`, so from there until the array assignment at
    /// the bottom this names the INCOMING conversation while `currentChatMessages` still holds the
    /// outgoing rows. That span is deliberately invisible — `isInitiallyLoadingConversation` goes
    /// true two lines later and `ChatHistoryView` drops the transcript to `.opacity(0)` behind a
    /// ProgressView — and it ends with the array being replaced wholesale. A consumer that cannot
    /// tolerate the incoming answer during a load must additionally check
    /// `isInitiallyLoadingConversation`; `ConversationSyncService`'s comment works the two spans
    /// through in full.
    ///
    /// A `pendingDestinationConversationID` that led the selection was added on 2026-09-06 and
    /// REMOVED on 2026-09-07. Folding it in here broke the Code Viewer in both directions: a
    /// live-write `completed` for the still-displayed conversation was dropped, leaving its tab
    /// pulsing "agent is writing this file" forever (that guard's own log line states exactly
    /// this consequence), while a `began` for the incoming conversation was filed into the
    /// outgoing viewer and then stashed under the wrong conversation. Splitting it into a separate
    /// `routingDestinationConversationID` fixed the breakage but left a property no production
    /// code read — machinery set on every switch and cleared on every load for no reader — so the
    /// whole chain went. If a future SEND path needs "where is the user going?", that is a
    /// genuinely different question: re-introduce it for that consumer, with that consumer, and do
    /// not route viewer state through it.
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

    /// Forgets this conversation's stashed tabs because the USER emptied the viewer.
    ///
    /// Deliberately called from the close paths rather than inferred from an empty viewer at
    /// switch time: only a close knows the emptiness was intentional. Without it, closing every
    /// tab and then triggering a same-conversation reload (the user-messages filter routes
    /// through `loadConversation`) restored the closed tabs from a stale entry.
    private func dropStashedTabs(reason: String) {
        guard ownsCodeViewer else { return }
        // NEVER drop while a load is in flight. `viewerOwningConversationID` still names the
        // OUTGOING conversation until the fetch returns, but `resetCodeViewer` has already filed
        // that conversation's tabs (and its unsaved drafts) under it and cleared the viewer — so
        // any tab the user can close right now belongs to the INCOMING one. Resolving the key
        // here would remove the outgoing conversation's stash instead, destroying drafts that
        // live nowhere else, and log a reason describing a tab the user never closed.
        //
        // Refusing costs a stale entry that may resurrect closed tabs on the next open — the
        // thing this method exists to prevent — which is the better of the two errors.
        //
        // ⚠️ As of 2026-09-12 this guard is a BACKSTOP WITH NO REACHABLE CALLER, and it is kept
        // deliberately. Both close paths are now closed during a load: the single close needs a
        // tab to close and `resetCodeViewer` has emptied the viewer, and
        // `forceCloseAllCodeViewerTabs` returns at its own
        // `guard !codeViewerTabs.isEmpty || isCodeViewerVisible` because the same reset made both
        // false. It is therefore UNTESTED — a test written against the close-all route passed
        // with this guard deleted, which is how that was discovered. Do not delete it on the
        // strength of "nothing reaches it": what it prevents is the loss of unsaved drafts that
        // live nowhere else, and the thing that currently makes it unreachable is vm-1's refusal
        // to plant a tab mid-load — one new mid-load path and this is load-bearing again.
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
        // Empties are checked BEFORE identity: with nothing open there is nothing to preserve
        // and nothing to lose, so an unresolvable identity is not a failure here. (It is on
        // every app launch — first load, `loadedConversationID` still nil — and reporting that
        // as a data-loss error would bury the one case that is.)
        guard !codeViewerTabs.isEmpty else {
            // NOTHING is dropped here. An empty viewer used to be read as "the user closed
            // everything" and the conversation's entry was deleted — but the viewer is ALSO
            // empty when an in-flight switch has already cleared it, and then the deletion
            // destroyed tabs (and unsaved drafts) belonging to a conversation the user never
            // left. Switch A→B, then to C before B's fetch returns, and A's drafts were gone.
            //
            // Emptiness cannot distinguish the two, so it is no longer asked to: the close
            // paths drop the entry explicitly via `dropStashedTabs`, because they are the only
            // places that know the user meant it.
            logger.debug("[CodeViewer] Nothing to stash for \(self.viewerOwningConversationID?.uuidString.prefix(8) ?? "no loaded conversation") — viewer already empty; any existing entry is left intact.")
            return true
        }
        guard let conversationID = viewerOwningConversationID else {
            // Was a SILENT return, and it sat directly upstream of `codeViewerTabs.removeAll()`
            // — so the one path that destroyed unsaved drafts was also the one path that said
            // nothing. The drafts exist nowhere else (see this type's doc comment).
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
        // STASH FIRST, unconditionally — before the guard and before `loadedConversationID`
        // moves, or the tabs get filed under the INCOMING conversation. Unconditional
        // because a viewer emptied by close-all must clear its entry too.
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
        // Report what actually happened. This line used to claim the tabs were stashed
        // unconditionally, including on the one path where the stash had just failed — a log
        // asserting the opposite of the truth on a data-loss path.
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

    /// Resolves a snippet's source attachment: the LOADED page of messages first (free,
    /// covers the common case), then the persistence store (the source message scrolled
    /// out of the paginated window — previously a silent dead-end for diff/apply in long
    /// conversations). Nil = the message/file is genuinely gone, not merely unloaded.
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

    /// The exact bytes to write when applying `snippetCode`: the snippet's code with the
    /// original file's EDGE whitespace re-attached.
    ///
    /// `CodeSnippet.normalizedCode` trims BOTH edges when a tab is opened, but this only ever
    /// restored the trailing side. The asymmetry meant a single ⌘S — even with no edits at
    /// all, since `saveTabToItsPath` has no unchanged-buffer guard — permanently deleted a
    /// file's leading blank line or indentation. (It ALSO collapsed multiple trailing blank
    /// lines to one and dropped a CRLF terminator outright — this sentence used to imply the
    /// asymmetry fix had covered that; it had not, and the symmetric restore below is what does.) The drift guard could not catch it either: it compares the two sides trimmed,
    /// so the loss is invisible to it by construction.
    ///
    /// Restoring rather than un-trimming `normalizedCode` is deliberate — that trimming is
    /// load-bearing for block-identity dedup and click-to-tab lookup.
    ///
    /// LIMITATION, inherent to trimming on open: a user cannot express "I deliberately
    /// removed the leading blank line", because they were never shown it. Re-attaching what
    /// the viewer hid is the safe direction; silently deleting it is not.
    ///
    /// `baseline` must be the ON-DISK bytes wherever they are available. An already-trimmed
    /// baseline simply has no edge whitespace to restore, so this degrades to a no-op rather
    /// than to damage. Pure for testing.
    static func contentToApply(snippetCode: String, preservingEdgeWhitespaceOf baseline: String) -> String {
        var out = snippetCode
        let lead = String(baseline.prefix(while: \.isWhitespace))
        // `lead.count != baseline.count` skips an all-whitespace baseline, which would
        // otherwise prepend the entire file to itself.
        // ⚠️ The test is "does the buffer have edge whitespace OF ITS OWN?", NOT "does it already
        // end in the baseline's exact run". The `hasPrefix`/`hasSuffix` form is NOT IDEMPOTENT:
        // a buffer carrying one newline of its own never matches a two-newline baseline run, so
        // every save appended the whole run on top of what was there — and because the result
        // becomes the next baseline (`lastSavedDisk`), the file grew by one character per ⌘S,
        // unbounded, on all three save engines. Measured: buffer "hello\n" against disk
        // "hello\n\n" gives \n\n\n, \n\n\n\n, \n\n\n\n\n … The drift guard cannot catch it —
        // it compares both sides TRIMMED — so every one of those writes is accepted.
        //
        // A buffer that already ends in whitespace has EXPRESSED an intent there; restoring is
        // only for a buffer the viewer trimmed, which by definition has none.
        if !lead.isEmpty, lead.count != baseline.count, out.first?.isWhitespace != true {
            out = lead + out
        }
        // ⚠️ [vm-6] SYMMETRIC with the leading side — capture the whole trailing whitespace RUN,
        // not a single "\n". The old `hasSuffix("\n")` test restored exactly one newline, so a
        // file ending in several blank lines had them collapsed to one by a save that changed
        // nothing else. Worse for CRLF: Swift compares grapheme clusters and "\r\n" is ONE
        // Character, so `"a\r\nb\r\n".hasSuffix("\n")` is FALSE — the guard never fired and the
        // final line terminator was DROPPED entirely, giving git a "\ No newline at end of file"
        // on a file nobody meant to change. Capturing the literal run fixes both, because the run
        // is whatever bytes were actually there.
        //
        // `trail.count != baseline.count` mirrors the leading guard and is what stops an
        // all-whitespace baseline splicing the file into itself.
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

    /// The ONE save engine: writes the snippet's tab BUFFER (the user's draft when one
    /// exists, else the block itself) back to the linked source file. Both the diff-mode
    /// Apply button and ⌘S land here. Surfaces every failure via `codeApplyError`; guards
    /// against on-disk drift.
    ///
    /// Two invariants worth their weight:
    /// - The drift-guard baseline ADVANCES with each of our own writes
    ///   (`tab.lastSavedDisk`), falling back to attach-time content only for the first.
    ///   Comparing against attach-time forever made the guard refuse every save after the
    ///   first — flagging our own previous write as "drift".
    /// - Success does NOT replace `tab.snippet` (the old behaviour): a new snippet id
    ///   forces a full editor rebuild, which nukes cursor and scroll on every ⌘S. The
    ///   buffer already shows the saved text; only the saved-state bookkeeping changes.
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

        // The write/verify/replace below is blocking filesystem I/O and this class is
        // @MainActor — running it inline beach-balled the UI for the duration on any
        // sizeable file. It runs off-main inside `atomicallyWrite`; the state update
        // after the await is back on the main actor.
        do {
            try await Self.atomicallyWrite(newContent, to: fileURL, expectingBaseline: baseline, fileName: fileName)

            logger.info("✅ Saved \(buffer.count) chars to file: \(fileURL.path)")
            withAnimation {
                self.codeApplyError = nil
                // Re-resolve the tab AFTER the await — it may have been closed, or STASHED by
                // a conversation switch, while the write was in flight (tab identity is
                // content-based and we no longer mutate `snippet`, so the lookup is stable
                // when the tab still exists). A live-array-only lookup silently skipped the
                // bookkeeping for a stashed tab, so the restored copy re-offered a save whose
                // bytes were already on disk.
                if let location = self.residence(ofSnippet: snippet) {
                    // Set inside the mutation when the buffer moved mid-write; logged after
                    // it returns, so the log line isn't emitted from inside a tab mutation.
                    var bufferMovedNote: String? = nil
                    self.mutateTab(at: location) { tab in
                        // The bytes ARE on disk, so the saved-state bookkeeping always advances:
                        // `lastSavedDisk` is the drift baseline for the next save, and
                        // `lastSavedBuffer` records which buffer produced it.
                        tab.lastSavedBuffer = buffer
                        tab.lastSavedDisk = newContent
                        Self.clearRejectedLiveState(&tab, savedTo: fileName)

                        // Only adopt `buffer` as the tab's text if the buffer hasn't moved
                        // DURING the write — keystrokes that landed mid-save are still unsaved
                        // edits. The editor writes through per keystroke
                        // (`updateCodeViewerDraft`) and its document is only rebuilt when
                        // `snippet.id` changes, which this path deliberately avoids; so an
                        // unconditional `editedCode = buffer` here silently reverted the model
                        // to the pre-keystroke text while the NSTextView kept showing the newer
                        // one, and `isDirty` (buffer == lastSavedBuffer) then reported clean, so
                        // close-gating never warned and the next ⌘S hit the no-op guard above.
                        // Keep the buffer rather than clearing it — clearing reverted the tab to
                        // the pristine block.
                        // `effectiveCode` is only trustworthy as "the editor's live text" because
                        // `updateCodeViewerDraft` always stores the content — see the ⚠️ on it. When
                        // it nilled `editedCode` at the restore point, this comparison read the
                        // pristine chat block instead, took the else-branch, and left the tab CLEAN
                        // holding that block; the next save then wrote it over the user's file.
                        let live = tab.effectiveCode
                        if live == buffer {
                            tab.editedCode = buffer
                        } else {
                            // Report the state REACHED, not the state intended. After AD1 the tab is
                            // dirty in the ordinary case (the editor's write-through keeps
                            // `editedCode`), but `handleAgentWriteBegan` can clear it mid-write when
                            // an agent rewrites the same file — and then the tab is clean and holds
                            // the agent's content, not "the newer text". Asserting the happy path
                            // here is the same shape as the comments this cluster keeps correcting.
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
    /// Writes a PATH-linked tab's buffer back to its file.
    ///
    /// Distinct from `applyChanges`, which resolves an ATTACHMENT (`sourceFileID`) through
    /// the message store. A tab can be linked to a real file without any attachment behind
    /// it — a Save-As'd tab, or one opened from an agent write — and those had no ⌘S route
    /// at all before: every save re-opened the panel.
    /// The three outcomes of reading a save destination to drift-check against, carried back
    /// across the actor hop as plain values.
    ///
    /// ⚠️ `.absent` and `.unreadable` are NOT the same answer and must never be merged: absent
    /// means the save may proceed as a create, unreadable means we could not establish what we
    /// would be overwriting and the save must be refused. Collapsing them is the exact bug the
    /// caller's own comment records. The failure carries Strings rather than the `Error` so the
    /// value is trivially `Sendable`.
    private enum DriftRead: Sendable {
        case content(String)
        case absent
        case unreadable(reason: String, description: String)
    }

    func saveTabToItsPath(tabID: UUID) async {
        guard let index = codeViewerTabs.firstIndex(where: { $0.id == tabID }),
              let path = codeViewerTabs[index].filePath else { return }
        // Write through a symlink to its TARGET. `write(to:atomically:)` aimed at a symlink
        // REPLACES the link with a regular file and leaves the real file untouched —
        // verified empirically. The drift check below reads THROUGH the link, so it compares
        // the correct bytes and then the write lands on a different inode: the user's log
        // says "Saved N chars", the link is silently gone, and every other consumer of the
        // shared file still sees the old content.
        let url = Self.writeTarget(forPath: path)
        let buffer = codeViewerTabs[index].effectiveCode

        // The baseline falls back to the content the tab was OPENED with, mirroring
        // `applyChanges`' `lastSavedDisk ?? sourceFile.content`. Without the fallback every
        // timeline-opened and agent-live-write tab (both start with `lastSavedDisk == nil`)
        // saved with no drift check at all — silently overwriting an external edit, which
        // is precisely the unprotected state design §12 D3 warns about. Found by the
        // 2026-07-26 re-scope audit.
        let baseline = codeViewerTabs[index].lastSavedDisk ?? codeViewerTabs[index].snippet.code

        // Read once: the same bytes answer "did this drift?" AND "did it end in a newline?".
        //
        // ⚠️ OFF THE MAIN ACTOR. This whole method runs on the main actor (the class is
        // `@MainActor`), and a path-linked tab can be an arbitrarily large agent-written file
        // opened straight from a timeline row — `openTimelineFileInCodeViewer` applies no size
        // cap — so slurping it here beachballed the app for the length of the read.
        //
        // ⚠️ And DELIBERATELY NOT size-capped, unlike the Save-As pre-read. There the read only
        // restores edge whitespace, so skipping it costs a trailing newline. HERE the read IS
        // the drift guard: skipping it would let a save silently overwrite an external edit,
        // which is the data loss the guard exists to prevent. Cost, not safety, is what moves.
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
            // Compare on the trimmed form: the tab's content came through
            // `CodeSnippet.normalizedCode`, so a pristine file differs from it by exactly
            // the trailing newline and would otherwise read as drift on every first save.
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
            // UNREADABLE IS NOT ABSENT. `String(contentsOf:encoding:.utf8)` also throws for a
            // non-UTF-8 document (Latin-1 source, a stray high byte) and for a permissions or
            // unreachable-mount failure. Those used to land in the branch above, which skipped
            // the drift guard entirely and then overwrote the file — discarding whatever was
            // on disk — while logging "No existing file", a claim the catch never established.
            logger.error("[CodeViewer] Save refused for \(url.lastPathComponent) — its current contents could not be read to drift-check against: \(reason). Its absence was NOT established, so overwriting could discard work; nothing was written.")
            codeApplyError = CodeApplyError.writeFailed(
                fileName: url.lastPathComponent,
                underlying: String(localized: "its current contents could not be read to compare against (\(description))")
            ).errorDescription
            return
        }

        // Preserve the file's edge whitespace — leading blank line/indentation AND the POSIX
        // trailing newline — which `normalizedCode` trimmed when the tab was opened. Writing
        // the trimmed buffer verbatim silently stripped both. The reference MUST be the
        // on-disk bytes: `baseline` may be the already-trimmed snippet, which has nothing
        // left to restore.
        let content = Self.contentToApply(
            snippetCode: buffer,
            preservingEdgeWhitespaceOf: onDiskContent ?? baseline
        )
        do {
            // ⚠️ `atomicallyWrite`, not `content.write(to:atomically:)`: it runs the blocking
            // write off the main actor (the reason this method was rewritten) and is
            // transaction-safe — temp file in the same directory, read back to verify, then an
            // atomic replace — so a crash or full disk mid-write cannot truncate the user's
            // file. `expectingBaseline` is deliberately nil: the drift check ran ABOVE, on the
            // TRIMMED comparison this path needs, and the helper's own guard is exact-equality,
            // which would read a pristine file's trailing newline as drift on every first save.
            try await Self.atomicallyWrite(content, to: url, fileName: url.lastPathComponent)
            guard let i = codeViewerTabs.firstIndex(where: { $0.id == tabID }) else {
                // Was a silent return. The bytes ARE on disk; only the tab's saved-state
                // bookkeeping is lost.
                logger.warning("[CodeViewer] Saved \(buffer.count) chars to \(url.path), but tab \(tabID.uuidString.prefix(8)) is no longer open — it was closed during the write. CONSEQUENCE: no drift baseline is recorded, so a tab reopened on this file drift-checks its next save against the block rather than these bytes.")
                return
            }
            // ⚠️ ONLY when the buffer is still the one that was written. Moving the read and the
            // write off the main actor opened a window this method never had: the user can type
            // during the awaits. An unconditional `editedCode = buffer` would then DISCARD those
            // keystrokes — silent data loss introduced by a performance fix. Leaving the newer
            // text in place keeps the tab dirty against the recorded baselines below, so the next
            // save writes it.
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

    /// Bookkeeping after a successful Save-As: the tab ADOPTS the chosen file.
    ///
    /// `lastSavedDisk` is set deliberately (design §12 D3). The conservative-looking option —
    /// linking the tab but leaving the drift baseline nil — is the LESS safe one: the guard
    /// resolves `lastSavedDisk ?? sourceFile.content`, and a Save-As'd tab has no source
    /// file, so later saves to that path would run with NO drift protection and could
    /// silently overwrite an external edit. Setting it is what arms the guard.
    ///
    /// Adopting the path is also what gives a follow-up query something real to work with:
    /// model-generated content stops being a bare filename the moment it lands on disk.
    /// `wroteToDisk` is the BYTES that landed on disk, which differ from `savedBuffer`
    /// whenever `contentToApply` restored the destination's edge whitespace. It is the drift
    /// baseline, so it must be the bytes and not the editor buffer — seeding the guard with
    /// the buffer made the next save read its own restored newline as external drift.
    /// Defaults to `savedBuffer` for callers that write the buffer verbatim.
    ///
    /// ⚠️ `editedCode` is adopted ONLY when the editor is still showing `savedBuffer` — the
    /// same guard `saveTabToItsPath` carries, arrived at here for a WIDER window. The caller
    /// captures its buffer before `savePanel.begin` and the panel is MODELESS (see the
    /// stashed branch below, where a conversation switch mid-panel was field-observed), so
    /// every keystroke from Save-As invocation until the write completes reaches
    /// `updateCodeViewerDraft` and lands in `editedCode`. An unconditional
    /// `editedCode = savedBuffer` then DISCARDED them — and because `lastSavedBuffer` is set
    /// to the same value, `isDirty` went FALSE, so the dot cleared and `closeCodeViewerTab`
    /// stopped asking for confirmation: silent data loss with the warning suppressed. The
    /// bookkeeping below stays unconditional in every case — the bytes really are on disk and
    /// the tab really is linked to that path — so keeping the newer text leaves the tab
    /// correctly DIRTY against the recorded baselines, and the next ⌘S writes it there.
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
                // ⚠️ MATERIALISE the newer text; do not merely flag it. `effectiveCode` is
                // `editedCode ?? snippet.code`, so it also moves when the SNIPPET is replaced and
                // `editedCode` is left nil — which `openTab`'s origin branch and
                // `handleAgentWriteBegan`'s update branch both do while the MODELESS Save-As panel
                // is open. Flagging alone left `editedCode == nil` while `lastSavedBuffer` became
                // something else, and `isDirty` early-returns FALSE on nil — so the tab reported
                // CLEAN with a buffer that did not match its restore point, ⌘W closed it without
                // the confirmation this guard exists to preserve, and the log said "stays dirty".
                // Assigning restores the invariant `editedCode` documents on itself.
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
            // Report the state actually REACHED — `performApplyChanges` does the same rather than
            // asserting its happy path, and an earlier version of this line claimed "stays dirty"
            // on a path where it did not.
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
            // The save panel is MODELESS, so the sidebar stayed clickable and a conversation
            // switch stashed the tab mid-panel. Patching the stashed copy is what makes the
            // link survive the switch — this used to miss, log "closed while the save panel
            // was open" (false), and leave the restored tab unlinked and dirty so the next
            // ⌘S re-opened Save As.
            logger.info("[CodeViewer] Tab \(tabID.uuidString.prefix(8)) saved as \(url.path) (\(savedBuffer.count) chars) while stashed for conversation \(conversationID.uuidString.prefix(8)) — the STASHED copy was linked, so reopening that conversation shows it \(keptNewerDraft ? "DIRTY (the buffer moved during the save, and the newer text was kept)" : "clean") and ⌘S writes there.")
        }
    }

    /// Clears a `.rejected` live-write badge once the user's own save has put that content
    /// on disk — the orange "This write was not applied — the file on disk is unchanged"
    /// banner is false the moment it lands, and nothing else ever reset it.
    ///
    /// `.active` is deliberately left alone: an agent write still in flight is still in
    /// flight, whatever the user just saved.
    private static func clearRejectedLiveState(_ tab: inout CodeViewerTab, savedTo fileName: String) {
        guard tab.liveState == .rejected else { return }
        tab.liveState = nil
        logger.info("[CodeViewer] Cleared the 'not applied' badge on '\(fileName)' — the user's save wrote the rejected proposal to disk, so the banner's claim no longer holds.")
    }

    /// The URL a save must actually write to.
    ///
    /// Resolves symlinks so a save lands on the real file rather than replacing the link with
    /// a regular file. Shared by both save engines so they cannot diverge: `saveTabToItsPath`
    /// silently unlinked the file, while `atomicallyWrite`'s `replaceItemAt` failed outright
    /// with "the file doesn't exist" on the same input — two different wrong answers.
    nonisolated static func writeTarget(forPath path: String) -> URL {
        let raw = URL(fileURLWithPath: path)
        let resolved = raw.resolvingSymlinksInPath()
        if resolved.path != raw.path {
            logger.info("[CodeViewer] '\(raw.lastPathComponent)' resolves through a symlink — writing to \(resolved.path) so the link is preserved and the real file is updated.")
        }
        return resolved
    }

    /// True only for "the file isn't there", the one read failure a save may ignore.
    ///
    /// Everything else — undecodable bytes, permissions, an I/O error — means we could not read
    /// the file and therefore cannot compare against it, which must refuse the save. Note this
    /// does NOT assert the file exists: only that its absence was not established. (An earlier
    /// version of this comment claimed an unreachable mount lands here; a path on an unmounted
    /// volume actually yields `fileReadNoSuchFile`, so it is classified ABSENT and the save
    /// proceeds. That is a separate open question, not something this function decides.)
    nonisolated static func meansFileAbsent(_ error: CocoaError) -> Bool {
        error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    }

    /// A short, honest name for why a read failed — so a refusal log states the CLASSIFIED
    /// reason instead of asserting one.
    ///
    /// The previous fixed sentence read "The file EXISTS but is unreadable as UTF-8" on every
    /// non-absent error, including permission failures, I/O errors and non-`CocoaError` throws —
    /// none of which establish either half of it. That is the same defect shape CH6 was filed
    /// for ("the log asserted a fact the catch had not established"), reproduced by its own fix.
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

    /// Transaction-safe file write, off the main actor.
    ///
    /// Writes to a temp file in the same directory, reads it back to verify, then
    /// atomically replaces the original — so a crash or full disk mid-write can't
    /// corrupt the user's file (the original is only removed once the verified temp
    /// is in place). `nonisolated` + `Task.detached` keeps every blocking call off
    /// the main thread; security-scoped access is opened and balanced around the
    /// whole transaction.
    /// Internal rather than private so the temp-file lifecycle can be tested directly — the
    /// orphan only appears on failure paths that cannot be provoked through `performApplyChanges`
    /// without injecting a filesystem. Same reason `writeTarget` / `meansFileAbsent` are internal.
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

            // Same symlink rule as `saveTabToItsPath`. Here the old behaviour failed loudly
            // rather than silently — `replaceItemAt` throws "the file doesn't exist" against a
            // symlink — but a save that cannot target a linked file at all is still a defect.
            let target = Self.writeTarget(forPath: fileURL.path)
            let displayName = fileName.isEmpty ? target.lastPathComponent : fileName

            // Disk-drift guard: `baseline` is the file's content when it was attached —
            // the same content the on-screen diff was computed against. If the file on
            // disk no longer matches, it was edited since (e.g. in Xcode), and applying
            // would silently discard those edits. Refuse rather than destroy work.
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

            // EVERY exit path from here must remove the temp. Only the verify-mismatch branch
            // used to, so a throwing read-back or replace left a hidden `.devgentic_tmp_<uuid>`
            // holding the file's full proposed contents next to the user's file — invisible in
            // Finder, one more per retry, and picked up by `git status` / `git add .`.
            //
            // A no-op on success: `replaceItemAt` MOVES the temp into place, so nothing remains
            // at `tempURL`. The existence check is what keeps the success path silent.
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
    }

    func copyMessageContentToClipboard(message: ChatMessage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // [Q9] Prefer the selected agent variant so Copy matches what's on screen for a
        // regenerated response; falls back to `content` (nil currentAgentContent) — no change
        // for user/non-regenerated messages.
        if let content = (message.currentAgentContent ?? message.content).textContent {
            pasteboard.setString(content, forType: .string)
            logger.info("Copied message \(message.id.uuidString) content to clipboard.")
        }
    }
    
    func openMessageInCodeViewer(message: ChatMessage, selectedSnippet: CodeSnippet? = nil) {
        // Extract this message's blocks, each paired with the filename to title its tab.
        var blocks: [(snippet: CodeSnippet, fileName: String?)] = []

        // ⚠️ [CF-5] `displayedContent`, not `content` — the same reason [Q9] gave `Copy` above.
        // For a REGENERATED response the stream writes only the selected variant, leaving
        // `content` on the ORIGINAL text, so enumerating it here opened the previous variant's
        // code from a card whose bubble was showing the new one. It also has to match what
        // `ContentBlockView.codeBlockOrdinal` numbers, or the two paths stamp the same origin
        // key (message.id, ordinal) onto different code and a card open overwrites an inline
        // tab's content.
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
                        // Keep the name for the tab title even when it doesn't resolve to an
                        // attached file (no diff/apply, but still a useful label). The name may
                        // come from the injected marker OR from CodeFileNameInference (prose /
                        // info string / leading comment) — either way it only links when it
                        // exactly matches a file the user actually attached.
                        // NOT a warning: code the model GENERATED (the common case) never has
                        // a matching attachment. It reads as a failure in the log while the
                        // feature is working exactly as designed.
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

        // Same large-block filter as the renderer: offer the large blocks (the ones drawn as
        // cards), else all of them (the "Open in Editor" path on a small-block-only message).
        //
        // The index is captured BEFORE filtering: it is the tab's stable identity, and a
        // block that is still streaming can cross the isLarge threshold between two opens,
        // which would shift every filtered index after it.
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

    /// Store-backed second pass for filename→attachment linking: the loaded window missed
    /// (attaching message scrolled out of the page), so search the conversation's
    /// persisted user messages instead. Successful matches are stamped onto the open tabs
    /// IN PLACE — var-field mutation, never a new snippet, because a fresh snippet id
    /// would rebuild the editor under the user. The diff/apply buttons appear as each
    /// link lands. Awaitable so tests can drive it deterministically.
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
        // ⚠️ [CR55] AMBIGUITY FAILS CLOSED. This resolves by BARE NAME, and `FileSystemItem.id` is
        // the URL, so the attach path happily accepts `web/app/page.tsx` and `docs/app/page.tsx`
        // together — two `AttachedTextFile`s both named "page.tsx". Taking the first match then
        // stamps `sourceFileID` for the wrong file, `canSaveAndClose` flips true, and
        // `performApplyChanges` writes one file's content over the other's URL. The drift guard
        // cannot catch it: it compares that file's own baseline against its own disk, which match.
        // The tab header shows "page.tsx" either way, so nothing on screen reveals the swap.
        //
        // A missing badge is a cost the user can see and work around; a silent overwrite is not.
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

        // Code Viewer tabs hold source links (sourceMessageID/sourceFileID) that only resolve
        // against the loaded conversation's messages, so a DIFFERENT conversation makes them
        // stale — clear the viewer. But NOT on a same-conversation reload (e.g. the
        // user-messages filter routes through here), which would wipe the user's open tabs.
        //
        // The identity MUST come from `viewerOwningConversationID`, the same expression the
        // stash keys on. Reading it from `currentChatMessages` alone meant a caller that
        // pre-cleared the messages before triggering a load (welcome screen, interface-mode
        // switch, ⌘N from code/workflow mode) made this `nil != nil` — so the reset was
        // SKIPPED here, `loadedConversationID` was then nil'd below, and the identity was gone
        // by the time the NEXT load ran the reset for real: the stash could not resolve a key,
        // and every tab and unsaved draft was cleared. Returning to the SAME conversation lost
        // them too, since the tabs were already orphaned.
        if id != viewerOwningConversationID {
            resetCodeViewer()
        }

        guard let selectedID = id else {
            currentChatMessages = []
            loadedConversationID = nil
            return
        }

        logger.debug("Loading conversation \(selectedID.uuidString), merging with active streams.")

        // Publish the DESTINATION for the duration of the load. Between here and the
        // assignments at the bottom, `currentChatMessages` and `loadedConversationID` both
        // still describe the OUTGOING conversation, so anything that asks "which conversation
        // is this?" mid-load gets the wrong answer — see `destinationConversationID`.
        //
        // Cleared under the epoch check so a STALE load (a newer one started while we were
        // suspended) cannot erase the newer load's destination on its way out. `defer` so
        // cancellation and the early returns below are covered too.
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

            // ⚠️ PERSISTED ONLY. A row that came off disk keeps whatever status was last flushed,
            // and `.running` renders as a spinner with a ticking clock — always a lie after a
            // relaunch, since quit kills every task. Live streaming messages are excluded because
            // the observer is already maintaining them; `reconcile` also asks the registry before
            // touching anything, so a genuinely running task is left alone either way.
            let reconciled = BackgroundTaskObserver.reconciledMessages(persistedMessages)
            if reconciled.rows > 0 {
                logger.info("[BGTASK] Reconciled \(reconciled.rows) background-task row(s) that loaded as 'running'. CONSEQUENCE: they now show their real outcome, or 'ended when the app restarted' — instead of a spinner and an elapsed time counting up from whenever they started.")
                // ⚠️ SAVED, not just shown. A real outcome recovered from the registry exists only
                // while this process remembers the task — unsaved, the next relaunch turns a task
                // that exited 0 into "interrupted". Detached so the load does not wait on the write;
                // the corrected rows are no longer `running`, so this never repeats for them.
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
            self.loadedConversationID = selectedID
            // The corpus belongs to the previous conversation (or a stale snapshot of this
            // one); drop it so search re-fetches against what is actually loaded.
            self.invalidateSearchCorpus()

            // Bring back this conversation's Code Viewer session (tabs, drafts, layout).
            // No-op on same-conversation reloads — tabs weren't cleared, so the
            // tabs-empty guard inside skips the restore.
            restoreCodeViewerSession(for: selectedID)

            self.canLoadMorePages = persistedMessages.count >= initialPageSize
            self.hasReachedResidencyCap = false

            logger.info("Successfully loaded and merged \(persistedMessages.count) persisted and \(activeStreamingMessages.count) active messages.")
        } catch {
            logger.info("Conversation load for \(selectedID.uuidString) was cancelled.")
        }

        // Only the latest load gets to flip the loading flag off — prevents a
        // stale straggler from briefly clearing the spinner while a newer load
        // is still in flight.
        if myEpoch == loadEpoch {
            self.isInitiallyLoadingConversation = false
        }
    }


    /// Test seam: advances the load epoch exactly as `loadConversation` does at its top,
    /// without running a full load. Lets a test place a conversation switch INSIDE a store
    /// fetch deterministically — the interleaving `loadMoreMessages`' guard exists for, and
    /// one that is otherwise unreachable because the real switch is itself async.
    /// Not called from app code.
    func bumpLoadEpochForTesting() {
        loadEpoch &+= 1
    }

    func loadMoreMessages() async {
        guard !isLoadingPage, canLoadMorePages, let selectedID = currentChatMessages.first?.conversationId else {
            return
        }

        // Residency ceiling. `canLoadMorePages` deliberately stays TRUE — the store really
        // does have more, and the history resolver depends on that distinction to keep
        // consulting the store instead of treating this window as the whole conversation.
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

        // ⚠️ Claim the epoch BEFORE the fetch, exactly as `loadConversation` does. This await is
        // a real window — the sidebar stays clickable — and `loadConversation` REPLACES
        // `currentChatMessages` wholesale. Without the check below, a switch landing inside this
        // one fetch appended conversation A's older messages onto conversation B's rendered
        // array, so B's transcript showed A's turns. Every other store round-trip in this file
        // already re-validates after its await (`loadConversation` by epoch, `prepareSearchCorpus`
        // by conversation, `performApplyChanges` by residence); this was the one that did not.
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

            trimMarkdownCachesOutsideWindow()
        }

        isLoadingPage = false
    }

    /// Drops the parsed-markdown cache for messages far from BOTH ends of the loaded window.
    ///
    /// The user is realistically looking at one end or the other: the newest messages
    /// (normal use) or the oldest just-loaded page (mid scroll-back). Everything between is
    /// retained AST nobody is rendering. Purely derived state — `getOrCreateMarkdownBlocks`
    /// rebuilds it lazily — so this changes memory, never behaviour.
    ///
    /// Streaming messages are skipped: their cache is owned by an incremental parser whose
    /// state must not be dropped mid-stream.
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
    ///
    /// Holds PROJECTIONS, not messages. It used to cache up to 1000 fully decoded
    /// `ChatMessage`s — including every attached image's full `binaryData` — released only
    /// when the conversation changed, so one ⌘F in a long image-heavy conversation pinned tens
    /// of MB for the rest of the session.
    @ObservationIgnored private var searchCorpusCache: [SearchDocument] = []

    /// Resident messages are projected at READ time so in-place mutations (a stream
    /// finalizing, a variant switch) are picked up — but re-decomposing the whole resident
    /// window on every keystroke is wasteful, so the result is memoized on a hash of the
    /// displayed text. Text changes → hash changes → automatic invalidation.
    @ObservationIgnored private var residentUnitsCache: [UUID: (textHash: Int, wasStreaming: Bool, units: [SearchUnit])] = [:]
    @ObservationIgnored private var searchCorpusConversationID: UUID?

    /// How far back search reaches. Larger than `maxResidentMessages`: finding a match is
    /// cheap (text scan), holding a message resident is not.
    @ObservationIgnored static let searchCorpusLimit = 1_000

    /// Everything search should look at: the cached store snapshot with the LIVE resident
    /// messages merged over it.
    ///
    /// Searching `currentChatMessages` alone meant the pagination window decided what was
    /// findable — open a long conversation and search for something 200 messages back and
    /// it reported "no results", which reads as "not there" rather than "not loaded".
    /// Merging resident over stored keeps streaming and just-sent messages fresh (they are
    /// not in the store yet) while still reaching everything older.
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

    /// [vm-3] THE way the chat view (re)runs search: ONE corpus snapshot feeds both the match
    /// list and the stored unreachable count, so the two can never disagree and the search bar
    /// never touches the corpus itself. The three call sites (membership change, debounced
    /// query, bar opened) all come through here; a fourth that calls `performSearch` directly
    /// would leave the count at its reset value of 0, i.e. under-report, never stall.
    func runSearch(_ searchViewModel: ChatSearchViewModel) {
        let corpus = searchCorpus
        searchViewModel.performSearch(in: corpus)
        searchViewModel.unreachableMatchCount = unreachableMatchCount(in: searchViewModel.matches, corpus: corpus)
    }

    /// A resident message's projection, memoized on its displayed text.
    private func projectedResidentDocument(_ message: ChatMessage) -> SearchDocument {
        let hash = message.displayedContent.textContent?.hashValue ?? 0
        // ⚠️ [vm-5] The streaming flag is part of the KEY, not a gate on serving.
        //
        // A streaming message is decomposed through `StreamingMarkdownParser`
        // (`ChatSearchDecomposition.units(for:)`), whose positional `block-N` ids can differ
        // from the authoritative `parseMarkdown` that `getOrCreateMarkdownBlocks` runs once the
        // message settles. The TEXT does not change at that moment —
        // `resolveFinalizedContent` returns the streamed content verbatim — so the hash alone
        // cannot notice the settle, and an entry written during the stream was served forever
        // after, pointing search at block ids the renderer no longer has.
        //
        // ⚠️ Refusing to SERVE while streaming does not fix it: the last write before the settle
        // is still a streaming projection, and the first settled read then serves it because the
        // hash matches. Only a key that includes the flag forces the recompute. (The weaker
        // spelling was tried first and the test below caught it.) Keying rather than gating also
        // keeps the memo doing its job mid-stream, where repeated reads at one flush are common.
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

    /// Loads the store snapshot once per conversation, when search opens. Deliberately NOT
    /// per keystroke: the query is debounced at 150ms and each fetch decodes every
    /// message's timeline blob, so re-fetching per keystroke would be far more expensive
    /// than the scan it feeds.
    ///
    /// ⚠️ [CF-38] Publishes NOTHING once its task is cancelled. The caller
    /// (`ChatHistoryView`'s `.task(id: isSearchActive)`) is cancelled both when the user
    /// closes search and when the chat view is torn down, and the release that accompanies
    /// either one runs BEFORE this continuation resumes — so publishing here regardless put
    /// the whole projection back after it had been freed, with (in the teardown case) no
    /// chat view left to ever release it again.
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
    ///
    /// Previously it lived until the conversation changed, so a single ⌘F kept the whole
    /// projection resident for the rest of the session.
    func releaseSearchCorpus() {
        let freed = searchCorpusCache.count
        let memoized = residentUnitsCache.count
        guard freed > 0 || memoized > 0 else { return }
        invalidateSearchCorpus()
        logger.info("[SEARCH] Corpus released — \(freed) stored document(s) and \(memoized) memoized resident projection(s) freed; the next search re-fetches.")
    }

    /// Where `messageID` sits in the search corpus (0 = newest), or nil when the corpus does
    /// not hold it. The corpus is NEWEST-FIRST — the store snapshot and the resident window
    /// are both served in descending timestamp order and merged on that key — so this index
    /// is also how many resident slots the message needs in front of it before paging could
    /// ever reach it.
    func searchCorpusIndex(of messageID: UUID) -> Int? {
        searchCorpus.firstIndex { $0.id == messageID }
    }

    /// Whether a search match can be brought on screen at all, decided from its corpus
    /// position WITHOUT paging: scroll-back stops at `maxResidentMessages`, so a match with
    /// that many (or more) newer messages in front of it can never be made resident, and
    /// every page fetched on its behalf is a main-actor decode burst that ends in "not
    /// scrollable" (CF-35). Resident messages are trivially reachable; a message the corpus
    /// no longer holds (the conversation changed, or the corpus was released) is treated as
    /// unreachable rather than hunted for through the store.
    func isMatchReachable(messageID: UUID) -> Bool {
        isMatchReachable(messageID: messageID, corpusIndex: searchCorpusIndex(of: messageID))
    }

    /// [views/bm-5] The same answer from a position the caller already has.
    ///
    /// `searchCorpusIndex` reads `searchCorpus`, which is COMPUTED — a 1,000-entry dictionary
    /// rebuild, a re-projection of every resident message and a sort, per access. The scroll
    /// path asked for the same position twice in a row (reachable? then page to it), so a
    /// single Next press on a non-resident match paid for two rebuilds that could only ever
    /// return the same number.
    func isMatchReachable(messageID: UUID, corpusIndex: Int?) -> Bool {
        if currentChatMessages.contains(where: { $0.id == messageID }) { return true }
        guard let corpusIndex else { return false }
        return corpusIndex < Self.maxResidentMessages
    }

    /// Pages older messages in until `messageID` is rendered, so a search hit outside the
    /// scroll window can actually be jumped to. Returns false when it can't be reached —
    /// the caller should say so rather than scroll nowhere.
    ///
    /// An unreachable target is refused BEFORE the first page (see `isMatchReachable`): the
    /// old loop only learned about the cap by hitting it, so the first search in a long
    /// conversation paid the whole walk — up to 28 synchronous store fetches decoding ~280
    /// messages with their timelines and image bytes — and then scrolled nowhere. For a
    /// reachable target the loop yields between pages so the main actor keeps servicing
    /// input while the rows come in.
    @discardableResult
    func ensureMessageIsResident(_ messageID: UUID) async -> Bool {
        await ensureMessageIsResident(messageID, corpusIndex: searchCorpusIndex(of: messageID))
    }

    /// [views/bm-5] As above, with the corpus position supplied by a caller that just computed
    /// it. Semantics are unchanged: this value was already resolved ONCE up front and never
    /// refreshed across the paging loop, so handing it in freezes nothing that was not already
    /// frozen — and the `loadEpoch` check inside the loop, not this index, is what stops an
    /// orphaned walk paging a newly-opened conversation to its cap.
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

        // Bounded by the residency cap; the extra guard is belt-and-braces against a store
        // that keeps returning pages.
        //
        // ⚠️ Deliberately NOT bounded per attempt. A smaller per-keypress budget was tried and
        // reverted: it made a deep-but-reachable match need several Next presses to arrive, which
        // trades a performance cost for a correctness one — "Next" that does not go to the next
        // match is a worse defect than a slow one. The two mitigations that DO apply are the
        // unreachable refusal above (which removes the entirely-wasted walk, the actual CF-35
        // complaint) and the `Task.yield()` below, which turns a freeze into a progressive load.
        // The residual cost is per-page main-actor decoding, whose root cause is that this app has
        // no background `ModelContext` — tracked as CH62 in `Chat_Production_Readiness.md`, and
        // not fixable here.
        var pagesLoaded = 0
        let maxPages = (Self.maxResidentMessages / subsequentPageSize) + 2
        // ⚠️ The walk is abandoned the moment ANY load starts, because the `Task.yield()` below
        // is a real suspension point and the conversation switch behind it is debounced —
        // `loadConversation` can complete between two pages. Nothing in the loop used to notice:
        // `loadMoreMessages` re-derives its target from `currentChatMessages` on every call, so
        // the orphaned walk carried on paging the NEWLY OPENED conversation up to the 300-message
        // residency cap, on the main actor. The user saw the scroll jump, the UI jank, and a
        // conversation they never scrolled back in reporting that older messages are not loaded —
        // with `canLoadMorePages`/`hasReachedResidencyCap` then disabling its own scroll-back.
        // The target message from the old conversation could never appear, so the early exit
        // never fired either.
        //
        // Keyed on `loadEpoch` rather than on the conversation id so a SAME-conversation reload
        // also abandons it: that reload invalidates the corpus this walk's `corpusIndex` came
        // from, making the remaining pages meaningless work toward a position that no longer means
        // anything. This is the same epoch `loadMoreMessages` and `loadConversation` check.
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

    /// Matches whose message can't be brought on screen. Surfaced so the count the user
    /// sees is honest about what navigation can actually reach (register CF-37).
    ///
    /// ⚠️ Routed through `isMatchReachable`, NOT "not currently resident". The earlier form
    /// subtracted `currentChatMessages` (the ~20-300 messages actually rendered right now)
    /// from the full match set — that overcounts by every match that is reachable by PAGING
    /// but has not been paged in yet, which is the common case right after a search opens.
    /// `isMatchReachable` is the same corpus-position predicate `ensureMessageIsResident`
    /// pages against, so this count and what Next/Previous can actually reach cannot drift
    /// apart the way the two already had (CF-37 was filed because they had).
    /// ⚠️ Counts MATCHES, not distinct messages, because the badge prints it beside a match
    /// count ("3 of 120 · 40 older not shown"). Counting messages there mixed two units and
    /// under-reported every message holding more than one hit.
    ///
    /// ⚠️ Takes ONE corpus snapshot and indexes it, instead of calling `isMatchReachable` per
    /// match: that reads `searchCorpus`, which is COMPUTED — it rebuilds a 1,000-entry
    /// dictionary and sorts it on every access. Per match, from a `body` that re-runs on every
    /// keystroke, that was a main-actor stall proportional to matches × corpus.
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
