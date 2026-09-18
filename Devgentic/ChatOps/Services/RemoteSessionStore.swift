// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteSessionStore.swift
//  Devgentic
//
//  Which conversation a remote channel is pointed at — C4 of the ChatOps remote-interface plan.
//
//  WHY THIS EXISTS. "Which conversation am I in" is currently three hand-written property bodies on
//  `ChatOpsConfigManager` — `activeConversationID`, `discordActiveConversationID`,
//  `slackActiveConversationID` — each independently reading and writing its own `UserDefaults` key,
//  read from 30 call sites across the three bridges. Three copies of one concept is how the concept
//  drifts, and it is the reason nothing outside `ChatOpsConfigManager` can ask the question
//  generically.
//
//  ⚠️ THIS COMMIT DELIBERATELY DOES NOT MIGRATE ANY DATA. The store reads and writes the SAME
//  `AppSettings` keys the properties use today, so an existing user's cursor survives untouched and
//  there is no migration to get wrong. The win here is ONE typed code path, not new storage —
//  `RemoteSessionKeyParityTests` pins the key mapping precisely so that stays true.
//
//  ⚠️ KEYED BY PROVIDER, NOT BY CHANNEL, AND THAT IS A CONSEQUENCE OF THE SINGLE-USER DECISION.
//  A paired channel means exactly one human, so one cursor per provider IS one cursor per session
//  and this preserves today's semantics exactly. If multi-user is ever revisited, the channel
//  dimension is an additive change to this one type instead of an edit to 30 call sites — which is
//  the actual point of collecting them here first.
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

    /// ⚠️ THESE THREE STRINGS ARE THE COMPATIBILITY CONTRACT. They are the keys the shipped
    /// properties already use, so changing one silently loses the cursor of every existing user —
    /// their next `/status` would report no active conversation and `/new` would create a duplicate
    /// instead of reusing the one they were in. `nonisolated static` so the mapping is testable
    /// with no store and no defaults.
    nonisolated static func defaultsKey(for provider: RemoteChannel.Provider) -> String {
        switch provider {
        case .telegram: return AppSettings.chatOpsActiveConversationIDKey
        case .discord:  return AppSettings.chatOpsDiscordActiveConversationIDKey
        case .slack:    return AppSettings.chatOpsSlackActiveConversationIDKey
        }
    }
}
