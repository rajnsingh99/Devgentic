// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationReading.swift
//  Devgentic
//
//  The conversation LIST read, as a seam — C1 of the ChatOps remote-interface plan.
//
//  WHY THIS EXISTS. There is no `fetchConversations` anywhere in this app. The sidebar's list, its
//  interface-mode filter, its date grouping and its title search are SwiftUI-private inside
//  `ConversationSidebarView`, so nothing outside a view can ask "what conversations are there?".
//  All three ChatOps bridges consequently roll their own identical `FetchDescriptor`
//  (`ChatOpsBridge.swift:454`, `DiscordChatOpsBridge.swift:604`, `SlackChatOpsBridge.swift:498`),
//  as does each bridge's `findReusableEmptyConversation`. Six copies of two queries.
//
//  ⚠️ WHY A SEPARATE PROTOCOL RATHER THAN TWO MORE MEMBERS ON `ChatPersistenceProtocol`.
//  Thirty test files conform to `ChatPersistenceProtocol`. Adding requirements there means either
//  breaking all thirty or defaulting them in an extension — and the defaulted extension is exactly
//  the landmine this file exists to avoid. `recentConversations(limit:)` returns `[]` when the
//  container is absent, so "the store never came up" and "the user has no history" are the same
//  answer; its own comment says so. On THIS surface that collapse is worse, because an empty list
//  is what a remote user is shown when they ask what they can reach.
//
//  ⚠️ SO BOTH MEMBERS THROW. Not for ceremony: `[]` and "I could not read" are different facts and
//  the caller renders them differently — "No conversations yet. Use /new to create one." is a lie
//  when the truth is that SwiftData is down. Today the bridges write `(try? context.fetch(d)) ?? []`
//  and tell that lie. Making the type carry the difference is what lets C5 stop telling it.
//
//  ⚠️ WHAT IS DELIBERATELY NOT ON THE ROW: pin state, message count, interface mode, search. Every
//  one is cheap and every one is tempting, and none has a reader. A field with no reader is how dead
//  vocabulary accumulates. Add each when the feature that reads it arrives, not before —
//  `boundProfileID` is the worked example: held back when this type was written, added at C9 the
//  moment `profile(boundTo:)` needed it.
//

import Foundation
import SwiftData

/// Own logger: `ChatPersistenceStore`'s is `private` and therefore file-scoped.
private let logger = DGLogger(category: "ConversationReading")

// MARK: - Row

/// One conversation, projected down to what a list can render.
///
/// Five fields, each with a caller: `id` becomes the `switch:<uuid>` callback payload, `title` the
/// button label, `isEmpty` decides whether `/new` reuses this conversation instead of creating one,
/// `timestamp` is the sort key — exposed so the ordering contract is testable rather than implied by
/// the query — and `boundProfileID` names the profile a free-text message will run under.
struct ConversationRow: Sendable, Equatable, Identifiable {

    let id: UUID

    /// ⚠️ DERIVED, via `ConversationSD.toRowStruct().displayTitle` — NOT the `ConversationSD.displayTitle`
    /// extension. There are two `displayTitle`s in this app and they disagree:
    ///
    ///   - `ConversationSD.displayTitle` (`ConversationSidebarView.swift:22`) is `userDefinedTitle`
    ///     or the literal `"New Conversation"`. No first-message fallback.
    ///   - `Conversation.displayTitle` (`ConversationModel.swift:87`), reached through
    ///     `toRowStruct()`, falls back to the first non-empty text message.
    ///
    /// The bridges render the SECOND (`conversationSD.toRowStruct().displayTitle`), so this row
    /// must too or every untitled conversation silently becomes "New Conversation" in the remote
    /// list. `recentConversations(limit:)` picks the first and documents the divergence as a
    /// known product call for the QuickAccess menu; that call does not transfer here.
    let title: String

    /// The sort key. Rows come back newest-first.
    let timestamp: Date

    /// Whether the conversation has no messages — the `/new` reuse condition.
    let isEmpty: Bool

    /// The profile this conversation runs under (`ConversationSD.backendEntityId`), or nil when it
    /// has never been bound.
    ///
    /// ⚠️ ADDED AT C9 WITH ITS READER, exactly as C1's header said such fields should be. It was
    /// deliberately left off the row when the type was written, because nothing then consumed it;
    /// `ChatOpsCommandService.profile(boundTo:)` is that consumer.
    let boundProfileID: UUID?
}

// MARK: - Message row

/// One message, projected down to what a remote transcript can render.
///
/// ⚠️ THREE FIELDS, EACH WITH A READER, following this file's own rule. No id, no attachments, no
/// timeline: `/history` prints who spoke and what they said.
struct ConversationMessageRow: Sendable, Equatable {
    /// Who spoke. A Bool rather than the role enum because the renderer only chooses an icon.
    let isFromUser: Bool
    /// The message, already flattened to text and truncated — see `previewLength`.
    let text: String
    let timestamp: Date

    /// How much of a message a transcript line shows.
    ///
    /// ⚠️ 200, and the truncation happens in the STORE projection rather than the renderer, so a
    /// 40 KB agent reply never crosses the seam just to be cut down afterwards.
    static let previewLength = 200
}

// MARK: - Search policy

/// Whether one conversation title matches a search query.
///
/// ⚠️ EXTRACTED BECAUSE A TEST FAKE HAD ITS OWN COPY. The service-level search tests run against a
/// `ConversationReading` fake, and that fake reimplemented this predicate — so a mutation making the
/// REAL matcher case-sensitive left every one of them green. A shared pure function is the only
/// version of this that a test can actually pin.
enum ConversationSearchPolicy {

    /// ⚠️ `localizedCaseInsensitiveContains` — the exact predicate `ConversationSidebarView` uses, so
    /// the remote search and the app's own search agree. Substring, case-insensitive, locale-folded,
    /// and NOT diacritic-insensitive: "cafe" does not find "café". `localizedStandardContains` would
    /// fold diacritics too, and changing that is a product decision about both surfaces at once, not
    /// something to do quietly on one of them.
    ///
    /// ⚠️ AN EMPTY QUERY MATCHES NOTHING. `localizedCaseInsensitiveContains("")` is already false;
    /// this states it, because the sidebar's `!searchText.isEmpty` guard means the opposite there
    /// ("show everything") and the difference is easy to import by accident.
    nonisolated static func matches(title: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return title.localizedCaseInsensitiveContains(trimmed)
    }
}

// MARK: - Search

/// What a title search found, and whether it looked at everything.
///
/// ⚠️ `scanWasTruncated` EXISTS BECAUSE "NO MATCHES" IS THE MOST DANGEROUS ANSWER THIS APP GIVES.
/// A remote user reads it as "that conversation does not exist" and acts on it — by starting a new
/// one, or by giving up. A bounded scan that says nothing about its bound turns "I looked at the
/// newest 200" into that claim, silently and with no error. This is the same reasoning that made
/// `ConversationReading`'s members throw rather than collapse a dead store into an empty list.
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

/// Reading the conversation list without a view.
///
/// Two members, matching the two queries the bridges duplicate. Anything richer — search, paging,
/// mode filtering — is a new member added with its feature, not reserved here.
@MainActor
protocol ConversationReading: AnyObject {

    /// The `limit` most recent conversations, newest first.
    ///
    /// ⚠️ EMPTY CONVERSATIONS ARE INCLUDED, deliberately. `recentConversations(limit:)` drops them
    /// because a recents MENU should not offer a blank row; the ChatOps list does not, because
    /// `/new` reuses an empty conversation and the user must be able to see and switch to the one
    /// they are about to reuse. Preserves `fetchRecentConversations(limit:)` in all three bridges.
    /// - Parameter offset: how many of the newest rows to skip. Zero is the first page.
    ///
    /// ⚠️ `offset` IS REQUIRED, NOT DEFAULTED. A defaulted paging parameter is how a caller silently
    /// keeps reading page one forever while looking like it pages — the same shape as the defaulted
    /// argument this repo has already watched revert a feature at its one call site.
    ///
    /// ⚠️ ASK FOR ONE MORE ROW THAN YOU INTEND TO SHOW. There is deliberately no count query: every
    /// row materialises its `messages` relationship and derives a title, so counting the table to
    /// learn whether a "Next" button belongs costs more than the page itself. One extra row answers
    /// the same question for the price of one row.
    func conversationRows(limit: Int, offset: Int) throws -> [ConversationRow]

    /// The most recent empty conversation that `/new` can reuse instead of creating another.
    ///
    /// - Parameter preferred: checked first, and returned when it is itself empty. This is the
    ///   caller's currently-active conversation: reusing it keeps the remote user where they are
    ///   instead of silently moving them to some older empty conversation.
    /// - Returns: nil when there is nothing to reuse, meaning the caller should create one.
    func reusableEmptyConversationID(preferring preferred: UUID?) throws -> UUID?

    /// Conversations whose DISPLAYED title contains `query`, newest first.
    ///
    /// ⚠️ FILTERED IN SWIFT, NOT IN A PREDICATE, and the reason is specific rather than habitual.
    /// `ConversationRow.title` is derived: `userDefinedTitle` when set, otherwise the first non-empty
    /// text message, markdown-stripped and cut to 30 characters. That fallback decodes
    /// `ChatMessageSD.contentData`, a JSON blob — SQLite sees bytes, so no `#Predicate` can reach it.
    /// A predicate on `userDefinedTitle` would cover most rows (every send path auto-titles) but
    /// would silently miss any row still falling back, and would match text the user cannot see.
    ///
    /// ⚠️ IT SEARCHES WHAT THE USER SEES, which is not the whole conversation. For an untitled row
    /// that is a 30-character preview, so a word further into the first message will not be found.
    /// That is inherited from `Conversation.displayTitle`, and matching it is deliberate: a search
    /// that returns rows whose rendered label does not contain the query reads as a bug.
    ///
    /// ⚠️ THE SCAN IS BOUNDED and says so — see `ConversationSearchResult.scanWasTruncated`.
    func searchConversations(matching query: String, limit: Int) throws -> ConversationSearchResult

    /// The `limit` most recent messages in a conversation, OLDEST FIRST.
    ///
    /// ⚠️⚠️ OLDEST FIRST, AND THE ORDER IS THE CONTRACT. `ChatPersistenceStore.fetchMessages` sorts
    /// `.reverse` — newest first — and shipping that order to a reader is invariant 8's exact
    /// failure, the one that mispaired every scheduled run's history for a release. A transcript
    /// printed newest-first reads as a conversation happening backwards, and nothing about it looks
    /// like an error. The conformance reverses ONCE, here, so no caller has to remember.
    ///
    /// ⚠️ NOT BUILT ON `fetchMessages`. That runs `toChatMessage()` per row, which this codebase
    /// documents as decoding the timeline and token blobs and materialising EVERY attached image's
    /// full `binaryData` — for text that is about to be cut to 200 characters. This reads the same
    /// columns `fetchSearchDocuments` does: sender and content blob, nothing else.
    func recentMessages(inConversation conversationID: UUID, limit: Int) throws -> [ConversationMessageRow]

    /// One conversation by id, or nil when it does not exist.
    ///
    /// ⚠️ ADDED AT C5a WITH ITS READER, not reserved. `/status` shows the ACTIVE conversation's
    /// title, and it cannot come from `conversationRows(limit:)` — a conversation older than that
    /// window would silently render as "None". `ChatPersistenceProtocol.getConversation(withId:)`
    /// answers the same question, but taking it would force `ChatOpsCommandService` to depend on a
    /// 14-member protocol with thirty existing conformers instead of this three-member one.
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
        // ⚠️ `fetchOffset` PAGES THE QUERY, not the results. Fetching everything and dropping the
        // first `offset` rows in Swift would materialise every skipped conversation's messages and
        // derive every skipped title — precisely the cost `ConversationRow.init` warns about.
        descriptor.fetchOffset = max(0, offset)
        return try context.fetch(descriptor).map(ConversationRow.init(_:))
    }

    /// How many of the newest conversations a search looks at.
    ///
    /// ⚠️ 200, and the number is affordable for a specific reason: `ConversationSD.toRowStruct()`
    /// skips all message work when `userDefinedTitle` is set, and every path that puts a message
    /// into a conversation sets it. So the common row costs a column read, not a JSON decode of its
    /// messages. It is bounded anyway because the fallback rows are not free, and because an
    /// unbounded scan over a long history is a stall the user experiences as a dead bot.
    static let searchScanLimit = 200

    func searchConversations(matching query: String, limit: Int) throws -> ConversationSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // ⚠️ AN EMPTY QUERY MATCHES NOTHING, deliberately. `localizedCaseInsensitiveContains("")` is
        // false, so the shipped sidebar guards on `!searchText.isEmpty` to mean "show everything" —
        // but a remote `/search` with no query is a user who forgot the query, and answering it with
        // the entire conversation list would look like the search silently ignored them.
        guard !trimmed.isEmpty else { return ConversationSearchResult(rows: [], scanWasTruncated: false) }

        let scanned = try conversationRows(limit: Self.searchScanLimit, offset: 0)
        let matches = scanned.filter { ConversationSearchPolicy.matches(title: $0.title, query: trimmed) }

        return ConversationSearchResult(
            rows: Array(matches.prefix(limit)),
            // ⚠️ Truncation is about the SCAN, not the results. A full scan window means older
            // conversations exist that were never examined, whether or not this page is full.
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
            // ⚠️ NEWEST FIRST so `fetchLimit` keeps the RECENT messages; reversed below for display.
            // Sorting ascending here would cap the transcript at the conversation's OLDEST turns.
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
        // ⚠️ THE ONE REVERSE. See the protocol's note on invariant 8.
        return rows.reversed()
    }

    /// Flattens a message to one transcript line.
    ///
    /// ⚠️ NO `default:` ARM. A `MessageContent` case added later must be considered here rather than
    /// silently rendering as blank — the same rule the ChatOps mirror's content switch now follows
    /// after `.error` spent a release being reported to remote users as "Response complete."
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
        return getConversation(withId: id).map(ConversationRow.init(_:))
    }

    func reusableEmptyConversationID(preferring preferred: UUID?) throws -> UUID? {
        guard let context = modelContainer?.mainContext else {
            logger.error("[CHATOPS] Empty-conversation reuse lookup requested before the SwiftData container was configured. CONSEQUENCE: the caller is told the store is unavailable rather than being handed nil, so `/new` reports a real error instead of silently creating a duplicate conversation on every invocation.")
            throw ConversationReadError.storeUnavailable
        }

        // Fast path: the conversation the caller is already in, when it is empty.
        if let preferred,
           let active = getConversation(withId: preferred),
           active.messages.isEmpty {
            return preferred
        }

        // Slow path. ⚠️ `messages.isEmpty` is NOT reliable inside a `#Predicate` — the same
        // constraint `recentConversations(limit:)` documents — so emptiness is filtered in Swift
        // and the fetch is bounded instead.
        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.reusableEmptyScanLimit
        return try context.fetch(descriptor).first { $0.messages.isEmpty }?.id
    }
}

// MARK: - Projection

extension ConversationRow {

    /// ⚠️ `toRowStruct()` is what makes the title correct, and it is not free: with no
    /// `userDefinedTitle` it sorts `messages` and JSON-decodes `contentData` until it finds the
    /// first non-empty text message. It stops at that first hit, and it skips the scan entirely
    /// when a user title exists. This is the cost the bridges already pay per row today.
    init(_ sd: ConversationSD) {
        self.id = sd.id
        self.title = sd.toRowStruct().displayTitle
        self.timestamp = sd.timestamp
        self.isEmpty = sd.messages.isEmpty
        self.boundProfileID = sd.backendEntityId
    }
}
