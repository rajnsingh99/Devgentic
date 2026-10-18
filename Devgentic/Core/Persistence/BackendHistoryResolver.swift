// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendHistoryResolver.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The single definition of "the history the model will actually receive".
/// The request path and the context gauge both use it, so the gauge never sizes the UI's pagination window instead.
enum BackendHistoryResolver {

    /// Upper bound on messages pulled from the store for model context. Downstream still trims
    /// to the model's real budget (`historyCharBudget`, the per-strategy turn limits), so this
    /// only bounds fetch+decode cost on a very long conversation — it is not the context policy.
    static let messageLimit = 300

    // Why: a store-authoritative merge would intermittently drop the user's own question from the request.
    /// Merges stored and in-memory history into one oldest-first list, deduplicated by id.
    /// In-memory wins on conflict, and in-memory-only messages are always kept: the user's message is persisted in a
    /// detached task that races this read, and streaming messages are not in the store while in flight.
    static func merge(stored: [ChatMessage], inMemory: [ChatMessage]) -> [ChatMessage] {
        var byID: [UUID: ChatMessage] = [:]
        for message in stored { byID[message.id] = message }
        for message in inMemory { byID[message.id] = message }
        return byID.values.sorted { $0.timestamp < $1.timestamp }
    }

    // Why: the stored half is decoded off the main actor: up to 300 messages' timelines, 60-125 ms in long Code conversations.
    /// The history a request for `conversationID` would carry, oldest-first.
    /// `inMemory` is merged over the stored set; `omittingImageBytes` is for callers that size rather than send.
    /// Returns the merged history and whether the store cap was hit.
    static func resolve(
        conversationID: UUID,
        inMemory: [ChatMessage],
        persistence: ChatPersistenceProtocol,
        omittingImageBytes: Bool = false
    ) async -> (history: [ChatMessage], storedCount: Int, capHit: Bool) {
        let scoped = inMemory.filter { $0.conversationId == conversationID }
        let stored = await persistence.fetchContextHistory(
            for: conversationID, limit: messageLimit, omittingImageBytes: omittingImageBytes
        )
        return (merge(stored: stored, inMemory: scoped), stored.count, stored.count >= messageLimit)
    }
}
