// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QuickAccessSessionViewModel.swift
//  Devgentic
//
//  [QA revival P1a] Replaces the dead OllamaConnect stub (old QuickAccessViewModel).
//  Routes the floating panel through the app's REAL streaming stack: it owns a
//  panel-scoped ChatHistoryViewModel bound to the SHARED ActiveStreamManager (so live
//  streams merge but the message list stays panel-local), a panel-local
//  BackendConfiguration (so the panel's profile choice never moves the main window), and
//  mirrors MessagingCoordinator.submitRemoteMessage for the send path.
//

import SwiftUI
import SwiftData
import os

@Observable @MainActor
final class QuickAccessSessionViewModel {

    // MARK: - Reused shared UI state

    /// The panel's own transcript VM — a SECOND ChatHistoryViewModel instance bound to the
    /// SHARED ActiveStreamManager, so live streams merge in but the message list is
    /// panel-local and never touches the main window's currentChatMessages.
    let chatHistoryViewModel: ChatHistoryViewModel

    /// Panel-local search VM. Cheap; the shared bubble views require it in the environment.
    let searchViewModel = ChatSearchViewModel()

    /// Panel-local profile selection — deliberately separate from the main window's
    /// BackendConfiguration so choosing a profile in the panel doesn't move the main UI.
    let backendConfiguration = BackendConfiguration()

    // MARK: - Injected graph (all reached through the one shared MainApplicationViewModel)

    @ObservationIgnored private weak var mainAppViewModel: MainApplicationViewModel?

    /// ⚠️ The SEAM, not the concrete manager. The panel starts a run and cancels the one it
    /// started — exactly the two members of `MessageStreamStarting` — so it depends on that and
    /// nothing wider.
    ///
    /// ⚠️ WHAT THAT BUYS HERE, precisely: a COMPILE-TIME narrowing. It does not, on this surface,
    /// let a test observe the hand-off — the init below takes a `MainApplicationViewModel` and
    /// reads the manager off it, deliberately (see the note there), so no double can be
    /// substituted. `SchedulerCoordinator` gets both benefits because its manager is injected;
    /// this one gets the narrowing only, until `mainAppViewModel` itself is narrowed. An earlier
    /// version of this comment claimed the observability benefit and was contradicted 90 lines
    /// below by the init that makes it impossible.
    @ObservationIgnored private let activeStreamManager: any MessageStreamStarting

    /// ⚠️ The PROTOCOL, not `ChatPersistenceStore`. Every comparable type already takes it
    /// (`ActiveStreamManager`, `ChatHistoryViewModel`, `ConversationSwitchCoordinator`,
    /// `MessagingCoordinator`, `SchedulerCoordinator`); the panel was the last holdout, and a
    /// parameter typed as the concrete class accepts only the real SwiftData store — so any test
    /// that constructed this view model wrote to a real container. The one use that pinned it,
    /// a `FetchDescriptor` over `modelContainer.mainContext`, now lives on the store itself as
    /// `recentConversations(limit:)`.
    @ObservationIgnored private let persistence: ChatPersistenceProtocol
    @ObservationIgnored private let logger = DGLogger(category: "QuickAccessSessionViewModel")

    // MARK: - Session state

    private(set) var conversationID: UUID?

    /// Non-nil while a panel-originated stream is in flight (drives the Send/Stop toggle).
    /// Deliberately panel-local — we do NOT touch the main window's streamingMessageID slot,
    /// which would clobber a concurrent main-window stream.
    private(set) var streamingMessageID: UUID?
    /// [C1] The conversation the in-flight stream belongs to. stop() drains THIS conversation's
    /// HITL suspension — not whichever conversation the panel currently shows (the user may have
    /// switched to another via the recents menu while the stream was still running).
    private(set) var streamingConversationID: UUID?
    /// [M5] Synchronous re-entry guard for the async gap between accepting a send and the stream
    /// actually starting. `streamingMessageID` is only known after `startMessageStream`, which
    /// runs several `await`s deep inside `send()`; without a flag flipped *synchronously* at
    /// accept time, a second submit during that gap would pass the `streamingMessageID == nil`
    /// check and start a duplicate stream (two user messages, two streams) on one conversation.
    private(set) var isPreparingSend = false
    var isSending: Bool { streamingMessageID != nil || isPreparingSend }

    /// [C3] The in-flight transcript load (prepareSession / openConversation). `send()` awaits it
    /// before building its turn.
    ///
    /// ⚠️ NOT for history any more. This said the await stops a fast first send from "shipping
    /// empty history"; the panel no longer assembles history at all — `ActiveStreamManager`
    /// derives it from the STORE, so a half-loaded transcript cannot shrink what the model sees.
    /// The await is still load-bearing for two other reasons, both verified: `openConversation`
    /// sets `conversationID` inside this task, so a send that overtook it would file the turn
    /// against a conversation the panel has not adopted; and the load assigns
    /// `currentChatMessages`, so one landing after the panel inserts its user row would wipe that
    /// row out of the visible transcript.
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// [C10] Observes external SwiftData writes so the panel transcript refreshes when another
    /// surface (main window / ChatOps / scheduler) appends to the panel's conversation.
    @ObservationIgnored private var didSaveObserver: NSObjectProtocol?
    @ObservationIgnored private var externalRefreshTask: Task<Void, Never>?
    /// [L7] When the last external-refresh reload ran — floors the reload rate so a stream of
    /// unrelated app-wide saves (e.g. a main-window run persisting tokens while the panel sits
    /// open on a different, idle conversation) can't reload on every single save.
    @ObservationIgnored private var lastExternalReload: Date = .distantPast

    // MARK: - Init

    /// Profile types a chat-style quick-entry panel may use. Deliberately excludes
    /// `.workflow` (a DAG, not a chat), `.code` (ephemeral, never in the store), and
    /// `.imageGen` (image-output UX). This is why the panel never "runs a workflow".
    static let allowedProfileTypes: Set<ProfileType> = [.bot, .agent]

    /// The panel's user turn: the message that is persisted, displayed AND handed to the send
    /// path — one object, so they cannot diverge.
    ///
    /// ⚠️ The panel sends NO `promptOverride`. Unlike Orb it does not decorate the query, so
    /// the model's text and the displayed text are the same string — and the duplicate-query strip
    /// keys on this message's ID either way. The absence is the contract: if a future change ever
    /// gives the panel its own prompt decoration, it must travel as `promptOverride` rather than by
    /// mutating this message, or the displayed row and the model's copy drift apart. That drift is
    /// exactly what made every Orb voice turn arrive as an orphan.
    ///
    /// ⚠️ It also builds NO HISTORY. The panel used to hand over a reversed slice of
    /// `currentChatMessages` — its PAGINATION WINDOW, a hard 20 rows that never grew because
    /// QuickAccess never calls `loadMoreMessages` — as model history. `ActiveStreamManager` derives
    /// history now, so the panel and the main window are given the same conversation.
    ///
    /// `static` + internal so the contract is testable without a `MainApplicationViewModel`
    /// (constructing one runs `ChatOpsCoordinator.bootstrap()`, which opens real Telegram/Discord/
    /// Slack connections). ⚠️ The store is no longer a blocker — `persistence` was widened to
    /// `ChatPersistenceProtocol` on 2026-09-07 — but the view model is, so the contract still lives
    /// here rather than being driven through `submitQuery`. Pinned by `QuickAccessDispatchTests`.
    static func panelTurn(
        query: String,
        conversationID: UUID,
        files: [FileSystemItem],
        fileProcessorService: FileProcessorService
    ) async -> ChatMessage {
        let userMessage = await MessagingCoordinator.makeUserMessage(
            conversationID: conversationID,
            query: query,
            files: files,
            fileProcessorService: fileProcessorService
        )
        userMessage.messageSource = .quickAccess   // [Q2] attribute panel traffic
        return userMessage
    }

    init(mainAppViewModel: MainApplicationViewModel,
         persistence: ChatPersistenceProtocol = ChatPersistenceStore.shared) {
        self.mainAppViewModel = mainAppViewModel
        // ⚠️ NOT injectable, deliberately — an `activeStreamManager:` parameter was added here on
        // 2026-09-07 and removed the same day. It would have produced a CHIMERA: the panel's
        // send/stop would reach the injected spy while `chatHistoryViewModel` below kept the real
        // manager, because `ChatHistoryViewModel.init` requires the CONCRETE type (it needs
        // `activeStreams` and `incompleteTurnIDs`, neither of which is on `MessageStreamStarting`
        // — that protocol is scoped to owning ONE run). A spy would report a stream the panel's
        // own transcript never reflects. Injecting it needs `ChatHistoryViewModel` widened first;
        // until then this object holds exactly one manager.
        self.activeStreamManager = mainAppViewModel.activeStreamManager
        self.persistence = persistence
        self.chatHistoryViewModel = ChatHistoryViewModel(
            persistenceService: persistence,
            activeStreamManager: mainAppViewModel.activeStreamManager
        )
        self.backendConfiguration.selectedProfileID = Self.resolveDefaultProfileID(mainAppViewModel: mainAppViewModel)

        // [C10] Refresh the transcript on external writes to the panel's conversation (the
        // deleted QuickAccessViewModel observed this; its replacement otherwise stays stale until
        // reopened). Guarded + debounced in scheduleExternalRefresh. queue:.main → the block runs
        // on the main thread, so assumeIsolated is safe.
        didSaveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleExternalRefresh() }
        }
    }

    deinit {
        if let didSaveObserver { NotificationCenter.default.removeObserver(didSaveObserver) }
    }

    /// Resolve the panel's default profile to a CHAT-type profile — never a workflow/code.
    /// Order: remembered QuickAccess profile → the main window's selection *only if it is a
    /// chat type* → first bot → first agent. (Inheriting the main window's selection blindly
    /// is what made the panel pick up a workflow profile.)
    private static func resolveDefaultProfileID(mainAppViewModel: MainApplicationViewModel) -> UUID? {
        // [Q6] Targeted fetches on the common path (remembered / main-window selection) instead of
        // materializing every profile on each summon; the full fetch runs only on first-run fallback.
        func chatTypeID(_ id: UUID?) -> UUID? {
            guard let id, let p = try? BackendProfileStore.shared.fetchProfile(byId: id),
                  allowedProfileTypes.contains(p.profileType) else { return nil }
            return id
        }
        // 1. Remembered QuickAccess profile (if it still exists and is a chat type).
        if let remembered = UserDefaults.standard.string(forKey: GlobalConstants.quickAccessProfileID),
           let id = chatTypeID(UUID(uuidString: remembered)) {
            return id
        }
        // 2. The main window's current selection, ONLY if it is a chat type.
        if let id = chatTypeID(mainAppViewModel.backendConfiguration.selectedProfileID) {
            return id
        }
        // 3. First bot, then first agent — needs the full list, only reached on first run or when
        //    neither a remembered nor a selected chat profile resolves.
        let profiles = (try? BackendProfileStore.shared.fetchSharedProfiles()) ?? []
        return profiles.first(where: { $0.profileType == .bot })?.id
            ?? profiles.first(where: { $0.profileType == .agent })?.id
    }

    /// [Q4] Memoized so the profile chip (which reads this 3× per render, on every keystroke)
    /// doesn't hit SwiftData each time. Still reads `backendConfiguration.selectedProfileID`
    /// first, so views re-render on change; the store fetch runs only when the id actually
    /// changes. The VM is rebuilt per summon, so a profile *edit* mid-session is picked up on
    /// the next open (acceptable for a transient panel).
    @ObservationIgnored private var cachedProfile: (id: UUID, snapshot: BackendProfileModel?)?

    var selectedProfile: BackendProfileModel? {
        guard let id = backendConfiguration.selectedProfileID else { return nil }
        if let cached = cachedProfile, cached.id == id { return cached.snapshot }
        let snapshot = try? BackendProfileStore.shared.fetchProfile(byId: id)
        cachedProfile = (id, snapshot)
        return snapshot
    }

    /// Persist the panel's current profile choice so it sticks across panel sessions.
    func rememberSelectedProfile() {
        if let id = backendConfiguration.selectedProfileID {
            UserDefaults.standard.set(id.uuidString, forKey: GlobalConstants.quickAccessProfileID)
        }
    }

    // MARK: - Session lifecycle

    /// Called when the panel appears. Resolves the persisted QuickAccess conversation (if
    /// any) and loads its transcript. Does NOT create a conversation — creation is deferred
    /// to the first send, so merely opening the panel never litters an empty conversation
    /// the main window's New Chat could steal (recon bug #7).
    /// Non-blocking: stores the load as `loadTask` so send() can await it (C3).
    func prepareSession(resume: Bool = true) {
        loadTask = Task { @MainActor [weak self] in
            await self?.performPrepare(resume: resume)
        }
    }

    private func performPrepare(resume: Bool) async {
        // [QA revival P1e] A timed-out (non-resumable) open starts a fresh session: rotate off
        // the last conversation so the next send creates a new one. The old conversation stays
        // in history — this only drops the "current QuickAccess conversation" pointer.
        guard resume else {
            startNewSession()
            return
        }
        if let existing = conversationID {
            await chatHistoryViewModel.loadConversation(id: existing)
            return
        }
        if let existing = resolveExistingConversationID() {
            conversationID = existing
            adoptConversationProfileIfChatType(existing)
            await chatHistoryViewModel.loadConversation(id: existing)
        }
    }

    /// When adopting an existing conversation (e.g. a transfer handed over from the main
    /// window), use its persisted profile if it is a chat type — otherwise keep the panel's
    /// default. Keeps "continue this chat in the panel" on the same backend it was using.
    private func adoptConversationProfileIfChatType(_ id: UUID) {
        guard let sd = persistence.getConversation(withId: id),
              let boundID = sd.backendEntityId,
              let profile = try? BackendProfileStore.shared.fetchProfile(byId: boundID),
              Self.allowedProfileTypes.contains(profile.profileType) else { return }
        backendConfiguration.selectedProfileID = boundID
    }

    /// Starts a fresh QuickAccess session: rotates off the current conversation so the next
    /// send creates a new one. Any in-flight stream keeps running on its own conversation
    /// (it still finalizes + persists via ActiveStreamManager).
    func startNewSession() {
        conversationID = nil
        streamingMessageID = nil
        streamingConversationID = nil
        isPreparingSend = false
        chatHistoryViewModel.currentChatMessages = []
        UserDefaults.standard.removeObject(forKey: GlobalConstants.quickAccessOverlayConversationId)
    }

    /// [QA revival P2c] Switch the panel to an existing conversation (from the recents menu).
    /// Non-blocking: stores the load as `loadTask` so send() can await it (C3).
    func openConversation(_ id: UUID) {
        loadTask = Task { @MainActor [weak self] in
            await self?.performOpen(id)
        }
    }

    private func performOpen(_ id: UUID) async {
        conversationID = id
        UserDefaults.standard.set(id.uuidString, forKey: GlobalConstants.quickAccessOverlayConversationId)
        adoptConversationProfileIfChatType(id)
        await chatHistoryViewModel.loadConversation(id: id)
    }

    /// [QA revival P2c] The N most-recent NON-empty conversations for the recents menu.
    ///
    /// The `FetchDescriptor` that used to live here moved onto `ChatPersistenceProtocol`
    /// (2026-09-07) — it was the single use that forced this type to depend on the concrete
    /// `ChatPersistenceStore`, and with it gone the panel can be built against a test double.
    /// The bound and the Swift-side emptiness filter are documented at the implementation.
    func recentConversations(limit: Int = 5) -> [(id: UUID, title: String)] {
        persistence.recentConversations(limit: limit)
    }

    /// [C10] Coalesced reload after external SwiftData writes. Only when the panel is IDLE
    /// (not mid-send — during its own stream, currentChatMessages + the live @Observable agent
    /// message already reflect state and a reload would fight them). loadConversation re-merges
    /// active streams, so an in-flight EXTERNAL stream on this conversation shows too.
    private func scheduleExternalRefresh() {
        guard let convID = conversationID, streamingMessageID == nil, !isPreparingSend else { return }
        externalRefreshTask?.cancel()
        externalRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // [C10] Debounce save bursts (400ms). [L7] Also floor to ≥1s since the last reload so
            // a steady drip of unrelated saves can't reload every time; because each save
            // reschedules, the trailing reload still captures the final state.
            let sinceLast = Date().timeIntervalSince(self.lastExternalReload)
            try? await Task.sleep(for: .seconds(max(0.4, 1.0 - sinceLast)))
            guard !Task.isCancelled,
                  self.streamingMessageID == nil, !self.isPreparingSend,
                  self.conversationID == convID else { return }
            self.lastExternalReload = Date()
            await self.chatHistoryViewModel.loadConversation(id: convID)
        }
    }

    // MARK: - Send / stop

    /// Outcome of a send attempt, so the view can react to a refusal (keep the draft, surface
    /// feedback) instead of silently discarding the user's text/attachments. [H2]
    enum SendOutcome {
        case accepted
        /// A panel stream is already in flight (or being prepared).
        case rejectedBusy
        /// No usable chat profile is selected/resolvable (first run, or a remembered profile was
        /// deleted). The view should prompt the user to pick one rather than eat the message.
        case rejectedNoProfile
        /// Nothing to send.
        case rejectedEmpty
        /// The shared graph is unavailable (should not happen in practice).
        case rejectedUnavailable
    }

    @discardableResult
    func send(_ rawText: String, files: [FileSystemItem] = []) -> SendOutcome {
        let query = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow send with text OR attachments (e.g. an image for a vision model).
        guard !(query.isEmpty && files.isEmpty) else { return .rejectedEmpty }
        // [M5] Re-entry guard: reject while a stream is in flight OR being prepared. Checking
        // isPreparingSend (set synchronously below) closes the async gap that a bare
        // streamingMessageID check leaves open.
        guard streamingMessageID == nil, !isPreparingSend else { return .rejectedBusy }
        guard let mainVM = mainAppViewModel else {
            logger.error("send aborted — main view model unavailable.")
            return .rejectedUnavailable
        }
        guard let config = backendConfiguration.getRequestConfig() else {
            logger.error("send aborted — no profile selected or profile not found in store.")
            return .rejectedNoProfile
        }

        // [M5] Reserve the in-flight slot SYNCHRONOUSLY, before the awaits below. A second submit
        // arriving during loadTask / panelTurn / addMessage now sees isPreparingSend and is
        // rejected (.rejectedBusy) instead of starting a duplicate stream.
        isPreparingSend = true

        Task { @MainActor in
            // Clear the prepare reservation once setup finishes (streamingMessageID has taken
            // over by then, so isSending stays continuously true) or if we bail early.
            defer { isPreparingSend = false }

            // [C3] Wait for any in-flight resume/open load to finish — for conversation IDENTITY
            // and for the visible transcript, NOT for history (which is derived from the store;
            // see the `loadTask` property comment).
            await loadTask?.value

            let title = query.isEmpty ? (files.first?.name ?? String(localized: "Attachment")) : query
            let convID = ensureConversation(titleFrom: title, profileID: config.profile.id)
            // Bind the profile so restart-resume (G1), ChatOps, and the sidebar all resolve it.
            persistence.updateBackendForConversation(id: convID, backendEntityId: config.profile.id)

            // Factory does the same text/image attachment classification as the main send path.
            // Built through `panelTurn` so the persisted row and the row handed to the send path
            // are one object — see that function for why the absence of a `promptOverride` and the
            // absence of a history slice are both part of the contract.
            let userMessage = await Self.panelTurn(
                query: query,
                conversationID: convID,
                files: files,
                fileProcessorService: mainVM.messagingCoordinator.fileProcessor
            )
            await persistence.addMessage(userMessage, toConversation: convID)
            chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)

            // ⚠️ The reversed `currentChatMessages` slice that used to be built here is GONE.
            // It was the panel's PAGINATION WINDOW — a hard 20 messages that never grew, since
            // QuickAccess never calls `loadMoreMessages` — shipped as model history. The panel
            // now gets exactly what the main window gets, because `ActiveStreamManager` derives
            // it (`architecture_readme.md` §7 invariant #8: "Never substitute the view's
            // `currentChatMessages`: that is a pagination window, not the conversation").

            // [C2] Identity for the completion guard. ActiveStreamManager fires onComplete on
            // EVERY termination (including a cancelled/stopped stream); without matching against
            // this id, a stopped older stream's late completion would nil a NEWER stream's state
            // and leave the newer stream unstoppable. Captured var is filled right after the call.
            var thisStreamID: UUID?
            // Workflow bookkeeping. ⚠️ Currently ALWAYS nil here: `allowedProfileTypes` is
            // `[.bot, .agent]`, so the panel cannot select a workflow profile. Kept so the call
            // shape is uniform across every `startMessageStream` site — if that filter ever
            // widens, the panel gets run records for free instead of silently reintroducing WF20.
            let workflowTicket = WorkflowRunBootstrap.begin(
                config: config,
                conversationID: convID,
                userInput: query,
                registry: mainVM,
                origin: .quickAccess
            )
            let agentMessage = activeStreamManager.startMessageStream(
                withConfig: config,
                userMessage: userMessage,
                // Spelled out because a protocol witness carries no default arguments.
                promptOverride: nil,
                files: files,
                updating: nil,
                workflowExecutionState: workflowTicket?.state,
                resumeState: nil,
                onComplete: { [weak self] in
                    DispatchQueue.main.async {
                        // ⚠️ finalize BEFORE the identity guard. That guard exists so a stopped
                        // older stream's late completion can't nil a NEWER stream's UI state —
                        // but the older run's RECORD still has to be frozen, or it stays
                        // `.running` on disk until the next launch reconciles it.
                        workflowTicket?.finalize()
                        guard let self, self.streamingMessageID == thisStreamID else { return }
                        self.streamingMessageID = nil
                        self.streamingConversationID = nil
                    }
                }
            )
            agentMessage.messageSource = .quickAccess // [Q2] attribute panel traffic
            thisStreamID = agentMessage.id
            streamingMessageID = agentMessage.id
            streamingConversationID = convID   // [C1] stop() drains THIS conversation, not the viewed one
            chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
        }
        return .accepted
    }

    /// Stop the in-flight panel stream, and drain any HITL-parked suspension so it returns
    /// immediately rather than waiting indefinitely.
    func stop() {
        guard let id = streamingMessageID else { return }
        activeStreamManager.cancelStream(for: id)
        // [C1] Drain the suspension for the conversation the STREAM belongs to — not the
        // conversation the panel currently shows (the user may have switched via recents),
        // which would force-resolve an unrelated HITL-parked run on that other conversation.
        if let convID = streamingConversationID {
            Task { await ExecutionSuspensionService.shared.cancel(for: convID) }
        }
        streamingMessageID = nil
        streamingConversationID = nil
    }

    // MARK: - HITL (in-panel)

    /// The shared HITL queue (one instance, owned by MainApplicationViewModel). Optional
    /// because the main VM ref is weak.
    var interactionCenter: InteractionCenter? { mainAppViewModel?.interactionCenter }

    /// The single pending interaction for THIS panel's conversation (strict FIFO), or nil.
    /// Reads InteractionCenter.pending, so a view referencing this re-renders when the queue
    /// changes — including when another surface (main window) answers the same request.
    var pendingInteraction: PendingHITL? {
        guard let convID = conversationID, let center = interactionCenter else { return nil }
        return center.current(for: convID)
    }

    // [Q1] All answers route through MessagingCoordinator's wrappers (via the VM forwards) so
    // panel HITL decisions are audit-logged ([HITL]/[ASK_USER]/[PLAN_REVIEW]/[GATE]) and share
    // the main window's answer path, instead of calling ExecutionSuspensionService raw. The
    // wrappers are keyed purely by operationID — no main-window-selection side effects — so
    // they're safe for the panel's (possibly non-selected) conversation.

    /// Routes a HITL decision to the view model, or reports that it went NOWHERE.
    ///
    /// (The two lines that used to open this block — "Approve a tool-confirmation. `allowForChat`
    /// registers a durable per-conversation grant BEFORE resuming" — describe `approveTool`, not
    /// this function, which has no `allowForChat` parameter and never touches
    /// `SessionToolApprovals`. They were inserted above rather than below the existing
    /// `approveTool` doc and silently annexed it. Moved back.)
    ///
    /// ⚠️ Every decision on this surface used to be a bare `mainAppViewModel?.submitX(…)` with no
    /// else branch. When that reference is nil the user taps Approve and **nothing happens**: no
    /// submission, no log line, no UI change — the run stays parked and the banner keeps waiting,
    /// with nothing in the log to explain it. That is the exact shape the production-logging
    /// directive calls a silent drop, and it is `.error` rather than `.warning` precisely because
    /// the app carries on looking fine.
    ///
    /// Funnelling every decision through here also means a NEW decision kind cannot reintroduce
    /// the silent path by forgetting the guard.
    ///
    /// ⚠️ One decision does not need the view model — gate CANCEL has no VM wrapper and goes
    /// straight to `ExecutionSuspensionService`. It routes through `submitHITLDirect` rather than
    /// calling the service inline, so it is still logged and still attributed to this surface;
    /// four of five arms carrying a `[HITL]` line and the fifth carrying none showed up in the
    /// field as three of four Escape presses.
    private func submitHITL(_ decision: String,
                            operationID: UUID,
                            detail: String,
                            _ submit: (MainApplicationViewModel) -> Void) {
        guard let vm = mainAppViewModel else {
            logger.error("[HITL] \(decision) for op \(operationID.uuidString.prefix(8)) went NOWHERE — the QuickAccess panel outlived its MainApplicationViewModel. CONSEQUENCE: the user's decision was DISCARDED, the run stays parked forever waiting on an answer that will never arrive, and the banner keeps showing as if it were still actionable. conversationID: \(conversationID?.uuidString.prefix(8) ?? "none")")
            return
        }
        logger.notice("[HITL] \(decision) op \(operationID.uuidString.prefix(8)) from the QuickAccess panel\(detail.isEmpty ? "" : " — " + detail). conversationID: \(conversationID?.uuidString.prefix(8) ?? "none")")
        submit(vm)
    }

    /// The same attribution and logging for a decision that reaches its service DIRECTLY.
    ///
    /// Gate cancel is the only one: `submitGateChoice` takes a non-optional option, so there is
    /// no view-model wrapper for "no choice". That makes it the one arm with no VM to be missing
    /// — hence no `.error` twin — but it is still a user decision that must be visible in a log
    /// alongside the other four, with the same surface attribution.
    private func submitHITLDirect(_ decision: String,
                                  operationID: UUID,
                                  detail: String,
                                  _ submit: @escaping () async -> Void) {
        logger.notice("[HITL] \(decision) op \(operationID.uuidString.prefix(8)) from the QuickAccess panel\(detail.isEmpty ? "" : " — " + detail). conversationID: \(conversationID?.uuidString.prefix(8) ?? "none")")
        Task { await submit() }
    }

    /// Approve a tool-confirmation. `allowForChat` registers a durable per-conversation grant
    /// BEFORE resuming — order matters, because the executor consults `SessionToolApprovals`
    /// first, and a grant registered after the resume arrives too late for the run it was meant
    /// to unblock.
    func approveTool(_ pending: PendingHITL, allowForChat: Bool) {
        let opID = pending.id
        if allowForChat, case .toolConfirmation(let c) = pending.kind, let convID = conversationID {
            Task { @MainActor in
                // ⚠️ Order matters: the durable grant is registered BEFORE the resume, or the run
                // continues and the next request for the same tool asks again anyway.
                await SessionToolApprovals.shared.allow(toolName: c.toolName, risk: c.risk, conversationID: convID)
                self.submitHITL("APPROVED", operationID: opID,
                                detail: "tool \(c.toolName), DURABLE grant for this conversation — subsequent calls to this tool will NOT ask again until the conversation ends") {
                    $0.submitToolApproval(operationID: opID, approved: true)
                }
            }
        } else {
            submitHITL("APPROVED", operationID: opID,
                       detail: "one-shot — the next request for the same tool asks again") {
                $0.submitToolApproval(operationID: opID, approved: true)
            }
        }
    }

    func denyTool(_ pending: PendingHITL) {
        submitHITL("DENIED", operationID: pending.id,
                   detail: "the tool does not run and the agent is told the user refused") {
            $0.submitToolApproval(operationID: pending.id, approved: false)
        }
    }

    func submitClarification(_ pending: PendingHITL, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // ⚠️ Length only — the answer is free text the user typed and re-enters the agent's context.
        submitHITL("Answered clarification", operationID: pending.id,
                   detail: "\(trimmed.count) character(s)\(trimmed.isEmpty ? " (empty — treated as no answer)" : ""); the run resumes with this text in context") {
            $0.submitClarificationResponse(operationID: pending.id, response: trimmed.isEmpty ? nil : trimmed)
        }
    }

    func resolvePlan(_ pending: PendingHITL, approved: Bool) {
        guard case .planReview(let plan) = pending.kind else {
            // ⚠️ Dropped the click with no line anywhere. The pending item can be replaced between
            // the render and the tap, and the button then simply does nothing — which reads as a
            // dead button rather than as a race.
            logger.error("[HITL] Plan decision for op \(pending.id.uuidString.prefix(8)) IGNORED — the pending item is no longer a plan review. CONSEQUENCE: the click did nothing and the run stays parked; the request on screen changed underneath the user.")
            return
        }
        submitHITL("Plan \(approved ? "APPROVED" : "REJECTED")", operationID: pending.id,
                   detail: "\(plan.subtasks.count) subtask(s); \(approved ? "the run proceeds with this plan" : "the run is told the plan was rejected")") {
            $0.submitPlanReview(operationID: pending.id, editedPlan: approved ? plan.subtasks : nil)
        }
    }

    func chooseGate(_ pending: PendingHITL, option: String?) {
        // submitGateChoice takes a non-optional option; a nil choice (cancel) has no VM wrapper,
        // so route that straight to the suspension service.
        if let option {
            submitHITL("Gate answered", operationID: pending.id,
                       detail: "option '\(option)' — the workflow continues down that output port") {
                $0.submitGateChoice(operationID: pending.id, option: option)
            }
        } else {
            submitHITLDirect("Gate cancelled", operationID: pending.id,
                             detail: "no option chosen — the workflow resumes down its default path") {
                await ExecutionSuspensionService.shared.resumeGate(for: pending.id, chosenOption: nil, resolvedBy: .quickAccess)
            }
        }
    }

    // MARK: - Conversation identity

    private func resolveExistingConversationID() -> UUID? {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: GlobalConstants.quickAccessOverlayConversationId),
              let id = UUID(uuidString: idString),
              persistence.getConversation(withId: id) != nil else {
            return nil
        }
        return id
    }

    /// Returns the current conversation, creating + persisting one on first send.
    private func ensureConversation(titleFrom query: String, profileID: UUID) -> UUID {
        if let existing = conversationID { return existing }
        if let existing = resolveExistingConversationID() {
            conversationID = existing
            return existing
        }
        let newConversation = Conversation(
            id: UUID(),
            timestamp: Date(),
            userDefinedTitle: query,
            backendEntityId: profileID
        )
        persistence.addConversation(from: newConversation)
        UserDefaults.standard.set(newConversation.id.uuidString,
                                  forKey: GlobalConstants.quickAccessOverlayConversationId)
        conversationID = newConversation.id
        return newConversation.id
    }
}
