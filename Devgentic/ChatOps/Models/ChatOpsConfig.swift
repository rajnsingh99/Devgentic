// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsConfig.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Security
import SwiftUI

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

// MARK: - Tool Approvals

// Why: no remote verb may grant it: a command that gives its own sender unattended shell is a privilege escalation.
/// Whether a remote-started run stops for tool approval. `.ask` is the default; `.autonomous` skips the prompt
/// for every tool, including `execute_shell`, so it is chosen only in the Mac's Settings pane, per platform, at `.full`.
enum ChatOpsToolApprovals: String, Codable, CaseIterable, Identifiable {
    /// Mirror the request and wait for a tap. The default.
    case ask
    /// Approve everything for a run this platform started, so a long run never stops.
    case autonomous

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .ask:        return "Ask me"
        case .autonomous: return "Autonomous"
        }
    }

    var description: String {
        switch self {
        case .ask:        return "Mirror each tool request and wait for Approve or Deny"
        case .autonomous: return "Run tools without asking — including shell commands"
        }
    }

    var isAutonomous: Bool { self == .autonomous }
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

    /// Whether this state means paired, but every remote command will be refused.
    /// Distinct from other `.error` states, which re-pairing does not fix; callers offering re-pairing check this.
    var needsRepairing: Bool {
        if case .error(let message) = self { return message == ChatOpsPairingRestore.needsRepairingMessage }
        return false
    }

    /// The status a user should read, given whether the listener is switched on.
    /// `.connected` means a pairing exists, not that messages arrive, so a switched-off listener reads as paired but off.
    func statusText(listenerEnabled: Bool) -> String {
        guard case .connected = self, !listenerEnabled else { return statusText }
        return "Paired — listener off"
    }
}

// MARK: - ChatOps Configuration

/// What a credential wipe actually deleted, so a disconnect cannot report success while a token is still stored.
struct ChatOpsCredentialClearSummary: Equatable, Sendable {

    /// One credential whose Keychain delete did not succeed.
    struct Failure: Equatable, Sendable {
        let label: String
        let status: OSStatus
    }

    var failures: [Failure] = []

    /// `errSecItemNotFound` is NOT a failure — the goal of a clear is "nothing stored", and it
    /// already was. Everything else (a locked Keychain's `errSecAuthFailed`, a denied ACL prompt's
    /// `errSecInteractionNotAllowed`) means the credential is still on this Mac.
    var allCleared: Bool { failures.isEmpty }

    var failedLabels: [String] { failures.map(\.label) }
}

// Why: `.absent` and `.unreadable` must never collapse: a locked Keychain would read as "never paired" and offer pairing again.
/// What a credential read actually told us.
enum ChatOpsCredentialState: Equatable {
    case present
    case absent
    case unreadable(OSStatus)

    // Why: `unreadable` dominates: one Slack token present and the other unreadable is an outage, not a partial pairing.
    /// Folds a set of credential reads into one verdict.
    static func combining(_ states: [ChatOpsCredentialState]) -> ChatOpsCredentialState {
        if let failure = states.first(where: { if case .unreadable = $0 { return true }; return false }) {
            return failure
        }
        return states.allSatisfy { $0 == .present } ? .present : .absent
    }
}

enum ChatOpsPairingRestore {

    /// Shown for a pairing that records no authorized account; matched exactly by `ChatOpsConnectionState.needsRepairing`,
    /// which is how the Settings pane tells it apart from a terminal token failure.
    static let needsRepairingMessage =
        "This pairing predates per-sender authorization and records no account, so every remote command is refused. Start pairing again to fix it."

    // Why: kept distinct from `needsRepairingMessage` so `needsRepairing` does not match it and offer the pairing button.
    /// Shown when stored credentials cannot be read from the Keychain; the fix is to unlock the Keychain, not to re-pair.
    static let unreadableMessage =
        "Your ChatOps credentials are stored but could not be read from the Keychain, so the bridge cannot start. Nothing has been lost — unlock your Keychain, or re-grant access after an app update, and reopen this pane. Do not re-pair: that would replace a credential that is still intact."

    /// Returns a provider's connection state at launch from what is on disk: credentials, address and authorized sender.
    /// - Parameter credentials: whether the tokens are present, absent, or unreadable.
    /// - Parameter authorizedUserID: the account recorded at pairing; nil is a pairing from before sender checks.
    static func state(credentials: ChatOpsCredentialState,
                      addressPresent: Bool,
                      authorizedUserID: String?,
                      chatID: Int64) -> ChatOpsConnectionState {
        // Checked first, before `addressPresent`: an unreadable Keychain must never read as `.disconnected` (never paired).
        if case .unreadable = credentials { return .error(unreadableMessage) }
        guard credentials == .present, addressPresent else { return .disconnected }
        guard authorizedUserID != nil else { return .error(needsRepairingMessage) }
        return .connected(chatID: chatID)
    }
}

/// Manages ChatOps state, persisted to UserDefaults (non-sensitive) and Keychain (tokens).
@Observable
@MainActor
final class ChatOpsConfigManager {

    static let shared = ChatOpsConfigManager()

    // Why: the test host's default Keychain cannot fail, so the failed save and delete branches need this seam.
    /// The backend behind every credential read and write; production never reassigns it, tests replace it.
    nonisolated(unsafe) private(set) var keychain: any KeychainAccessing = SecureKeyStorage()

    /// Swaps the Keychain backend. Test-only — pass nil to restore the real one.
    static func setKeychainForTesting(_ replacement: (any KeychainAccessing)?) {
        shared.keychain = replacement ?? SecureKeyStorage()
    }

    private let logger = DGLogger(category: "ChatOpsConfig")
    nonisolated private static let keychainService = Bundle.main.bundleIdentifier ?? "app.devgentic.macos"

    // MARK: - Credential read cache
    // One memoized value per account; only a definitive found or not-found enters the cache.
    // A failed read is never memoized, so the next getter call retries and a recovered Keychain is seen at once.

    private var credentialCache: [String: String?] = [:]

    private func readCredential(_ account: String) -> String? {
        if let cached = credentialCache[account] { return cached }
        switch keychain.read(service: Self.keychainService, account: account) {
        case .found(let value):
            credentialCache[account] = .some(value)
            return value
        case .notFound:
            credentialCache[account] = .some(nil)
            return nil
        case .failed(let status):
            logger.error(
                "[SECRETS] Could not read the ChatOps credential '\(account)' "
                + "(\(SecureKeyStorage.osStatusName(status))). CONSEQUENCE: this read reports "
                + "absent, but the result is deliberately NOT cached — the next read retries the "
                + "Keychain, so a recovered keychain is observed on the following access. Nothing "
                + "is written or deleted off this answer."
            )
            return nil
        }
    }

    /// Drops the memoized credential values so the next read hits the Keychain. A test that swaps
    /// backends must call it — a stale entry from the previous backend would otherwise survive the
    /// swap.
    func refreshCredentialCache() {
        credentialCache.removeAll()
    }

    // Why: `nonisolated static` with an injected keychain so the failed-to-unreadable mapping is testable without the singleton.
    /// Reads one ChatOps credential, distinguishing not stored from could not look.
    /// Used by the restore path; the getters return `String?` because they run in view bodies and cannot record a failure.
    nonisolated static func credentialState(
        _ account: String,
        keychain: KeychainAccessing,
        logger: DGLogger? = nil
    ) -> ChatOpsCredentialState {
        switch keychain.read(service: keychainService, account: account) {
        case .found:
            return .present
        case .notFound:
            return .absent
        case .failed(let status):
            logger?.error(
                "[CHATOPS] Could not read the credential '\(account)' from the Keychain "
                + "(OSStatus \(status)) — this is NOT the same as it being absent. CONSEQUENCE: this "
                + "provider is reported as UNREADABLE rather than unpaired, so the Settings pane does "
                + "not offer to re-pair and overwrite a credential that is still intact; the bridge "
                + "stays down until the Keychain is readable."
            )
            return .unreadable(status)
        }
    }

    // Why: a test of `ChatOpsPairingRestore.state` alone would not cover how `init` derives it, so the decision lives here.
    /// Folds the per-provider credential reads into the three restore verdicts; `init` only stores the result.
    nonisolated static func restoreStates(
        keychain: KeychainAccessing,
        logger: DGLogger? = nil,
        telegram: (addressPresent: Bool, userID: String?, chatID: Int64),
        discord: (addressPresent: Bool, userID: String?, chatID: Int64),
        slack: (addressPresent: Bool, userID: String?)
    ) -> (telegram: ChatOpsConnectionState, discord: ChatOpsConnectionState, slack: ChatOpsConnectionState) {
        func state(_ account: String) -> ChatOpsCredentialState {
            credentialState(account, keychain: keychain, logger: logger)
        }
        return (
            telegram: ChatOpsPairingRestore.state(
                credentials: state(AppSettings.chatOpsBotTokenKey),
                addressPresent: telegram.addressPresent,
                authorizedUserID: telegram.userID,
                chatID: telegram.chatID),
            discord: ChatOpsPairingRestore.state(
                credentials: state(AppSettings.chatOpsDiscordBotTokenKey),
                addressPresent: discord.addressPresent,
                authorizedUserID: discord.userID,
                chatID: discord.chatID),
            // Slack needs both tokens, and `combining` lets `unreadable` dominate `absent`:
            // one present plus one unreadable is an outage, not a half-finished pairing.
            slack: ChatOpsPairingRestore.state(
                credentials: .combining([
                    state(AppSettings.chatOpsSlackBotTokenKey),
                    state(AppSettings.chatOpsSlackAppTokenKey),
                ]),
                addressPresent: slack.addressPresent,
                authorizedUserID: slack.userID,
                chatID: 0)
        )
    }

    var connectionState: ChatOpsConnectionState = .disconnected

    var botToken: String? {
        get {
            access(keyPath: \.botToken)
            // Cached three-state read; a failed read is never memoized (see `readCredential`). The restore path reads the backend
            // directly, so the user-facing state sees the truth; this cached value feeds only value-or-nothing consumers.
            return readCredential(AppSettings.chatOpsBotTokenKey)
        }
        set {
            if let value = newValue {
                _ = storeBotToken(value)
            } else {
                _ = clearBotToken()
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

    /// Telegram's security tier, stored per platform so a change on one tab never re-tiers the others.
    /// Three stored properties rather than one function, because `@Observable` tracks key paths;
    /// the switch helper below serves call sites that hold a provider in a variable.
    var securityTier: ChatOpsSecurityTier {
        get {
            access(keyPath: \.securityTier)
            return Self.tier(forKey: AppSettings.chatOpsSecurityTierKey)
        }
        set {
            withMutation(keyPath: \.securityTier) {
                UserDefaults.standard.set(newValue.rawValue, forKey: AppSettings.chatOpsSecurityTierKey)
            }
        }
    }

    /// Discord's security tier. See `securityTier`.
    var discordSecurityTier: ChatOpsSecurityTier {
        get {
            access(keyPath: \.discordSecurityTier)
            return Self.tier(forKey: Self.discordSecurityTierKey)
        }
        set {
            withMutation(keyPath: \.discordSecurityTier) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.discordSecurityTierKey)
            }
        }
    }

    /// Slack's security tier. See `securityTier`.
    var slackSecurityTier: ChatOpsSecurityTier {
        get {
            access(keyPath: \.slackSecurityTier)
            return Self.tier(forKey: Self.slackSecurityTierKey)
        }
        set {
            withMutation(keyPath: \.slackSecurityTier) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.slackSecurityTierKey)
            }
        }
    }

    /// Telegram's tool-approval mode. See `ChatOpsToolApprovals`.
    var toolApprovals: ChatOpsToolApprovals {
        get {
            access(keyPath: \.toolApprovals)
            return Self.approvals(forKey: Self.telegramToolApprovalsKey)
        }
        set {
            withMutation(keyPath: \.toolApprovals) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.telegramToolApprovalsKey)
            }
        }
    }

    /// Discord's tool-approval mode. See `ChatOpsToolApprovals`.
    var discordToolApprovals: ChatOpsToolApprovals {
        get {
            access(keyPath: \.discordToolApprovals)
            return Self.approvals(forKey: Self.discordToolApprovalsKey)
        }
        set {
            withMutation(keyPath: \.discordToolApprovals) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.discordToolApprovalsKey)
            }
        }
    }

    /// Slack's tool-approval mode. See `ChatOpsToolApprovals`.
    var slackToolApprovals: ChatOpsToolApprovals {
        get {
            access(keyPath: \.slackToolApprovals)
            return Self.approvals(forKey: Self.slackToolApprovalsKey)
        }
        set {
            withMutation(keyPath: \.slackToolApprovals) {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.slackToolApprovalsKey)
            }
        }
    }

    nonisolated static let telegramToolApprovalsKey = "chatOpsToolApprovals"
    nonisolated static let discordToolApprovalsKey = "chatOpsDiscordToolApprovals"
    nonisolated static let slackToolApprovalsKey = "chatOpsSlackToolApprovals"

    /// An absent key defaults to `.ask`, the setting that stops and shows the arguments.
    nonisolated private static func approvals(forKey key: String) -> ChatOpsToolApprovals {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = ChatOpsToolApprovals(rawValue: raw) else { return .ask }
        return value
    }

    func toolApprovals(for provider: RemoteChannel.Provider) -> ChatOpsToolApprovals {
        switch provider {
        case .telegram: return toolApprovals
        case .discord:  return discordToolApprovals
        case .slack:    return slackToolApprovals
        }
    }

    func setToolApprovals(_ value: ChatOpsToolApprovals, for provider: RemoteChannel.Provider) {
        switch provider {
        case .telegram: toolApprovals = value
        case .discord:  discordToolApprovals = value
        case .slack:    slackToolApprovals = value
        }
    }

    // Why: re-checks the tier, not only the UI: the stored value survives a drop to Standard or Read Only, which must revoke it.
    /// Whether this provider actually runs tools without asking.
    func isAutonomous(for provider: RemoteChannel.Provider) -> Bool {
        securityTier(for: provider) == .full && toolApprovals(for: provider).isAutonomous
    }

    nonisolated static let discordSecurityTierKey = "chatOpsDiscordSecurityTier"
    nonisolated static let slackSecurityTierKey = "chatOpsSlackSecurityTier"

    /// An absent key defaults to `.readOnly`: a provider never given a tier starts at the least privilege.
    nonisolated private static func tier(forKey key: String) -> ChatOpsSecurityTier {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let tier = ChatOpsSecurityTier(rawValue: raw) else { return .readOnly }
        return tier
    }

    /// The tier governing one provider.
    func securityTier(for provider: RemoteChannel.Provider) -> ChatOpsSecurityTier {
        switch provider {
        case .telegram: return securityTier
        case .discord:  return discordSecurityTier
        case .slack:    return slackSecurityTier
        }
    }

    func setSecurityTier(_ tier: ChatOpsSecurityTier, for provider: RemoteChannel.Provider) {
        switch provider {
        case .telegram: securityTier = tier
        case .discord:  discordSecurityTier = tier
        case .slack:    slackSecurityTier = tier
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

    // Why: authorizes the sender, not the chat: a group or channel identifies a room, and every member could send commands.
    /// The one remote account allowed to drive this Mac over Telegram, recorded when the PIN matches.
    /// Nil is refused, not waved through: a pairing without a recorded sender fails closed and names re-pairing as the fix.
    var authorizedUserID: String? {
        get {
            access(keyPath: \.authorizedUserID)
            return UserDefaults.standard.string(forKey: "chatOpsAuthorizedUserID")
        }
        set {
            withMutation(keyPath: \.authorizedUserID) {
                UserDefaults.standard.set(newValue, forKey: "chatOpsAuthorizedUserID")
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

    /// Forwards over `RemoteSessionStore`, keeping the `access`/`withMutation` wrappers so `@Observable` invalidation works.
    var activeConversationID: UUID? {
        get {
            access(keyPath: \.activeConversationID)
            return RemoteSessionStore.shared.activeConversation(for: .telegram)
        }
        set {
            withMutation(keyPath: \.activeConversationID) {
                RemoteSessionStore.shared.setActiveConversation(newValue, for: .telegram)
            }
        }
    }

    // MARK: - Discord Configuration

    var discordConnectionState: ChatOpsConnectionState = .disconnected

    var discordBotToken: String? {
        get {
            access(keyPath: \.discordBotToken)
            return readCredential(AppSettings.chatOpsDiscordBotTokenKey)
        }
        set {
            if let value = newValue {
                _ = storeDiscordBotToken(value)
            } else {
                _ = clearDiscordBotToken()
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

    /// The ONE Discord account allowed to drive this Mac. See `authorizedUserID`.
    var discordAuthorizedUserID: String? {
        get {
            access(keyPath: \.discordAuthorizedUserID)
            return UserDefaults.standard.string(forKey: "chatOpsDiscordAuthorizedUserID")
        }
        set {
            withMutation(keyPath: \.discordAuthorizedUserID) {
                UserDefaults.standard.set(newValue, forKey: "chatOpsDiscordAuthorizedUserID")
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

    /// Forwards over `RemoteSessionStore`; see `activeConversationID`.
    var discordActiveConversationID: UUID? {
        get {
            access(keyPath: \.discordActiveConversationID)
            return RemoteSessionStore.shared.activeConversation(for: .discord)
        }
        set {
            withMutation(keyPath: \.discordActiveConversationID) {
                RemoteSessionStore.shared.setActiveConversation(newValue, for: .discord)
            }
        }
    }

    // MARK: - Credential writes

    // Why: a property setter cannot return the `OSStatus`, so setter-only writes would report success over a failed save.
    /// The shared body behind every explicit credential write; returns the Keychain `OSStatus`.
    /// The property setters delegate here; callers that act on the result call these methods directly.
    @discardableResult
    private func writeCredential(
        _ value: String?,
        account: String,
        label: String,
        keyPath: KeyPath<ChatOpsConfigManager, String?>
    ) -> OSStatus {
        var status: OSStatus = errSecSuccess
        withMutation(keyPath: keyPath) {
            if let value {
                status = keychain.save(value: value, service: Self.keychainService, account: account)
                if status == errSecSuccess {
                    credentialCache[account] = .some(value)
                } else {
                    // An uncertain state must not survive in the cache.
                    credentialCache.removeValue(forKey: account)
                }
                if status != errSecSuccess {
                    logger.error(
                        "[SECRETS] Could not SAVE the \(label) to the Keychain (OSStatus \(status)). "
                        + "CONSEQUENCE: the credential is stored NOWHERE — the caller must treat this "
                        + "as a failure; reporting success would promise a pairing that cannot survive relaunch."
                    )
                }
            } else {
                status = keychain.delete(service: Self.keychainService, account: account)
                if status == errSecSuccess || status == errSecItemNotFound {
                    credentialCache[account] = .some(nil)
                } else {
                    credentialCache.removeValue(forKey: account)
                }
                if status != errSecSuccess && status != errSecItemNotFound {
                    logger.error(
                        "[SECRETS] Could not DELETE the \(label) from the Keychain (OSStatus \(status)). "
                        + "CONSEQUENCE: the credential is still stored — the caller must not report it as cleared."
                    )
                }
            }
        }
        return status
    }

    /// Stores the Telegram bot token. `- Returns:` the Keychain status; `errSecSuccess` = stored.
    @discardableResult
    func storeBotToken(_ value: String) -> OSStatus {
        writeCredential(value, account: AppSettings.chatOpsBotTokenKey, label: "Telegram bot token", keyPath: \.botToken)
    }

    /// Deletes the Telegram bot token. `errSecItemNotFound` = already absent, which counts as cleared.
    @discardableResult
    func clearBotToken() -> OSStatus {
        writeCredential(nil, account: AppSettings.chatOpsBotTokenKey, label: "Telegram bot token", keyPath: \.botToken)
    }

    /// Stores the Discord bot token and returns the Keychain `OSStatus`.
    @discardableResult
    func storeDiscordBotToken(_ value: String) -> OSStatus {
        writeCredential(value, account: AppSettings.chatOpsDiscordBotTokenKey, label: "Discord bot token", keyPath: \.discordBotToken)
    }

    /// Deletes the Discord bot token. `errSecItemNotFound` = already absent, which counts as cleared.
    @discardableResult
    func clearDiscordBotToken() -> OSStatus {
        writeCredential(nil, account: AppSettings.chatOpsDiscordBotTokenKey, label: "Discord bot token", keyPath: \.discordBotToken)
    }

    /// Stores the Slack bot token and returns the Keychain `OSStatus`.
    @discardableResult
    func storeSlackBotToken(_ value: String) -> OSStatus {
        writeCredential(value, account: AppSettings.chatOpsSlackBotTokenKey, label: "Slack bot token", keyPath: \.slackBotToken)
    }

    /// Deletes the Slack bot token. `errSecItemNotFound` = already absent, which counts as cleared.
    @discardableResult
    func clearSlackBotToken() -> OSStatus {
        writeCredential(nil, account: AppSettings.chatOpsSlackBotTokenKey, label: "Slack bot token", keyPath: \.slackBotToken)
    }

    /// Stores the Slack app-level token and returns the Keychain `OSStatus`.
    @discardableResult
    func storeSlackAppToken(_ value: String) -> OSStatus {
        writeCredential(value, account: AppSettings.chatOpsSlackAppTokenKey, label: "Slack app token", keyPath: \.slackAppToken)
    }

    /// Deletes the Slack app-level token. `errSecItemNotFound` = already absent, which counts as cleared.
    @discardableResult
    func clearSlackAppToken() -> OSStatus {
        writeCredential(nil, account: AppSettings.chatOpsSlackAppTokenKey, label: "Slack app token", keyPath: \.slackAppToken)
    }

    // Why: a separate literal from `unreadableMessage`, which says not to re-pair; the two must never collapse.
    /// Shown when a pairing's token write was refused by the Keychain; nothing was saved, so trying again is right.
    static let credentialSaveFailedMessage =
        "The bot token could not be saved to the Keychain, so nothing was paired and nothing was "
        + "overwritten. Unlock your login keychain — or click Allow if macOS asked for access — and try again."

    /// The error copy for a disconnect whose credential delete failed.
    static func clearFailedMessage(labels: [String]) -> String {
        "Disconnect could not delete \(labels.joined(separator: ", ")) from the Keychain, so this "
        + "integration is NOT fully disconnected — the credential is still stored on this Mac. "
        + "Unlock your login keychain, or allow Devgentic access, then disconnect again."
    }

    /// Records one credential-clear outcome. `errSecItemNotFound` is not a failure: the goal of a
    /// clear is "nothing stored", and it already was.
    private func recordClear(_ status: OSStatus, label: String, into summary: inout ChatOpsCredentialClearSummary) {
        guard status != errSecSuccess, status != errSecItemNotFound else { return }
        summary.failures.append(.init(label: label, status: status))
    }

    // MARK: - Reset

    /// Resets all Telegram ChatOps state (used on disconnect).
    /// - Returns: what the credential wipe did; callers log the failures. When a delete failed the connection is left in
    ///   `.error`, never `.disconnected`, so a clean disconnect is not reported over a stored token.
    @discardableResult
    func reset() -> ChatOpsCredentialClearSummary {
        var summary = ChatOpsCredentialClearSummary()
        recordClear(clearBotToken(), label: "the Telegram bot token", into: &summary)
        authorizedUserID = nil
        securityTier = .readOnly
        toolApprovals = .ask
        botUsername = nil
        authorizedChatID = nil
        isEnabled = false
        activeConversationID = nil
        connectionState = summary.allCleared
            ? .disconnected
            : .error(Self.clearFailedMessage(labels: summary.failedLabels))
        return summary
    }

    /// Resets all Discord ChatOps state (used on disconnect); returns the credential-wipe summary like `reset()`.
    @discardableResult
    func resetDiscord() -> ChatOpsCredentialClearSummary {
        var summary = ChatOpsCredentialClearSummary()
        recordClear(clearDiscordBotToken(), label: "the Discord bot token", into: &summary)
        discordAuthorizedUserID = nil
        // The tier goes with the pairing: a new pairing starts at Read Only, not at the previous Full Access.
        discordSecurityTier = .readOnly
        discordToolApprovals = .ask
        discordBotUsername = nil
        discordAuthorizedChannelID = nil
        discordApplicationID = nil
        discordGuildID = nil
        isDiscordEnabled = false
        discordActiveConversationID = nil
        discordConnectionState = summary.allCleared
            ? .disconnected
            : .error(Self.clearFailedMessage(labels: summary.failedLabels))
        return summary
    }

    // MARK: - Slack Configuration

    var slackConnectionState: ChatOpsConnectionState = .disconnected

    var slackBotToken: String? {
        get {
            access(keyPath: \.slackBotToken)
            return readCredential(AppSettings.chatOpsSlackBotTokenKey)
        }
        set {
            if let value = newValue {
                _ = storeSlackBotToken(value)
            } else {
                _ = clearSlackBotToken()
            }
        }
    }

    var slackAppToken: String? {
        get {
            access(keyPath: \.slackAppToken)
            return readCredential(AppSettings.chatOpsSlackAppTokenKey)
        }
        set {
            if let value = newValue {
                _ = storeSlackAppToken(value)
            } else {
                _ = clearSlackAppToken()
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

    /// The ONE Slack account allowed to drive this Mac. See `authorizedUserID`.
    var slackAuthorizedUserID: String? {
        get {
            access(keyPath: \.slackAuthorizedUserID)
            return UserDefaults.standard.string(forKey: "chatOpsSlackAuthorizedUserID")
        }
        set {
            withMutation(keyPath: \.slackAuthorizedUserID) {
                UserDefaults.standard.set(newValue, forKey: "chatOpsSlackAuthorizedUserID")
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

    /// Forwards over `RemoteSessionStore`; see `activeConversationID`.
    var slackActiveConversationID: UUID? {
        get {
            access(keyPath: \.slackActiveConversationID)
            return RemoteSessionStore.shared.activeConversation(for: .slack)
        }
        set {
            withMutation(keyPath: \.slackActiveConversationID) {
                RemoteSessionStore.shared.setActiveConversation(newValue, for: .slack)
            }
        }
    }

    /// Resets all Slack ChatOps state (used on disconnect).
    /// Slack folds two credentials; a failure on either one keeps the bridge in `.error`.
    @discardableResult
    func resetSlack() -> ChatOpsCredentialClearSummary {
        var summary = ChatOpsCredentialClearSummary()
        recordClear(clearSlackBotToken(), label: "the Slack bot token", into: &summary)
        recordClear(clearSlackAppToken(), label: "the Slack app token", into: &summary)
        slackAuthorizedUserID = nil
        slackSecurityTier = .readOnly
        slackToolApprovals = .ask
        slackBotUsername = nil
        slackTeamName = nil
        slackAuthorizedChannelID = nil
        isSlackEnabled = false
        slackActiveConversationID = nil
        slackConnectionState = summary.allCleared
            ? .disconnected
            : .error(Self.clearFailedMessage(labels: summary.failedLabels))
        return summary
    }

    private init() {
        // `connectionState` says whether a usable pairing exists (credentials, address, authorized sender), not whether the
        // listener runs; that is `isEnabled`. The derivation lives in `restoreStates`; this only stores it.
        let restored = Self.restoreStates(
            keychain: keychain,
            logger: logger,
            telegram: (authorizedChatID != nil, authorizedUserID, authorizedChatID ?? 0),
            discord: (discordAuthorizedChannelID != nil, discordAuthorizedUserID,
                      Int64(discordAuthorizedChannelID ?? "0") ?? 0),
            slack: (slackAuthorizedChannelID != nil, slackAuthorizedUserID)
        )
        connectionState = restored.telegram
        discordConnectionState = restored.discord
        slackConnectionState = restored.slack
    }
}
