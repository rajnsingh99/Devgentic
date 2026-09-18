// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NotificationGatePolicy.swift
//  Devgentic
//
//  "Should this notification be delivered?", as one pure function two isolation domains share.
//
//  WHY THIS EXISTS. `NotificationDispatcher` is an `actor`; `NotificationConfiguration` is
//  `@Observable @MainActor`. The same question has to be answerable from both — the settings pane
//  reads it to render the switch, and `dispatch()` must ENFORCE it — and the two answers must never
//  disagree. A pure `nonisolated` decision function is how this project already shares policy
//  across isolation domains.
//
//  ⚠️ THE ALTERNATIVE WAS `await NotificationConfiguration.shared.isNotificationEnabled(for:)` FROM
//  INSIDE THE ACTOR: one line, no new type, semantics identical by construction. It was rejected
//  because it makes background notification delivery depend on `@MainActor` availability, and adds
//  a suspension point to an actor that is already reentrant across `channel.send`. Every call site
//  that gates today ALREADY pays one MainActor hop for its `userIsViewing` check; this would have
//  been a second one, on a path whose whole job is to run while the user is away.
//

import Foundation

enum NotificationGatePolicy {

    // MARK: - The decision

    /// ⚠️ ONE implementation, called by BOTH `NotificationConfiguration.isNotificationEnabled(for:)`
    /// and `NotificationDispatcher.dispatch(_:)`. Written twice, the switch would come to mean one
    /// thing to the settings pane and another to delivery.
    ///
    /// ⚠️ THE TWO ALSO READ THE SAME STATE for the master switch: `isGloballyEnabled` is a computed
    /// property over `isGloballyEnabled(in:)` below, not a cached copy. It WAS a cached copy — an
    /// `@ObservationIgnored @AppStorage` on a class — and the pane could report ON while this
    /// function said OFF. The per-conversation overrides are still held in memory by the
    /// configuration object and written through to `UserDefaults` on every mutation, so the two
    /// agree for every write the app makes; only an out-of-band write to that key could separate
    /// them, and nothing does that outside tests.
    ///
    /// Pure: no I/O, no isolation, no defaults store.
    static func shouldDeliver(globallyEnabled: Bool, override: Bool?) -> Bool {
        guard globallyEnabled else { return false }
        // ⚠️ AFTER the master guard, never before it. A per-conversation override outranks the
        // "on unless told otherwise" fallback, but it must not resurrect a notification the user
        // switched off globally.
        if let override { return override }
        return true
    }

    // MARK: - Reading the stored state

    /// ⚠️ ABSENT MEANS ON. `NotificationConfiguration` declares
    /// `@AppStorage(AppSettings.notificationsEnabledKey) var isGloballyEnabled: Bool = true`, so a
    /// fresh install has no stored value and notifications are on. `bool(forKey:)` alone returns
    /// `false` for an absent key, so a naive direct read here would invert the shipped default and
    /// silently switch notifications OFF for every install that had never touched the setting.
    static func isGloballyEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: AppSettings.notificationsEnabledKey) != nil else { return true }
        return defaults.bool(forKey: AppSettings.notificationsEnabledKey)
    }

    /// The per-conversation overrides in their stored form: JSON `[String: Bool]` keyed by
    /// `uuidString`.
    ///
    /// ⚠️ THE ONLY DECODER, shared with `NotificationConfiguration.loadOverrides()`. A second
    /// decoder is how the actor and the UI would come to disagree about a single conversation.
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

    /// What `dispatch()` calls. Safe from any isolation domain: `UserDefaults` is thread-safe, and
    /// a `@AppStorage` write from the UI lands in the same store synchronously, so the actor's read
    /// cannot be stale with respect to a switch the user has already flipped.
    ///
    /// ⚠️ The override decode is skipped entirely for a payload with no conversation — which is
    /// most of them — so the common path is a single `UserDefaults` lookup and no JSON.
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
