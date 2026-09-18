// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MainApplicationViewModel+ChatOps.swift
//  Devgentic
//
//  The one production conformance to the ChatOps host seam.
//
//  Every member here is a forward to what the three bridges already call today, so adopting the
//  seam changes no behaviour — it only gives the call a name that a test can stand behind. The one
//  member that is more than a forward is `cancelRun`, which bundles a three-step ordering the
//  bridges currently open-code; see its doc comment for why that is a fix and not a refactor.
//
//  ⚠️ This extension is the ONLY place the seam meets the god object. Nothing here may grow logic:
//  if a forward starts making a decision, that decision belongs in `ChatOpsCommandService`, which
//  is testable, rather than here, which is not.
//

import Foundation

// MARK: - RemoteRunControlling

extension MainApplicationViewModel: RemoteRunControlling {

    func hasActiveRun(inConversation conversation: UUID) -> Bool {
        activeStreamManager.hasActiveStream(inConversation: conversation)
    }

    func pendingClarificationID(inConversation conversation: UUID) -> UUID? {
        interactionCenter.items(for: conversation)
            .first { if case .clarification = $0.kind { return true }; return false }?
            .id
    }

    /// [WF-SE10] `hasActiveRun` is read BEFORE the cancel because cancelling destroys the evidence
    /// — the bridges' reply text ("cancelled the active run" vs "no run was active") depends on it.
    /// `ExecutionSuspensionService.cancel` runs after the stream cancel as belt-and-braces for a
    /// parked interaction with no live stream task; after a stream cancel it finds nothing and
    /// no-ops. See `RemoteRunControlling.cancelRun` for why these three steps are one method.
    @discardableResult
    func cancelRun(inConversation conversation: UUID) async -> Bool {
        let hadActiveRun = activeStreamManager.hasActiveStream(inConversation: conversation)
        activeStreamManager.cancelStreams(forConversation: conversation)
        await ExecutionSuspensionService.shared.cancel(for: conversation)
        return hadActiveRun
    }
}

// MARK: - RemoteConversationCommanding

extension MainApplicationViewModel: RemoteConversationCommanding {

    var defaultProfileID: UUID? {
        backendConfiguration.selectedProfileID
    }

    func createConversation(profile: BackendProfileModel, title: String) -> UUID {
        // The existing call labels its parameter `profileID:` while taking a model; the seam
        // corrects the label and this forward absorbs the mismatch.
        createConversationForScheduledTask(profileID: profile, title: title)
    }

    func bindProfile(_ profile: UUID, toConversation conversation: UUID) {
        updateBackendForCurrentConversation(conversationID: conversation, profileID: profile)
    }

    func focusConversationInMainWindow(_ conversation: UUID) {
        selectedConversationID = conversation
    }

    func submitRemote(
        prompt: String,
        conversationID: UUID,
        source: MessageSource,
        config: BackendRequestConfig
    ) {
        submitRemoteMessage(
            prompt: prompt,
            conversationID: conversationID,
            source: source,
            config: config
        )
    }
}
