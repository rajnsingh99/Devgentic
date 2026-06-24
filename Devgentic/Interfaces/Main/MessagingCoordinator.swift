//
//  MessagingCoordinator.swift
//  Devgentic
//
//  Owns the message-sending pipeline: local sends, remote (ChatOps) submissions,
//  response regeneration, stream cancellation, HITL resolutions, and the shared
//  `createUserMessage` factory. Extracted from `MainApplicationViewModel` as the
//  biggest piece of the Gap C god-object split — before extraction these methods
//  accounted for ~360 of the VM's lines.
//
//  Dependency posture:
//
//  - Services used directly (persistence, streaming, file processing, backend
//    config) are injected explicitly. The coordinator calls them without going
//    through the VM, which keeps intent legible and unit-testable.
//
//  - Shared VM state (interfaceMode, selectedConversationID, attachedFiles,
//    streaming properties, query history, workflow state) still lives on
//    `MainApplicationViewModel`. The coordinator reaches back via a weak
//    reference because moving those state properties into the coordinator
//    would be a bigger refactor (observable-binding churn across views).
//    That's deliberate scope: this pass is about *method* extraction.
//
//  A future pass could lift the stream/workflow state here, at which point
//  the weak back-reference would shrink to just interfaceMode + helpers.
//

import Foundation
import os

@MainActor
final class MessagingCoordinator {

    private let logger = DGLogger(category: "MessagingCoordinator")

    // MARK: - Dependencies

    /// Weak back-reference to the VM for the shared state it still owns
    /// (see file header). Never accessed for anything the coordinator could
    /// do on its own.
    private weak var viewModel: MainApplicationViewModel?

    private let chatHistoryViewModel: ChatHistoryViewModel
    private let activeStreamManager: ActiveStreamManager
    private let persistenceService: ChatPersistenceProtocol
    private let fileProcessorService: FileProcessorService
    private let backendConfiguration: BackendConfiguration

    // MARK: - Init

    init(
        viewModel: MainApplicationViewModel,
        chatHistoryViewModel: ChatHistoryViewModel,
        activeStreamManager: ActiveStreamManager,
        persistenceService: ChatPersistenceProtocol,
        fileProcessorService: FileProcessorService,
        backendConfiguration: BackendConfiguration
    ) {
        self.viewModel = viewModel
        self.chatHistoryViewModel = chatHistoryViewModel
        self.activeStreamManager = activeStreamManager
        self.persistenceService = persistenceService
        self.fileProcessorService = fileProcessorService
        self.backendConfiguration = backendConfiguration
    }

    // MARK: - Message Sending

    func sendMessage(attributedString: NSAttributedString, withConfig config: BackendRequestConfig) {
        let plainUserQueryFromEditor = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !chatHistoryViewModel.isSending else {
            logger.warning("[sendMessage] Message sending already in progress. Ignoring new request.")
            return
        }
        guard let vm = viewModel else {
            logger.warning("[sendMessage] view model deallocated — aborting.")
            return
        }
        guard !plainUserQueryFromEditor.isEmpty || !vm.attachedFiles.isEmpty else {
            return
        }

        // Code mode: refresh instructions (picks up context.md changes) and set selectedProfileID.
        if vm.interfaceMode == .code {
            logger.info("[CODE] ────────── Code mode send initiated ──────────")
            logger.info("[CODE] Query preview: \(String(plainUserQueryFromEditor.prefix(120)))")
            vm.prepareCodeProfileForSend()
        }

        guard let config = backendConfiguration.getRequestConfig() else {
            logger.error("[sendMessage] CRITICAL: Could not get backend request config. Is a profile selected? (interfaceMode: \(vm.interfaceMode.rawValue), selectedProfileID: \(self.backendConfiguration.selectedProfileID?.uuidString ?? "nil"))")
            return
        }

        chatHistoryViewModel.isSending = true
        let profileType: String
        switch config.profile.details {
        case .bot: profileType = "bot"
        case .agent: profileType = "agent"
        case .workflow: profileType = "workflow"
        case .imageGen: profileType = "imageGen"
        case .code: profileType = "code"
        }
        logger.info("[sendMessage] Profile: \(config.profile.displayName) (type: \(profileType), id: \(config.profile.id.uuidString.prefix(8)))")

        // Add to query history
        if !plainUserQueryFromEditor.isEmpty, vm.queryHistory.last != plainUserQueryFromEditor {
            vm.appendToQueryHistory(plainUserQueryFromEditor)
        }
        vm.resetQueryHistoryIndex() // Reset index after sending a new message

        let conversationIDToUse = vm.selectedConversationID ?? vm.createAndSelectNewConversation()

        // Persist the selected profile to the conversation at send time.
        vm.updateBackendForCurrentConversation(conversationID: conversationIDToUse, profileID: backendConfiguration.selectedProfileID)

        // Tag Code mode conversations with profileTypeRaw for sidebar filtering
        if vm.interfaceMode == .code {
            persistenceService.updateProfileType(for: conversationIDToUse, profileTypeRaw: ProfileType.code.rawValue)
        }

        // Auto-title if empty
        if let conversationSD = persistenceService.getConversation(withId: conversationIDToUse) {
            if conversationSD.userDefinedTitle == nil || conversationSD.userDefinedTitle?.isEmpty == true {
                conversationSD.userDefinedTitle = plainUserQueryFromEditor
                logger.info("Auto-setting conversation title to: \(plainUserQueryFromEditor)")
            }
        } else {
            logger.error("[sendMessage] CRITICAL: Could not find conversation for ID: \(conversationIDToUse.uuidString)")
            chatHistoryViewModel.isSending = false
            return
        }

        let filesForBackend = vm.attachedFiles
        vm.clearAttachedFiles()
        logger.debug("Cleared user input and attachments from UI.")

        Task { @MainActor [weak self] in
            guard let self, let vm = self.viewModel else { return }

            let userMessage = await self.createUserMessage(
                conversationID: conversationIDToUse,
                query: plainUserQueryFromEditor,
                files: filesForBackend
            )

            self.chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)
            self.logger.debug("Appended user message into UI.")

            Task { [persistenceService] in
                await persistenceService.addMessage(userMessage, toConversation: conversationIDToUse)
                self.logger.debug("User message persisted successfully.")
            }

            // Prepare workflow execution state if this is a workflow profile.
            //
            // We also insert a `.running` run history record immediately so the
            // run is discoverable from the history list / run picker from frame 1
            // — important for the very first run in a fresh conversation, where
            // there's otherwise no on-disk handle on the in-flight execution.
            // The same `record.id` is upserted with the finalized payload in the
            // `onComplete` block below.
            let workflowState: WorkflowExecutionState? = {
                guard config.profile.profileType == .workflow else { return nil }
                let state = WorkflowExecutionState()
                state.userInput = plainUserQueryFromEditor
                state.workflowProfileID = config.profile.id
                state.startedAt = Date()

                let initialRecord = WorkflowRunRecord(
                    id: UUID(),
                    conversationID: conversationIDToUse,
                    workflowProfileID: config.profile.id,
                    workflowName: config.profile.displayName,
                    timestamp: state.startedAt,
                    userInput: plainUserQueryFromEditor,
                    nodeResults: [],
                    finalOutput: "",
                    variables: [:],
                    status: .running,
                    duration: 0,
                    error: nil
                )
                state.runRecordID = initialRecord.id
                vm.workflowExecutionStates[conversationIDToUse] = state
                vm.workflowRunHistory[conversationIDToUse, default: []].insert(initialRecord, at: 0)
                if vm.workflowRunHistory[conversationIDToUse]!.count > 20 {
                    vm.workflowRunHistory[conversationIDToUse] = Array(vm.workflowRunHistory[conversationIDToUse]!.prefix(20))
                }
                WorkflowRunHistoryStore.shared.upsert(initialRecord, forConversation: conversationIDToUse)
                return state
            }()

            self.logger.info("[sendMessage] Handing off to ActiveStreamManager — conversationID: \(conversationIDToUse.uuidString.prefix(8)), messageID: \(userMessage.id.uuidString.prefix(8)), historyCount: \(self.chatHistoryViewModel.currentChatMessages.count), files: \(filesForBackend.count)")

            let agentMessage = self.activeStreamManager.startMessageStream(
                withConfig: config,
                conversationID: conversationIDToUse,
                userQuery: plainUserQueryFromEditor,
                history: self.chatHistoryViewModel.currentChatMessages.reversed(),
                files: filesForBackend,
                updating: nil,
                workflowExecutionState: workflowState,
                onComplete: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, let vm = self.viewModel else { return }
                        vm.streamingMessageID = nil
                        vm.streamingMessage = nil
                        self.logger.info("Stream completed. Resetting streamingMessageID.")

                        // Finalize the workflow run record. The `.running` row was
                        // already inserted at run start (see above); we reuse the
                        // same `id` so `upsert` rewrites that row in place rather
                        // than creating a duplicate.
                        if let wfState = workflowState, config.profile.profileType == .workflow {
                            let layout = WorkflowLayoutStore.shared.load(for: config.profile.id)
                            let frozen = WorkflowRunRecord.freeze(
                                from: wfState,
                                conversationID: conversationIDToUse,
                                workflowProfileID: config.profile.id,
                                workflowName: config.profile.displayName,
                                userInput: plainUserQueryFromEditor,
                                timestamp: wfState.startedAt,
                                layout: layout
                            )
                            // Stamp the finalized record with the in-flight ID so
                            // the upsert targets the existing row.
                            var record = frozen
                            if let existingID = wfState.runRecordID {
                                record = WorkflowRunRecord(
                                    id: existingID,
                                    conversationID: frozen.conversationID,
                                    workflowProfileID: frozen.workflowProfileID,
                                    workflowName: frozen.workflowName,
                                    timestamp: frozen.timestamp,
                                    userInput: frozen.userInput,
                                    nodeResults: frozen.nodeResults,
                                    finalOutput: frozen.finalOutput,
                                    variables: frozen.variables,
                                    status: frozen.status,
                                    duration: frozen.duration,
                                    error: frozen.error
                                )
                            }

                            // In-memory: replace the matching row if present, else insert.
                            if let idx = vm.workflowRunHistory[conversationIDToUse]?.firstIndex(where: { $0.id == record.id }) {
                                vm.workflowRunHistory[conversationIDToUse]?[idx] = record
                            } else {
                                vm.workflowRunHistory[conversationIDToUse, default: []].insert(record, at: 0)
                                if vm.workflowRunHistory[conversationIDToUse]!.count > 20 {
                                    vm.workflowRunHistory[conversationIDToUse] = Array(vm.workflowRunHistory[conversationIDToUse]!.prefix(20))
                                }
                            }
                            WorkflowRunHistoryStore.shared.upsert(record, forConversation: conversationIDToUse)
                            self.logger.info("Workflow run record finalized: \(record.id) — \(record.status.rawValue)")
                        }
                    }
                }
            )

            vm.streamingMessageID = agentMessage.id
            vm.streamingMessage = agentMessage
            self.chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
            self.logger.debug("Appended agent's streaming message placeholder into UI for real-time updates.")

            await self.chatHistoryViewModel.resetSendingState()
        }
    }

    // MARK: - Response Regeneration

    func regenerateResponse(for agentMessage: ChatMessage) {
        guard let agentResponse = agentMessage.agentResponse, agentResponse.generationAttempts < 5 else {
            logger.warning("Max generation attempts reached for message \(agentMessage.id.uuidString).")
            return
        }
        guard let vm = viewModel else { return }

        guard let agentMessageIndex = chatHistoryViewModel.currentChatMessages.firstIndex(of: agentMessage) else {
            logger.error("Could not find agent message in chat history to regenerate.")
            return
        }

        let historyForRegeneration = Array(chatHistoryViewModel.currentChatMessages.dropFirst(agentMessageIndex + 1).reversed())

        guard let userQueryMessage = chatHistoryViewModel.currentChatMessages[safe: agentMessageIndex + 1],
              userQueryMessage.sender == .user else {
            logger.error("Could not find the preceding user query for regeneration.")
            return
        }
        let userQuery = userQueryMessage.content.textContent ?? ""

        let filesForBackend = (userQueryMessage.attachedTextFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? []) +
                              (userQueryMessage.attachedImageFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? [])

        guard let config = backendConfiguration.getRequestConfig() else {
            logger.error("[regenerateResponse] Could not get backend request config. Is a profile selected?")
            return
        }

        let newVariant = ResponseMessageVariant(
            content: .markdownText(""),
            backendEntityId: config.profile.id
        )
        agentMessage.agentResponse?.variants.append(newVariant)
        agentMessage.agentResponse?.selectedVariantIndex = (agentMessage.agentResponse?.variants.count ?? 1) - 1
        agentMessage.agentResponse?.generationAttempts += 1
        agentMessage.isStreaming = true

        let newStreamingMessage = activeStreamManager.startMessageStream(
            withConfig: config,
            conversationID: agentMessage.conversationId,
            userQuery: userQuery,
            history: historyForRegeneration,
            files: filesForBackend,
            updating: agentMessage,
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, let vm = self.viewModel else { return }
                    vm.streamingMessageID = nil
                    vm.streamingMessage = nil
                    self.logger.info("Regeneration stream completed for message \(agentMessage.id.uuidString).")
                }
            }
        )

        vm.streamingMessageID = newStreamingMessage.id
        vm.streamingMessage = newStreamingMessage
    }

    func cancelStreamingResponse() {
        guard let messageID = viewModel?.streamingMessageID else {
            logger.warning("cancelStreamingResponse called but no streamingMessageID is set.")
            return
        }

        logger.info("User requested to cancel streaming for message: \(messageID.uuidString)")
        activeStreamManager.cancelStream(for: messageID)

        // [HITL/P0] If a HITL banner is up for this conversation, drain the parked suspension
        // immediately so Stop returns at once. The suspend* cancellation handlers cover the
        // task-cancellation path; this also covers a suspension whose owning task isn't the one
        // we just cancelled (defensive, idempotent — resume on a resolved op is a no-op).
        if let conversationID = viewModel?.streamingMessage?.conversationId {
            Task { await ExecutionSuspensionService.shared.cancel(for: conversationID) }
        }
    }

    // MARK: - [HITL] Human-in-the-Loop Permissions

    /// Submits the user's decision (Approve/Deny) for a pending tool execution.
    func submitToolApproval(operationID: UUID, approved: Bool, editedArguments: [String: JSONValue]? = nil) {
        logger.info("[HITL] Submitting approval decision: \(approved) for operation \(operationID)\(editedArguments != nil ? " (edited args)" : "")")
        Task {
            await ExecutionSuspensionService.shared.resume(for: operationID, approved: approved, editedArguments: editedArguments)
        }
    }

    /// Submits the user's text response (or nil for skip) for a pending clarification request.
    func submitClarificationResponse(operationID: UUID, response: String?) {
        logger.info("[ASK_USER] Submitting clarification response for operation \(operationID)")
        Task {
            await ExecutionSuspensionService.shared.resumeClarification(for: operationID, userInput: response)
        }
    }

    /// Submits the user's plan review decision — approved (with edited subtasks) or rejected (nil).
    func submitPlanReview(operationID: UUID, editedPlan: [SubTask]?) {
        logger.info("[PLAN_REVIEW] Submitting plan review for \(operationID), approved: \(editedPlan != nil)")
        Task {
            await ExecutionSuspensionService.shared.resumePlanReview(for: operationID, editedPlan: editedPlan)
        }
    }

    /// [E1] Submits the user's chosen option for a pending workflow Gate — routes to that option's port.
    func submitGateChoice(operationID: UUID, option: String) {
        logger.info("[GATE] Submitting gate choice '\(option)' for operation \(operationID)")
        Task {
            await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: option)
        }
    }

    // MARK: - Remote Message Submission (ChatOps Single-Path)

    /// Submits a message from a remote transport (Telegram, Discord, etc.) through the SAME
    /// flow as the Mac UI's `sendMessage()`. This ensures:
    /// - The message appears in Mac UI chat history
    /// - HITL banners work identically on both surfaces
    /// - The agent response streams through ActiveStreamManager (not a truncated summary)
    ///
    /// The `RemoteMirrorService` observes the resulting stream and mirrors events back to the transport.
    func submitRemoteMessage(
        prompt: String,
        conversationID: UUID,
        source: MessageSource,
        config: BackendRequestConfig
    ) {
        guard let conversationSD = persistenceService.getConversation(withId: conversationID) else {
            logger.error("[ChatOps] Could not find conversation for ID: \(conversationID.uuidString)")
            return
        }
        guard let vm = viewModel else {
            logger.warning("[ChatOps] submitRemoteMessage aborted — view model deallocated.")
            return
        }

        // Auto-title if empty (same as sendMessage)
        if conversationSD.userDefinedTitle == nil || conversationSD.userDefinedTitle?.isEmpty == true {
            conversationSD.userDefinedTitle = prompt
        }

        // Auto-navigate Mac UI to this conversation so the user can see remote activity,
        // HITL banners, and agent responses in real-time. Setting selectedConversationID
        // triggers the conversation loader which loads messages and merges active streams.
        if vm.selectedConversationID != conversationID {
            logger.info("[ChatOps] Auto-navigating Mac UI to conversation \(conversationID.uuidString).")
            vm.selectedConversationID = conversationID
        }

        Task { @MainActor [weak self] in
            guard let self, let vm = self.viewModel else { return }

            let userMessage = await self.createUserMessage(conversationID: conversationID, query: prompt, files: [])
            userMessage.messageSource = source

            // Insert into Mac UI — the conversation is now guaranteed to be selected
            self.chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)

            Task { [persistenceService = self.persistenceService] in
                await persistenceService.addMessage(userMessage, toConversation: conversationID)
            }

            // Fetch history for context (same as sendMessage)
            let history = self.chatHistoryViewModel.currentChatMessages.filter { $0.conversationId == conversationID }.reversed()

            let agentMessage = self.activeStreamManager.startMessageStream(
                withConfig: config,
                conversationID: conversationID,
                userQuery: prompt,
                history: Array(history),
                files: [],
                updating: nil,
                onComplete: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, let vm = self.viewModel else { return }
                        vm.streamingMessageID = nil
                        vm.streamingMessage = nil
                        self.logger.info("[ChatOps] Remote stream completed for conversation \(conversationID).")
                    }
                }
            )

            agentMessage.messageSource = source
            vm.streamingMessageID = agentMessage.id
            vm.streamingMessage = agentMessage

            // Insert agent streaming message into Mac UI
            self.chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
        }
    }

    // MARK: - Message Factory

    /// Builds a `ChatMessage` for the user, classifying attached files into
    /// text (with read-in content) vs. image (with binary data). Internal
    /// rather than private because `MainApplicationViewModel`'s scheduler
    /// path (`sendScheduledMessage`) also needs this factory; that scheduler
    /// code still lives on the VM for now and calls through to here.
    func createUserMessage(conversationID: UUID, query: String, files: [FileSystemItem]) async -> ChatMessage {
        var attachedTextFiles: [AttachedTextFile] = []
        var attachedImageFiles: [AttachedImageFile] = []

        for fileItem in files {
            let mimeType = fileProcessorService.getFileMimeType(for: fileItem.url)
            let fileExtension = fileItem.url.pathExtension
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileItem.url.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

            if fileProcessorService.isTextFile(mimeType: mimeType, url: fileItem.url) {
                if let content = await fileProcessorService.readFileContent(for: fileItem.url) {
                    let textFile = AttachedTextFile(name: fileItem.name, url: fileItem.url, fileExtension: fileExtension, content: content, size: fileSize)
                    attachedTextFiles.append(textFile)
                }
            } else if fileProcessorService.isImageFile(mimeType: mimeType, url: fileItem.url) {
                do {
                    _ = fileItem.url.startAccessingSecurityScopedResource()
                    let data = try Data(contentsOf: fileItem.url)
                    fileItem.url.stopAccessingSecurityScopedResource()
                    let imageFile = AttachedImageFile(name: fileItem.name, url: fileItem.url, fileExtension: fileExtension, binaryData: data, size: fileSize)
                    attachedImageFiles.append(imageFile)
                } catch {
                    logger.error("Could not read image data for file: \(fileItem.name)")
                }
            }
        }

        return ChatMessage(
            conversationId: conversationID,
            sender: .user,
            content: .plainText(query),
            attachedTextFiles: attachedTextFiles.isEmpty ? nil : attachedTextFiles,
            attachedImageFiles: attachedImageFiles.isEmpty ? nil : attachedImageFiles
        )
    }
}
