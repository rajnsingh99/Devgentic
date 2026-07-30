//
//  CodeViewerSessionStore.swift
//  Devgentic
//
//  MIGRATION SHIM — the Code Viewer no longer persists anything.
//
//  Tabs are a view onto content that already lives in the conversation, so they now live in
//  memory for the app session only (`ChatHistoryViewModel.tabsByConversation`). That removed
//  the snapshot types, the debounced save, the 4MB cap and the whole `[CV-SESSION]` layer —
//  see `Docs/codeviewer-rescope-design.md` §6.
//
//  What remains is deliberately a two-step retirement (§9). The entity stays in the schema
//  for ONE release and its rows are purged at launch; the entity is dropped in the release
//  after. Removing it outright would rely on SwiftData silently discarding a removed
//  entity's rows, and that store holds every conversation the user has — "probably fine" is
//  doing too much work next to real user data.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "CodeViewerSessionStore")

// MARK: - SwiftData entity (retiring — see file header)

@Model
final class CodeViewerSessionSD {
    @Attribute(.unique) var conversationId: UUID
    var savedAt: Date
    /// Formerly a JSON-encoded tab session. Nothing writes this any more.
    var payload: Data

    @Relationship
    var conversation: ConversationSD?

    init(conversationId: UUID, savedAt: Date, payload: Data, conversation: ConversationSD?) {
        self.conversationId = conversationId
        self.savedAt = savedAt
        self.payload = payload
        self.conversation = conversation
    }
}

// MARK: - Retirement sweep

@MainActor
final class CodeViewerSessionStore {

    static let shared = CodeViewerSessionStore()
    private init() {}

    private(set) var modelContainer: ModelContainer?

    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    /// Deletes every persisted viewer session, once, at launch.
    ///
    /// Idempotent: after the first run it finds nothing and says nothing. Replaces the old
    /// `reconcileOrphans()` — there is no longer such a thing as a NON-orphan session.
    func purgePersistedSessions() {
        guard let context = modelContainer?.mainContext else {
            logger.error("[CV-SESSION] Purge skipped — container not configured; retired session rows stay on disk.")
            return
        }
        do {
            let rows = try context.fetch(FetchDescriptor<CodeViewerSessionSD>())
            guard !rows.isEmpty else { return }
            let reclaimed = rows.reduce(0) { $0 + $1.payload.count }
            for row in rows { context.delete(row) }
            try context.save()
            logger.info("[CV-SESSION] Purged \(rows.count) retired viewer session(s) (\(reclaimed) bytes) — tabs are in-memory only now.")
        } catch {
            logger.error("[CV-SESSION] Purge failed: \(error.localizedDescription) — retired session rows remain on disk.")
        }
    }
}
