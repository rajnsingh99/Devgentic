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
                SettingsCard(title: "Channels", icon: "square.grid.2x2.fill", theme: theme) {
                    ChannelRow(
                        name: "Local Notification",
                        description: permissionStatus == .denied
                            ? "Permission denied — tap Open Settings above"
                            : "macOS system notifications",
                        icon: "bell.badge",
                        isEnabled: permissionStatus != .denied,
                        isComingSoon: false,
                        theme: theme
                    )

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    ChannelRow(
                        name: "Slack Webhook",
                        description: "Coming soon",
                        icon: "number",
                        isEnabled: false,
                        isComingSoon: true,
                        theme: theme
                    )

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    ChannelRow(
                        name: "Discord Webhook",
                        description: "Coming soon",
                        icon: "gamecontroller",
                        isEnabled: false,
                        isComingSoon: true,
                        theme: theme
                    )

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    ChannelRow(
                        name: "Telegram Bot",
                        description: "Coming soon",
                        icon: "paperplane",
                        isEnabled: false,
                        isComingSoon: true,
                        theme: theme
                    )
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
                        .disabled(!config.isGloballyEnabled || permissionStatus == .denied)
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
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check when user returns from System Settings.
            Task { await refreshPermissionStatus() }
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
            await NotificationDispatcher.shared.dispatch(payload)
            await MainActor.run {
                testSent = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                testSent = false
            }
        }
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

private struct ChannelRow: View {
    let name: LocalizedStringKey
    let description: LocalizedStringKey
    let icon: String
    let isEnabled: Bool
    let isComingSoon: Bool
    let theme: any Theme

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(isComingSoon ? theme.secondaryText.opacity(0.4) : (isEnabled ? theme.accentColor : .orange))
                .frame(width: 24, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isComingSoon ? theme.secondaryText.opacity(0.5) : theme.primaryText)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
            }

            Spacer()

            if isComingSoon {
                Text("Soon")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.secondaryText.opacity(0.08))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(theme.secondaryText.opacity(0.15), lineWidth: 0.5)
                    )
            } else if !isEnabled {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange.opacity(0.8))
                    .font(.system(size: 14))
                    .accessibilityHidden(true)
            }
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
