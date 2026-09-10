// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  NotificationService.swift
//  Devgentic
//
//  Extensible notification system using the Strategy Pattern.
//  Defines the protocol, payload, and dispatcher for all notification channels.
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
///
/// ⚠️ THIS TYPE EXISTS BECAUSE `NotificationChannel` MUST NOT LEAVE THE ACTOR. The protocol is
/// `AnyObject` and not `Sendable`, and it has a mutable `isEnabled`. Handing a channel to a
/// `@MainActor` view and binding a `Toggle` to `channel.isEnabled` would race `dispatch()`'s
/// `channels.values.filter { $0.isEnabled }` on the actor's executor — a genuine data race on a
/// class property, which this project's `SWIFT_STRICT_CONCURRENCY = complete` under Swift 5 mode
/// reports only as a WARNING. A snapshot removes the race rather than silencing it.
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

    /// Dispatch a notification to all enabled channels.
    /// Errors from individual channels are logged but do not block other channels.
    ///
    /// - Returns: how many channels actually accepted the payload. Zero is a real outcome, not an
    ///   error: the master switch is off, this conversation is muted, every channel is switched off,
    ///   or every channel threw.
    ///
    /// ⚠️ THE RETURN VALUE EXISTS SO A CALLER CAN STOP LYING. `dispatch` was `Void`, so the
    /// settings pane's "Send Test Notification" button flashed a green "Test Sent!" unconditionally
    /// — and once the pane grew per-channel switches, a user could switch every channel off, press
    /// Test, and be told it was sent. `@discardableResult` keeps every existing fire-and-forget
    /// caller unchanged.
    @discardableResult
    func dispatch(_ payload: AppNotificationPayload) async -> Int {
        // ⚠️ THE MASTER SWITCH IS ENFORCED HERE, AND ONLY HERE. It used to be enforced only where a
        // caller CHOSE to ask — so a call site bypassed the user's preference simply by not asking,
        // which is not a hypothetical: `SchedulerService` fired every scheduled-task completion with
        // notifications switched off, and that is precisely the notification the ChatOps channel
        // forwards to Telegram, Discord and Slack. A rule that every caller must remember is a rule
        // that will be forgotten; a rule inside the one function every notification passes through
        // cannot be. New call sites are covered without knowing this exists.
        //
        // ⚠️ `NotificationGatePolicy` reads UserDefaults rather than hopping to the @MainActor
        // configuration object — see that file for why. The decision RULE is shared with the
        // settings pane, so the two cannot implement different logic.
        //
        // ⚠️ AND THEY READ THE SAME STATE, which is a stronger claim than sharing a rule and was
        // NOT true when this gate was first written. `NotificationConfiguration.isGloballyEnabled`
        // was then an `@ObservationIgnored @AppStorage` declared on a class — a shape whose
        // `DynamicProperty.update()` never runs, so it cached a copy and the pane could report ON
        // while the store said OFF. It is now a computed property reading this same
        // `NotificationGatePolicy` function, so the pane cannot show something other than what is
        // enforced here. `MasterSwitchObservabilityTests` pins both halves of that.
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
    ///
    /// ⚠️ Prefer `channelSnapshots()` from any UI: this hands out non-`Sendable` class references.
    func registeredChannels() -> [any NotificationChannel] {
        Array(channels.values)
    }

    /// The registered channels as values, in a STABLE order.
    ///
    /// ⚠️ `channels` is a dictionary, so `Array(channels.values)` is unordered — rendering it
    /// directly shuffles the settings rows between launches. Local delivery sorts first because it
    /// is the one every install has; the rest sort by name.
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

    /// Toggle the enabled state of a specific channel by ID.
    /// - Returns: whether a channel with that id was actually registered.
    ///
    /// ⚠️ IT USED TO LOG SUCCESS UNCONDITIONALLY while `channels[channelID]?` silently did nothing
    /// for an unregistered id — and registration is asynchronous from two different fire-and-forget
    /// `Task`s, so an early toggle really can miss. A dropped setting that logs "enabled: true" is
    /// the worst of both.
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
