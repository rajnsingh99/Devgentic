// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationSD.swift
//  Devgentic
//
//  Created by Raj Singh on 03/04/26.
//  SwiftData model replacing ConversationEntity (CoreData).
//

import Foundation
import SwiftData

@Model
final class ConversationSD {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var userDefinedTitle: String?
    var isPinned: Bool
    var openAIThreadID: String?
    var backendType: String?
    var backendEntityId: UUID?
    var profileTypeRaw: String?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessageSD.conversation)
    var messages: [ChatMessageSD] = []

    /// Workflow execution runs that happened in this conversation. Cascade-deleted
    /// with the conversation. Matches the `messages` pattern above — the to-many
    /// side declares the inverse keypath and the delete rule.
    @Relationship(deleteRule: .cascade, inverse: \WorkflowRunRecordSD.conversation)
    var workflowRuns: [WorkflowRunRecordSD] = []

    // RETIRED 2026-08-04: `codeViewerSessions`. The Code Viewer no longer persists anything —
    // tabs live in `ChatHistoryViewModel.tabsByConversation` for the app session only — so the
    // relationship and its `CodeViewerSessionSD` destination were both dropped.

    init(id: UUID = UUID(), timestamp: Date = Date(), userDefinedTitle: String? = nil,
         isPinned: Bool = false, openAIThreadID: String? = nil,
         backendType: String? = nil, backendEntityId: UUID? = nil,
         profileTypeRaw: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.userDefinedTitle = userDefinedTitle
        self.isPinned = isPinned
        self.openAIThreadID = openAIThreadID
        self.backendType = backendType
        self.backendEntityId = backendEntityId
        self.profileTypeRaw = profileTypeRaw
    }

    func toStruct() -> Conversation {
        Conversation(
            id: id,
            messages: messages.sorted(by: { $0.timestamp < $1.timestamp }).map { $0.toChatMessage() },
            timestamp: timestamp,
            userDefinedTitle: userDefinedTitle,
            isPinned: isPinned,
            openAIThreadID: openAIThreadID,
            backendType: backendType.flatMap { BackendType(rawValue: $0) },
            backendEntityId: backendEntityId
        )
    }

    /// [P1] Row-weight projection for the sidebar. `toStruct()` maps EVERY message
    /// through `toChatMessage()` — four JSON blob decodes per message — and the
    /// sidebar called it per row, per render, on the MainActor, re-running on every
    /// mid-stream flush (each flush touches `timestamp`, invalidating the @Query).
    /// A row displays five fields; the only one needing message data is the derived
    /// title, which needs at most the FIRST message carrying non-empty text.
    ///
    /// The probe message reuses `Conversation.displayTitle`'s own selection +
    /// truncation logic (one-element `messages`), so row titles can never drift from
    /// the full projection's. `isStreaming` reads false either way — the persisted
    /// column doesn't exist (known P8), so the full decode bought nothing there.
    func toRowStruct() -> Conversation {
        var probe: ChatMessage?
        let hasUserTitle = !(userDefinedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !hasUserTitle {
            for sd in messages.sorted(by: { $0.timestamp < $1.timestamp }) {
                guard let content = try? JSONDecoder().decode(MessageContent.self, from: sd.contentData) else { continue }
                switch content {
                case .plainText(let text), .markdownText(let text):
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    probe = ChatMessage(
                        conversationId: id,
                        timestamp: sd.timestamp,
                        sender: SenderRole(rawValue: sd.senderType) ?? .user,
                        content: content
                    )
                default:
                    continue
                }
                break
            }
        }
        return Conversation(
            id: id,
            messages: probe.map { [$0] } ?? [],
            timestamp: timestamp,
            userDefinedTitle: userDefinedTitle,
            isPinned: isPinned,
            openAIThreadID: openAIThreadID,
            backendType: backendType.flatMap { BackendType(rawValue: $0) },
            backendEntityId: backendEntityId
        )
    }
}
