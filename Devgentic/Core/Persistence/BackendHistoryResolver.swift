//
//  BackendHistoryResolver.swift
//  Devgentic
//
//  The single definition of "the history the model will actually receive".
//
//  There are two consumers and they MUST agree: the request path, which sends it, and the
//  context gauge, which sizes it. They did not. The request has always been
//  store-authoritative; the gauge summed `ChatHistoryViewModel.currentChatMessages`, which is
//  the UI's PAGINATION WINDOW — 20 messages on open, +10 per scroll-back, capped at 300.
//
//  So the ring moved when the user scrolled, while the request did not change, and a freshly
//  opened long conversation under-read its own history by up to 15×. `resolveBackendHistory`
//  had already written the rule down:
//
//      "What the model sees is a context concern; what the list renders is a rendering
//       concern, and the two must not be the same value."
//
//  Sizing the request from the render window broke exactly that rule. One resolver, called by
//  both, is what makes the rule enforceable rather than aspirational.
//

import Foundation

enum BackendHistoryResolver {

    /// Upper bound on messages pulled from the store for model context. Downstream still trims
    /// to the model's real budget (`historyCharBudget`, the per-strategy turn limits), so this
    /// only bounds fetch+decode cost on a very long conversation — it is not the context policy.
    static let messageLimit = 300

    /// Merges stored and in-memory history into one oldest-first list, deduplicated by id.
    ///
    /// In-memory wins on conflict, and in-memory-only messages are ALWAYS kept — that is the
    /// load-bearing property. The user's message is persisted in a detached task that races
    /// this read, and streaming messages are never in the store while in flight, so a
    /// store-authoritative merge would intermittently drop the user's own question from the
    /// request that answers it.
    static func merge(stored: [ChatMessage], inMemory: [ChatMessage]) -> [ChatMessage] {
        var byID: [UUID: ChatMessage] = [:]
        for message in stored { byID[message.id] = message }
        for message in inMemory { byID[message.id] = message }
        return byID.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// The history a request for `conversationID` would carry, OLDEST-FIRST.
    ///
    /// - Parameter inMemory: the caller's live messages (the UI window, or streaming rows not
    ///   yet persisted). Merged OVER the stored set, never replaced by it.
    /// - Returns: the merged history and whether the store cap was hit, so callers can report
    ///   that older turns fell out of direct context and now rely on retrieval.
    static func resolve(
        conversationID: UUID,
        inMemory: [ChatMessage],
        persistence: ChatPersistenceProtocol
    ) async -> (history: [ChatMessage], storedCount: Int, capHit: Bool) {
        let scoped = inMemory.filter { $0.conversationId == conversationID }
        let stored = await persistence.fetchMessages(for: conversationID, offset: 0, limit: messageLimit)
        return (merge(stored: stored, inMemory: scoped), stored.count, stored.count >= messageLimit)
    }
}
