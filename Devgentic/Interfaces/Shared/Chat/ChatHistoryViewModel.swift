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
    var codeViewerTabs: [CodeViewerTab] = []
    var activeCodeViewerTabID: UUID? = nil
    /// Whether the panel is on screen. The panel shows when this is `true` AND there is at
    /// least one tab; when `false` with tabs open, the UI shows the floating reopen button.
    var isCodeViewerVisible: Bool = false
    /// How the panel occupies the window (overlay / split / full — see
    /// `CodeViewerPresentation`). A MODE rather than a stored width so the panel keeps
    /// tracking the window through resizes — a "full" captured as points would stop being
    /// full the moment the window grew. Survives minimize/reopen; cleared with the tabs.
    var codeViewerPresentation: CodeViewerPresentation = .overlay
    /// Where the full-width toggle returns to: entering `.full` from `.split` and toggling
    /// back should land in `.split`, not silently forget it.
    @ObservationIgnored private var lastNonFullPresentation: CodeViewerPresentation = .overlay

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
    var isCodeViewerPanelPresented: Bool { isCodeViewerVisible && !codeViewerTabs.isEmpty }
    /// The floating reopen button shows when the panel was minimized but tabs remain.
    var isCodeViewerMinimized: Bool { !isCodeViewerVisible && !codeViewerTabs.isEmpty }

    /// Diff state of the ACTIVE tab, as read-only proxies. Per-tab diff is the source of
    /// truth (see `CodeViewerTab`); views and tests read the "current" status through these
    /// so a single shared flag can't leak one tab's diff onto another.

    // MARK: - State Properties for Chat History
    // OPTIMIZATION: Stores messages in Descending order (Newest -> Oldest).
    // This allows O(1) appending of history pages instead of O(n) insertion at index 0.
    var currentChatMessages: [ChatMessage] = []

    /// The history the NEXT request would actually carry, OLDEST-FIRST — resolved exactly the
    /// way `MessagingCoordinator` resolves it, through the same `BackendHistoryResolver`.
    ///
    /// The context gauge must size the REQUEST, not this view model's `currentChatMessages`,
    /// which is a pagination window (20 on open, +10 per scroll, cap 300). Sizing from the
    /// window made the ring climb as the user scrolled while the prompt never changed, and
    /// made a freshly-opened long conversation under-read its own history by up to 15×.
    func resolveContextHistory(for conversationID: UUID) async -> [ChatMessage] {
        let resolved = await BackendHistoryResolver.resolve(
            conversationID: conversationID,
            inMemory: currentChatMessages,
            persistence: persistenceService
        )
        logger.debug("[CTXGAUGE] Resolved \(resolved.history.count) message(s) for sizing (stored \(resolved.storedCount), resident window \(currentChatMessages.count))\(resolved.capHit ? ", CAP HIT" : "") — conv \(conversationID.uuidString.prefix(8))")
        return resolved.history
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

    // Tracks the in-flight task spawned by `toggleUserMessagesFilter` so rapid
    // toggles cancel the prior reload instead of racing it.
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    var isSending: Bool = false
    var isUserMessagesOnlyFilterActive: Bool = false

    /// Aggregated token usage across all messages in the current conversation.
    var conversationTokenUsage: TokenUsage? {
        let usages = currentChatMessages.compactMap(\.tokenUsage)
        guard !usages.isEmpty else { return nil }
        return usages.dropFirst().reduce(into: usages[0]) { $0.accumulate($1) }
    }

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

        // Pre-read the on-disk state so the pending tab shows a DIFF while the write is
        // awaiting approval — reviewing the change in the full viewer beats the banner's
        // mini-diff. Size-capped like every snapshot.
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
                guard let self, let pre,
                      let index = self.codeViewerTabs.firstIndex(where: { $0.filePath == path }),
                      self.codeViewerTabs[index].liveState == .active,
                      !self.codeViewerTabs[index].isDirty else { return }
            }
        }
    }

    /// The write finished: settle the tab (success) or mark it rejected (denied/failed —
    /// the tab shows a proposal that never reached disk). The executor's authoritative
    /// pre-write snapshot replaces the UI's best-effort pre-read.
    func handleAgentWriteCompleted(_ payload: AgentLiveWriteEvent.Completed) {
        // MUST be the same expression `handleAgentWriteBegan` admits on. It was left reading
        // `currentChatMessages.first?.conversationId`, which names the OUTGOING conversation for
        // the whole duration of a switch — so a write admitted mid-load by the began-guard could
        // never be settled here, and returned SILENTLY. The tab then keeps `liveState == .active`
        // forever: the orange "Agent is writing this file" banner stays up, `hasLiveAgentTabs`
        // keeps the pill pulsing, and a DENIED write is never flipped to `.rejected`, so the user
        // is told a file is being written when the proposal never reached disk.
        guard payload.conversationID == destinationConversationID else {
            logger.warning("[CodeViewer] Live-write completion for '\(payload.fileName)' DROPPED — it belongs to conversation \(payload.conversationID.uuidString.prefix(8)) but \(self.destinationConversationID?.uuidString.prefix(8) ?? "none") is \(self.loadingConversationID == nil ? "loaded" : "loading"). CONSEQUENCE: if that conversation holds a live tab for this file it stays marked as writing and is never settled or marked rejected.")
            return
        }
        guard let index = codeViewerTabs.firstIndex(where: { $0.filePath == payload.path && $0.liveState == .active }) else {
            logger.debug("[CodeViewer] Live-write completion for '\(payload.fileName)' has no active live tab — settled or skipped earlier.")
            return
        }

        if payload.isSuccess {
            codeViewerTabs[index].liveState = nil
            logger.info("[CodeViewer] Live tab '\(payload.fileName)' settled — write landed.")
        } else {
            codeViewerTabs[index].liveState = .rejected
            logger.info("[CodeViewer] Live tab '\(payload.fileName)' marked rejected — the write was denied or failed; its content never reached disk.")
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
            if !codeViewerTabs[index].isDirty {
                codeViewerTabs[index].snippet = snippet
            } else {
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
    func updateCodeViewerDraft(tabID: UUID, content: String) {
        guard let index = codeViewerTabs.firstIndex(where: { $0.id == tabID }) else { return }
        codeViewerTabs[index].editedCode = content
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

        if codeViewerTabs.isEmpty {
            activeCodeViewerTabID = nil
            isCodeViewerVisible = false
            codeViewerPresentation = .overlay
            lastNonFullPresentation = .overlay
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
            codeViewerTabs.removeAll()
            activeCodeViewerTabID = nil
            isCodeViewerVisible = false
            codeViewerPresentation = .overlay
            lastNonFullPresentation = .overlay
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

    /// Toggles the EXPERIMENTAL side-by-side split with the chat. From full-width it goes
    /// straight to split (the user asked for split — routing through overlay first would
    /// just add a flicker).
    func toggleCodeViewerSplit() {
        withAnimation(.easeInOut(duration: 0.25)) {
            codeViewerPresentation = (codeViewerPresentation == .split) ? .overlay : .split
            lastNonFullPresentation = codeViewerPresentation
        }
        logger.info("[CodeViewer] Presentation → \(self.codeViewerPresentation.rawValue).")
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

    // MARK: - Session persistence (tabs survive conversation switches and relaunches)

    /// Cap on persisted tabs — a runaway accumulation guard, not a practical limit.
    private static let persistedTabLimit = 20

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
    private var viewerOwningConversationID: UUID? {
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
    private var destinationConversationID: UUID? {
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
        codeViewerPresentation = .overlay
        lastNonFullPresentation = .overlay
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
    /// file's leading blank line or indentation, and collapsed multiple trailing blank lines
    /// to one. The drift guard could not catch it either: it compares the two sides trimmed,
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
        if !lead.isEmpty, lead.count != baseline.count, !out.hasPrefix(lead) {
            out = lead + out
        }
        if baseline.hasSuffix("\n"), !out.hasSuffix("\n") { out += "\n" }
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
                // Re-resolve the tab AFTER the await — it may have been closed while the
                // write was in flight (tab identity is content-based and we no longer
                // mutate `snippet`, so the lookup is stable when the tab still exists).
                if let index = self.tabIndex(for: snippet) {
                    // The bytes ARE on disk, so the saved-state bookkeeping always advances:
                    // `lastSavedDisk` is the drift baseline for the next save, and
                    // `lastSavedBuffer` records which buffer produced it.
                    self.codeViewerTabs[index].lastSavedBuffer = buffer
                    self.codeViewerTabs[index].lastSavedDisk = newContent

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
                    let live = self.codeViewerTabs[index].effectiveCode
                    if live == buffer {
                        self.codeViewerTabs[index].editedCode = buffer
                    } else {
                        // Report the state REACHED, not the state intended. After AD1 the tab is
                        // dirty in the ordinary case (the editor's write-through keeps
                        // `editedCode`), but `handleAgentWriteBegan` can clear it mid-write when
                        // an agent rewrites the same file — and then the tab is clean and holds
                        // the agent's content, not "the newer text". Asserting the happy path
                        // here is the same shape as the comments this cluster keeps correcting.
                        let stillDirty = self.codeViewerTabs[index].isDirty
                        logger.info("[CodeViewer] Saved \(buffer.count) chars of '\(fileName)', but the tab's buffer moved to \(live.count) chars during the write — kept the newer text; tab is now \(stillDirty ? "DIRTY (the next save writes it)" : "CLEAN (its buffer was reset mid-write, e.g. by an agent rewrite)").")
                    }
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
        var onDiskContent: String? = nil
        do {
            let onDisk = try String(contentsOf: url, encoding: .utf8)
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
        } catch let error as CocoaError where Self.meansFileAbsent(error) {
            // Missing file is fine — a Save-As target may legitimately not exist yet.
            logger.info("[CodeViewer] No existing file at \(url.path) to drift-check; treating the save as a create.")
        } catch {
            // UNREADABLE IS NOT ABSENT. `String(contentsOf:encoding:.utf8)` also throws for a
            // non-UTF-8 document (Latin-1 source, a stray high byte) and for a permissions or
            // unreachable-mount failure. Those used to land in the branch above, which skipped
            // the drift guard entirely and then overwrote the file — discarding whatever was
            // on disk — while logging "No existing file", a claim the catch never established.
            logger.error("[CodeViewer] Save refused for \(url.lastPathComponent) — its current contents could not be read to drift-check against: \(Self.readFailureReason(error)). Its absence was NOT established, so overwriting could discard work; nothing was written.")
            codeApplyError = CodeApplyError.writeFailed(
                fileName: url.lastPathComponent,
                underlying: String(localized: "its current contents could not be read to compare against (\(error.localizedDescription))")
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
            try content.write(to: url, atomically: true, encoding: .utf8)
            guard let i = codeViewerTabs.firstIndex(where: { $0.id == tabID }) else { return }
            codeViewerTabs[i].editedCode = buffer
            codeViewerTabs[i].lastSavedBuffer = buffer
            codeViewerTabs[i].lastSavedDisk = content
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
    func markCodeViewerTabSavedAs(tabID: UUID, savedBuffer: String, savedTo url: URL, wroteToDisk: String? = nil) {
        guard let index = codeViewerTabs.firstIndex(where: { $0.id == tabID }) else {
            logger.warning("[CodeViewer] Save-As bookkeeping skipped — tab \(tabID.uuidString.prefix(8)) closed while the save panel was open; the file WAS written to \(url.path).")
            return
        }
        codeViewerTabs[index].editedCode = savedBuffer
        codeViewerTabs[index].filePath = url.path
        codeViewerTabs[index].fileName = url.lastPathComponent
        codeViewerTabs[index].lastSavedDisk = wroteToDisk ?? savedBuffer
        codeViewerTabs[index].lastSavedBuffer = savedBuffer
        logger.info("[CodeViewer] Tab \(tabID.uuidString.prefix(8)) saved as \(url.path) (\(savedBuffer.count) chars) — the tab is now linked to that file and ⌘S writes there.")
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

        switch message.content {
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
        for message in currentChatMessages {
            if message.sender == .user {
                if let files = message.attachedTextFiles, files.contains(where: { $0.name == fileName }) {
                    return message
                }
            }
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

            if isUserMessagesOnlyFilterActive {
                applyUserMessagesFilter()
            }
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

        // Fetches the next page of older messages, sorted newest-to-oldest.
        let olderMessages = await persistenceService.fetchMessages(for: selectedID, offset: offset, limit: subsequentPageSize)

        if olderMessages.isEmpty {
            canLoadMorePages = false
        } else {
            // OPTIMIZATION: Append to the end of the array (Newest...Oldest -> Append Older).
            // Since we are storing Descending, older messages go to the end (Index N).
            self.currentChatMessages.append(contentsOf: olderMessages)

            if isUserMessagesOnlyFilterActive {
                applyUserMessagesFilter()
            }
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
    @ObservationIgnored private var residentUnitsCache: [UUID: (textHash: Int, units: [SearchUnit])] = [:]
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

    /// A resident message's projection, memoized on its displayed text.
    private func projectedResidentDocument(_ message: ChatMessage) -> SearchDocument {
        let hash = message.displayedContent.textContent?.hashValue ?? 0
        if let cached = residentUnitsCache[message.id], cached.textHash == hash {
            return SearchDocument(id: message.id, timestamp: message.timestamp, units: cached.units)
        }
        let units = ChatSearchDecomposition.units(for: message)
        residentUnitsCache[message.id] = (hash, units)
        return SearchDocument(id: message.id, timestamp: message.timestamp, units: units)
    }

    /// Loads the store snapshot once per conversation, when search opens. Deliberately NOT
    /// per keystroke: the query is debounced at 150ms and each fetch decodes every
    /// message's timeline blob, so re-fetching per keystroke would be far more expensive
    /// than the scan it feeds.
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

    /// Pages older messages in until `messageID` is rendered, so a search hit outside the
    /// scroll window can actually be jumped to. Returns false when it can't be reached —
    /// the caller should say so rather than scroll nowhere.
    @discardableResult
    func ensureMessageIsResident(_ messageID: UUID) async -> Bool {
        if currentChatMessages.contains(where: { $0.id == messageID }) { return true }

        // Bounded by the residency cap; the extra guard is belt-and-braces against a store
        // that keeps returning pages.
        var pagesLoaded = 0
        let maxPages = (Self.maxResidentMessages / subsequentPageSize) + 2
        while canLoadMorePages, !hasReachedResidencyCap, pagesLoaded < maxPages {
            let countBefore = currentChatMessages.count
            await loadMoreMessages()
            pagesLoaded += 1
            if currentChatMessages.contains(where: { $0.id == messageID }) {
                logger.info("[SEARCH] Paged in \(pagesLoaded) page(s) to reach match \(messageID.uuidString.prefix(8)).")
                return true
            }
            if currentChatMessages.count == countBefore { break }   // no progress
        }

        logger.info("[SEARCH] Match \(messageID.uuidString.prefix(8)) is beyond the residency cap (\(Self.maxResidentMessages)) — found but not scrollable.")
        return false
    }

    /// Matches whose message can't be brought on screen. Surfaced so the count the user
    /// sees is honest about what navigation can actually reach.
    func unreachableMatchCount(in matches: [SearchMatch]) -> Int {
        guard hasReachedResidencyCap else { return 0 }
        let resident = Set(currentChatMessages.map(\.id))
        return Set(matches.map(\.messageID)).subtracting(resident).count
    }

    func toggleUserMessagesFilter() {
        isUserMessagesOnlyFilterActive.toggle()
        filterTask?.cancel()
        filterTask = Task {
            await loadConversation(id: currentChatMessages.first?.conversationId)
        }
    }
    
    private func applyUserMessagesFilter() {
        if isUserMessagesOnlyFilterActive {
            currentChatMessages = currentChatMessages.filter { $0.sender == .user }
        }
    }
    
    func resetSendingState() async {
        self.isSending = false
        logger.info("✅ [Request Finished] Sending state has been reset.")
    }
}
