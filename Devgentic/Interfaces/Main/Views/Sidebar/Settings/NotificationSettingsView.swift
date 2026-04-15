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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notifications")
                        .font(.system(.caption, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .tracking(0.5)
                        .textCase(.uppercase)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Notifications")
                                .font(theme.fontBody.weight(.medium))
                                .foregroundColor(theme.primaryText)
                            Text("Receive alerts when queries complete while the app is in the background.")
                                .font(.system(.caption))
                                .foregroundColor(theme.secondaryText)
                        }
                        Spacer()
                        Toggle("", isOn: $config.isGloballyEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .padding(12)
                    .background(theme.surfaceOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Channels
                VStack(alignment: .leading, spacing: 8) {
                    Text("Channels")
                        .font(.system(.caption, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .tracking(0.5)
                        .textCase(.uppercase)

                    VStack(spacing: 0) {
                        channelRow(
                            name: "Local Notification",
                            description: permissionStatus == .denied
                                ? "Permission denied — tap Open Settings above"
                                : "macOS system notifications",
                            icon: "bell.badge",
                            isEnabled: permissionStatus != .denied
                        )

                        Divider().padding(.leading, 40)

                        channelRow(
                            name: "Slack Webhook",
                            description: "Coming soon",
                            icon: "number",
                            isEnabled: false,
                            isComingSoon: true
                        )

                        Divider().padding(.leading, 40)

                        channelRow(
                            name: "Discord Webhook",
                            description: "Coming soon",
                            icon: "gamecontroller",
                            isEnabled: false,
                            isComingSoon: true
                        )

                        Divider().padding(.leading, 40)

                        channelRow(
                            name: "Telegram Bot",
                            description: "Coming soon",
                            icon: "paperplane",
                            isEnabled: false,
                            isComingSoon: true
                        )
                    }
                    .background(theme.surfaceOverlay)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Test Notification
                VStack(alignment: .leading, spacing: 8) {
                    Text("Test")
                        .font(.system(.caption, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .tracking(0.5)
                        .textCase(.uppercase)

                    Button {
                        sendTestNotification()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: testSent ? "checkmark.circle.fill" : "bell.and.waves.left.and.right")
                                .foregroundColor(testSent ? .green : theme.accentColor)
                            Text(testSent ? "Test Sent!" : "Send Test Notification")
                                .font(theme.fontSubheadline.weight(.medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(theme.surfaceOverlay)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(!config.isGloballyEnabled || permissionStatus == .denied)
                    .opacity((config.isGloballyEnabled && permissionStatus != .denied) ? 1.0 : 0.5)

                    if let errorMsg = testErrorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(.caption))
                                .accessibilityHidden(true)
                            Text(errorMsg)
                                .font(.system(.caption))
                                .foregroundColor(.red)
                        }
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

    @ViewBuilder
    private func channelRow(name: LocalizedStringKey, description: LocalizedStringKey, icon: String, isEnabled: Bool, isComingSoon: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(.body)) // scales with Dynamic Type; ~16pt
                .foregroundColor(isComingSoon ? theme.secondaryText.opacity(0.4) : (isEnabled ? theme.accentColor : .orange))
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundColor(isComingSoon ? theme.secondaryText.opacity(0.5) : theme.primaryText)
                Text(description)
                    .font(.system(.caption))
                    .foregroundColor(theme.secondaryText.opacity(0.6))
            }

            Spacer()

            if isComingSoon {
                Text("Soon")
                    .font(.system(size: 10, weight: .medium)) // Fixed size: intentional (badge/chip text)
                    .foregroundColor(theme.secondaryText.opacity(0.4))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.secondaryText.opacity(0.08))
                    .clipShape(Capsule())
            } else if !isEnabled && !isComingSoon {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange.opacity(0.7))
                    .font(.system(.body)) // scales with Dynamic Type; ~14pt
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
