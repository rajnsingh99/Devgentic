//
//  NotificationService.swift
//  Devgentic
//
//  Extensible notification system using the Strategy Pattern.
//  Defines the protocol, payload, and dispatcher for all notification channels.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "NotificationService")

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

    /// Dispatch a notification to all enabled channels.
    /// Errors from individual channels are logged but do not block other channels.
    func dispatch(_ payload: AppNotificationPayload) async {
        let enabledChannels = channels.values.filter { $0.isEnabled }

        guard !enabledChannels.isEmpty else {
            logger.debug("No enabled notification channels — skipping dispatch.")
            return
        }

        logger.info("Dispatching notification '\(payload.title)' to \(enabledChannels.count) channel(s).")

        for channel in enabledChannels {
            do {
                try await channel.send(payload)
                logger.debug("Notification sent via \(channel.channelID).")
            } catch {
                logger.error("Failed to send notification via \(channel.channelID): \(error.localizedDescription)")
            }
        }
    }

    /// Returns all registered channels (for UI display in Settings).
    func registeredChannels() -> [any NotificationChannel] {
        Array(channels.values)
    }

    /// Toggle the enabled state of a specific channel by ID.
    func setEnabled(_ enabled: Bool, for channelID: String) {
        channels[channelID]?.isEnabled = enabled
        logger.info("Channel \(channelID) enabled: \(enabled)")
    }
}
