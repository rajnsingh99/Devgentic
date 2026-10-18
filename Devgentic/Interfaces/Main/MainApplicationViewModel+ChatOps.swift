// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MainApplicationViewModel+ChatOps.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - RemoteRunControlling

/// The production conformance to the ChatOps host seam (`RemoteRunControlling`); each member forwards to existing code.
/// Keep logic out of this extension: decisions belong in `ChatOpsCommandService`, which is testable.
extension MainApplicationViewModel: RemoteRunControlling {

    func hasActiveRun(inConversation conversation: UUID) -> Bool {
        activeStreamManager.hasActiveStream(inConversation: conversation)
    }

    func pendingClarificationID(inConversation conversation: UUID) -> UUID? {
        interactionCenter.items(for: conversation)
            .first { if case .clarification = $0.kind { return true }; return false }?
            .id
    }

    func pendingQuestionNoun(inConversation conversation: UUID) -> String? {
        interactionCenter.current(for: conversation)?.kind.staleNoun
    }

    /// `hasActiveRun` is read before the cancel because cancelling destroys the evidence the bridges' reply text depends on.
    /// `ExecutionSuspensionService.cancel` runs after the stream cancel for a parked interaction with no live stream task;
    /// after a stream cancel it finds nothing and no-ops.
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
