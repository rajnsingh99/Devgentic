//
//  NotificationConfiguration.swift
//  Devgentic
//
//  UserDefaults-backed configuration for the notification system.
//  Tracks global enable, per-channel enable, and per-conversation overrides.
//

import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "NotificationConfiguration")

@Observable @MainActor
final class NotificationConfiguration {

    static let shared = NotificationConfiguration()

    @ObservationIgnored @AppStorage(AppSettings.notificationsEnabledKey) var isGloballyEnabled: Bool = true

    /// Per-conversation override. `true` = force enabled, `false` = force disabled, absent = use global.
    var perConversationOverrides: [UUID: Bool] = [:] {
        didSet { persistOverrides() }
    }

    private init() {
        loadOverrides()
    }

    /// Check whether notifications should fire for a given conversation.
    func isNotificationEnabled(for conversationID: UUID?) -> Bool {
        guard isGloballyEnabled else { return false }

        if let id = conversationID, let override = perConversationOverrides[id] {
            return override
        }

        return true // Default: enabled if global is on and no per-conversation opt-out
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

    private func persistOverrides() {
        let dict = perConversationOverrides.reduce(into: [String: Bool]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: AppSettings.notificationPerConversationKey)
        }
    }

    private func loadOverrides() {
        guard let data = UserDefaults.standard.data(forKey: AppSettings.notificationPerConversationKey),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data) else { return }

        perConversationOverrides = dict.reduce(into: [UUID: Bool]()) { result, pair in
            if let uuid = UUID(uuidString: pair.key) {
                result[uuid] = pair.value
            }
        }
    }
}
