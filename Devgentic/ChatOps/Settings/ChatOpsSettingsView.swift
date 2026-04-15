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

// MARK: - Settings View

struct ChatOpsSettingsView: View {

    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(\.appTheme) private var theme

    @State private var config = ChatOpsConfigManager.shared
    @State private var pairingService = ChatOpsPairingService()
    @State private var discordPairingService = DiscordPairingService()
    @State private var slackPairingService = SlackPairingService()

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
            VStack(spacing: 32) {
                platformSelector
                platformContent
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(theme.primaryBackground)
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
        VStack(spacing: 32) {
            botConfigCard
            pairingCard
            securityCard
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
                                .font(.system(.caption))
                            Text("@\(username)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced)) // Fixed size: monospaced design
                                .foregroundColor(theme.primaryText)
                        }
                    }
                }

                Divider().background(theme.dividerColor)

                // Token input row (custom layout since it's a multi-element input)
                HStack(spacing: 8) {
                    SecureField("Bot Token", text: $tokenInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced)) // Fixed size: monospaced design
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.secondaryBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )
                        .disabled(config.connectionState.isConnected)

                    Button(action: validateToken) {
                        if isValidating {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("Validate")
                                .frame(width: 60)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentColor)
                    .controlSize(.small)
                    .disabled(tokenInput.isEmpty || isValidating || config.connectionState.isConnected)
                }

                if let error = validationError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(.caption2))
                            .foregroundColor(theme.warningColor)
                        Text(error)
                            .font(.system(.caption))
                            .foregroundColor(theme.warningColor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
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
                        Button("Start Pairing") {
                            guard let token = config.botToken, !token.isEmpty else { return }
                            pairingService.startPairing(botToken: token)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accentColor)
                        .controlSize(.small)
                        .disabled(config.botToken == nil || config.botToken?.isEmpty == true)
                    }

                case .validating:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Validating token...")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                    }

                case .awaitingPairing(let pin):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Send this message to your bot on Telegram:")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)

                        HStack(spacing: 10) {
                            Text("PAIR \(pin)")
                                .font(.system(size: 20, weight: .bold, design: .monospaced)) // Fixed size: monospaced design
                                .foregroundColor(theme.accentColor)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(theme.accentColor.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(theme.accentColor.opacity(0.2), lineWidth: 0.5)
                                )

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("PAIR \(pin)", forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(.caption))
                            }
                            .buttonStyle(.borderless)
                            .help("Copy to clipboard")
                        }

                        HStack(spacing: 12) {
                            Text("Waiting for pairing... (expires in 5 minutes)")
                                .font(.system(.caption))
                                .foregroundColor(theme.secondaryText)

                            Button("Cancel") {
                                pairingService.cancelPairing()
                                config.connectionState = .disconnected
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                case .connected(let chatID):
                    SettingsRow(
                        title: "Linked",
                        description: "Paired with chat ID \(chatID). Messages from this chat are authorized.",
                        theme: theme
                    ) {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Active")
                                .font(.system(.caption, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }

                case .error(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.warningColor)
                            .font(.system(.caption))
                        Text(message)
                            .font(.system(.caption))
                            .foregroundColor(theme.warningColor)
                    }
                }
            }
        }
    }

    // MARK: - Security Card

    private var securityCard: some View {
        SettingsCard(title: "Security", icon: "lock.shield.fill", theme: theme) {
            SettingsRow(
                title: "Security Tier",
                description: LocalizedStringKey(config.securityTier.description),
                theme: theme
            ) {
                Picker("", selection: Binding(
                    get: { config.securityTier },
                    set: { config.securityTier = $0 }
                )) {
                    ForEach(ChatOpsSecurityTier.allCases) { tier in
                        Text(tier.rawValue).tag(tier)
                    }
                }
                .labelsHidden()
                .fixedSize()
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

                Divider().background(theme.dividerColor)

                SettingsRow(
                    title: "Status",
                    description: "Current connection state of the ChatOps bridge.",
                    theme: theme
                ) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(config.connectionState.statusText)
                            .font(.system(.caption, weight: .medium))
                            .foregroundColor(theme.primaryText)
                    }
                }

                if config.connectionState.isConnected {
                    Divider().background(theme.dividerColor)

                    HStack {
                        Spacer()
                        DisconnectButton {
                            Task {
                                viewModel.chatOpsBridge?.stop()
                                await pairingService.disconnect()
                            }
                        }
                    }
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
        VStack(spacing: 32) {
            discordBotConfigCard
            discordPairingCard
            securityCard // Shared with Telegram
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
                                .font(.system(.caption))
                            Text(username)
                                .font(.system(size: 12, weight: .medium, design: .monospaced)) // Fixed size: monospaced design
                                .foregroundColor(theme.primaryText)
                        }
                    }
                }

                Divider().background(theme.dividerColor)

                HStack(spacing: 8) {
                    SecureField("Bot Token", text: $discordTokenInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced)) // Fixed size: monospaced design
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.secondaryBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )
                        .disabled(config.discordConnectionState.isConnected)

                    Button(action: validateDiscordToken) {
                        if isDiscordValidating {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("Validate")
                                .frame(width: 60)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentColor)
                    .controlSize(.small)
                    .disabled(discordTokenInput.isEmpty || isDiscordValidating || config.discordConnectionState.isConnected)
                }

                if let error = discordValidationError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(.caption2))
                            .foregroundColor(theme.warningColor)
                        Text(error)
                            .font(.system(.caption))
                            .foregroundColor(theme.warningColor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                Divider().background(theme.dividerColor)

                // Intent reminder
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(.caption2))
                        .foregroundColor(theme.secondaryText)
                    Text("Enable the MESSAGE CONTENT privileged intent in your bot's settings on the Discord Developer Portal.")
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                }
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
                        Button("Start Pairing") {
                            guard let token = config.discordBotToken, !token.isEmpty else { return }
                            discordPairingService.startPairing(botToken: token)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accentColor)
                        .controlSize(.small)
                        .disabled(config.discordBotToken == nil || config.discordBotToken?.isEmpty == true)
                    }

                case .validating:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Validating token...")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                    }

                case .awaitingPairing(let pin):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Type this in any channel where your bot is present:")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)

                        HStack(spacing: 10) {
                            Text("PAIR \(pin)")
                                .font(.system(size: 20, weight: .bold, design: .monospaced)) // Fixed size: monospaced design
                                .foregroundColor(ChatOpsPlatform.discord.color)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(ChatOpsPlatform.discord.color.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(ChatOpsPlatform.discord.color.opacity(0.2), lineWidth: 0.5)
                                )

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("PAIR \(pin)", forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(.caption))
                            }
                            .buttonStyle(.borderless)
                            .help("Copy to clipboard")
                        }

                        HStack(spacing: 12) {
                            Text("Waiting for pairing... (expires in 5 minutes)")
                                .font(.system(.caption))
                                .foregroundColor(theme.secondaryText)

                            Button("Cancel") {
                                discordPairingService.cancelPairing()
                                config.discordConnectionState = .disconnected
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                case .connected:
                    SettingsRow(
                        title: "Linked",
                        description: "Paired with channel \(config.discordAuthorizedChannelID ?? "unknown"). Messages from this channel are authorized.",
                        theme: theme
                    ) {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Active")
                                .font(.system(.caption, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }

                case .error(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.warningColor)
                            .font(.system(.caption))
                        Text(message)
                            .font(.system(.caption))
                            .foregroundColor(theme.warningColor)
                    }
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

                Divider().background(theme.dividerColor)

                SettingsRow(
                    title: "Status",
                    description: "Current connection state of the Discord bridge.",
                    theme: theme
                ) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(discordStatusColor)
                            .frame(width: 7, height: 7)
                        Text(config.discordConnectionState.statusText)
                            .font(.system(.caption, weight: .medium))
                            .foregroundColor(theme.primaryText)
                    }
                }

                if config.discordConnectionState.isConnected {
                    Divider().background(theme.dividerColor)

                    HStack {
                        Spacer()
                        DisconnectButton {
                            Task {
                                viewModel.discordChatOpsBridge?.stop()
                                await discordPairingService.disconnect()
                            }
                        }
                    }
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
        VStack(spacing: 32) {
            slackBotConfigCard
            slackAppTokenCard
            slackPairingCard
            securityCard
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
                                .font(.system(.caption))
                            Text(username)
                                .font(.system(size: 12, weight: .medium, design: .monospaced)) // Fixed size: monospaced design
                                .foregroundColor(theme.primaryText)
                        }
                    }
                }

                Divider().background(theme.dividerColor)

                HStack(spacing: 8) {
                    SecureField("xoxb-...", text: $slackBotTokenInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced)) // Fixed size: monospaced design
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.secondaryBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )
                        .disabled(config.slackConnectionState.isConnected)
                }
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

                Divider().background(theme.dividerColor)

                HStack(spacing: 8) {
                    SecureField("xapp-...", text: $slackAppTokenInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced)) // Fixed size: monospaced design
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.secondaryBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )
                        .disabled(config.slackConnectionState.isConnected)

                    Button(action: validateSlackTokens) {
                        if isSlackValidating {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("Validate")
                                .frame(width: 60)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentColor)
                    .controlSize(.small)
                    .disabled(slackBotTokenInput.isEmpty || slackAppTokenInput.isEmpty || isSlackValidating || config.slackConnectionState.isConnected)
                }

                if let error = slackValidationError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(.caption2))
                            .foregroundColor(theme.warningColor)
                        Text(error)
                            .font(.system(.caption))
                            .foregroundColor(theme.warningColor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
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
                        Button("Start Pairing") {
                            guard let botToken = config.slackBotToken, !botToken.isEmpty,
                                  let appToken = config.slackAppToken, !appToken.isEmpty else { return }
                            slackPairingService.startPairing(botToken: botToken, appToken: appToken)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accentColor)
                        .controlSize(.small)
                        .disabled(config.slackBotToken == nil || config.slackAppToken == nil)
                    }

                case .validating:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Validating tokens...")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)
                    }

                case .awaitingPairing(let pin):
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Type this in any Slack channel where your bot is present:")
                            .font(.system(.caption))
                            .foregroundColor(theme.secondaryText)

                        HStack(spacing: 10) {
                            Text("PAIR \(pin)")
                                .font(.system(size: 20, weight: .bold, design: .monospaced)) // Fixed size: monospaced design
                                .foregroundColor(ChatOpsPlatform.slack.color)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(ChatOpsPlatform.slack.color.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(ChatOpsPlatform.slack.color.opacity(0.2), lineWidth: 0.5)
                                )

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("PAIR \(pin)", forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(.caption))
                            }
                            .buttonStyle(.borderless)
                            .help("Copy to clipboard")
                        }

                        HStack(spacing: 12) {
                            Text("Waiting for pairing... (expires in 5 minutes)")
                                .font(.system(.caption))
                                .foregroundColor(theme.secondaryText)

                            Button("Cancel") {
                                slackPairingService.cancelPairing()
                                config.slackConnectionState = .disconnected
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                case .connected:
                    SettingsRow(
                        title: "Linked",
                        description: "Paired with channel \(config.slackAuthorizedChannelID ?? "unknown"). Messages from this channel are authorized.",
                        theme: theme
                    ) {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Active")
                                .font(.system(.caption, weight: .medium))
                                .foregroundColor(.green)
                        }
                    }

                case .error(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.warningColor)
                            .font(.system(.caption))
                        Text(message)
                            .font(.system(.caption))
                            .foregroundColor(theme.warningColor)
                    }
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

                Divider().background(theme.dividerColor)

                SettingsRow(
                    title: "Status",
                    description: "Current connection state of the Slack bridge.",
                    theme: theme
                ) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(slackStatusColor)
                            .frame(width: 7, height: 7)
                        Text(config.slackConnectionState.statusText)
                            .font(.system(.caption, weight: .medium))
                            .foregroundColor(theme.primaryText)
                    }
                }

                if config.slackConnectionState.isConnected {
                    Divider().background(theme.dividerColor)

                    HStack {
                        Spacer()
                        DisconnectButton {
                            Task {
                                viewModel.slackChatOpsBridge?.stop()
                                await slackPairingService.disconnect()
                            }
                        }
                    }
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

                Text(platform.rawValue)
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

// MARK: - Disconnect Button (with hover effect)

private struct DisconnectButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "xmark.circle")
                    .font(.system(.caption, weight: .medium))
                Text("Disconnect")
                    .font(.system(.caption, weight: .medium))
            }
            .foregroundColor(isHovering ? .red : .red.opacity(0.65))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.red.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isHovering ? Color.red.opacity(0.25) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
