// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationReading.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData

/// Own logger: `ChatPersistenceStore`'s is `private` and therefore file-scoped.
private let logger = DGLogger(category: "ConversationReading")

// MARK: - Row

/// One conversation, projected down to what a list can render. `id` is the `switch:<uuid>` callback payload, `title`
/// the button label, `isEmpty` lets `/new` reuse the conversation, `timestamp` the sort key, and `boundProfileID` the
/// profile a free-text message runs under.
struct ConversationRow: Sendable, Equatable, Identifiable {

    let id: UUID

    /// The display title, derived via `ConversationSD.toRowStruct().displayTitle`, which falls back to the first
    /// non-empty text message. The sidebar's `ConversationSD.displayTitle` extension does not fall back (it shows "New
    /// Conversation"), and the bridges render the former, so this row must too.
    let title: String

    /// The sort key. Rows come back newest-first.
    let timestamp: Date

    /// Whether the conversation has no messages — the `/new` reuse condition.
    let isEmpty: Bool

    /// The profile this conversation runs under (`ConversationSD.backendEntityId`), or nil when it has never been bound.
    /// Consumed by `ChatOpsCommandService.profile(boundTo:)`.
    let boundProfileID: UUID?
}

// MARK: - Message row

/// One message, projected down to what a remote transcript can render. Three fields only (no id, attachments or
/// timeline): `/history` prints who spoke and what they said.
struct ConversationMessageRow: Sendable, Equatable {
    /// Who spoke. A Bool rather than the role enum because the renderer only chooses an icon.
    let isFromUser: Bool
    /// The message, already flattened to text and truncated — see `previewLength`.
    let text: String
    let timestamp: Date

    /// How much of a message a transcript line shows. Truncation happens in the store projection so a large reply never
    /// crosses the seam.
    static let previewLength = 200
}

// MARK: - Search policy

/// Whether one conversation title matches a search query. A shared pure function so tests can pin the real matcher
/// rather than a fake's copy.
enum ConversationSearchPolicy {

    /// Uses `localizedCaseInsensitiveContains`, the same predicate as `ConversationSidebarView`: substring,
    /// case-insensitive, locale-folded, not diacritic-insensitive. An empty query matches nothing, unlike the sidebar's
    /// "show everything" guard.
    nonisolated static func matches(title: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return title.localizedCaseInsensitiveContains(trimmed)
    }
}

// MARK: - Search

/// What a title search found, and whether it looked at everything. `scanWasTruncated` tells the caller a bounded scan
/// stopped early, so "no matches" is not read as "does not exist".
struct ConversationSearchResult: Sendable, Equatable {
    let rows: [ConversationRow]

    /// True when the scan stopped at its bound, so there may be older matches it never saw.
    let scanWasTruncated: Bool
}

// MARK: - Errors

enum ConversationReadError: Error, Equatable {
    /// The SwiftData container has not been configured yet. Distinct from "there are no
    /// conversations", which is an empty array.
    case storeUnavailable
}

// MARK: - Seam

/// Reads the conversation list without a view. Two members, matching the two queries the bridges duplicate; richer
/// queries are added with their feature.
@MainActor
protocol ConversationReading: AnyObject {

    /// Returns the `limit` most recent conversations, newest first, skipping the `offset` newest rows; empty
    /// conversations are included so `/new` can reuse them. `offset` is required, not defaulted. Request one extra row to
    /// detect a next page; there is no count query.
    func conversationRows(limit: Int, offset: Int) throws -> [ConversationRow]

    /// The most recent empty conversation that `/new` can reuse instead of creating another. - Parameter preferred:
    /// checked first and returned when empty, keeping the user in their active conversation. - Returns: nil when there is
    /// nothing to reuse and the caller should create one.
    func reusableEmptyConversationID(preferring preferred: UUID?) throws -> UUID?

    /// Conversations whose displayed title contains `query`, newest first. Filtered in Swift: the title is derived from
    /// the first text message (a JSON blob), which no `#Predicate` can reach. It searches what the user sees, over a
    /// bounded scan (see `ConversationSearchResult.scanWasTruncated`).
    func searchConversations(matching query: String, limit: Int) throws -> ConversationSearchResult

    /// The `limit` most recent messages in a conversation, oldest first; the order is the contract, so the conformance
    /// reverses once here. Not built on `fetchMessages`, which materialises every attached image; it reads only sender
    /// and content, like `fetchSearchDocuments`.
    func recentMessages(inConversation conversationID: UUID, limit: Int) throws -> [ConversationMessageRow]

    /// One conversation by id, or nil when it does not exist. Used by `/status`, which needs the active conversation even
    /// when it is older than the `conversationRows(limit:)` window.
    func conversationRow(id: UUID) throws -> ConversationRow?
}

// MARK: - Conformance

extension ChatPersistenceStore: ConversationReading {

    /// How far back the reuse scan looks. Ten, because that is what all three bridges' slow paths
    /// already use, and because emptiness cannot be tested in the fetch (below) — every row scanned
    /// materialises its `messages` relationship, so this is a real cost and not a free bound.
    static let reusableEmptyScanLimit = 10

    func conversationRows(limit: Int, offset: Int) throws -> [ConversationRow] {
        guard let context = modelContainer?.mainContext else {
            logger.error("[CHATOPS] Conversation list requested before the SwiftData container was configured. CONSEQUENCE: the caller is told the store is unavailable rather than being handed an empty list, so a remote user sees a real error instead of \"no conversations yet\".")
            throw ConversationReadError.storeUnavailable
        }
        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        // `fetchOffset` pages the query itself; dropping rows in Swift would materialise every skipped conversation's
        // messages.
        descriptor.fetchOffset = max(0, offset)
        return try context.fetch(descriptor).map {
            ConversationRow($0, isEmpty: try !ChatPersistenceStore.hasMessages(conversationID: $0.id, in: context))
        }
    }

    /// How many of the newest conversations a search looks at. Cheap per row because `toRowStruct()` skips message work
    /// when `userDefinedTitle` is set; bounded because fallback rows are not free.
    static let searchScanLimit = 200

    func searchConversations(matching query: String, limit: Int) throws -> ConversationSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty query matches nothing: a remote `/search` with no query is a forgotten argument, not a request for the
        // whole list.
        guard !trimmed.isEmpty else { return ConversationSearchResult(rows: [], scanWasTruncated: false) }

        let scanned = try conversationRows(limit: Self.searchScanLimit, offset: 0)
        let matches = scanned.filter { ConversationSearchPolicy.matches(title: $0.title, query: trimmed) }

        return ConversationSearchResult(
            rows: Array(matches.prefix(limit)),
            // Truncation describes the scan, not the results: a full scan window means older conversations were never examined.
            scanWasTruncated: scanned.count == Self.searchScanLimit
        )
    }

    func recentMessages(inConversation conversationID: UUID, limit: Int) throws -> [ConversationMessageRow] {
        guard let context = modelContainer?.mainContext else {
            logger.error("[CHATOPS] Message history requested before the SwiftData container was configured. CONSEQUENCE: the caller is told the store is unavailable rather than being handed an empty transcript, so a remote user sees a real error instead of an empty conversation that has messages in it.")
            throw ConversationReadError.storeUnavailable
        }

        var descriptor = FetchDescriptor<ChatMessageSD>(
            predicate: #Predicate { $0.conversationId == conversationID },
            // Newest first so `fetchLimit` keeps the recent messages; reversed below for display.
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        let rows = try context.fetch(descriptor).map { entity -> ConversationMessageRow in
            let sender = SenderRole(rawValue: entity.senderType) ?? .user
            let content = try? JSONDecoder().decode(MessageContent.self, from: entity.contentData)
            return ConversationMessageRow(
                isFromUser: sender == .user,
                text: Self.preview(of: content),
                timestamp: entity.timestamp
            )
        }
        // The single reverse that restores oldest-first order.
        return rows.reversed()
    }

    /// Flattens a message to one transcript line. No `default:` arm, so a new `MessageContent` case must be considered
    /// here instead of rendering blank.
    private static func preview(of content: MessageContent?) -> String {
        guard let content else { return "⚠️ (unreadable message)" }
        let raw: String
        switch content {
        case .plainText(let text), .markdownText(let text):
            raw = text
        case .codeBlock(_, let code):
            raw = code
        case .error(let title, let details, _, _):
            raw = "⚠️ " + [title, details].compactMap { $0 }.joined(separator: ": ")
        case .mediaArtifact(let artifact):
            raw = "🖼 " + (artifact.label ?? artifact.kind.rawValue)
        case .checkpoint:
            raw = "🗜 (older turns compacted)"
        case .unknown(let type, _):
            raw = "(content this version cannot display: \(type))"
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // A transcript line is one line: newlines would break the field layout on every platform.
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.count > ConversationMessageRow.previewLength
            ? String(trimmed.prefix(ConversationMessageRow.previewLength)) + "…"
            : trimmed
    }

    func conversationRow(id: UUID) throws -> ConversationRow? {
        guard modelContainer?.mainContext != nil else {
            logger.error("[CHATOPS] Single-conversation read requested before the SwiftData container was configured. CONSEQUENCE: the caller is told the store is unavailable rather than being handed nil, so `/status` reports a real error instead of claiming the active conversation does not exist.")
            throw ConversationReadError.storeUnavailable
        }
        // Reuses the shipped single-row lookup rather than a second descriptor — it is already the
        // uncapped, id-keyed query, and duplicating it is how the three bridges ended up with six.
        guard let context = modelContainer?.mainContext, let sd = getConversation(withId: id) else { return nil }
        return ConversationRow(sd, isEmpty: try !ChatPersistenceStore.hasMessages(conversationID: sd.id, in: context))
    }

    func reusableEmptyConversationID(preferring preferred: UUID?) throws -> UUID? {
        guard let context = modelContainer?.mainContext else {
            logger.error("[CHATOPS] Empty-conversation reuse lookup requested before the SwiftData container was configured. CONSEQUENCE: the caller is told the store is unavailable rather than being handed nil, so `/new` reports a real error instead of silently creating a duplicate conversation on every invocation.")
            throw ConversationReadError.storeUnavailable
        }

        // Fast path: the conversation the caller is already in, when it is empty.
        if let preferred,
           getConversation(withId: preferred) != nil,
           try !ChatPersistenceStore.hasMessages(conversationID: preferred, in: context) {
            return preferred
        }

        // Slow path: `messages.isEmpty` is unreliable inside a `#Predicate`, so emptiness is filtered in Swift and the fetch
        // is bounded.
        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.reusableEmptyScanLimit
        return try context.fetch(descriptor).first {
            try !ChatPersistenceStore.hasMessages(conversationID: $0.id, in: context)
        }?.id
    }
}

// MARK: - Projection

extension ConversationRow {

    /// Builds a row from a `ConversationSD`; `toRowStruct()` gives the correct title but sorts and JSON-decodes messages
    /// until it finds the first text message. `isEmpty` is passed in (from `ChatPersistenceStore.hasMessages`) rather
    /// than read from `sd.messages`, which faults the whole relationship.
    init(_ sd: ConversationSD, isEmpty: Bool) {
        self.id = sd.id
        self.title = sd.toRowStruct().displayTitle
        self.timestamp = sd.timestamp
        self.isEmpty = isEmpty
        self.boundProfileID = sd.backendEntityId
    }
}
