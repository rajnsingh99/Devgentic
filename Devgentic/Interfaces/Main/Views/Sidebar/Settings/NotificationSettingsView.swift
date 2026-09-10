// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  NotificationSettingsView.swift
//  Devgentic
//
//  Settings panel for configuring the notification system.
//

import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {

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
        ScrollView {
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
                                .font(.system(.caption))
                                .foregroundColor(theme.secondaryText)
                        }
                        Spacer()
                        Button("Open Settings") {
                            openSystemNotificationSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(theme.warningColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.warningColor.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Master Toggle
                SettingsCard(title: "Notifications", icon: "bell.fill", theme: theme) {
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
                }

                // Channels
                //
                // ⚠️ THIS CARD USED TO BE FOUR HARDCODED ROWS — "Local Notification" plus Slack,
                // Discord and Telegram marked "Coming soon" — and it never asked the dispatcher
                // anything. Both halves of that were wrong by the time it was read: the ChatOps
                // channel (Telegram, Discord AND Slack) is registered and delivering, so the pane
                // advertised as unbuilt something that already worked, and offered no way to turn
                // it on or off. The rows now come from the registry, so a channel registered later
                // appears here without this file changing.
                SettingsCard(title: "Channels", icon: "square.grid.2x2.fill", theme: theme) {
                    // ⚠️ A NOTICE, NOT A DISABLED STATE. These switches used to grey out when the
                    // master switch was off, which said the same thing but also took the controls
                    // away. This re-renders correctly only because `isGloballyEnabled` is now an
                    // observed property — as an `@ObservationIgnored @AppStorage` it would have
                    // rendered once and then gone stale, which is why the old code could not have
                    // used a conditional here.
                    if !config.isGloballyEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText.opacity(0.7))
                                .accessibilityHidden(true)
                            Text("Notifications are switched off above, so nothing is delivered on any channel. These switches still record your choice.")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    if channels.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "hourglass")
                                .font(.system(size: 14))
                                .foregroundColor(theme.secondaryText.opacity(0.6))
                                .frame(width: 24, alignment: .center)
                                .accessibilityHidden(true)
                            Text("No delivery channels are registered yet.")
                                .font(.system(size: 12))
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
                                // ⚠️ NOT `.disabled(!config.isGloballyEnabled)`, which is what this
                                // was. It trapped the user: switching the master off greyed out
                                // every channel switch, so no combination of controls gave ChatOps
                                // mirroring without desktop banners, and a channel could not be
                                // pre-configured before switching notifications on. Delivery is
                                // enforced in `dispatch()`; this pane records intent, and recording
                                // intent while the master switch is off is fine — the notice at the
                                // top of this card says so plainly instead of greying things out.
                                .accessibilityLabel(Text(verbatim: info.displayName))
                            }
                        }
                    }

                    if let channelErrorMessage {
                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(.caption))
                                .accessibilityHidden(true)
                            Text(verbatim: channelErrorMessage)
                                .font(.system(.caption))
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }

                // Test Notification
                SettingsCard(title: "Test Alert", icon: "hammer.fill", theme: theme) {
                    SettingsRow(
                        title: "Send Test Notification",
                        description: "Send a mock local alert to verify Devgentic has correctly configured system permissions.",
                        theme: theme
                    ) {
                        Button {
                            sendTestNotification()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: testSent ? "checkmark.circle.fill" : "bell.and.waves.left.and.right")
                                    .foregroundColor(testSent ? .green : theme.accentColor)
                                Text(testSent ? "Test Sent!" : "Test")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        // ⚠️ DELIBERATELY NOT `.disabled(!config.isGloballyEnabled ...)`. A
                        // diagnostic control that refuses to run cannot diagnose: greying this out
                        // when notifications are off tells the user nothing they did not already
                        // know, while running it and naming the real cause tells them exactly which
                        // of the three gates — master switch, channel switch, OS permission — is
                        // stopping delivery. (This modifier was ALSO reading a value SwiftUI never
                        // refreshed; that defect is fixed at its source now, but the reasoning above
                        // is why the modifier stays gone.)
                        .disabled(permissionStatus == .denied)
                    }

                    if let errorMsg = testErrorMessage {
                        Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(.caption))
                                .accessibilityHidden(true)
                            Text(errorMsg)
                                .font(.system(.caption))
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }
            .padding(24)
        }
        .task {
            await refreshPermissionStatus()
            await refreshChannels()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check when user returns from System Settings.
            // ⚠️ Channels are re-read too, and not only for tidiness: registration happens from two
            // detached `Task`s at launch, so a pane opened early can genuinely render before the
            // ChatOps channel exists. This is the second chance to show it.
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
            // ⚠️ "Test Sent!" USED TO BE UNCONDITIONAL, which was survivable only while the pane
            // had no channel switches. Now that it does, a user can switch every channel off, press
            // Test and — before this — be told it was sent. The whole point of a test button is
            // that its answer can be trusted.
            let delivered = await NotificationDispatcher.shared.dispatch(payload)
            // ⚠️ `delivered == 0` HAS TWO CAUSES AND THEY NEED DIFFERENT ANSWERS: the master switch
            // (or a per-conversation mute) suppressed it, or every channel is switched off. An `Int`
            // cannot tell them apart, so the cause is re-derived from the same pure policy the
            // dispatcher used. Naming the wrong one on the ONE screen whose job is diagnosing
            // delivery is worse than saying nothing.
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

    /// Flips one channel.
    ///
    /// ⚠️ OPTIMISTIC WRITE, AUTHORITATIVE RE-READ. The switch moves immediately so it does not lag
    /// under the pointer, but the local array is not the truth — the actor is. The re-read is what
    /// makes a rejected change visibly snap back instead of leaving the pane showing a setting that
    /// was never applied.
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

    /// ⚠️ Falls back rather than rendering a blank slot: a channel registered after this file was
    /// written still gets a row, which is the entire point of reading the registry.
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

    /// ⚠️ Only claims a channel cannot deliver where that is actually KNOWN here. Local delivery is
    /// checkable (the system permission). Whether ChatOps has a paired channel is not visible from
    /// a snapshot, and a warning triangle guessed from `requiresConfiguration` alone would sit
    /// permanently next to a channel that is working.
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

/// ⚠️ `name` IS A RUNTIME STRING, not a `LocalizedStringKey`, and it is rendered with
/// `Text(verbatim:)`. It carries a channel's own `displayName` out of the registry; passing a
/// runtime value where a `LocalizedStringKey` is expected asks the bundle for a translation keyed by
/// that literal text and silently renders the key when there is none. `description` stays a
/// `LocalizedStringKey` because every one of its values is still a literal in this file.
///
/// ⚠️ `isComingSoon` IS GONE. It only ever dimmed rows for channels this app had already built.
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(description)
                    .font(.system(size: 11))
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
