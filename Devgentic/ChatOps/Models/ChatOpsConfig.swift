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
@MainActor
final class ChatOpsConfigManager: ObservableObject {

    static let shared = ChatOpsConfigManager()

    private let keychain = SecureKeyStorage()
    private static let keychainService = Bundle.main.bundleIdentifier ?? "com.devgentic.app"

    @Published var connectionState: ChatOpsConnectionState = .disconnected

    var botToken: String? {
        get { keychain.retrieve(service: Self.keychainService, account: AppSettings.chatOpsBotTokenKey) }
        set {
            if let value = newValue {
                _ = keychain.save(value: value, service: Self.keychainService, account: AppSettings.chatOpsBotTokenKey)
            } else {
                _ = keychain.delete(service: Self.keychainService, account: AppSettings.chatOpsBotTokenKey)
            }
            objectWillChange.send()
        }
    }

    var authorizedChatID: Int64? {
        get {
            let val = UserDefaults.standard.integer(forKey: AppSettings.chatOpsAuthorizedChatIDKey)
            return val == 0 ? nil : Int64(val)
        }
        set {
            if let id = newValue {
                UserDefaults.standard.set(Int(id), forKey: AppSettings.chatOpsAuthorizedChatIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSettings.chatOpsAuthorizedChatIDKey)
            }
            objectWillChange.send()
        }
    }

    var securityTier: ChatOpsSecurityTier {
        get {
            guard let raw = UserDefaults.standard.string(forKey: AppSettings.chatOpsSecurityTierKey),
                  let tier = ChatOpsSecurityTier(rawValue: raw) else { return .readOnly }
            return tier
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppSettings.chatOpsSecurityTierKey)
            objectWillChange.send()
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: AppSettings.chatOpsEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsEnabledKey)
            objectWillChange.send()
        }
    }

    var botUsername: String? {
        get { UserDefaults.standard.string(forKey: "chatOpsBotUsername") }
        set {
            UserDefaults.standard.set(newValue, forKey: "chatOpsBotUsername")
            objectWillChange.send()
        }
    }

    var activeConversationID: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: AppSettings.chatOpsActiveConversationIDKey) else { return nil }
            return UUID(uuidString: str)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: AppSettings.chatOpsActiveConversationIDKey)
            objectWillChange.send()
        }
    }

    // MARK: - Discord Configuration

    @Published var discordConnectionState: ChatOpsConnectionState = .disconnected

    var discordBotToken: String? {
        get { keychain.retrieve(service: Self.keychainService, account: AppSettings.chatOpsDiscordBotTokenKey) }
        set {
            if let value = newValue {
                _ = keychain.save(value: value, service: Self.keychainService, account: AppSettings.chatOpsDiscordBotTokenKey)
            } else {
                _ = keychain.delete(service: Self.keychainService, account: AppSettings.chatOpsDiscordBotTokenKey)
            }
            objectWillChange.send()
        }
    }

    var discordAuthorizedChannelID: String? {
        get { UserDefaults.standard.string(forKey: AppSettings.chatOpsDiscordChannelIDKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsDiscordChannelIDKey)
            objectWillChange.send()
        }
    }

    var discordApplicationID: String? {
        get { UserDefaults.standard.string(forKey: AppSettings.chatOpsDiscordApplicationIDKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsDiscordApplicationIDKey)
            objectWillChange.send()
        }
    }

    var discordGuildID: String? {
        get { UserDefaults.standard.string(forKey: AppSettings.chatOpsDiscordGuildIDKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsDiscordGuildIDKey)
            objectWillChange.send()
        }
    }

    var discordBotUsername: String? {
        get { UserDefaults.standard.string(forKey: "chatOpsDiscordBotUsername") }
        set {
            UserDefaults.standard.set(newValue, forKey: "chatOpsDiscordBotUsername")
            objectWillChange.send()
        }
    }

    var isDiscordEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: AppSettings.chatOpsDiscordEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsDiscordEnabledKey)
            objectWillChange.send()
        }
    }

    var discordActiveConversationID: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: AppSettings.chatOpsDiscordActiveConversationIDKey) else { return nil }
            return UUID(uuidString: str)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: AppSettings.chatOpsDiscordActiveConversationIDKey)
            objectWillChange.send()
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

    @Published var slackConnectionState: ChatOpsConnectionState = .disconnected

    var slackBotToken: String? {
        get { keychain.retrieve(service: Self.keychainService, account: AppSettings.chatOpsSlackBotTokenKey) }
        set {
            if let value = newValue {
                _ = keychain.save(value: value, service: Self.keychainService, account: AppSettings.chatOpsSlackBotTokenKey)
            } else {
                _ = keychain.delete(service: Self.keychainService, account: AppSettings.chatOpsSlackBotTokenKey)
            }
            objectWillChange.send()
        }
    }

    var slackAppToken: String? {
        get { keychain.retrieve(service: Self.keychainService, account: AppSettings.chatOpsSlackAppTokenKey) }
        set {
            if let value = newValue {
                _ = keychain.save(value: value, service: Self.keychainService, account: AppSettings.chatOpsSlackAppTokenKey)
            } else {
                _ = keychain.delete(service: Self.keychainService, account: AppSettings.chatOpsSlackAppTokenKey)
            }
            objectWillChange.send()
        }
    }

    var slackAuthorizedChannelID: String? {
        get { UserDefaults.standard.string(forKey: AppSettings.chatOpsSlackChannelIDKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsSlackChannelIDKey)
            objectWillChange.send()
        }
    }

    var slackBotUsername: String? {
        get { UserDefaults.standard.string(forKey: "chatOpsSlackBotUsername") }
        set {
            UserDefaults.standard.set(newValue, forKey: "chatOpsSlackBotUsername")
            objectWillChange.send()
        }
    }

    var slackTeamName: String? {
        get { UserDefaults.standard.string(forKey: "chatOpsSlackTeamName") }
        set {
            UserDefaults.standard.set(newValue, forKey: "chatOpsSlackTeamName")
            objectWillChange.send()
        }
    }

    var isSlackEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: AppSettings.chatOpsSlackEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsSlackEnabledKey)
            objectWillChange.send()
        }
    }

    var slackActiveConversationID: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: AppSettings.chatOpsSlackActiveConversationIDKey) else { return nil }
            return UUID(uuidString: str)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: AppSettings.chatOpsSlackActiveConversationIDKey)
            objectWillChange.send()
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
