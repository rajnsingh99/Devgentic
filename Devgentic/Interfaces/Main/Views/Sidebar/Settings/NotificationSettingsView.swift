// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NotificationSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import UserNotifications

// Why: a section, not a pane: it owns no ScrollView or outer padding, since the host supplies both.
/// The notifications settings, rendered inside `GeneralSettingsView`.
struct NotificationSettingsSection: View {

    @Bindable private var config = NotificationConfiguration.shared
    @Environment(\.appTheme) private var theme

    @State private var testSent = false
    @State private var permissionStatus: UNAuthorizationStatus = .notDetermined
    @State private var testErrorMessage: String? = nil

    /// The registered channels, as values. Empty until the first refresh lands — registration is
    /// asynchronous (`DevgenticApp` and `ChatOpsCoordinator` each register from a detached `Task`),
    /// so an empty card here is a real state and not a bug.
    @State private var channels: [NotificationChannelInfo] = []
    @State private var channelErrorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {

            // Permission Status Banner
            if permissionStatus == .denied {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notifications Disabled in System Settings")
                            .font(theme.fontSubheadline.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Devgentic doesn't have permission to send notifications. Enable them to use this feature.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    TactileButton(
                        title: "Open Settings",
                        icon: "gearshape",
                        variant: .primary,
                        size: .compact
                    ) {
                        openSystemNotificationSettings()
                    }
                }
                .padding(12)
                .background(theme.warningColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.warningColor.opacity(0.3), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Consolidated Notifications Card
            SettingsCard(title: "Notifications", icon: "bell.fill", theme: theme) {
                // Master Toggle
                SettingsRow(
                    title: "Enable Notifications",
                    description: "Receive alerts when queries complete while the app is in the background.",
                    theme: theme
                ) {
                    Toggle("", isOn: $config.isGloballyEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(theme.accentColor)
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                // Channels List
                if !config.isGloballyEnabled {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText.opacity(0.7))
                            .accessibilityHidden(true)
                        Text("Notifications are switched off above, so nothing is delivered on any channel. These switches still record your choice.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                }

                if channels.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "hourglass")
                            .font(theme.fontCallout)
                            .foregroundColor(theme.secondaryText.opacity(0.6))
                            .frame(width: 24, alignment: .center)
                            .accessibilityHidden(true)
                        Text("No delivery channels are registered yet.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                } else {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { index, info in
                        if index > 0 {
                            Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                        }
                        ChannelRow(
                            name: info.displayName,
                            description: description(for: info),
                            icon: icon(for: info),
                            isEnabled: info.isEnabled,
                            showsUnavailableWarning: isUnavailable(info),
                            theme: theme
                        ) {
                            Toggle("", isOn: Binding(
                                get: { info.isEnabled },
                                set: { setChannel(info, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                            .accessibilityLabel(Text(verbatim: info.displayName))
                        }
                    }
                }

                if let channelErrorMessage {
                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(theme.fontCaption2)
                            .accessibilityHidden(true)
                        Text(verbatim: channelErrorMessage)
                            .font(theme.fontCaption2)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                // Test Notification
                SettingsRow(
                    title: "Send Test Notification",
                    description: "Send a mock local alert to verify Devgentic has correctly configured system permissions.",
                    theme: theme
                ) {
                    TactileButton(
                        title: testSent ? "Test Sent!" : "Test",
                        icon: testSent ? "checkmark.circle.fill" : "bell.and.waves.left.and.right",
                        variant: testSent ? .primary : .secondary,
                        size: .compact,
                        isDisabled: permissionStatus == .denied
                    ) {
                        sendTestNotification()
                    }
                }

                if let errorMsg = testErrorMessage {
                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(theme.fontCaption2)
                            .accessibilityHidden(true)
                        Text(errorMsg)
                            .font(theme.fontCaption2)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .task {
            await refreshPermissionStatus()
            await refreshChannels()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check when the user returns from System Settings. Channels are re-read too: registration runs from detached
            // tasks at launch, so a pane opened early can render before the ChatOps channel exists.
            Task {
                await refreshPermissionStatus()
                await refreshChannels()
            }
        }
    }

    private func sendTestNotification() {
        testErrorMessage = nil
        Task {
            let payload = AppNotificationPayload(
                title: "Test Notification",
                body: "Devgentic notifications are working correctly.",
                conversationID: nil
            )
            // Report "Test Sent!" only when something was delivered: with every channel switched off, the test must not claim
            // success.
            let delivered = await NotificationDispatcher.shared.dispatch(payload)
            // `delivered == 0` has two causes (master switch or mute, versus every channel off); an `Int` cannot tell them
            // apart, so the cause is re-derived from the dispatcher's pure policy.
            let masterSwitchAllowedIt = NotificationGatePolicy.shouldDeliver(conversationID: nil)
            await MainActor.run {
                if delivered > 0 {
                    testSent = true
                } else if !masterSwitchAllowedIt {
                    testErrorMessage = "Notifications are switched off — turn on “Enable Notifications” above."
                } else {
                    testErrorMessage = "No channel accepted the test. Check the channel switches above."
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                testSent = false
            }
        }
    }

    // MARK: - Channels

    /// Reads the registry. The dispatcher is an actor and its channels are mutable class instances,
    /// so what crosses back is `NotificationChannelInfo` values — see the type's own warning.
    @MainActor
    private func refreshChannels() async {
        channels = await NotificationDispatcher.shared.channelSnapshots()
    }

    // Why: optimistic write then authoritative re-read, so a rejected change visibly snaps back.
    /// Flips one channel.
    @MainActor
    private func setChannel(_ info: NotificationChannelInfo, enabled: Bool) {
        channelErrorMessage = nil
        if let index = channels.firstIndex(where: { $0.id == info.id }) {
            channels[index] = NotificationChannelInfo(
                id: info.id,
                displayName: info.displayName,
                isEnabled: enabled,
                requiresConfiguration: info.requiresConfiguration
            )
        }
        Task {
            let applied = await NotificationDispatcher.shared.setEnabled(enabled, for: info.id)
            await refreshChannels()
            if !applied {
                channelErrorMessage = "\(info.displayName) is no longer registered — the change was not applied."
            }
        }
    }

    /// Falls back to a generic icon rather than a blank slot, so a channel registered later still gets a row.
    private func icon(for info: NotificationChannelInfo) -> String {
        switch info.id {
        case "local_notification": return "bell.badge"
        case "chatops":            return "paperplane"
        default:                   return "square.grid.2x2"
        }
    }

    private func description(for info: NotificationChannelInfo) -> LocalizedStringKey {
        switch info.id {
        case "local_notification":
            return permissionStatus == .denied
                ? "Permission denied — use Open Settings above"
                : "macOS system notifications"
        case "chatops":
            return "Mirrored to your paired Telegram, Discord and Slack channels"
        default:
            return info.requiresConfiguration
                ? "Needs configuration before it can deliver"
                : "Registered delivery channel"
        }
    }

    /// Only claims a channel cannot deliver where that is known here: local delivery is checkable (system permission),
    /// while ChatOps pairing is not visible from a snapshot, so no warning is guessed from `requiresConfiguration`.
    private func isUnavailable(_ info: NotificationChannelInfo) -> Bool {
        info.id == "local_notification" && permissionStatus == .denied
    }

    @MainActor
    private func refreshPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permissionStatus = settings.authorizationStatus
    }

    private func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Reusable Custom Channel Row with Hover States

// Why: a runtime value as `LocalizedStringKey` looks up a translation by its text and renders the key if none.
/// A settings row for one channel. `name` is a runtime string (a channel's `displayName`) rendered with
/// `Text(verbatim:)`; `description` stays a `LocalizedStringKey` because every value is a literal in this file.
private struct ChannelRow<Control: View>: View {
    let name: String
    let description: LocalizedStringKey
    let icon: String
    let isEnabled: Bool
    let showsUnavailableWarning: Bool
    let theme: any Theme
    @ViewBuilder let control: Control

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(isEnabled ? theme.accentColor : theme.secondaryText.opacity(0.5))
                .frame(width: 24, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text(description)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText.opacity(0.8))
            }

            Spacer()

            if showsUnavailableWarning {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange.opacity(0.8))
                    .font(.system(size: 14))
                    .accessibilityHidden(true)
            }

            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(isHovered ? theme.accentColor.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
