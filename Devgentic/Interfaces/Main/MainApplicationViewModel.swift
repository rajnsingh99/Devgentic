//
//  MainApplicationViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import SwiftData
import Combine
import os
import AppKit
import AVFoundation


private let logger = DGLogger(category: "MainApplicationViewModel")

@Observable @MainActor
final class MainApplicationViewModel {

    // MARK: - Dependencies

    let backendConfiguration = BackendConfiguration()
    let explorerViewModel = ExplorerViewModel()

    // Dependencies are now injected and stored.
    @ObservationIgnored private(set) var activeStreamManager: ActiveStreamManager
    /// [HITL/P1] Single source of truth for pending HITL across all interfaces. Views read it
    /// (it is itself @Observable); ASM gets the reference injected in init for P2 enqueue.
    @ObservationIgnored let interactionCenter = InteractionCenter()
    @ObservationIgnored private(set) var persistenceService: ChatPersistenceProtocol
    @ObservationIgnored private let fileProcessorService: FileProcessorService
    @ObservationIgnored private let chatHistoryViewModel: ChatHistoryViewModel

    /// Whether a send/stream is in flight — exposed because `chatHistoryViewModel` is private and
    /// views must not reach it. Reading through this computed property still registers observation
    /// (`ChatHistoryViewModel` is `@Observable`), so a view that reads it re-renders when the
    /// stream starts and ends — which is exactly what lets the Re-run pill disable itself live
    /// (WF-UI4: it used to stay fully enabled during a stream and silently drop the click).
    var isSendInProgress: Bool { chatHistoryViewModel.isSending }

    @ObservationIgnored private var useStreamingResponseObserver: AnyCancellable?
    @ObservationIgnored private var intelligenceCoreObserver: AnyCancellable?

    // Code mode — used to build ephemeral profiles on each send
    @ObservationIgnored private(set) var codeSessionManager: CodeSessionManager?

    // MARK: - ChatOps
    //
    // Lifecycle + bridge ownership has been extracted to `ChatOpsCoordinator`
    // (Gap C — the MainApplicationViewModel god-object split). The properties
    // and methods remaining in this file are thin forwards preserved for
    // external callers (currently: `ChatOpsSettingsView`).
    @ObservationIgnored private var chatOpsCoordinator: ChatOpsCoordinator!

    /// Owns the message-sending pipeline (local + remote sends, regeneration,
    /// cancellation, HITL resolutions, createUserMessage factory). Extracted
    /// from this file as part of Gap C — see `MessagingCoordinator.swift`.
    @ObservationIgnored private(set) var messagingCoordinator: MessagingCoordinator!

    /// Owns conversation CRUD (create/select/pin/rename/delete/export + the
    /// conversation↔profile mapping). See `ConversationManagementCoordinator.swift`.
    @ObservationIgnored private(set) var conversationManagementCoordinator: ConversationManagementCoordinator!

    /// Owns load/persist for every UserDefaults-backed setting (streaming
    /// toggle, intelligence core, web search, interface mode). See
    /// `SettingsCoordinator.swift`.
    @ObservationIgnored private(set) var settingsCoordinator: SettingsCoordinator!

    /// Owns scheduled-task + ChatOps-bridge message flows that run outside the
    /// Mac UI's selected conversation. See `SchedulerCoordinator.swift`.
    @ObservationIgnored private(set) var schedulerCoordinator: SchedulerCoordinator!

    /// Owns the "what happens on conversation selection change" pipeline —
    /// observation, debounce, model unload, message load, backend rebind,
    /// workflow history fetch. See `ConversationSwitchCoordinator.swift`.
    @ObservationIgnored private var conversationSwitchCoordinator: ConversationSwitchCoordinator!
    /// Forward for external callers that previously reached `viewModel.chatOpsBridge?.stop()`.
    var chatOpsBridge: ChatOpsBridge? { chatOpsCoordinator.telegramBridge }
    /// Forward for external callers that previously reached `viewModel.discordChatOpsBridge?.stop()`.
    var discordChatOpsBridge: DiscordChatOpsBridge? { chatOpsCoordinator.discordBridge }
    /// Forward for external callers that previously reached `viewModel.slackChatOpsBridge?.stop()`.
    var slackChatOpsBridge: SlackChatOpsBridge? { chatOpsCoordinator.slackBridge }

    // MARK: - Service & Store
    @ObservationIgnored var ollamaService = OllamaService.shared

    // MARK: - State Properties
    var conversations: [Conversation] = []
    var selectedConversationID: UUID?
    var isSidebarCollapsed: Bool = true
    var showContextArea: Bool = false
    var activeContextFilePath: String? = nil
    var attachedFiles: [FileSystemItem] = []
    var useStreamingResponse: Bool = true
    var isWebSearchEnabled: Bool = false
    var webSearchAPIKey: String?
    var isWebSearchActive: Bool = false

    // Intelligence Core
    var isIntelligenceCoreEnabled: Bool = false

    /// The run the composer is talking about: what Stop targets, and whether the send button
    /// shows Send or Stop. DERIVED — never stored.
    ///
    /// ⚠️ This was two stored `var`s until 2026-08-17. Five surfaces wrote them and five
    /// completions nil'd them, none with an ownership guard, so whichever run finished first
    /// silently orphaned every other run — the composer flipped back to Send and the survivor
    /// became unstoppable from the UI. A clear-side identity guard provably does NOT fix that
    /// (see `ForegroundRunResolver`), so the storage was removed instead of guarded.
    ///
    /// Scope rule: a run belongs to a conversation, and only the conversation on screen can stop
    /// it. `nil` while a background scheduled or ChatOps run streams elsewhere is CORRECT — that
    /// run is stopped by opening its conversation, not from here.
    ///
    /// `streamingMessage` was deleted outright rather than derived: it had one reader
    /// (`MessagingCoordinator.cancelStreamingResponse`), which now takes the conversation id from
    /// the resolver directly.
    var streamingMessageID: UUID? {
        ForegroundRunResolver.foregroundRun(
            live: activeStreamManager.liveRunSnapshot(),
            selectedConversation: selectedConversationID
        )?.messageID
    }

    // MARK: - Interface Mode (User-Switchable)

    /// The interface mode — user-switchable via the floating mode picker.
    /// Workflow mode renders WorkflowDedicatedView; chat mode renders ChatHistoryView.
    /// Also controls sidebar filtering and backend picker profile types.
    enum InterfaceMode: String, CaseIterable {
        case chat = "Chat"
        case workflow = "Workflow"
        case code = "Code"

        var icon: String {
            switch self {
            case .chat: return "bubble.left.and.text.bubble.right"
            case .workflow: return "point.3.connected.trianglepath.dotted"
            case .code: return "chevron.left.forwardslash.chevron.right"
            }
        }

        /// Profile types visible in the backend picker for this mode.
        var allowedProfileTypes: Set<ProfileType> {
            switch self {
            case .chat: return [.bot, .agent, .imageGen]
            case .workflow: return [.workflow]
            case .code: return [.code]
            }
        }
    }

    /// The active interface mode — persisted to UserDefaults for session continuity.
    var interfaceMode: InterfaceMode = .chat

    /// Resolved profile type — derived from the currently selected profile ID.
    var selectedProfileType: ProfileType? {
        guard let pid = backendConfiguration.selectedProfileID,
              let profile = (try? BackendProfileStore.shared.fetchProfiles())?.first(where: { $0.id == pid })
        else { return nil }
        return profile.profileType
    }

    /// Guards navigation away from a workflow canvas with unsaved edits. The active
    /// `WorkflowCanvasView` registers its dirty-state + save/discard hooks here; the
    /// navigation sites route their transition through `workflowEditGuard.attempt`.
    let workflowEditGuard = WorkflowEditGuard()

    /// Switches to the given interface mode, clearing conversation and profile selection.
    /// This resets the view to either the Welcome screen (chat) or the Empty Workflow view (workflow).
    /// Routed through `workflowEditGuard` so leaving a dirty workflow canvas prompts Save/Discard/Cancel.
    func switchInterfaceMode(to mode: InterfaceMode) {
        guard mode != interfaceMode else { return }
        workflowEditGuard.attempt { [weak self] in
            self?.performInterfaceSwitch(to: mode)
        }
    }

    /// [HITL/P4] Navigate to a (possibly different-mode) conversation that has a pending HITL —
    /// e.g. from the cross-conversation chip in `InteractionBannerStack`. Aligns `interfaceMode`
    /// to the request's origin so the correct dedicated view + mode-filtered sidebar are shown
    /// (not a contextually-wrong empty screen), and routes through `workflowEditGuard` so leaving
    /// a dirty workflow canvas still prompts Save/Discard/Cancel.
    func navigateToPendingInteraction(conversationID: UUID, interface: HITLOrigin.Interface) {
        let targetMode: InterfaceMode = {
            switch interface {
            case .workflow:          return .workflow
            case .code:              return .code
            case .chat, .scheduled:  return .chat
            }
        }()
        workflowEditGuard.attempt { [weak self] in
            guard let self else { return }
            // performInterfaceSwitch nulls selectedConversationID, so set the mode first
            // (only when it actually differs) and select the target afterward.
            if self.interfaceMode != targetMode {
                self.performInterfaceSwitch(to: targetMode)
            }
            self.selectedConversationID = conversationID
        }
    }

    private func performInterfaceSwitch(to mode: InterfaceMode) {
        interfaceMode = mode
        // Deselecting is what clears the composer now: the per-conversation draft restore
        // swaps in the "new chat" draft (see ComposerDraftStore). The old
        // `clearAttachedFiles()` ran BEFORE this line, so the draft saved for the
        // conversation being left captured zero attachments and the user lost them.
        // Both branches stay consistent — if the id was already nil the box already holds
        // that same new-chat draft, so there is nothing to swap.
        selectedConversationID = nil
        backendConfiguration.selectedProfileID = nil
        chatHistoryViewModel.currentChatMessages = []
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
        settingsCoordinator.didChangeInterfaceMode(mode)
        logger.info("Switched interface mode to \(mode.rawValue).")
    }

    // MARK: - Workflow Execution State
    /// Live workflow execution state keyed by conversation ID.
    var workflowExecutionStates: [UUID: WorkflowExecutionState] = [:]

    /// Persistent run history keyed by conversation ID.
    var workflowRunHistory: [UUID: [WorkflowRunRecord]] = [:]

    /// Live canvas editing state keyed by WORKFLOW PROFILE ID (not conversation).
    ///
    /// ⚠️ Owned here, not by `WorkflowCanvasView`, because the view is torn down and rebuilt
    /// whenever the dedicated view flips between Canvas and Execution — and a run STARTING flips
    /// it automatically. While this lived in the view's `@State`, that flip destroyed every
    /// unsaved node, edge and task description with no prompt and no dirty indicator, on the most
    /// natural action there is: running the workflow you were just editing.
    ///
    /// Keyed by profile so the edits also survive a conversation switch. ⚠️ In-memory only — the
    /// ONLY thing that writes them to disk is an explicit Save (there is no autosave), so the quit
    /// path must drain them: see `unsavedWorkflowCanvasProfileIDs` / `persistDirtyWorkflowCanvases`.
    @ObservationIgnored private var workflowCanvasStates: [UUID: WorkflowCanvasState] = [:]

    /// Profiles whose cached canvas holds unsaved edits — the OBSERVABLE mirror of that fact.
    ///
    /// ⚠️ Exists because `workflowCanvasStates` is `@ObservationIgnored` (deliberately — body-time
    /// `workflowCanvasState(for:)` mutates it, and observing that would reintroduce "Modifying state
    /// during view update"). So nothing could drive UI from it, and the only dirty signal reaching
    /// the chrome was `WorkflowEditGuard.hasUnsavedChanges` — which mirrors ONLY the canvas currently
    /// on screen and is cleared by `unregister()` on teardown. Consequence: edit a graph, navigate
    /// away, and the unsaved work became invisible until ⌘Q asked about it.
    ///
    /// ⚠️ A MIRROR, NEVER THE AUTHORITY. The quit gate must keep reading
    /// `unsavedWorkflowCanvasProfileIDs`, which pulls from the live state objects; this set is
    /// pushed from views and would silently under-report if a push were ever missed. Do not swap the
    /// quit decision onto it.
    private(set) var dirtyWorkflowCanvasIDs: Set<UUID> = []

    /// Pushed by `WorkflowCanvasView` whenever its canvas's dirty flag changes, and on mount.
    func setWorkflowCanvasDirty(_ dirty: Bool, for profileID: UUID) {
        if dirty {
            dirtyWorkflowCanvasIDs.insert(profileID)
        } else {
            dirtyWorkflowCanvasIDs.remove(profileID)
        }
    }

    /// The canvas state for a workflow profile, created on first use and reused thereafter.
    func workflowCanvasState(for profileID: UUID) -> WorkflowCanvasState {
        if let existing = workflowCanvasStates[profileID] { return existing }
        let created = WorkflowCanvasState(profileID: profileID)
        workflowCanvasStates[profileID] = created
        return created
    }

    /// Profiles whose cached canvas holds edits that are not on disk.
    ///
    /// ⚠️ This is deliberately NOT `workflowEditGuard.hasUnsavedChanges`. That guard mirrors only
    /// the canvas currently ON SCREEN, and these states outlive the view: edit workflow A, switch
    /// to workflow B, and A's dirty state stays cached while the guard now reports B's. An exit
    /// point that consults the guard alone therefore cannot see A's work at all.
    var unsavedWorkflowCanvasProfileIDs: [UUID] {
        workflowCanvasStates.filter { $0.value.hasUnsavedChanges }.map(\.key)
    }

    /// What a bulk canvas drain actually did, per profile.
    ///
    /// ⚠️ Three fields, not two, because an exit point needs THREE questions answered: "must I
    /// cancel the exit?" (`failed` — genuinely, plausibly-transiently failed, worth retrying); "is
    /// this profile refused by design, so canceling-and-asking-to-retry would be asking for
    /// something that can never happen?" (`refused`, [WF-PE2]); and "has this profile's row already
    /// been written OR already conclusively resolved-without-writing, so an on-screen `saveHook` for
    /// it would be a redundant/second write attempt?" (`persisted` — see WF-PE1; `refused` profiles
    /// belong in that same "already handled" bucket for that specific question, since a refusal is
    /// exactly as final as a write and a caller must not chase it a second time).
    struct CanvasDrainResult {
        /// Profiles whose layout reached disk.
        let persisted: [UUID]
        /// [WF-PE2] Profiles refused BY DESIGN — `.refusedUnreadable`/`.refusedNewerVersion` — with
        /// the outcome carried so a caller can build an accurate, per-reason message. A non-empty
        /// value must NOT be treated the same as `failed`: retrying can never succeed for these.
        let refused: [(id: UUID, outcome: WorkflowLayoutSaveOutcome)]
        /// Profiles whose layout could NOT be written for a plausibly-transient reason — a non-empty
        /// value must block the exit and invite a retry.
        let failed: [UUID]

        init(persisted: [UUID], refused: [(id: UUID, outcome: WorkflowLayoutSaveOutcome)] = [], failed: [UUID]) {
            self.persisted = persisted
            self.refused = refused
            self.failed = failed
        }
    }

    /// Writes every dirty cached canvas to disk. Returns the profiles it could NOT persist.
    ///
    /// Mirrors `WorkflowCanvasView.saveLayout()` — store write first, owned-row reconcile only
    /// once the bytes are down, `markSaved()` only once both succeeded — because a partial save is
    /// worse than none: collecting a node's configuration against a canvas that was never written
    /// would delete the config of nodes that still exist.
    ///
    /// ⚠️ Callers at an exit point must treat a non-empty `failed` as a REFUSAL to continue. Quitting
    /// after a failed save destroys the very work the user asked to keep.
    ///
    /// ⚠️ [WF-PE2] `refused` is NOT `failed`. A `.refusedUnreadable`/`.refusedNewerVersion` canvas
    /// will refuse identically on every retry — cancelling the exit and telling the user to "save it
    /// from the canvas" asks for something that can never happen. A caller must offer an explicit
    /// choice for `refused` instead of the retry framing `failed` gets.
    ///
    /// ⚠️ `persisted` is reported so an exit point can tell whether a canvas it is ALSO about to save
    /// through an on-screen `saveHook` has already been written here (WF-PE1). Both paths write the
    /// same `WorkflowLayoutSD` row and the store has no compare-and-swap, so "did the drain already
    /// cover this profile?" has to be answerable rather than assumed. A REFUSED profile belongs in
    /// that same "already handled" question too — see the caller-side note in `saveOpenProfileEdits`
    /// for why treating it as un-covered would fire a redundant, misleadingly-logged second attempt.
    @discardableResult
    func persistDirtyWorkflowCanvases(profileService: BackendProfileService) -> CanvasDrainResult {
        let dirty = workflowCanvasStates.filter { $0.value.hasUnsavedChanges }
        guard !dirty.isEmpty else { return CanvasDrainResult(persisted: [], failed: []) }

        var persisted: [UUID] = []
        var refused: [(id: UUID, outcome: WorkflowLayoutSaveOutcome)] = []
        var failed: [UUID] = []
        for (profileID, state) in dirty {
            // Through the guarded accessor, not `currentLayout()`. The dictionary key and the
            // state's own id agree by construction today, and this is what keeps that true.
            guard let layout = state.layout(forProfile: profileID) else {
                failed.append(profileID)
                continue
            }
            let outcome = WorkflowLayoutStore.shared.save(layout, for: profileID)

            // [WF-PE2] Refused-by-design is not a failure: it will refuse identically on every
            // retry, so a caller that cancels an exit and asks the user to "save it from the
            // canvas" would be asking for the one thing that can never happen. Bucketed separately
            // from `failed`, which stays for the plausibly-transient cases — a caller must still
            // block on THOSE.
            //
            // ⚠️ NO UNIT-TEST SEAM for this branch itself — `MainApplicationViewModel` cannot be
            // constructed in a test (claims `HITLPresenter` globally; established by
            // `EditBufferRebaseTests.swift`'s own disclosure and repeated by every VM-adjacent fix
            // this session). What IS tested, exhaustively, is the classifier this branching decision
            // is entirely DERIVED FROM — `WorkflowLayoutSaveOutcome.isRefusedByDesign`/`didPersist`
            // in `BlobWriteRefusalTests.swift`'s WF-PE2 section — so the 3-way split below is proven
            // correct at the decision level even though the loop that consumes it is reviewed, not
            // directly tested.
            if outcome.isRefusedByDesign {
                refused.append((profileID, outcome))
                logger.notice(
                    "[WF_CANVAS] Exit-time save REFUSED (by design) for workflow \(profileID): \(String(describing: outcome)). "
                    + "CONSEQUENCE: \(layout.nodes.count) node(s) and \(layout.edges.count) edge(s) stay "
                    + "in-memory-only; this will refuse identically on retry, so the caller must offer "
                    + "an explicit choice rather than cancel-and-ask-to-retry."
                )
                continue
            }

            guard outcome.didPersist else {
                failed.append(profileID)
                logger.error(
                    "[WF_CANVAS] Exit-time save FAILED for workflow \(profileID): \(String(describing: outcome)). "
                    + "CONSEQUENCE: \(layout.nodes.count) node(s) and \(layout.edges.count) edge(s) are "
                    + "still only in memory; the caller must cancel the exit rather than discard them."
                )
                continue
            }

            // Same ordering rule as the canvas's own save, and for the same reason: this is past
            // `outcome.didPersist`, so the nodes named here are the ones that reached disk.
            // Same refusal as the canvas save — a state loaded from a failed read cannot be
            // trusted to name every node this workflow has.
            if state.lastLoadDidFail {
                logger.error("[WF_CANVAS] Exit-time owned-row reconcile REFUSED for workflow \(profileID): its canvas was loaded from a failed read. CONSEQUENCE: rows for deleted nodes are left on disk rather than risking deletion of configurations whose nodes still exist.")
            } else {
            profileService.reconcileOwnedProfiles(
                forWorkflow: profileID,
                // Same union as the canvas save — see `undoRecoverableProfileIDs`. A cached state
                // reaching the quit drain can still hold an undo stack.
                referencedProfileIDs: Set(layout.nodes.compactMap(\.profileID))
                    .union(state.undoRecoverableProfileIDs)
            )
            }

            // ⚠️ NO PROFILE RE-SAVE HERE ANY MORE (2026-08-29). This block existed solely to
            // recompute `WorkflowConfig.agentProfileIDs` from the layout; that field is retired,
            // because a workflow's nodes own their configuration and the layout is the only record
            // of what a workflow contains.
            //
            // Nothing replaces it: unlike the canvas's own save, this drain has no editor draft to
            // flush — it runs over cached canvas STATES whose views may not even be mounted, and
            // the profile row it would have re-saved was never edited here. The layout write above
            // plus the reconcile is the whole job.

            state.markSaved()
            // The drain runs over states whose views may not be mounted, so no `onChange` will fire
            // to clear the mirror — do it here or the tab dot outlives the save.
            dirtyWorkflowCanvasIDs.remove(profileID)
            persisted.append(profileID)
            logger.info(
                "[WF_CANVAS] Exit-time save: workflow \(profileID) persisted "
                + "(\(layout.nodes.count) node(s), \(layout.edges.count) edge(s))."
            )
        }
        return CanvasDrainResult(persisted: persisted, refused: refused, failed: failed)
    }

    /// Drops the cached canvas state for a profile that no longer exists.
    ///
    /// ⚠️ Wired from `BackendProfileService.onProfileDeleted`, alongside the layout-row delete, so
    /// every delete path cascades. Without it a DIRTY canvas for a just-deleted workflow stayed in
    /// the cache and `persistDirtyWorkflowCanvases` re-INSERTED its `WorkflowLayoutSD` row at quit —
    /// resurrecting the layout the delete had removed, as a row nothing will ever collect.
    ///
    /// ⚠️ Deliberately silent when there is nothing cached: deleting a non-workflow profile, or a
    /// workflow whose canvas was never opened, is the ordinary case and must not log.
    func discardWorkflowCanvasState(for profileID: UUID) {
        dirtyWorkflowCanvasIDs.remove(profileID)
        guard let state = workflowCanvasStates.removeValue(forKey: profileID) else { return }
        if state.hasUnsavedChanges {
            logger.notice(
                "[WF_CANVAS] Discarded the cached canvas for DELETED workflow \(profileID), which had "
                + "UNSAVED edits. CONSEQUENCE: those edits are gone — which is correct, the user "
                + "deleted the workflow — and the quit-time drain can no longer re-create its layout "
                + "row as an orphan."
            )
        }
    }

    // No general-purpose `discard(for:)` beyond the delete cascade above. Profile ids are UUIDs, so a
    // deleted profile's state is a few KB that no recreated profile can ever inherit. Shipping an
    // unreachable cleanup hook would be a guard with no consumer, which is a defect in its own
    // right; add one here only alongside a caller that actually runs.

    // MARK: - Query History Properties
    private(set) var queryHistory: [String] = []
    @ObservationIgnored private var currentHistoryIndex: Int = -1
    
    enum QueryNavigationDirection {
        case up, down
    }
    
    private let groupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yy"
        return formatter
    }()

    // MARK: - Computed Properties
    var currentConversationTitle: String {
        guard let selectedID = selectedConversationID,
              let conversationSD = persistenceService.getConversation(withId: selectedID) else {
            return "Devgentic"
        }
        return conversationSD.toRowStruct().displayTitle
    }

    // MARK: - Initialization
    init(
        persistenceService: ChatPersistenceProtocol = ChatPersistenceStore.shared,
        fileProcessorService: FileProcessorService = FileProcessorService(),
        activeStreamManager: ActiveStreamManager,
        chatHistoryViewModel: ChatHistoryViewModel
    ) {
        self.persistenceService = persistenceService
        self.fileProcessorService = fileProcessorService
        self.activeStreamManager = activeStreamManager
        self.chatHistoryViewModel = chatHistoryViewModel

        // [HITL/P1] Hand the shared interaction queue to the stream manager (dead in P1 —
        // ASM begins enqueueing in P2). The VM owns it; ASM holds the back-reference.
        activeStreamManager.interactionCenter = interactionCenter

        // Claim presentation for out-of-band HITL. MCP sampling / elicitation requests
        // arrive from a server at a moment of its choosing, with no stream in scope, so they
        // cannot go through ActiveStreamManager's injected reference. The main window owns
        // this; QuickAccess deliberately does not claim it.
        HITLPresenter.claim(interactionCenter)

        logger.info("MainApplicationViewModel initialized.")

        // Settings load is first so other coordinators see the correct persisted
        // values (e.g. `interfaceMode`, `useStreamingResponse`) during their setup.
        settingsCoordinator = SettingsCoordinator(viewModel: self)
        settingsCoordinator.load()

        // Conversation CRUD lives in its own coordinator (Gap C extraction).
        conversationManagementCoordinator = ConversationManagementCoordinator(
            viewModel: self,
            chatHistoryViewModel: chatHistoryViewModel,
            persistenceService: persistenceService,
            backendConfiguration: backendConfiguration
        )

        // Selection-change observer. Constructed AFTER `conversationManagementCoordinator`
        // because its debounced task calls into it for the backend rebind.
        conversationSwitchCoordinator = ConversationSwitchCoordinator(
            viewModel: self,
            chatHistoryViewModel: chatHistoryViewModel,
            persistenceService: persistenceService,
            backendConfiguration: backendConfiguration,
            ollamaService: ollamaService
        )

        // Messaging pipeline lives in its own coordinator. Constructed before
        // ChatOps so remote bridges can reach it immediately.
        messagingCoordinator = MessagingCoordinator(
            viewModel: self,
            chatHistoryViewModel: chatHistoryViewModel,
            activeStreamManager: activeStreamManager,
            persistenceService: persistenceService,
            fileProcessorService: fileProcessorService,
            backendConfiguration: backendConfiguration
        )

        // Scheduler / remote-bridge message flow.
        //
        // ⚠️ This said "Must come after messagingCoordinator since it reaches through the VM for
        // the shared `createUserMessage` factory". It no longer reaches through the VM for that:
        // it takes the static `MessagingCoordinator.makeUserMessage` with an injected
        // `FileProcessorService`. (The ordering was never a real construction constraint even
        // then — the reach was lazy, at send time.) The order below is now free.
        schedulerCoordinator = SchedulerCoordinator(
            viewModel: self,
            persistenceService: persistenceService,
            activeStreamManager: activeStreamManager,
            fileProcessorService: fileProcessorService,
            runRegistry: self
        )

        // ChatOps lifecycle lives in its own coordinator. We build it here
        // (needs `self` as back-reference for bridges) and let it bootstrap
        // the always-on sync service plus any enabled bridges.
        chatOpsCoordinator = ChatOpsCoordinator(
            viewModel: self,
            chatHistoryViewModel: chatHistoryViewModel,
            activeStreamManager: activeStreamManager
        )
        chatOpsCoordinator.bootstrap()
    }

    // MARK: - Code Session

    /// Late-injected by DevgenticApp after init (avoids init-order dependency).
    func configureCodeSession(_ manager: CodeSessionManager) {
        self.codeSessionManager = manager
    }

    /// Refreshes the code profile's instructions and sets it as the selected profile for send.
    /// Called before each send when `interfaceMode == .code`.
    /// Visibility: needed by `MessagingCoordinator` for its code-mode branch.
    func prepareCodeProfileForSend() {
        guard let csm = codeSessionManager, csm.isConfigured else {
            logger.warning("[CODE] prepareCodeProfileForSend: CodeSessionManager not configured")
            return
        }
        csm.refreshInstructionsOnProfile()
        backendConfiguration.selectedProfileID = csm.codeProfileID
        logger.info("[CODE] Code profile prepared for send (profile ID: \(csm.codeProfileID?.uuidString ?? "nil"))")
    }

    // MARK: - ChatOps Lifecycle (forwards to ChatOpsCoordinator)
    //
    // These entry points are kept on the VM so `ChatOpsSettingsView` (the
    // only external caller) continues to work unchanged. All logic lives in
    // the coordinator — the methods here are one-line forwards.

    func startChatOps()        { chatOpsCoordinator.startTelegram() }
    func stopChatOps()         { chatOpsCoordinator.stopTelegram() }
    func startDiscordChatOps() { chatOpsCoordinator.startDiscord() }
    func stopDiscordChatOps()  { chatOpsCoordinator.stopDiscord() }
    func startSlackChatOps()   { chatOpsCoordinator.startSlack() }
    func stopSlackChatOps()    { chatOpsCoordinator.stopSlack() }

    deinit {
        logger.info("MainApplicationViewModel deinitialized.")
        useStreamingResponseObserver?.cancel()
        intelligenceCoreObserver?.cancel()
        NotificationCenter.default.removeObserver(self)
        // `conversationSwitchCoordinator` owns the former `conversationLoadTask`
        // and observation stream; they unwind via its own deinit.
    }
    
    // MARK: - Settings (forwards to SettingsCoordinator)
    //
    // Load + persist paths live in `SettingsCoordinator`. These forwards are
    // kept so the SwiftUI settings views (GeneralSettings, CoreIntelligence,
    // ChatInput's API key popup) can keep calling `viewModel.didChange...()`
    // / `viewModel.saveAndEnableWebSearch(...)` without refactoring.

    func didChangeUseStreamingResponse() {
        settingsCoordinator.didChangeUseStreamingResponse()
    }

    func didChangeIntelligenceCoreEnabled() {
        settingsCoordinator.didChangeIntelligenceCoreEnabled()
    }

    func toggleWebSearch() {
        settingsCoordinator.toggleWebSearch()
    }

    func saveAndEnableWebSearch(apiKey: String) {
        settingsCoordinator.saveAndEnableWebSearch(apiKey: apiKey)
    }

    func disableAndRemoveWebSearch() {
        settingsCoordinator.disableAndRemoveWebSearch()
    }

    // `loadWorkflowRunHistoryIfNeeded` (was a private helper here) and
    // `setupConversationLoader` (was a ~65-line method) both moved to
    // `ConversationSwitchCoordinator` — the selection-change pipeline lives
    // fully in that coordinator now.

    // MARK: - Message Sending (forwards to MessagingCoordinator)
    //
    // Full implementation lives in `MessagingCoordinator`. Kept here as a
    // forwarding method for API stability — many SwiftUI views call
    // `viewModel.sendMessage(...)` directly via a closure passed down from
    // `MainApplicationView`.

    func sendMessage(attributedString: NSAttributedString, withConfig config: BackendRequestConfig) {
        messagingCoordinator.sendMessage(attributedString: attributedString, withConfig: config)
    }

    // MARK: - Query History Navigation

    /// Appends a query to history without allowing external callers to corrupt
    /// the array. Used by `MessagingCoordinator.sendMessage` (the `private(set)`
    /// on `queryHistory` prevents direct mutation from outside the VM).
    func appendToQueryHistory(_ query: String) {
        queryHistory.append(query)
    }

    func getQueryFromHistory(direction: QueryNavigationDirection) -> String? {
        if queryHistory.isEmpty { return nil }

        if currentHistoryIndex == -1 {
            if direction == .up {
                currentHistoryIndex = queryHistory.count - 1
                return queryHistory[currentHistoryIndex]
            }
            return nil // Can't go down from "new" input state
        }

        if direction == .up {
            if currentHistoryIndex > 0 {
                currentHistoryIndex -= 1
                return queryHistory[currentHistoryIndex]
            }
            return queryHistory[0] // Return the oldest item if already at the top
        } else { // direction == .down
            if currentHistoryIndex < queryHistory.count - 1 {
                currentHistoryIndex += 1
                return queryHistory[currentHistoryIndex]
            } else {
                // Navigated past the most recent query, back to a new input state
                currentHistoryIndex = -1
                return "" // Return empty string to clear the input field
            }
        }
    }

    func resetQueryHistoryIndex() {
        currentHistoryIndex = -1
    }
    
    // MARK: - Response Regeneration / Cancel / HITL / Remote Send
    //
    // All bodies live in `MessagingCoordinator`. These are thin forwards for
    // API stability (multiple SwiftUI views and the three ChatOps bridges
    // call `viewModel.xxx(...)` directly).

    /// Why Redo / Retry is unavailable for `message`, or `nil` if it may run.
    ///
    /// Single source for the button's disabled state AND the runtime refusal — they used to
    /// disagree: the view hardcoded `generationAttempts >= 5` while the coordinator read
    /// `ChatMessage.maxGenerationAttempts`, and nothing at all expressed "a run is already live
    /// here". Reading this from a view body registers on `activeStreams`, so the control
    /// re-enables by itself when the blocking run ends.
    func regenerationRefusal(for message: ChatMessage) -> RunAdmissionPolicy.Refusal? {
        RunAdmissionPolicy.admitRegeneration(
            in: message.conversationId,
            attempts: message.agentResponse?.generationAttempts,
            live: activeStreamManager.liveRunSnapshot()
        )
    }

    /// Why Resume is unavailable for `message`, or `nil` if it may run. Same rule as
    /// `regenerationRefusal` minus the attempt cap — a resume consumes no generation attempt.
    func resumeRefusal(for message: ChatMessage) -> RunAdmissionPolicy.Refusal? {
        RunAdmissionPolicy.admitResume(
            in: message.conversationId,
            live: activeStreamManager.liveRunSnapshot()
        )
    }

    func regenerateResponse(for agentMessage: ChatMessage) {
        messagingCoordinator.regenerateResponse(for: agentMessage)
    }

    /// [G1 Piece 2] Resume a run that was parked on a HITL when the app last closed.
    func resumeRun(for agentMessage: ChatMessage) {
        messagingCoordinator.resumeRun(for: agentMessage)
    }

    func cancelStreamingResponse() {
        messagingCoordinator.cancelStreamingResponse()
    }

    func submitToolApproval(operationID: UUID, approved: Bool, editedArguments: [String: JSONValue]? = nil) {
        messagingCoordinator.submitToolApproval(operationID: operationID, approved: approved, editedArguments: editedArguments)
    }

    func submitClarificationResponse(operationID: UUID, response: String?) {
        messagingCoordinator.submitClarificationResponse(operationID: operationID, response: response)
    }

    func submitPlanReview(operationID: UUID, editedPlan: [SubTask]?) {
        messagingCoordinator.submitPlanReview(operationID: operationID, editedPlan: editedPlan)
    }

    func submitGateChoice(operationID: UUID, option: String) {
        messagingCoordinator.submitGateChoice(operationID: operationID, option: option)
    }

    func submitRemoteMessage(
        prompt: String,
        conversationID: UUID,
        source: MessageSource,
        config: BackendRequestConfig
    ) {
        messagingCoordinator.submitRemoteMessage(
            prompt: prompt,
            conversationID: conversationID,
            source: source,
            config: config
        )
    }

    // MARK: - Chat History Management (forwards to ConversationManagementCoordinator)
    //
    // All bodies live in `ConversationManagementCoordinator`. Kept here as
    // thin forwards because many SwiftUI views (sidebar, welcome, activity
    // bar) plus `MessagingCoordinator` call `viewModel.xxx(...)` directly.

    func toggleUserMessagesFilter() {
        conversationManagementCoordinator.toggleUserMessagesFilter()
    }

    func startNewConversation() {
        conversationManagementCoordinator.startNewConversation()
    }

    func deselectConversationAndShowWelcome() {
        conversationManagementCoordinator.deselectConversationAndShowWelcome()
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        conversationManagementCoordinator.createAndSelectNewConversation()
    }

    /// Persists the backend profile selection on the given conversation.
    /// Visibility: needed by `MessagingCoordinator.sendMessage` at send time
    /// (stays on the VM so the messaging coordinator can reach it via its
    /// own weak VM back-reference without learning about a second coordinator).
    func updateBackendForCurrentConversation(conversationID: UUID, profileID: UUID?) {
        conversationManagementCoordinator.updateBackendForCurrentConversation(
            conversationID: conversationID,
            profileID: profileID
        )
    }

    func transferSelectedConversationToOverlay() {
        conversationManagementCoordinator.transferSelectedConversationToOverlay()
    }

    func togglePinStatus(for conversationId: UUID) {
        conversationManagementCoordinator.togglePinStatus(for: conversationId)
    }

    func deleteConversation(conversationID: UUID) {
        conversationManagementCoordinator.deleteConversation(conversationID: conversationID)
    }

    func deleteMultipleConversations(ids: Set<UUID>) {
        conversationManagementCoordinator.deleteMultipleConversations(ids: ids)
    }

    func renameConversation(conversationID: UUID, newTitle: String) {
        conversationManagementCoordinator.renameConversation(conversationID: conversationID, newTitle: newTitle)
    }

    func exportConversation(conversationID: UUID) {
        conversationManagementCoordinator.exportConversation(conversationID: conversationID)
    }

    func toggleSidebar() { withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() } }
    func toggleContextArea() { withAnimation { showContextArea.toggle() } }
    
    func groupKey(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return self.groupDateFormatter.string(from: date)
    }
    
    @MainActor
    func addAttachedFile(fileItem: FileSystemItem) {
        if !attachedFiles.contains(where: { $0.id == fileItem.id }) {
            attachedFiles.append(fileItem)
        }
    }

    @MainActor
    func addAttachedFiles(fileItems: [FileSystemItem]) {
        for fileItem in fileItems {
            if !attachedFiles.contains(where: { $0.id == fileItem.id }) {
                attachedFiles.append(fileItem)
            }
        }
    }

    @MainActor
    func removeAttachedFile(fileItem: FileSystemItem) {
        attachedFiles.removeAll { $0.id == fileItem.id }
    }
    
    @MainActor
    func removeAttachedFile(byId fileId: URL) {
        attachedFiles.removeAll { $0.id == fileId }
    }

    @MainActor
    func clearAttachedFiles() {
        if !attachedFiles.isEmpty {
            attachedFiles.removeAll()
        }
    }
    
    // MARK: - Scheduler Support (forwards to SchedulerCoordinator)
    //
    // Bodies live in `SchedulerCoordinator`. Kept as forwards because
    // `SchedulerService` and the three ChatOps bridges call these directly
    // on the VM.

    @discardableResult
    func createConversationForScheduledTask(profileID: BackendProfileModel, title: String) -> UUID {
        schedulerCoordinator.createConversationForScheduledTask(profileID: profileID, title: title)
    }

    func sendScheduledMessage(
        prompt: String,
        config: BackendRequestConfig,
        conversationID: UUID,
        attachedFileURLs: [URL]
    ) async -> String {
        await schedulerCoordinator.sendScheduledMessage(
            prompt: prompt,
            config: config,
            conversationID: conversationID,
            attachedFileURLs: attachedFileURLs
        )
    }
}

// MARK: - ChatInputMainDelegate Conformance

extension MainApplicationViewModel: ChatInputMainDelegate { }

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
