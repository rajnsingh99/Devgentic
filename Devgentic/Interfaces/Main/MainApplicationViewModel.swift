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

    var streamingMessageID: UUID? = nil
    var streamingMessage: ChatMessage? = nil

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
        clearAttachedFiles()
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
        return conversationSD.toStruct().displayTitle
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

        // Scheduler / remote-bridge message flow. Must come after
        // messagingCoordinator since it reaches through the VM for the
        // shared `createUserMessage` factory.
        schedulerCoordinator = SchedulerCoordinator(
            viewModel: self,
            persistenceService: persistenceService,
            activeStreamManager: activeStreamManager
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
