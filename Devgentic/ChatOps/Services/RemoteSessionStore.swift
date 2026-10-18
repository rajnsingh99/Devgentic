// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteSessionStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The conversation each remote provider is currently pointed at.
@MainActor
final class RemoteSessionStore {

    /// The instance the app runs on. Tests construct their own with an injected suite rather than
    /// touching the developer's real `UserDefaults`.
    static let shared = RemoteSessionStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Cursor

    func activeConversation(for provider: RemoteChannel.Provider) -> UUID? {
        guard let raw = defaults.string(forKey: Self.defaultsKey(for: provider)) else { return nil }
        return UUID(uuidString: raw)
    }

    func setActiveConversation(_ conversationID: UUID?, for provider: RemoteChannel.Provider) {
        defaults.set(conversationID?.uuidString, forKey: Self.defaultsKey(for: provider))
    }

    // MARK: - Keys

    /// The `UserDefaults` key for a provider's cursor. These strings are a compatibility contract with the shipped keys:
    /// changing one loses every existing user's cursor. `nonisolated static` so the mapping is testable with no store and
    /// no defaults.
    nonisolated static func defaultsKey(for provider: RemoteChannel.Provider) -> String {
        switch provider {
        case .telegram: return AppSettings.chatOpsActiveConversationIDKey
        case .discord:  return AppSettings.chatOpsDiscordActiveConversationIDKey
        case .slack:    return AppSettings.chatOpsSlackActiveConversationIDKey
        }
    }
}
