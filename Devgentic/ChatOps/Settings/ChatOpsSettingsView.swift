// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import SwiftUI

// MARK: - Platform Model

/// Represents a supported ChatOps messaging platform.
private enum ChatOpsPlatform: String, CaseIterable, Identifiable {
    case telegram = "Telegram"
    case discord = "Discord"
    case slack = "Slack"

    var id: String { rawValue }

    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` stays for persistence and logging only.
    /// These are brand names, but non-Latin locales transliterate them, so they stay extractable.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .telegram: return "Telegram"
        case .discord:  return "Discord"
        case .slack:    return "Slack"
        }
    }

    var icon: String {
        switch self {
        case .telegram: return "paperplane.fill"
        case .discord: return "gamecontroller.fill"
        case .slack: return "number.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .telegram: return Color(red: 0.16, green: 0.63, blue: 0.89)
        case .discord: return Color(red: 0.34, green: 0.40, blue: 0.87)
        case .slack: return Color(red: 0.58, green: 0.13, blue: 0.37)
        }
    }

    var subtitle: String {
        switch self {
        case .telegram: return "Long Polling — recommended for personal use"
        case .discord: return "WebSocket Gateway — ideal for teams"
        case .slack: return "Socket Mode — ideal for team workspaces"
        }
    }

    var isAvailable: Bool { self == .telegram || self == .discord || self == .slack }
}

// MARK: - Localized Titles

extension ChatOpsSecurityTier {
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` is the persisted/`Codable` value — never edit it.
    /// Declared here (not next to the enum in `ChatOpsConfig.swift`) so the model layer keeps
    /// its `Foundation`-only imports.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .readOnly: return "Read Only"
        case .standard: return "Standard"
        case .full:     return "Full Access"
        }
    }
}

// MARK: - Secret Input Field

/// Reusable credential input field with leading icon, monospace font, show/hide eye toggle, and clear button.
private struct SecretInputField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var isConnected: Bool = false
    @State private var isRevealed: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText.opacity(0.7))
                .accessibilityHidden(true)

            if isRevealed {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(theme.fontCodeCaption)
                    .foregroundColor(theme.primaryText)
                    .disabled(isConnected)
            } else {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(theme.fontCodeCaption)
                    .foregroundColor(theme.primaryText)
                    .disabled(isConnected)
            }

            if !text.isEmpty && !isConnected {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help(isRevealed ? "Hide token" : "Show token")

                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Clear token")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Settings View

struct ChatOpsSettingsView: View {

    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(\.appTheme) private var theme

    @State private var config = ChatOpsConfigManager.shared
    // ⚠️ NOT `@State`. These own an in-flight pairing window that must survive this view being
    // torn down — see `ChatOpsPairingService.shared`. Nothing here observes them; the PIN and the
    // status both come from `ChatOpsConfigManager`, which is what the card actually renders.
    private let pairingService = ChatOpsPairingService.shared
    private let discordPairingService = DiscordPairingService.shared
    private let slackPairingService = SlackPairingService.shared

    @State private var selectedPlatform: ChatOpsPlatform = .telegram
    // Telegram state
    @State private var tokenInput: String = ""
    @State private var isValidating: Bool = false
    @State private var validationError: String?
    @State private var botUsername: String?
    // Discord state
    @State private var discordTokenInput: String = ""
    @State private var isDiscordValidating: Bool = false
    @State private var discordValidationError: String?
    @State private var discordBotUsername: String?
    // Slack state
    @State private var slackBotTokenInput: String = ""
    @State private var slackAppTokenInput: String = ""
    @State private var isSlackValidating: Bool = false
    @State private var slackValidationError: String?
    @State private var slackBotUsername: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                platformSelector
                platformContent
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onAppear {
            tokenInput = config.botToken ?? ""
            botUsername = config.botUsername
            discordTokenInput = config.discordBotToken ?? ""
            discordBotUsername = config.discordBotUsername
            pairingService.onPairingComplete = { [weak viewModel] in
                viewModel?.startChatOps()
            }
            discordPairingService.onPairingComplete = { [weak viewModel] in
                viewModel?.startDiscordChatOps()
            }
            slackBotTokenInput = config.slackBotToken ?? ""
            slackAppTokenInput = config.slackAppToken ?? ""
            slackBotUsername = config.slackBotUsername
            slackPairingService.onPairingComplete = { [weak viewModel] in
                viewModel?.startSlackChatOps()
            }
        }
    }

    // MARK: - Platform Selector

    private var platformSelector: some View {
        SettingsCard(title: "Platform", icon: "antenna.radiowaves.left.and.right", theme: theme) {
            HStack(spacing: 0) {
                ForEach(Array(ChatOpsPlatform.allCases.enumerated()), id: \.element.id) { index, platform in
                    if index > 0 {
                        Divider()
                            .frame(height: 44)
                            .background(theme.dividerColor)
                    }
                    PlatformTab(
                        platform: platform,
                        isSelected: selectedPlatform == platform,
                        isConnected: (platform == .telegram && config.connectionState.isConnected) ||
                                     (platform == .discord && config.discordConnectionState.isConnected) ||
                                     (platform == .slack && config.slackConnectionState.isConnected),
                        theme: theme
                    ) {
                        selectedPlatform = platform
                    }
                }
            }
        }
    }

    // MARK: - Platform Content (stable ZStack to prevent scroll jitter)

    private var platformContent: some View {
        ZStack(alignment: .top) {
            telegramSettings
                .opacity(selectedPlatform == .telegram ? 1 : 0)
                .frame(maxHeight: selectedPlatform == .telegram ? nil : 0)
                .clipped()

            discordSettings
                .opacity(selectedPlatform == .discord ? 1 : 0)
                .frame(maxHeight: selectedPlatform == .discord ? nil : 0)
                .clipped()

            slackSettings
                .opacity(selectedPlatform == .slack ? 1 : 0)
                .frame(maxHeight: selectedPlatform == .slack ? nil : 0)
                .clipped()
        }
    }

    // MARK: - Telegram Settings

    private var telegramSettings: some View {
        VStack(spacing: 24) {
            botConfigCard
            pairingCard
            securityCard(for: .telegram)
            connectionCard
        }
    }

    // MARK: - Bot Configuration Card

    private var botConfigCard: some View {
        SettingsCard(title: "Bot Configuration", icon: "key.fill", theme: theme) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Bot Token",
                    description: "Paste your token from Telegram's @BotFather. This authenticates Devgentic with your bot.",
                    theme: theme
                ) {
                    if let username = botUsername {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(theme.fontCaption2)
                            Text("@\(username)")
                                .font(theme.fontCodeCaption.weight(.medium))
                                .foregroundColor(theme.primaryText)
                        }
                    }
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                // Token input row
                HStack(spacing: 8) {
                    SecretInputField(
                        placeholder: "Enter Telegram Bot Token",
                        text: $tokenInput,
                        isConnected: config.connectionState.isConnected
                    )

                    TactileButton(
                        title: "Validate",
                        icon: "checkmark.shield.fill",
                        variant: .primary,
                        size: .compact,
                        isLoading: isValidating,
                        isDisabled: tokenInput.isEmpty || isValidating || config.connectionState.isConnected
                    ) {
                        validateToken()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let error = validationError {
                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - Pairing Card

    private var pairingCard: some View {
        SettingsCard(title: "Pairing", icon: "link.circle.fill", theme: theme) {
            VStack(spacing: 0) {
                switch config.connectionState {
                case .disconnected:
                    SettingsRow(
                        title: "Pair with Telegram",
                        description: "Validate your bot token first, then initiate pairing. A 6-digit PIN will appear — send it to your bot on Telegram to link.",
                        theme: theme
                    ) {
                        TactileButton(
                            title: "Start Pairing",
                            icon: "link",
                            variant: .primary,
                            size: .compact,
                            isDisabled: config.botToken == nil || config.botToken?.isEmpty == true
                        ) {
                            guard let token = config.botToken, !token.isEmpty else { return }
                            pairingService.startPairing(botToken: token)
                        }
                    }

                case .validating:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Validating token…")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                case .awaitingPairing(let pin):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Send this message to your bot on Telegram:")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)

                        HStack(spacing: 10) {
                            Text("PAIR \(pin)")
                                .font(theme.fontTitle3.weight(.bold).monospaced())
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(theme.accentColor.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(theme.accentColor.opacity(0.2), lineWidth: 0.5)
                                )

                            TactileIconButton(
                                icon: "doc.on.doc",
                                tooltip: "Copy PIN to clipboard"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("PAIR \(pin)", forType: .string)
                            }
                        }

                        HStack(spacing: 12) {
                            Text("Waiting for pairing (expires in 5 minutes)")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)

                            Spacer()

                            TactileButton(
                                title: "Cancel",
                                variant: .subtle,
                                size: .compact
                            ) {
                                pairingService.cancelPairing()
                                config.connectionState = .disconnected
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                case .connected(let chatID):
                    SettingsRow(
                        title: "Linked",
                        description: "Paired with chat ID \(chatID). Messages from this chat are authorized.",
                        theme: theme
                    ) {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Active")
                                .font(theme.fontCaption2.weight(.medium))
                                .foregroundColor(.green)
                        }
                    }

                case .error(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(theme.warningColor)
                                .font(theme.fontCaption2)
                                .accessibilityHidden(true)
                            Text(message)
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.warningColor)
                        }
                        TactileButton(
                            title: config.connectionState.needsRepairing ? "Re-pair" : "Start Pairing",
                            icon: "arrow.triangle.2.circlepath",
                            variant: .primary,
                            size: .compact,
                            isDisabled: config.botToken == nil || config.botToken?.isEmpty == true
                        ) {
                            guard let token = config.botToken, !token.isEmpty else { return }
                            pairingService.startPairing(botToken: token)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    // MARK: - Security Card

    private func securityCard(for provider: RemoteChannel.Provider) -> some View {
        SettingsCard(title: "Security", icon: "lock.shield.fill", theme: theme) {
            SettingsRow(
                title: "Security Tier",
                description: LocalizedStringKey(config.securityTier(for: provider).description),
                theme: theme
            ) {
                Picker("", selection: Binding(
                    get: { config.securityTier(for: provider) },
                    set: { config.setSecurityTier($0, for: provider) }
                )) {
                    ForEach(ChatOpsSecurityTier.allCases) { tier in
                        Text(tier.localizedTitle).tag(tier)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if config.securityTier(for: provider) == .full {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                SettingsRow(
                    title: "Tool Approvals",
                    description: LocalizedStringKey(config.toolApprovals(for: provider).description),
                    theme: theme
                ) {
                    Picker("", selection: Binding(
                        get: { config.toolApprovals(for: provider) },
                        set: { config.setToolApprovals($0, for: provider) }
                    )) {
                        ForEach(ChatOpsToolApprovals.allCases) { approvals in
                            Text(approvals.localizedTitle).tag(approvals)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - Connection Card

    private var connectionCard: some View {
        SettingsCard(title: "Connection", icon: "bolt.horizontal.fill", theme: theme) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Enable ChatOps",
                    description: "Start the Telegram long-polling listener. Your Mac will receive messages while this is on.",
                    theme: theme
                ) {
                    Toggle("", isOn: Binding(
                        get: { config.isEnabled },
                        set: { newValue in
                            config.isEnabled = newValue
                            if newValue {
                                viewModel.startChatOps()
                            } else {
                                viewModel.stopChatOps()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(theme.accentColor)
                    .disabled(!config.connectionState.isConnected)
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                SettingsRow(
                    title: "Status",
                    description: "Current connection state of the ChatOps bridge.",
                    theme: theme
                ) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(config.connectionState.statusText(listenerEnabled: config.isEnabled))
                            .font(theme.fontCaption2.weight(.medium))
                            .foregroundColor(theme.primaryText)
                    }
                }

                if config.connectionState.isConnected {
                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    HStack {
                        Spacer()
                        TactileButton(
                            title: "Disconnect",
                            icon: "xmark.circle",
                            variant: .destructive,
                            size: .compact
                        ) {
                            Task {
                                viewModel.chatOpsBridge?.stop()
                                await pairingService.disconnect()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch config.connectionState {
        case .connected: return .green
        case .awaitingPairing, .validating: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private func validateToken() {
        isValidating = true
        validationError = nil
        botUsername = nil

        Task {
            do {
                let username = try await pairingService.validateToken(tokenInput)
                botUsername = username
                config.botToken = tokenInput
                config.botUsername = username
                validationError = nil
            } catch {
                validationError = error.localizedDescription
                botUsername = nil
            }
            isValidating = false
        }
    }

    // MARK: - Discord Settings

    private var discordSettings: some View {
        VStack(spacing: 24) {
            discordBotConfigCard
            discordPairingCard
            securityCard(for: .discord)
            discordConnectionCard
        }
    }

    // MARK: - Discord Bot Configuration Card

    private var discordBotConfigCard: some View {
        SettingsCard(title: "Bot Configuration", icon: "key.fill", theme: theme) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Bot Token",
                    description: "Paste your token from the Discord Developer Portal. Create a bot at discord.com/developers.",
                    theme: theme
                ) {
                    if let username = discordBotUsername {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(theme.fontCaption2)
                            Text(username)
                                .font(theme.fontCodeCaption.weight(.medium))
                                .foregroundColor(theme.primaryText)
                        }
                    }
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                HStack(spacing: 8) {
                    SecretInputField(
                        placeholder: "Enter Discord Bot Token",
                        text: $discordTokenInput,
                        isConnected: config.discordConnectionState.isConnected
                    )

                    TactileButton(
                        title: "Validate",
                        icon: "checkmark.shield.fill",
                        variant: .primary,
                        size: .compact,
                        isLoading: isDiscordValidating,
                        isDisabled: discordTokenInput.isEmpty || isDiscordValidating || config.discordConnectionState.isConnected
                    ) {
                        validateDiscordToken()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let error = discordValidationError {
                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                // Intent reminder
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.accentColor)
                        .accessibilityHidden(true)
                    Text("Enable the MESSAGE CONTENT privileged intent in your bot's settings on the Discord Developer Portal.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Discord Pairing Card

    private var discordPairingCard: some View {
        SettingsCard(title: "Pairing", icon: "link.circle.fill", theme: theme) {
            VStack(spacing: 0) {
                switch config.discordConnectionState {
                case .disconnected:
                    SettingsRow(
                        title: "Pair with Discord",
                        description: "Validate your bot token first, add the bot to your server, then initiate pairing. A 6-digit PIN will appear — type PAIR <pin> in your chosen Discord channel.",
                        theme: theme
                    ) {
                        TactileButton(
                            title: "Start Pairing",
                            icon: "link",
                            variant: .primary,
                            size: .compact,
                            isDisabled: config.discordBotToken == nil || config.discordBotToken?.isEmpty == true
                        ) {
                            guard let token = config.discordBotToken, !token.isEmpty else { return }
                            discordPairingService.startPairing(botToken: token)
                        }
                    }

                case .validating:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Validating token…")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                case .awaitingPairing(let pin):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Type this in any channel where your bot is present:")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)

                        HStack(spacing: 10) {
                            Text("PAIR \(pin)")
                                .font(theme.fontTitle3.weight(.bold).monospaced())
                                .foregroundColor(ChatOpsPlatform.discord.color)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(ChatOpsPlatform.discord.color.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(ChatOpsPlatform.discord.color.opacity(0.2), lineWidth: 0.5)
                                )

                            TactileIconButton(
                                icon: "doc.on.doc",
                                tooltip: "Copy PIN to clipboard"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("PAIR \(pin)", forType: .string)
                            }
                        }

                        HStack(spacing: 12) {
                            Text("Waiting for pairing (expires in 5 minutes)")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)

                            Spacer()

                            TactileButton(
                                title: "Cancel",
                                variant: .subtle,
                                size: .compact
                            ) {
                                discordPairingService.cancelPairing()
                                config.discordConnectionState = .disconnected
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                case .connected:
                    SettingsRow(
                        title: "Linked",
                        description: "Paired with channel \(config.discordAuthorizedChannelID ?? "unknown"). Messages from this channel are authorized.",
                        theme: theme
                    ) {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Active")
                                .font(theme.fontCaption2.weight(.medium))
                                .foregroundColor(.green)
                        }
                    }

                case .error(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(theme.warningColor)
                                .font(theme.fontCaption2)
                                .accessibilityHidden(true)
                            Text(message)
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.warningColor)
                        }
                        TactileButton(
                            title: config.discordConnectionState.needsRepairing ? "Re-pair" : "Start Pairing",
                            icon: "arrow.triangle.2.circlepath",
                            variant: .primary,
                            size: .compact,
                            isDisabled: config.discordBotToken == nil || config.discordBotToken?.isEmpty == true
                        ) {
                            guard let token = config.discordBotToken, !token.isEmpty else { return }
                            discordPairingService.startPairing(botToken: token)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    // MARK: - Discord Connection Card

    private var discordConnectionCard: some View {
        SettingsCard(title: "Connection", icon: "bolt.horizontal.fill", theme: theme) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Enable ChatOps",
                    description: "Start the Discord WebSocket Gateway listener. Your Mac will receive messages while this is on.",
                    theme: theme
                ) {
                    Toggle("", isOn: Binding(
                        get: { config.isDiscordEnabled },
                        set: { newValue in
                            config.isDiscordEnabled = newValue
                            if newValue {
                                viewModel.startDiscordChatOps()
                            } else {
                                viewModel.stopDiscordChatOps()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(theme.accentColor)
                    .disabled(!config.discordConnectionState.isConnected)
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                SettingsRow(
                    title: "Status",
                    description: "Current connection state of the Discord bridge.",
                    theme: theme
                ) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(discordStatusColor)
                            .frame(width: 7, height: 7)
                        Text(config.discordConnectionState.statusText(listenerEnabled: config.isDiscordEnabled))
                            .font(theme.fontCaption2.weight(.medium))
                            .foregroundColor(theme.primaryText)
                    }
                }

                if config.discordConnectionState.isConnected {
                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    HStack {
                        Spacer()
                        TactileButton(
                            title: "Disconnect",
                            icon: "xmark.circle",
                            variant: .destructive,
                            size: .compact
                        ) {
                            Task {
                                viewModel.discordChatOpsBridge?.stop()
                                await discordPairingService.disconnect()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var discordStatusColor: Color {
        switch config.discordConnectionState {
        case .connected: return .green
        case .awaitingPairing, .validating: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private func validateDiscordToken() {
        isDiscordValidating = true
        discordValidationError = nil
        discordBotUsername = nil

        Task {
            do {
                let username = try await discordPairingService.validateToken(discordTokenInput)
                discordBotUsername = username
                config.discordBotToken = discordTokenInput
                config.discordBotUsername = username
                discordValidationError = nil
            } catch {
                discordValidationError = error.localizedDescription
                discordBotUsername = nil
            }
            isDiscordValidating = false
        }
    }

    // MARK: - Slack Settings

    private var slackSettings: some View {
        VStack(spacing: 24) {
            slackBotConfigCard
            slackAppTokenCard
            slackPairingCard
            securityCard(for: .slack)
            slackConnectionCard
        }
    }

    // MARK: - Slack Bot Token Card

    private var slackBotConfigCard: some View {
        SettingsCard(title: "Bot Token", icon: "key.fill", theme: theme) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Bot Token (xoxb-)",
                    description: "Create a Slack app at api.slack.com/apps, then copy the Bot User OAuth Token.",
                    theme: theme
                ) {
                    if let username = slackBotUsername {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(theme.fontCaption2)
                            Text(username)
                                .font(theme.fontCodeCaption.weight(.medium))
                                .foregroundColor(theme.primaryText)
                        }
                    }
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                HStack(spacing: 8) {
                    SecretInputField(
                        placeholder: "xoxb-token",
                        text: $slackBotTokenInput,
                        isConnected: config.slackConnectionState.isConnected
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Slack App Token Card

    private var slackAppTokenCard: some View {
        SettingsCard(title: "App Token", icon: "lock.fill", theme: theme) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "App-Level Token (xapp-)",
                    description: "Required for Socket Mode. Generate one under your app's Basic Information → App-Level Tokens with 'connections:write' scope.",
                    theme: theme
                ) {
                    EmptyView()
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                HStack(spacing: 8) {
                    SecretInputField(
                        placeholder: "xapp-token",
                        text: $slackAppTokenInput,
                        isConnected: config.slackConnectionState.isConnected
                    )

                    TactileButton(
                        title: "Validate",
                        icon: "checkmark.shield.fill",
                        variant: .primary,
                        size: .compact,
                        isLoading: isSlackValidating,
                        isDisabled: slackBotTokenInput.isEmpty || slackAppTokenInput.isEmpty || isSlackValidating || config.slackConnectionState.isConnected
                    ) {
                        validateSlackTokens()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if let error = slackValidationError {
                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - Slack Pairing Card

    private var slackPairingCard: some View {
        SettingsCard(title: "Pairing", icon: "link.circle.fill", theme: theme) {
            VStack(spacing: 0) {
                switch config.slackConnectionState {
                case .disconnected:
                    SettingsRow(
                        title: "Pair with Slack",
                        description: "Validate both tokens first, then initiate pairing. A 6-digit PIN will appear — type PAIR <pin> in your chosen Slack channel.",
                        theme: theme
                    ) {
                        TactileButton(
                            title: "Start Pairing",
                            icon: "link",
                            variant: .primary,
                            size: .compact,
                            isDisabled: config.slackBotToken == nil || config.slackAppToken == nil
                        ) {
                            guard let botToken = config.slackBotToken, !botToken.isEmpty,
                                  let appToken = config.slackAppToken, !appToken.isEmpty else { return }
                            slackPairingService.startPairing(botToken: botToken, appToken: appToken)
                        }
                    }

                case .validating:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Validating tokens…")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                case .awaitingPairing(let pin):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Type this in any Slack channel where your bot is present:")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)

                        HStack(spacing: 10) {
                            Text("PAIR \(pin)")
                                .font(theme.fontTitle3.weight(.bold).monospaced())
                                .foregroundColor(ChatOpsPlatform.slack.color)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(ChatOpsPlatform.slack.color.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(ChatOpsPlatform.slack.color.opacity(0.2), lineWidth: 0.5)
                                )

                            TactileIconButton(
                                icon: "doc.on.doc",
                                tooltip: "Copy PIN to clipboard"
                            ) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("PAIR \(pin)", forType: .string)
                            }
                        }

                        HStack(spacing: 12) {
                            Text("Waiting for pairing (expires in 5 minutes)")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)

                            Spacer()

                            TactileButton(
                                title: "Cancel",
                                variant: .subtle,
                                size: .compact
                            ) {
                                slackPairingService.cancelPairing()
                                config.slackConnectionState = .disconnected
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                case .connected:
                    SettingsRow(
                        title: "Linked",
                        description: "Paired with channel \(config.slackAuthorizedChannelID ?? "unknown"). Messages from this channel are authorized.",
                        theme: theme
                    ) {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Active")
                                .font(theme.fontCaption2.weight(.medium))
                                .foregroundColor(.green)
                        }
                    }

                case .error(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(theme.warningColor)
                                .font(theme.fontCaption2)
                                .accessibilityHidden(true)
                            Text(message)
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.warningColor)
                        }
                        TactileButton(
                            title: config.slackConnectionState.needsRepairing ? "Re-pair" : "Start Pairing",
                            icon: "arrow.triangle.2.circlepath",
                            variant: .primary,
                            size: .compact,
                            isDisabled: config.slackBotToken == nil || config.slackAppToken == nil
                        ) {
                            guard let botToken = config.slackBotToken, !botToken.isEmpty,
                                  let appToken = config.slackAppToken, !appToken.isEmpty else { return }
                            slackPairingService.startPairing(botToken: botToken, appToken: appToken)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
            }
        }
    }

    // MARK: - Slack Connection Card

    private var slackConnectionCard: some View {
        SettingsCard(title: "Connection", icon: "bolt.horizontal.fill", theme: theme) {
            VStack(spacing: 0) {
                SettingsRow(
                    title: "Enable ChatOps",
                    description: "Start the Slack Socket Mode listener. Your Mac will receive messages while this is on.",
                    theme: theme
                ) {
                    Toggle("", isOn: Binding(
                        get: { config.isSlackEnabled },
                        set: { newValue in
                            config.isSlackEnabled = newValue
                            if newValue {
                                viewModel.startSlackChatOps()
                            } else {
                                viewModel.stopSlackChatOps()
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(theme.accentColor)
                    .disabled(!config.slackConnectionState.isConnected)
                }

                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                SettingsRow(
                    title: "Status",
                    description: "Current connection state of the Slack bridge.",
                    theme: theme
                ) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(slackStatusColor)
                            .frame(width: 7, height: 7)
                        Text(config.slackConnectionState.statusText(listenerEnabled: config.isSlackEnabled))
                            .font(theme.fontCaption2.weight(.medium))
                            .foregroundColor(theme.primaryText)
                    }
                }

                if config.slackConnectionState.isConnected {
                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    HStack {
                        Spacer()
                        TactileButton(
                            title: "Disconnect",
                            icon: "xmark.circle",
                            variant: .destructive,
                            size: .compact
                        ) {
                            Task {
                                viewModel.slackChatOpsBridge?.stop()
                                await slackPairingService.disconnect()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var slackStatusColor: Color {
        switch config.slackConnectionState {
        case .connected: return .green
        case .awaitingPairing, .validating: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private func validateSlackTokens() {
        isSlackValidating = true
        slackValidationError = nil
        slackBotUsername = nil

        Task {
            do {
                let username = try await slackPairingService.validateBotToken(slackBotTokenInput)
                try await slackPairingService.validateAppToken(slackAppTokenInput)
                slackBotUsername = username
                config.slackBotToken = slackBotTokenInput
                config.slackAppToken = slackAppTokenInput
                config.slackBotUsername = username
                slackValidationError = nil
            } catch {
                slackValidationError = error.localizedDescription
                slackBotUsername = nil
            }
            isSlackValidating = false
        }
    }
}

// MARK: - Platform Tab

private struct PlatformTab: View {
    let platform: ChatOpsPlatform
    let isSelected: Bool
    let isConnected: Bool
    let theme: any Theme
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: platform.icon)
                        .font(theme.fontBody.weight(.medium))
                        .foregroundStyle(isSelected ? platform.color : theme.secondaryText.opacity(0.5))

                    if isConnected {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -3)
                    }
                }

                Text(platform.localizedTitle)
                    .font(theme.fontSubheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                if !platform.isAvailable {
                    Text("Soon")
                        .font(.system(size: 9, weight: .bold)) // Fixed size: badge chip ≤9pt
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.secondaryText.opacity(0.5))
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isSelected
                    ? platform.color.opacity(0.06)
                    : (isHovering ? theme.surfaceOverlay : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.1), value: isHovering)
    }
}
