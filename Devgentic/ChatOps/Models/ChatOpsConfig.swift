//
//  ChatOpsConfig.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation

// MARK: - Security Tier

/// Defines what a remote Telegram user is allowed to do.
enum ChatOpsSecurityTier: String, Codable, CaseIterable, Identifiable {
    /// View-only: `/status`, `/conversations` — no agent interaction.
    case readOnly = "Read Only"
    /// Can send messages, switch conversations, create new ones.
    case standard = "Standard"
    /// Full access including HITL approve/deny from Telegram.
    case full = "Full Access"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .readOnly:  return "Can only view status and list conversations"
        case .standard:  return "Can send messages and manage conversations"
        case .full:      return "Full access including tool approval"
        }
    }
}

// MARK: - Connection State

/// Observable connection state for the settings UI.
enum ChatOpsConnectionState: Equatable {
    case disconnected
    case validating
    case awaitingPairing(pin: String)
    case connected(chatID: Int64)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .disconnected:            return "Disconnected"
        case .validating:              return "Validating bot token..."
        case .awaitingPairing(let p):  return "Send PAIR \(p) to your bot"
        case .connected:               return "Connected"
        case .error(let msg):          return "Error: \(msg)"
        }
    }
}

// MARK: - ChatOps Configuration

/// Manages ChatOps state, persisted to UserDefaults (non-sensitive) and Keychain (tokens).
@Observable @MainActor
final class ChatOpsConfigManager {

    static let shared = ChatOpsConfigManager()

    private let keychain = SecureKeyStorage()
    private static let keychainService = Bundle.main.bundleIdentifier ?? "com.devgentic.app"

    var connectionState: ChatOpsConnectionState = .disconnected

    var botToken: String? {
        get {
            access(keyPath: \.botToken)
            return keychain.retrieve(service: Self.keychainService, account: AppSettings.chatOpsBotTokenKey)
        }
        set {
            withMutation(keyPath: \.botToken) {
                if let value = newValue {
                    _ = keychain.save(value: value, service: Self.keychainService, account: AppSettings.chatOpsBotTokenKey)
                } else {
                    _ = keychain.delete(service: Self.keychainService, account: AppSettings.chatOpsBotTokenKey)
                }
            }
        }
    }

    var authorizedChatID: Int64? {
        get {
            access(keyPath: \.authorizedChatID)
            let val = UserDefaults.standard.integer(forKey: AppSettings.chatOpsAuthorizedChatIDKey)
            return val == 0 ? nil : Int64(val)
        }
        set {
            withMutation(keyPath: \.authorizedChatID) {
                if let id = newValue {
                    UserDefaults.standard.set(Int(id), forKey: AppSettings.chatOpsAuthorizedChatIDKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: AppSettings.chatOpsAuthorizedChatIDKey)
                }
            }
        }
    }

    var securityTier: ChatOpsSecurityTier {
        get {
            access(keyPath: \.securityTier)
            guard let raw = UserDefaults.standard.string(forKey: AppSettings.chatOpsSecurityTierKey),
                  let tier = ChatOpsSecurityTier(rawValue: raw) else { return .readOnly }
            return tier
        }
        set {
            withMutation(keyPath: \.securityTier) {
                UserDefaults.standard.set(newValue.rawValue, forKey: AppSettings.chatOpsSecurityTierKey)
            }
        }
    }

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return UserDefaults.standard.bool(forKey: AppSettings.chatOpsEnabledKey)
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsEnabledKey)
            }
        }
    }

    var botUsername: String? {
        get {
            access(keyPath: \.botUsername)
            return UserDefaults.standard.string(forKey: "chatOpsBotUsername")
        }
        set {
            withMutation(keyPath: \.botUsername) {
                UserDefaults.standard.set(newValue, forKey: "chatOpsBotUsername")
            }
        }
    }

    var activeConversationID: UUID? {
        get {
            access(keyPath: \.activeConversationID)
            guard let str = UserDefaults.standard.string(forKey: AppSettings.chatOpsActiveConversationIDKey) else { return nil }
            return UUID(uuidString: str)
        }
        set {
            withMutation(keyPath: \.activeConversationID) {
                UserDefaults.standard.set(newValue?.uuidString, forKey: AppSettings.chatOpsActiveConversationIDKey)
            }
        }
    }

    // MARK: - Discord Configuration

    var discordConnectionState: ChatOpsConnectionState = .disconnected

    var discordBotToken: String? {
        get {
            access(keyPath: \.discordBotToken)
            return keychain.retrieve(service: Self.keychainService, account: AppSettings.chatOpsDiscordBotTokenKey)
        }
        set {
            withMutation(keyPath: \.discordBotToken) {
                if let value = newValue {
                    _ = keychain.save(value: value, service: Self.keychainService, account: AppSettings.chatOpsDiscordBotTokenKey)
                } else {
                    _ = keychain.delete(service: Self.keychainService, account: AppSettings.chatOpsDiscordBotTokenKey)
                }
            }
        }
    }

    var discordAuthorizedChannelID: String? {
        get {
            access(keyPath: \.discordAuthorizedChannelID)
            return UserDefaults.standard.string(forKey: AppSettings.chatOpsDiscordChannelIDKey)
        }
        set {
            withMutation(keyPath: \.discordAuthorizedChannelID) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsDiscordChannelIDKey)
            }
        }
    }

    var discordApplicationID: String? {
        get {
            access(keyPath: \.discordApplicationID)
            return UserDefaults.standard.string(forKey: AppSettings.chatOpsDiscordApplicationIDKey)
        }
        set {
            withMutation(keyPath: \.discordApplicationID) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsDiscordApplicationIDKey)
            }
        }
    }

    var discordGuildID: String? {
        get {
            access(keyPath: \.discordGuildID)
            return UserDefaults.standard.string(forKey: AppSettings.chatOpsDiscordGuildIDKey)
        }
        set {
            withMutation(keyPath: \.discordGuildID) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsDiscordGuildIDKey)
            }
        }
    }

    var discordBotUsername: String? {
        get {
            access(keyPath: \.discordBotUsername)
            return UserDefaults.standard.string(forKey: "chatOpsDiscordBotUsername")
        }
        set {
            withMutation(keyPath: \.discordBotUsername) {
                UserDefaults.standard.set(newValue, forKey: "chatOpsDiscordBotUsername")
            }
        }
    }

    var isDiscordEnabled: Bool {
        get {
            access(keyPath: \.isDiscordEnabled)
            return UserDefaults.standard.bool(forKey: AppSettings.chatOpsDiscordEnabledKey)
        }
        set {
            withMutation(keyPath: \.isDiscordEnabled) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsDiscordEnabledKey)
            }
        }
    }

    var discordActiveConversationID: UUID? {
        get {
            access(keyPath: \.discordActiveConversationID)
            guard let str = UserDefaults.standard.string(forKey: AppSettings.chatOpsDiscordActiveConversationIDKey) else { return nil }
            return UUID(uuidString: str)
        }
        set {
            withMutation(keyPath: \.discordActiveConversationID) {
                UserDefaults.standard.set(newValue?.uuidString, forKey: AppSettings.chatOpsDiscordActiveConversationIDKey)
            }
        }
    }

    // MARK: - Reset

    /// Resets all Telegram ChatOps state (used on disconnect).
    func reset() {
        botToken = nil
        botUsername = nil
        authorizedChatID = nil
        isEnabled = false
        activeConversationID = nil
        connectionState = .disconnected
    }

    /// Resets all Discord ChatOps state (used on disconnect).
    func resetDiscord() {
        discordBotToken = nil
        discordBotUsername = nil
        discordAuthorizedChannelID = nil
        discordApplicationID = nil
        discordGuildID = nil
        isDiscordEnabled = false
        discordActiveConversationID = nil
        discordConnectionState = .disconnected
    }

    // MARK: - Slack Configuration

    var slackConnectionState: ChatOpsConnectionState = .disconnected

    var slackBotToken: String? {
        get {
            access(keyPath: \.slackBotToken)
            return keychain.retrieve(service: Self.keychainService, account: AppSettings.chatOpsSlackBotTokenKey)
        }
        set {
            withMutation(keyPath: \.slackBotToken) {
                if let value = newValue {
                    _ = keychain.save(value: value, service: Self.keychainService, account: AppSettings.chatOpsSlackBotTokenKey)
                } else {
                    _ = keychain.delete(service: Self.keychainService, account: AppSettings.chatOpsSlackBotTokenKey)
                }
            }
        }
    }

    var slackAppToken: String? {
        get {
            access(keyPath: \.slackAppToken)
            return keychain.retrieve(service: Self.keychainService, account: AppSettings.chatOpsSlackAppTokenKey)
        }
        set {
            withMutation(keyPath: \.slackAppToken) {
                if let value = newValue {
                    _ = keychain.save(value: value, service: Self.keychainService, account: AppSettings.chatOpsSlackAppTokenKey)
                } else {
                    _ = keychain.delete(service: Self.keychainService, account: AppSettings.chatOpsSlackAppTokenKey)
                }
            }
        }
    }

    var slackAuthorizedChannelID: String? {
        get {
            access(keyPath: \.slackAuthorizedChannelID)
            return UserDefaults.standard.string(forKey: AppSettings.chatOpsSlackChannelIDKey)
        }
        set {
            withMutation(keyPath: \.slackAuthorizedChannelID) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsSlackChannelIDKey)
            }
        }
    }

    var slackBotUsername: String? {
        get {
            access(keyPath: \.slackBotUsername)
            return UserDefaults.standard.string(forKey: "chatOpsSlackBotUsername")
        }
        set {
            withMutation(keyPath: \.slackBotUsername) {
                UserDefaults.standard.set(newValue, forKey: "chatOpsSlackBotUsername")
            }
        }
    }

    var slackTeamName: String? {
        get {
            access(keyPath: \.slackTeamName)
            return UserDefaults.standard.string(forKey: "chatOpsSlackTeamName")
        }
        set {
            withMutation(keyPath: \.slackTeamName) {
                UserDefaults.standard.set(newValue, forKey: "chatOpsSlackTeamName")
            }
        }
    }

    var isSlackEnabled: Bool {
        get {
            access(keyPath: \.isSlackEnabled)
            return UserDefaults.standard.bool(forKey: AppSettings.chatOpsSlackEnabledKey)
        }
        set {
            withMutation(keyPath: \.isSlackEnabled) {
                UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsSlackEnabledKey)
            }
        }
    }

    var slackActiveConversationID: UUID? {
        get {
            access(keyPath: \.slackActiveConversationID)
            guard let str = UserDefaults.standard.string(forKey: AppSettings.chatOpsSlackActiveConversationIDKey) else { return nil }
            return UUID(uuidString: str)
        }
        set {
            withMutation(keyPath: \.slackActiveConversationID) {
                UserDefaults.standard.set(newValue?.uuidString, forKey: AppSettings.chatOpsSlackActiveConversationIDKey)
            }
        }
    }

    /// Resets all Slack ChatOps state (used on disconnect).
    func resetSlack() {
        slackBotToken = nil
        slackAppToken = nil
        slackBotUsername = nil
        slackTeamName = nil
        slackAuthorizedChannelID = nil
        isSlackEnabled = false
        slackActiveConversationID = nil
        slackConnectionState = .disconnected
    }

    private init() {
        // Restore Telegram connection state on launch
        if let chatID = authorizedChatID, botToken != nil, isEnabled {
            connectionState = .connected(chatID: chatID)
        }
        // Restore Discord connection state on launch
        if discordAuthorizedChannelID != nil, discordBotToken != nil, isDiscordEnabled {
            discordConnectionState = .connected(chatID: Int64(discordAuthorizedChannelID ?? "0") ?? 0)
        }
        // Restore Slack connection state on launch
        if slackAuthorizedChannelID != nil, slackBotToken != nil, slackAppToken != nil, isSlackEnabled {
            slackConnectionState = .connected(chatID: 0)
        }
    }
}
