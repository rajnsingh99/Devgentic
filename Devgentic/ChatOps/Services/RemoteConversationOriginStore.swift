// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteConversationOriginStore.swift
//  Devgentic
//
//  [CF-39] Which ChatOps service created a conversation, recorded at creation instead of guessed
//  from its title afterwards.
//

import Foundation
import os

private let logger = DGLogger(category: "RemoteConversationOrigin")

/// A conversation's remote provenance, persisted so it survives a rename.
///
/// ⚠️ WHY NOT A `ConversationSD` COLUMN, which is what the CF-39 row asked for. Adding a stored
/// property to that entity is a full versioned-schema step: a `DevgenticSchemaV4`, and — per step
/// 5b of `DevgenticSchemaVersions.swift`'s own procedure — NESTED FROZEN COPIES of the changed
/// entity's entire relationship closure, which for `ConversationSD` is `ChatMessageSD` and
/// `WorkflowRunRecordSD` and everything they reach. Getting that wrong crashes EVERY container
/// open with "Duplicate version checksums detected". The value being stored decides one icon and
/// one sentence on an empty conversation's placeholder and is documented as never gating an
/// action, so a migration of that blast radius is not proportionate to it.
///
/// The precedent for conversation-keyed decoration in a side store is
/// `NotificationConfiguration.perConversationOverrides`, whose shape this matches.
///
/// ⚠️ Being a side store, it can hold rows for conversations that were deleted. That is bounded
/// and harmless — a stale row is only ever read by id, so it can never be shown against another
/// conversation — and `forget(conversationID:)` is called on deletion to keep it tidy.
enum RemoteConversationOrigin: String, CaseIterable, Sendable {
    case telegram, discord, slack

    /// How the copy refers to the service. Proper nouns — deliberately not localized.
    var serviceName: String {
        switch self {
        case .telegram: return "Telegram"
        case .discord:  return "Discord"
        case .slack:    return "Slack"
        }
    }

    /// The title the service's bridge stamps on the conversation it creates.
    ///
    /// ⚠️ Retained ONLY as the fallback for conversations created before origins were recorded.
    /// It is a guess: `userDefinedTitle` is user-editable, so a rename drops the hint and naming a
    /// local conversation "Discord Chat" fakes one.
    var bridgeTitle: String {
        switch self {
        case .telegram: return "Telegram Chat"
        case .discord:  return "Discord Chat"
        case .slack:    return "Slack Chat"
        }
    }
}

enum RemoteConversationOriginStore {

    /// Records the service that created `conversationID`. Called by each bridge at creation.
    static func record(_ origin: RemoteConversationOrigin, for conversationID: UUID) {
        var map = load()
        guard map[conversationID.uuidString] != origin.rawValue else { return }
        map[conversationID.uuidString] = origin.rawValue
        save(map)
        logger.info("[CHATOPS] Recorded \(origin.serviceName) as the origin of conversation \(conversationID.uuidString.prefix(8)). CONSEQUENCE: the empty-conversation placeholder names the right service even after the user renames the conversation.")
    }

    /// The recorded origin, or nil when none was recorded (every conversation created before this
    /// existed, and every local one).
    static func origin(for conversationID: UUID) -> RemoteConversationOrigin? {
        load()[conversationID.uuidString].flatMap(RemoteConversationOrigin.init(rawValue:))
    }

    /// Drops a deleted conversation's row.
    static func forget(conversationID: UUID) {
        var map = load()
        guard map.removeValue(forKey: conversationID.uuidString) != nil else { return }
        save(map)
    }

    private static func load() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: AppSettings.remoteConversationOriginsKey) else {
            // ⚠️ NOT AN ERROR. No key means no remote conversation has been created yet, which is
            // the ordinary first-run state — logging it as a failure would cry wolf on every launch.
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            // ⚠️ THIS ONE IS A REAL LOSS, and it read as "no remote conversations exist". The
            // save path already logs its own failure with a consequence; the load path did not,
            // so a corrupted map silently un-labelled EVERY remote conversation at once.
            logger.error("[CHATOPS] Could not decode the remote-origin map (\(data.count) bytes): \(error.localizedDescription). CONSEQUENCE: every conversation created from chat loses its recorded origin at once and falls back to the title heuristic, so conversations named after the user's own first message no longer show as remote anywhere in the UI. The next save overwrites the unreadable data, making this permanent.")
            return [:]
        }
    }

    private static func save(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else {
            logger.error("[CHATOPS] Could not encode the remote-origin map (\(map.count) entries) — it was NOT saved. CONSEQUENCE: those conversations fall back to the title heuristic, so a renamed one shows the generic placeholder.")
            return
        }
        UserDefaults.standard.set(data, forKey: AppSettings.remoteConversationOriginsKey)
    }
}
