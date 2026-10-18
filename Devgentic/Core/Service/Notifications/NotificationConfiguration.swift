// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NotificationConfiguration.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI
import os

private let logger = DGLogger(category: "NotificationConfiguration")

/// UserDefaults-backed configuration for the notification system: global enable, per-channel enable and
/// per-conversation overrides.
@Observable @MainActor
final class NotificationConfiguration {

    static let shared = NotificationConfiguration()

    // Why: `@AppStorage` on a class caches its value and notifies no observer, so a view reading it goes stale.
    /// The master switch, backed directly by `UserDefaults` with observation wired by hand through `access` and
    /// `withMutation`. The getter reads through `NotificationGatePolicy`, the same function the dispatcher uses, so the
    /// pane shows what is enforced.
    var isGloballyEnabled: Bool {
        get {
            access(keyPath: \.isGloballyEnabled)
            return NotificationGatePolicy.isGloballyEnabled(in: .standard)
        }
        set {
            withMutation(keyPath: \.isGloballyEnabled) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.notificationsEnabledKey)
            }
        }
    }

    /// Per-conversation override. `true` = force enabled, `false` = force disabled, absent = use global.
    var perConversationOverrides: [UUID: Bool] = [:] {
        didSet { persistOverrides() }
    }

    private init() {
        loadOverrides()
    }

    /// Checks whether notifications should fire for a given conversation. The UI's read of the decision `dispatch()`
    /// enforces: the rule lives in `NotificationGatePolicy`, this supplies the observed in-memory state.
    func isNotificationEnabled(for conversationID: UUID?) -> Bool {
        NotificationGatePolicy.shouldDeliver(
            globallyEnabled: isGloballyEnabled,
            override: conversationID.flatMap { perConversationOverrides[$0] }
        )
    }

    /// Set or clear a per-conversation override.
    func setOverride(_ enabled: Bool?, for conversationID: UUID) {
        if let enabled = enabled {
            perConversationOverrides[conversationID] = enabled
        } else {
            perConversationOverrides.removeValue(forKey: conversationID)
        }
    }

    // MARK: - Persistence

    // Both halves delegate to the shared codec: `NotificationDispatcher` decodes the same key, so the stored shape has
    // one definition.
    private func persistOverrides() {
        if let data = NotificationGatePolicy.encodeOverrides(perConversationOverrides) {
            UserDefaults.standard.set(data, forKey: AppSettings.notificationPerConversationKey)
        }
    }

    private func loadOverrides() {
        let stored = NotificationGatePolicy.decodeOverrides()
        guard !stored.isEmpty else { return }
        perConversationOverrides = stored
    }
}
