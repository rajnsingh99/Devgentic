// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationManagementCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI
import SwiftData
import os

/// Owns conversation lifecycle: creation (reusing an empty one), selection, pinning, rename, delete (single and bulk),
/// overlay transfer, export and the per-conversation backend-profile mapping.
/// Services are injected; state still owned by `MainApplicationViewModel` is reached through a weak back-reference.
@MainActor
final class ConversationManagementCoordinator {

    private let logger = DGLogger(category: "ConversationManagement")

    /// Weak back-reference to the VM for the shared state it still owns.
    private weak var viewModel: MainApplicationViewModel?

    private let chatHistoryViewModel: ChatHistoryViewModel
    private let persistenceService: ChatPersistenceProtocol
    private let backendConfiguration: BackendConfiguration

    // MARK: - Init

    init(
        viewModel: MainApplicationViewModel,
        chatHistoryViewModel: ChatHistoryViewModel,
        persistenceService: ChatPersistenceProtocol,
        backendConfiguration: BackendConfiguration
    ) {
        self.viewModel = viewModel
        self.chatHistoryViewModel = chatHistoryViewModel
        self.persistenceService = persistenceService
        self.backendConfiguration = backendConfiguration
    }

    // MARK: - Create / Select

    func startNewConversation() {
        guard let vm = viewModel else { return }
        // No attachment clearing here: the composer's per-conversation draft restore clears the box on selection,
        // and clearing before the id changes would lose the attachments of the conversation being left.
        let newConversationID = createAndSelectNewConversation()
        logger.info("Started new conversation with ID \(newConversationID.uuidString).")
    }

    /// Deselect the currently-open conversation and return to the welcome screen.
    func deselectConversationAndShowWelcome() {
        guard let vm = viewModel else { return }
        // The draft restore owns clearing the composer; clearing before the id changes would discard the attachments
        // of the conversation being left.
        vm.selectedConversationID = nil
        backendConfiguration.selectedProfileID = nil
        chatHistoryViewModel.currentChatMessages = []

        if vm.interfaceMode == .code {
            vm.codeSessionManager?.resetSession()
            // Home has no project — the Explorer shows "Select Project folder", not the last one.
            vm.syncExplorerToInterfaceMode()
        }

        logger.info("Deselected conversation, returning to welcome screen.")
    }

    // MARK: - Code projects
    // A Code conversation is bound to one project folder: recorded on its first send, reopened when selected, never changed.
    // A different folder means a different session, since the model's view of the project is spread through the history.

    /// The folder the conversation is bound to, or nil when it has not run yet (or predates the field).
    func recordedProjectPath(of conversationID: UUID?) -> String? {
        guard let conversationID else { return nil }
        return persistenceService.getConversation(withId: conversationID)?.projectPath
    }

    /// Opens `url` in the Code session and the Explorer.
    func openCodeProject(_ url: URL) {
        guard let vm = viewModel else { return }
        // Set the workspace first, before either slot's own publish is queued (see `MCPRootsProvider.setWorkspace`).
        Task { await MCPRootsProvider.setWorkspace(url) }
        vm.codeSessionManager?.updateProjectPath(url)
        vm.syncExplorerToInterfaceMode()
    }

    /// Handles the user picking a folder from the composer or the welcome screen.
    /// Until the session has a message the folder simply follows the pick;
    /// afterwards a different folder starts a new session and the old one keeps its own.
    func chooseCodeFolder(_ url: URL) {
        guard let vm = viewModel else { return }
        let conversationID = vm.selectedConversationID
        let bound = recordedProjectPath(of: conversationID)
        let isEmpty = conversationID.flatMap { persistenceService.getConversation(withId: $0)?.messages.isEmpty } ?? true
        openCodeProject(url)
        if let conversationID, isEmpty, bound.map({ !URL(fileURLWithPath: $0).sameLocationLexically(as: url) }) ?? true {
            persistenceService.updateProjectPath(for: conversationID, projectPath: url.path)
            logger.info("[CODE_PROJECT] Empty session \(conversationID.uuidString) re-pointed to '\(url.lastPathComponent)'\(bound.map { " (was '\(URL(fileURLWithPath: $0).lastPathComponent)')" } ?? "") — it has no messages yet, so the folder is not fixed.")
        } else if let bound, !URL(fileURLWithPath: bound).sameLocationLexically(as: url) {
            logger.info("[CODE_PROJECT] Folder changed to '\(url.lastPathComponent)' while in session \(conversationID?.uuidString ?? "nil") bound to '\(URL(fileURLWithPath: bound).lastPathComponent)'. CONSEQUENCE: a new session starts in the new folder; the old session keeps its own.")
            startNewConversation()
        } else {
            logger.info("[CODE_PROJECT] Folder '\(url.lastPathComponent)' chosen for session \(conversationID?.uuidString ?? "(none — welcome screen)") — \(bound == nil ? "not yet bound; its first send binds it here" : "already bound here").")
        }
    }

    /// The sidebar's per-project "+": a new session in that project.
    func startNewCodeSession(in url: URL) {
        logger.info("[CODE_PROJECT] New session requested in '\(url.lastPathComponent)' from the sidebar.")
        openCodeProject(url)
        startNewConversation()
    }

    /// Called on selection: reopen the selected Code conversation's folder.
    func restoreCodeProjectForSelectedConversation() {
        guard let vm = viewModel, vm.interfaceMode == .code, let conversationID = vm.selectedConversationID else { return }
        guard let manager = vm.codeSessionManager else {
            logger.error("[CODE_PROJECT] Session \(conversationID.uuidString) selected in Code mode with no CodeSessionManager. CONSEQUENCE: its folder is not reopened; a send from it is refused if the open folder differs.")
            return
        }
        let path = recordedProjectPath(of: conversationID)
        if let path, FileManager.default.fileExists(atPath: path),
           manager.projectPath.map({ !$0.sameLocation(as: URL(fileURLWithPath: path)) }) ?? true {
            // Queued before `openProject` queues the Code slot's own publish — see `MCPRootsProvider.setWorkspace`.
            let url = URL(fileURLWithPath: path)
            Task { await MCPRootsProvider.setWorkspace(url) }
        }
        let outcome = manager.openProject(forConversationPath: path)
        logger.info("[CODE_PROJECT] Selected session \(conversationID.uuidString) — bound folder: \(path.map { "'\(URL(fileURLWithPath: $0).lastPathComponent)'" } ?? "none"), outcome: \(String(describing: outcome)).")
        // EVERY outcome, not just `.restored`: on `.alreadyOpen` the Code folder is right but the
        // Explorer may still be showing Chat's folder (the bug fixed here).
        vm.syncExplorerToInterfaceMode()
    }

    /// Returns why a send from the selected Code conversation must not run, or nil when it may.
    /// The one case: the conversation's bound folder is not the open one (it was moved or deleted and could not reopen).
    /// Running anyway would carry that session's work into a different project.
    func codeSendRefusal(openFolder: URL?) -> String? {
        guard let vm = viewModel, vm.interfaceMode == .code,
              let bound = recordedProjectPath(of: vm.selectedConversationID) else { return nil }
        let boundURL = URL(fileURLWithPath: bound)
        if let openFolder, openFolder.sameLocationLexically(as: boundURL) { return nil }
        return String(localized: "This session belongs to “\(boundURL.lastPathComponent)”, which is no longer at \(bound). Start a new session to continue.")
    }

    /// Create (or reuse) an empty conversation and make it the selected one.
    /// Returns the conversation ID. Discardable so callers that only want the
    /// side-effect (UI navigation) can ignore the return value.
    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        guard let vm = viewModel else { return UUID() }

        // Reuse an existing empty conversation if one exists — prevents duplicate empties.
        if let emptyConvID = findReusableEmptyConversation() {
            logger.info("[NewChat] Reusing existing empty conversation \(emptyConvID.uuidString).")
            tagConversationWithCurrentMode(emptyConvID)
            chatHistoryViewModel.currentChatMessages = []
            vm.selectedConversationID = emptyConvID
            return emptyConvID
        }

        let newConversation = Conversation(
            id: UUID(),
            messages: [],
            timestamp: Date(),
            backendEntityId: nil
        )
        persistenceService.addConversation(from: newConversation)
        tagConversationWithCurrentMode(newConversation.id)
        chatHistoryViewModel.currentChatMessages = []
        vm.selectedConversationID = newConversation.id

        return newConversation.id
    }

    /// Tags a new or reused conversation with the current mode's profile type so the matching sidebar lists it at once.
    /// Chat mode is left untagged because chat hosts several profile types and the exact one resolves at send time.
    private func tagConversationWithCurrentMode(_ conversationID: UUID) {
        guard let vm = viewModel else { return }
        switch vm.interfaceMode {
        case .code:
            persistenceService.updateProfileType(for: conversationID, profileTypeRaw: ProfileType.code.rawValue)
            // Bound at creation when a folder is open, so a session started from a project's "+" never lists under "No project".
            // An empty session may still be re-pointed; see `chooseCodeFolder`.
            if let folder = vm.codeSessionManager?.projectPath?.path {
                persistenceService.updateProjectPath(for: conversationID, projectPath: folder)
            } else {
                logger.debug("[CODE_PROJECT] New Code session \(conversationID.uuidString) created with no project selected — its first folder pick or send binds it.")
            }
        case .workflow:
            persistenceService.updateProfileType(for: conversationID, profileTypeRaw: ProfileType.workflow.rawValue)
        case .chat:
            break
        }
    }

    /// Finds the most recent empty conversation (zero messages) that belongs to the current mode and can be reused.
    /// A project's "+" in Code must not claim an empty Chat conversation or another project's empty session.
    private func findReusableEmptyConversation() -> UUID? {
        guard let vm = viewModel,
              let context = ChatPersistenceStore.shared.modelContainer?.mainContext else { return nil }
        // [QA revival P1e] Never repurpose the QuickAccess conversation — it's owned by the
        // panel. (create-on-first-send already means it's rarely empty, but guard the gap.)
        let qaID = UserDefaults.standard.string(forKey: GlobalConstants.quickAccessOverlayConversationId).flatMap(UUID.init)
        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 5
        guard let results = try? context.fetch(descriptor) else { return nil }
        let openFolder = vm.codeSessionManager?.projectPath?.path
        let empties = results.filter { $0.messages.isEmpty && $0.id != qaID }
        let reusable = empties.first {
            Self.isReusableEmptyConversation(profileTypeRaw: $0.profileTypeRaw, projectPath: $0.projectPath,
                                             mode: vm.interfaceMode, openFolder: openFolder)
        }
        if reusable == nil, !empties.isEmpty {
            logger.info("[NewChat] \(empties.count) recent empty conversation(s) belong to another mode or project — creating a new one instead of taking one over.")
        }
        return reusable?.id
    }

    /// Whether an empty conversation may be reused for a new one in `mode`.
    /// Code: an unbound session or one bound to the open folder. Workflow: a workflow one. Chat: the rest.
    nonisolated static func isReusableEmptyConversation(profileTypeRaw: String?, projectPath: String?,
                                                        mode: MainApplicationViewModel.InterfaceMode,
                                                        openFolder: String?) -> Bool {
        let code = ProfileType.code.rawValue, workflow = ProfileType.workflow.rawValue
        switch mode {
        case .code:
            guard profileTypeRaw == code else { return false }
            guard let projectPath else { return true }
            return CodeQuickSettingsStore.normalizedKey(projectPath) == CodeQuickSettingsStore.normalizedKey(openFolder)
        case .workflow:
            return profileTypeRaw == workflow
        case .chat:
            return profileTypeRaw != code && profileTypeRaw != workflow
        }
    }

    // MARK: - Backend Profile Binding

    /// Called when a conversation is newly selected — pulls its persisted
    /// backend profile into `backendConfiguration` so the next send uses it.
    func loadBackendStateForSelectedConversation(conversationID: UUID) {
        guard let conversationSD = persistenceService.getConversation(withId: conversationID) else {
            logger.warning("Could not find conversation \(conversationID.uuidString) to load backend state. Resetting.")
            backendConfiguration.selectedProfileID = nil
            return
        }

        let profileID = conversationSD.backendEntityId
        backendConfiguration.selectedProfileID = profileID

        logger.info("Loaded backend profile ID \(profileID?.uuidString ?? "nil") (type: \(self.viewModel?.selectedProfileType?.rawValue ?? "nil")) for conversation \(conversationID)")
    }

    /// Persists the backend profile selection on the given conversation.
    /// Called at send time by `MessagingCoordinator` (through a VM forward)
    /// and from the scheduler path.
    func updateBackendForCurrentConversation(conversationID: UUID, profileID: UUID?) {
        persistenceService.updateBackendForConversation(
            id: conversationID,
            backendEntityId: profileID
        )
        logger.debug("Persisted profile ID \(profileID?.uuidString ?? "nil") for conversation \(conversationID.uuidString).")
    }

    // MARK: - Overlay Handoff

    /// Transfers the currently-selected conversation to the QuickAccess overlay
    /// window. Clears the Mac UI selection so the two surfaces don't double-own
    /// the same conversation.
    func transferSelectedConversationToOverlay() {
        guard let vm = viewModel else { return }
        guard let conversationID = vm.selectedConversationID else { return }
        // Uses the shared constants rather than literals: AppDelegate creates the panel from
        // `GlobalConstants.quickAccessOverlayConversationId` and observes `GlobalConstants.showQuickAccessPanelNotification`.
        UserDefaults.standard.set(conversationID.uuidString, forKey: GlobalConstants.quickAccessOverlayConversationId)
        NotificationCenter.default.post(
            name: GlobalConstants.showQuickAccessPanelNotification,
            object: nil,
            userInfo: ["forceExpand": true]
        )
        vm.selectedConversationID = nil
    }

    // MARK: - Pin / Delete / Rename

    func togglePinStatus(for conversationId: UUID) {
        logger.debug("Toggling pin status for conversation: \(conversationId.uuidString)")
        persistenceService.togglePinStatus(for: conversationId)
    }

    /// Tears down any live run for a conversation before it is deleted, so a run parked on a HITL does not strand.
    /// Cancelling the stream cascades to the suspension's cancellation handler; the explicit cancel and `resolveAll`
    /// calls make sure the unified queue is cleared even on the remote path.
    private func drainLiveExecution(conversationID: UUID, vm: MainApplicationViewModel) {
        let short = conversationID.uuidString.prefix(8)
        // Each teardown is logged: deleting a conversation with a run in flight is exactly when they are needed.
        vm.activeStreamManager.cancelStreams(forConversation: conversationID)
        vm.interactionCenter.resolveAll(conversationID: conversationID)
        logger.info("[DELETE] \(short) — cancelled in-flight streams and resolved pending interactions.")
        Task {
            await ExecutionSuspensionService.shared.cancel(for: conversationID)
            logger.info("[DELETE] \(short) — released any parked (HITL-suspended) operations.")
        }
        // Drop this conversation's "Allow for this chat" tool grants — the conversation is being
        // deleted, so its durable per-conversation allowlist should go with it.
        Task {
            await SessionToolApprovals.shared.clear(conversationID: conversationID)
            logger.info("[DELETE] \(short) — cleared 'Allow for this chat' tool grants.")
        }
        // Kills background tasks still running for the conversation and removes their log directory.
        // Lives here, not in `deleteConversation`, so both delete paths (single and bulk) share it.
        BackgroundProcessRegistry.shared.discard(conversationID: conversationID)
        logger.info("[DELETE] \(short) — background tasks terminated and their logs removed. CONSEQUENCE: any build or dev server this conversation started is stopped now, rather than running on with no surface left that can list or stop it.")
    }


    /// Clears the ChatOps cursor for a deleted conversation.
    /// A stale cursor makes bridges reply "no agent profile found" forever while `/status` reports no active conversation.
    /// Cleared for every provider whose cursor points here, since several bridges can be bound to one conversation.
    private func forgetRemoteBindings(conversationID: UUID) {
        for provider in RemoteChannel.Provider.allCases
        where RemoteSessionStore.shared.activeConversation(for: provider) == conversationID {
            RemoteSessionStore.shared.setActiveConversation(nil, for: provider)
            logger.info("[DELETE] \(conversationID.uuidString.prefix(8)) — cleared the \(provider.rawValue) ChatOps cursor, which pointed at it. CONSEQUENCE: the next remote message is answered with 'no active conversation' and a prompt to pick one, instead of a misleading 'no agent profile found' repeated indefinitely.")
        }
        // The mirror's session is an address book keyed by conversation; a deleted conversation is never mirrored again,
        // so its session is unregistered.
        guard let vm = viewModel else { return }
        for mirror in [vm.chatOpsBridge?.remoteMirrorService,
                       vm.discordChatOpsBridge?.remoteMirrorService,
                       vm.slackChatOpsBridge?.remoteMirrorService] {
            mirror?.unregisterSession(conversationID: conversationID)
        }
    }

    func deleteConversation(conversationID: UUID) {
        guard let vm = viewModel else { return }
        let short = conversationID.uuidString.prefix(8)
        logger.info("[DELETE] Deleting conversation \(short) — draining live execution first.")
        drainLiveExecution(conversationID: conversationID, vm: vm)
        // Unsent draft text shouldn't outlive the conversation it belonged to.
        ComposerDraftStore.shared.discard(for: conversationID)
        logger.info("[DELETE] \(short) — discarded any unsent composer draft.")
        // A side store keyed by conversation id must not outlive the conversation.
        RemoteConversationOriginStore.forget(conversationID: conversationID)
        forgetRemoteBindings(conversationID: conversationID)
        persistenceService.deleteConversation(with: conversationID)
        // Privacy: delete the conversation's traces too (foreign-key cascades cover spans, events and configs),
        // so raw content does not linger in traces.sqlite; a failure is logged, not swallowed.
        do {
            try TraceStore.shared?.deleteTraces(forConversationID: conversationID.uuidString)
            logger.info("[DELETE] \(short) — traces removed from traces.sqlite (spans/events/configs cascade).")
        } catch {
            logger.error("[DELETE] \(short) — FAILED to delete traces: \(error.localizedDescription). The conversation's raw prompts and responses REMAIN in traces.sqlite.")
        }
        // Also deletes its vector memory (chunks and parents); otherwise the RAG store is append-only and content lingers.
        Task.detached(priority: .utility) {
            VectorStoreService.shared.deleteDocuments(forConversation: conversationID)
        }
        let hadExecState = vm.workflowExecutionStates.removeValue(forKey: conversationID) != nil
        let hadRunHistory = vm.workflowRunHistory.removeValue(forKey: conversationID) != nil
        WorkflowRunHistoryStore.shared.clearHistory(forConversation: conversationID)
        logger.info("[DELETE] \(short) — in-memory workflow state cleared (exec state: \(hadExecState), run history: \(hadRunHistory)). Vector cleanup runs off the main actor and logs separately.")
        if vm.selectedConversationID == conversationID {
            vm.selectedConversationID = nil
        }
        logger.info("[DELETE] \(short) — teardown complete.")
    }

    func deleteMultipleConversations(ids: Set<UUID>) {
        guard !ids.isEmpty, let vm = viewModel else { return }
        logger.info("[DELETE] Bulk delete of \(ids.count) conversation(s) starting.")
        var traceFailures = 0
        for id in ids {
            drainLiveExecution(conversationID: id, vm: vm)
            ComposerDraftStore.shared.discard(for: id)
            RemoteConversationOriginStore.forget(conversationID: id)
            forgetRemoteBindings(conversationID: id)
            persistenceService.deleteConversation(with: id)
            do {
                try TraceStore.shared?.deleteTraces(forConversationID: id.uuidString)
            } catch {
                traceFailures += 1
                logger.error("[DELETE] \(id.uuidString.prefix(8)) — FAILED to delete traces: \(error.localizedDescription). Raw prompts/responses REMAIN in traces.sqlite.")
            }
            Task.detached(priority: .utility) {
                VectorStoreService.shared.deleteDocuments(forConversation: id)
            }
            vm.workflowExecutionStates.removeValue(forKey: id)
            vm.workflowRunHistory.removeValue(forKey: id)
            WorkflowRunHistoryStore.shared.clearHistory(forConversation: id)
        }
        if let currentSelected = vm.selectedConversationID, ids.contains(currentSelected) {
            vm.selectedConversationID = nil
        }
        if traceFailures > 0 {
            logger.error("[DELETE] Bulk delete finished — \(traceFailures) of \(ids.count) conversation(s) left traces behind in traces.sqlite.")
        } else {
            logger.info("[DELETE] Bulk delete finished — \(ids.count) conversation(s) torn down cleanly.")
        }
    }

    /// Renames the conversation and saves the change through the store.
    func renameConversation(conversationID: UUID, newTitle: String) {
        persistenceService.setTitle(newTitle, for: conversationID)
    }

    // MARK: - Export

    func exportConversation(conversationID: UUID) {
        guard let conversationSD = persistenceService.getConversation(withId: conversationID) else {
            logger.warning("Cannot export: conversation \(conversationID.uuidString) not found.")
            return
        }
        let title = conversationSD.toRowStruct().displayTitle

        // The save panel goes up first; the fetch runs only after a file is picked, via the export projection (no image bytes),
        // so a long image-heavy conversation cannot freeze the window before anything is on screen.
        let persistenceService = persistenceService
        let logger = logger
        ConversationExporter.exportToFile(title: title) {
            // The panel is modeless: the conversation can be deleted while it is up. Nil tells
            // the exporter to report that instead of writing a header-only file.
            guard persistenceService.getConversation(withId: conversationID) != nil else {
                logger.warning("[EXPORT] Conversation \(conversationID.uuidString.prefix(8)) no longer exists at save time — export abandoned.")
                return nil
            }
            let limit = 10_000
            let source = await persistenceService.fetchMessagesForExport(for: conversationID, limit: limit)
            // Newest-first, so hitting the cap drops the conversation's earliest turns; the truncation is logged.
            if source.isTruncated {
                logger.warning("[EXPORT] Conversation \(conversationID.uuidString.prefix(8)) exceeds the \(limit)-message export cap — the export carries the most recent \(source.messages.count) and its EARLIEST turns are omitted. CONSEQUENCE: stated in the exported document's header so the file is not silently partial.")
            }
            return source
        }
    }
}
