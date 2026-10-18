// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteConversationOriginStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "RemoteConversationOrigin")

// Why: kept out of `ConversationSD`: a new stored property there needs a versioned-schema step with frozen copies of
// its whole relationship closure, and a mistake crashes every container open.
/// A conversation's remote provenance, persisted in a side store so it survives a rename.
/// Rows for deleted conversations are harmless (read only by id); `forget(conversationID:)` removes them on deletion.
enum RemoteConversationOrigin: String, CaseIterable, Sendable {
    case telegram, discord, slack

    /// How the copy refers to the service: proper nouns, not localized.
    var serviceName: String {
        switch self {
        case .telegram: return "Telegram"
        case .discord:  return "Discord"
        case .slack:    return "Slack"
        }
    }

    /// The title the service's bridge stamps on the conversation it creates.
    /// Used only as a fallback when no origin was recorded; it is a guess, since `userDefinedTitle` is user-editable.
    /// A rename drops the hint, and naming a local conversation "Discord Chat" fakes one.
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
            // Not an error: no key means no remote conversation has been created yet, the ordinary first-run state.
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            // A real loss: a corrupted map silently un-labels every remote conversation at once, so the failure is logged
            // with its consequence.
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
