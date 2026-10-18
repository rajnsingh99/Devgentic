// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NotificationService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "NotificationService")

// MARK: - Notification Payload

/// Channel-agnostic payload representing a single notification event.
struct AppNotificationPayload {
    let title: String
    let body: String
    let conversationID: UUID?
    let metadata: [String: String]

    init(title: String, body: String, conversationID: UUID? = nil, metadata: [String: String] = [:]) {
        self.title = title
        self.body = body
        self.conversationID = conversationID
        self.metadata = metadata
    }
}

// MARK: - Channel Snapshot

/// One registered channel, projected to values.
/// `NotificationChannel` is a non-Sendable class with a mutable `isEnabled`; a snapshot keeps it inside
/// the actor and avoids a data race with `dispatch()`.
struct NotificationChannelInfo: Sendable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let isEnabled: Bool
    let requiresConfiguration: Bool
}

// MARK: - Notification Channel Protocol

/// Strategy interface for notification delivery.
/// Conform to this protocol to add new channels (Slack, Discord, Telegram, etc.).
protocol NotificationChannel: AnyObject {
    /// Stable identifier for persistence (e.g., "local_notification", "slack_webhook").
    var channelID: String { get }

    /// Human-readable name shown in Settings UI.
    var displayName: String { get }

    /// Whether this channel is currently enabled by the user.
    var isEnabled: Bool { get set }

    /// Whether the channel requires additional configuration (e.g., webhook URL).
    /// `false` for local notifications, `true` for webhooks.
    var requiresConfiguration: Bool { get }

    /// Deliver a notification through this channel.
    func send(_ payload: AppNotificationPayload) async throws
}

// MARK: - Notification Dispatcher

/// Thread-safe dispatcher that fans out notifications to all registered, enabled channels.
actor NotificationDispatcher {
    static let shared = NotificationDispatcher()

    private var channels: [String: any NotificationChannel] = [:]

    private init() {}

    /// Register a new notification channel.
    func register(_ channel: any NotificationChannel) {
        channels[channel.channelID] = channel
        logger.info("Registered notification channel: \(channel.displayName) (\(channel.channelID))")
    }

    /// Remove a notification channel.
    func unregister(channelID: String) {
        if let removed = channels.removeValue(forKey: channelID) {
            logger.info("Unregistered notification channel: \(removed.displayName)")
        }
    }

    /// Dispatches a notification to all enabled channels; a channel's error does not block others.
    /// - Returns: how many channels accepted it; zero means disabled, muted, all off or all threw.
    @discardableResult
    func dispatch(_ payload: AppNotificationPayload) async -> Int {
        // The master switch is enforced here, in the one function every notification passes through.
        // `NotificationGatePolicy` reads UserDefaults, the same state the settings pane reports.
        guard NotificationGatePolicy.shouldDeliver(conversationID: payload.conversationID) else {
            let conversation = payload.conversationID?.uuidString ?? "app-wide"
            logger.info("[NOTIFY] Suppressed '\(payload.title)' for conversation \(conversation) — notifications are switched off (master switch, or a mute on this conversation). CONSEQUENCE: nothing is delivered on ANY channel, so ChatOps mirroring to Telegram/Discord/Slack stops too. This is the user's setting, not a delivery failure.")
            return 0
        }

        let enabledChannels = channels.values.filter { $0.isEnabled }

        guard !enabledChannels.isEmpty else {
            let conversation = payload.conversationID?.uuidString ?? "app-wide"
            logger.info("[NOTIFY] Not delivered '\(payload.title)' for conversation \(conversation): the master switch is ON but every registered channel is switched off. CONSEQUENCE: the user sees nothing — and this is a DIFFERENT cause from the master switch, which the settings pane distinguishes when it reports a failed test.")
            return 0
        }

        logger.info("Dispatching notification '\(payload.title)' to \(enabledChannels.count) channel(s).")

        var delivered = 0
        for channel in enabledChannels {
            do {
                try await channel.send(payload)
                delivered += 1
                logger.debug("Notification sent via \(channel.channelID).")
            } catch {
                logger.error("Failed to send notification via \(channel.channelID): \(error.localizedDescription). CONSEQUENCE: this channel delivered nothing; other channels are unaffected and the caller sees a lower delivered count.")
            }
        }
        return delivered
    }

    /// Returns all registered channels (for UI display in Settings).
    /// Prefer `channelSnapshots()` from any UI: this hands out non-`Sendable` class references.
    func registeredChannels() -> [any NotificationChannel] {
        Array(channels.values)
    }

    /// The registered channels as values, in a stable order: local delivery first, the rest by name.
    /// `channels` is a dictionary, so unsorted output would shuffle the settings rows between launches.
    func channelSnapshots() -> [NotificationChannelInfo] {
        channels.values
            .map { NotificationChannelInfo(
                id: $0.channelID,
                displayName: $0.displayName,
                isEnabled: $0.isEnabled,
                requiresConfiguration: $0.requiresConfiguration
            ) }
            .sorted { lhs, rhs in
                if lhs.id == "local_notification" { return true }
                if rhs.id == "local_notification" { return false }
                return lhs.displayName < rhs.displayName
            }
    }

    /// Toggles the enabled state of a specific channel by ID.
    /// - Returns: whether a channel with that id was registered. Registration is asynchronous, so an early
    /// toggle can miss.
    @discardableResult
    func setEnabled(_ enabled: Bool, for channelID: String) -> Bool {
        guard channels[channelID] != nil else {
            logger.error("Cannot enable/disable channel \(channelID) — it is not registered. CONSEQUENCE: the user's choice was DROPPED; registration happens asynchronously at launch, so a toggle flipped very early can land before the channel exists.")
            return false
        }
        channels[channelID]?.isEnabled = enabled
        logger.info("Channel \(channelID) enabled: \(enabled)")
        return true
    }
}
