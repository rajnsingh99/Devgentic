// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NotificationGatePolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: avoids awaiting the MainActor config from inside the actor, which would tie background delivery to MainActor.
/// Decides whether a notification should be delivered, as one pure `nonisolated` function shared by
/// `NotificationConfiguration` (@MainActor, the settings pane) and `NotificationDispatcher` (actor, which enforces it).
enum NotificationGatePolicy {

    // MARK: - The decision

    // Why: both read the master switch through `isGloballyEnabled(in:)`, never a cached copy, or the pane and delivery diverge.
    /// The delivery decision shared by `NotificationConfiguration.isNotificationEnabled(for:)` and
    /// `NotificationDispatcher.dispatch(_:)`, so the settings pane and delivery cannot disagree. Pure: no I/O, no isolation.
    static func shouldDeliver(globallyEnabled: Bool, override: Bool?) -> Bool {
        guard globallyEnabled else { return false }
        // After the master guard, never before it: a per-conversation override outranks the default but must not
        // resurrect a notification the user switched off globally.
        if let override { return override }
        return true
    }

    // MARK: - Reading the stored state

    // Why: `bool(forKey:)` returns false for an absent key and would invert the shipped default; check `object(forKey:)` first.
    /// Reads the master switch from `defaults`; an absent key means on, matching `NotificationConfiguration`'s default.
    static func isGloballyEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: AppSettings.notificationsEnabledKey) != nil else { return true }
        return defaults.bool(forKey: AppSettings.notificationsEnabledKey)
    }

    // Why: the only decoder, shared with `NotificationConfiguration.loadOverrides()`, so actor and UI cannot disagree.
    /// The per-conversation overrides in their stored form: JSON `[String: Bool]` keyed by `uuidString`.
    static func decodeOverrides(from defaults: UserDefaults = .standard) -> [UUID: Bool] {
        guard let data = defaults.data(forKey: AppSettings.notificationPerConversationKey),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return [:] }
        return dict.reduce(into: [UUID: Bool]()) { result, pair in
            if let uuid = UUID(uuidString: pair.key) { result[uuid] = pair.value }
        }
    }

    /// The encoder half, so the shape can only ever change in one place.
    static func encodeOverrides(_ overrides: [UUID: Bool]) -> Data? {
        let dict = overrides.reduce(into: [String: Bool]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        return try? JSONEncoder().encode(dict)
    }

    // MARK: - The whole decision, from a defaults store

    /// What `dispatch()` calls. Safe from any isolation domain: `UserDefaults` is thread-safe, and UI writes are synchronous.
    /// The override decode is skipped for a payload with no conversation, so the common path is one `UserDefaults` lookup.
    static func shouldDeliver(conversationID: UUID?, defaults: UserDefaults = .standard) -> Bool {
        let globallyEnabled = isGloballyEnabled(in: defaults)
        guard globallyEnabled else { return false }
        guard let conversationID else { return true }
        return shouldDeliver(
            globallyEnabled: globallyEnabled,
            override: decodeOverrides(from: defaults)[conversationID]
        )
    }
}
