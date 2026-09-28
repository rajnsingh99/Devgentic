// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsConfig.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
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

/// Whether a remote-started run stops for tool approval.
///
/// ⚠️⚠️ THE MOST PRIVILEGED SETTING IN CHATOPS, AND ITS SAFETY IS ITS SHAPE — the same argument
/// `OrbToolApprovals` rests on, which this deliberately mirrors. `.autonomous` means a message
/// from a phone runs `execute_shell` with no prompt on ANY surface: the banner is skipped, so no
/// `PendingHITL` exists and the mirror has nothing to post either. What keeps that defensible:
///
///   • `.ask` is the DEFAULT, and it already works — the mirror posts tappable Approve/Deny.
///   • Chosen from the Mac's Settings pane and NOWHERE ELSE. ⚠️ There is deliberately no remote
///     verb for it: a command that grants its own sender unattended shell is not a setting, it is
///     a privilege escalation. `ChatOpsCommand` must never gain one.
///   • Revealed only at the `.full` tier, and `isAutonomous(for:)` re-checks that — so dropping the
///     tier revokes it even though the stored value stays put.
///   • Per platform, so a private Telegram DM and a shared Slack channel can differ.
///   • Single-user: only the account that completed pairing can reach it (invariant 38).
///   • The GRANT it produces is in-memory and re-applied every turn, so a relaunch fails safe to
///     Ask — and the user can still answer the mirrored buttons.
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

    /// Whether this state means "paired, but every remote command will be refused".
    ///
    /// ⚠️ Distinct from `.error` in general: a terminal token failure is also `.error`, and that one
    /// is not fixed by re-pairing. Callers that want to offer re-pairing check this.
    var needsRepairing: Bool {
        if case .error(let message) = self { return message == ChatOpsPairingRestore.needsRepairingMessage }
        return false
    }

    /// The status a user should read, given whether the listener is switched on.
    ///
    /// ⚠️⚠️ `.connected` MEANS "A PAIRING EXISTS", NOT "MESSAGES ARE ARRIVING" — and once the
    /// restore stopped conflating the two (see `ChatOpsConfigManager.init`), a paired provider whose
    /// listener the user had switched off started reading "Connected". That is a smaller lie than
    /// the one it replaced, which greyed out the only control that could switch it back on, but it
    /// is still a lie: nothing is being received. The caller knows `isEnabled`; the vocabulary lives
    /// here, so it is composed here rather than at three call sites that could drift.
    func statusText(listenerEnabled: Bool) -> String {
        guard case .connected = self, !listenerEnabled else { return statusText }
        return "Paired — listener off"
    }
}

// MARK: - ChatOps Configuration

/// What a provider's connection state should be at launch, given what is actually on disk.
///
/// ⚠️⚠️ WHY THIS IS A FUNCTION AND NOT THREE INLINE `if`s. The restore used to read
/// `if let chatID = authorizedChatID, botToken != nil { connectionState = .connected(chatID:) }` —
/// credentials plus an ADDRESS — and said nothing about whether anyone is authorized to USE it.
/// Per-sender authorization (invariant 38) then made `authorizedUserID` load-bearing: it is written
/// only by a pairing service and nothing backfills it, so a pairing made before that build restores
/// with `authorizedUserID == nil` and `senderIsAuthorized` refuses EVERY inbound message. The UI,
/// reading `.connected`, painted a green dot over a bridge that could not answer anything, and the
/// remote user got silence. A green light over a dead path is worse than a red one.
///
/// ⚠️ THE REGISTER CALLED THIS AN "ACCEPTED COST" BECAUSE "THE LOG LINE SAYS SO EXPLICITLY". That was
/// wrong, and this function is the correction: a log line is not an affordance. The user is not
/// reading Console; they are looking at a green dot and wondering why their phone is ignored.
/// What a credential read actually told us. Register KC-10.
///
/// ⚠️⚠️ `.absent` AND `.unreadable` MUST NOT COLLAPSE. The four ChatOps getters returned `String?`
/// via `SecureKeyStorage.retrieve`, which maps both to nil — so a locked Keychain, or a denied ACL
/// prompt on the first launch after an update re-signed the binary, rendered as **"you have never
/// paired"**. All three bridges declined to start and the Settings pane offered "Start Pairing" for
/// a pairing that was intact the whole time. The user's only visible option was to redo a pairing
/// they never undid — on all three platforms.
/// What a credential wipe actually deleted. Register KC-12: "credentials cleared" used to be
/// logged unconditionally over `OSStatus` values nobody looked at, so a Keychain that refused the
/// delete reported a disconnected bridge while the bot token stayed stored and usable.
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

enum ChatOpsCredentialState: Equatable {
    case present
    case absent
    case unreadable(OSStatus)

    /// Folds a set of reads into one verdict. ⚠️ `unreadable` DOMINATES: Slack needs two tokens, and
    /// "one token present, the other unreadable" is not a partial pairing — it is an outage.
    static func combining(_ states: [ChatOpsCredentialState]) -> ChatOpsCredentialState {
        if let failure = states.first(where: { if case .unreadable = $0 { return true }; return false }) {
            return failure
        }
        return states.allSatisfy { $0 == .present } ? .present : .absent
    }
}

enum ChatOpsPairingRestore {

    /// ⚠️ MATCHED EXACTLY by `ChatOpsConnectionState.needsRepairing`, which is how the Settings pane
    /// tells this apart from a terminal token failure (also `.error`, but NOT fixed by re-pairing).
    /// One literal, one place.
    static let needsRepairingMessage =
        "This pairing predates per-sender authorization and records no account, so every remote command is refused. Start pairing again to fix it."

    /// ⚠️ DELIBERATELY NOT `needsRepairingMessage`. Re-pairing is the wrong advice here and would
    /// overwrite a working credential with a new one for no reason; the fix is to make the Keychain
    /// readable. Kept distinct so `needsRepairing` does not match it and offer the pairing button.
    static let unreadableMessage =
        "Your ChatOps credentials are stored but could not be read from the Keychain, so the bridge cannot start. Nothing has been lost — unlock your Keychain, or re-grant access after an app update, and reopen this pane. Do not re-pair: that would replace a credential that is still intact."

    /// - Parameter credentials: whether the tokens are present, absent, **or unreadable**.
    /// - Parameter authorizedUserID: the account recorded at pairing. ⚠️ NIL IS THE UPGRADE CASE,
    ///   not a corrupt install — it is what every pairing made before invariant 38 looks like.
    static func state(credentials: ChatOpsCredentialState,
                      addressPresent: Bool,
                      authorizedUserID: String?,
                      chatID: Int64) -> ChatOpsConnectionState {
        // ⚠️ FIRST, and before `addressPresent`. An unreadable Keychain must never be reported as
        // `.disconnected`, which is the state that renders as "never paired".
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

    /// ⚠️ TEST SEAM (registers KC-11 / KC-12). The backend behind every credential read/write, so
    /// the FAILED save/delete branches — the entire point of the explicit store/clear methods
    /// below — are reachable from a test. Mirrors `HuggingFaceTokenStore.setBackingForTesting`;
    /// production never reassigns it. Under the XCTest host the default already routes to
    /// `TestHostKeychain`, which cannot fail — which is precisely why this seam is needed.
    nonisolated(unsafe) private(set) var keychain: any KeychainAccessing = SecureKeyStorage()

    /// Swaps the Keychain backend. Test-only — pass nil to restore the real one.
    static func setKeychainForTesting(_ replacement: (any KeychainAccessing)?) {
        shared.keychain = replacement ?? SecureKeyStorage()
    }

    private let logger = DGLogger(category: "ChatOpsConfig")
    nonisolated private static let keychainService = Bundle.main.bundleIdentifier ?? "app.devgentic.macos"

    // MARK: - Credential read cache (registers KC-29 + KC-47)
    //
    // The four credential getters used to issue an uncached synchronous `SecItemCopyMatching` on
    // EVERY access — and the Settings pane evaluates several credentials per keystroke while the
    // notification-dispatch path reads them as well. One memoized value per account fixes that,
    // with the rule that makes it safe:
    //
    // ⚠️ A FAILED read is NEVER memoized. That is KC-8's bug shape — HuggingFaceTokenStore
    // memoized "no token" for the whole process lifetime off one locked-Keychain read. Only a
    // definitive `.found` / `.notFound` enters the cache; a `.failed` leaves no entry, so the
    // next getter call retries the Keychain and a recovered Keychain is observed immediately.

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

    /// Drops the memoized credential values so the next read hits the Keychain. The legacy
    /// migration in `init` writes through the same backend outside this cache, and a test that
    /// swaps backends must call it too — a stale entry from the previous backend would otherwise
    /// survive the swap.
    func refreshCredentialCache() {
        credentialCache.removeAll()
    }

    /// Reads one ChatOps credential, distinguishing "not stored" from "could not look". Register KC-10.
    ///
    /// ⚠️ Used by the RESTORE path, not by the four getters. The getters still return `String?` —
    /// they are reached from SwiftUI view bodies, and recording a failure from there would mean
    /// mutating observable state during a view update. The restore path runs in `init`, where it is
    /// safe, and it is the only place `connectionState` is derived.
    ///
    /// ⚠️ TEST SEAM: `nonisolated static` with an injected `keychain`, exactly like
    /// `migrateCredentialsFromLegacyServices(keychain:)` above. The manager is a singleton with a
    /// `private init`, so the restore cannot be re-run from a test; making the derivation static is
    /// what lets the `.failed → .unreadable` mapping be exercised at all.
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

    /// Folds the per-provider credential reads into the three restore verdicts.
    ///
    /// ⚠️ EXTRACTED SO THE WIRING IS TESTABLE, not for tidiness. Mutation-checking found that a
    /// test of `ChatOpsPairingRestore.state` alone stays green when `init` goes back to
    /// `botToken != nil ? .present : .absent` — i.e. it covers the policy and not the thing that
    /// actually decides what the user sees. This function is the decision; `init` only stores it.
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
            // ⚠️ Slack needs BOTH tokens, and `combining` lets `unreadable` dominate `absent`:
            // one present + one unreadable is an outage, not a half-finished pairing.
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
            // Cached three-state read (registers KC-29 / KC-47); a FAILED read is never
            // memoized — see `readCredential`. The KC-10 distinction survives: the
            // `credentialState`/`restoreStates` machine reads the backend DIRECTLY, so the
            // user-facing state still sees truth, while this cached value only ever feeds
            // "value or nothing" consumers.
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

    /// Telegram's security tier.
    ///
    /// ⚠️⚠️ ONE TIER USED TO GOVERN ALL THREE PLATFORMS WHILE BEING RENDERED INSIDE EACH PLATFORM'S
    /// OWN TAB. The Settings pane embeds the same `securityCard` in the Telegram, Discord and Slack
    /// stacks with no qualifier anywhere, so a user who set "Full Access" on Telegram — to approve
    /// tools from their phone — found the Discord tab already reading Full Access, and a user who
    /// then set Discord to "Read Only" silently dropped their phone to Read Only too, whereupon its
    /// approvals began failing with a message that named no cause.
    ///
    /// ⚠️ THE FILE ALREADY SOLVED THIS ONCE, FOR THE CURSOR. `ProviderSessionContext`'s header says
    /// a service reading the bare `activeConversationID` "would have moved Discord's conversation by
    /// writing Telegram's" — the tier is the same shape and simply never got the same treatment.
    ///
    /// ⚠️ THREE STORED PROPERTIES RATHER THAN ONE FUNCTION, because `@Observable` tracks key paths:
    /// a computed `securityTier(for:)` alone could not invalidate a view when the value changed.
    /// The switch helper below exists for call sites that hold a provider in a variable.
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

    /// ⚠️ ABSENT KEY → `.ask`. The default must be the one that stops and shows you the arguments.
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

    /// Whether this provider actually runs tools without asking.
    ///
    /// ⚠️⚠️ THE TIER IS RE-CHECKED HERE, NOT ONLY IN THE UI. The picker is revealed only at `.full`,
    /// but the stored value survives a later drop to Standard or Read Only — so a user who granted
    /// Autonomous and then tightened the tier would still be running unattended if this read the
    /// approvals setting alone. The UI hides it; this makes it actually stop.
    func isAutonomous(for provider: RemoteChannel.Provider) -> Bool {
        securityTier(for: provider) == .full && toolApprovals(for: provider).isAutonomous
    }

    nonisolated static let discordSecurityTierKey = "chatOpsDiscordSecurityTier"
    nonisolated static let slackSecurityTierKey = "chatOpsSlackSecurityTier"

    /// ⚠️ ABSENT KEY → `.readOnly`. A provider that has never had a tier chosen for it must start at
    /// the least-privileged one, not inherit whatever another platform was granted.
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

    /// Gives an ALREADY-PAIRED Discord or Slack the tier it has been running under.
    ///
    /// ⚠️⚠️ WITHOUT THIS THE FIX IS A SILENT DOWNGRADE. Splitting the tier means Discord and Slack
    /// start reading their own keys, which do not exist yet — so an install that had been running at
    /// Full Access would drop to Read Only on upgrade and its remote approvals would begin failing
    /// with a message naming no cause. Seeded only for a provider that is ALREADY paired; one paired
    /// after this runs gets `.readOnly`, which is the point of the split.
    private func seedPerProviderTiers() {
        let inherited = securityTier
        for (provider, isPaired, key) in [
            (RemoteChannel.Provider.discord, discordAuthorizedChannelID != nil, Self.discordSecurityTierKey),
            (RemoteChannel.Provider.slack, slackAuthorizedChannelID != nil, Self.slackSecurityTierKey)
        ] where isPaired && UserDefaults.standard.string(forKey: key) == nil {
            setSecurityTier(inherited, for: provider)
            logger.info("[CHATOPS] Seeded the \(provider.rawValue) security tier as '\(inherited.rawValue)', inherited from the single tier that used to govern all three platforms. CONSEQUENCE: an already-paired provider keeps the access it has been running under instead of silently dropping to Read Only; a provider paired from now on starts at Read Only.")
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

    /// The ONE remote account allowed to drive this Mac over Telegram.
    ///
    /// ⚠️⚠️ CHATOPS IS A SINGLE-USER REMOTE CONTROL, AND THIS IS WHERE THAT IS ENFORCED RATHER THAN
    /// ASSUMED. Authorization used to compare the CHAT (or, on Discord and Slack, the CHANNEL) and
    /// nothing else. A Telegram chat id in a DM happens to identify a person, so the assumption held
    /// there by accident — but a Telegram group, a Discord channel and a Slack channel all identify a
    /// ROOM, and every member of one could send commands, answer clarifications, and at `.full` tap
    /// Approve on a mirrored tool call. The sender was on the wire the whole time and decoded; it was
    /// simply never compared. Recorded at the moment the PIN matches, from the same `origin` value the
    /// pairing lockout already computes.
    ///
    /// ⚠️ NIL IS REFUSED, NOT WAVED THROUGH. A pairing made before this existed has no recorded
    /// sender, and treating "unknown" as "anyone" is the original hole with extra steps. The gate
    /// fails closed and names re-pairing as the fix.
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

    /// ⚠️ FORWARDS OVER `RemoteSessionStore` — see that file. This used to read and write
    /// `UserDefaults` inline, as did its Discord and Slack twins: three copies of one concept.
    /// The storage is unchanged (same key, no migration); only the code path is now single.
    /// The `access`/`withMutation` wrappers are kept so `@Observable` invalidation still works —
    /// nothing observes these three today, but a settings row showing the bound conversation would.
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

    // MARK: - Credential writes (registers KC-11 / KC-12)

    /// The shared body behind every explicit credential write. Register KC-11: a Swift property
    /// setter cannot return the `OSStatus`, so every failed Keychain save/delete was discarded at
    /// these exact sites (`_ = keychain.save(…)`) and pairing kept reporting success over a
    /// credential that was never stored. The property setters now delegate HERE; callers that act
    /// on the result call these methods directly.
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

    /// Stores the Discord bot token. Register KC-11 — see `writeCredential`.
    @discardableResult
    func storeDiscordBotToken(_ value: String) -> OSStatus {
        writeCredential(value, account: AppSettings.chatOpsDiscordBotTokenKey, label: "Discord bot token", keyPath: \.discordBotToken)
    }

    /// Deletes the Discord bot token. `errSecItemNotFound` = already absent, which counts as cleared.
    @discardableResult
    func clearDiscordBotToken() -> OSStatus {
        writeCredential(nil, account: AppSettings.chatOpsDiscordBotTokenKey, label: "Discord bot token", keyPath: \.discordBotToken)
    }

    /// Stores the Slack bot token. Register KC-11 — see `writeCredential`.
    @discardableResult
    func storeSlackBotToken(_ value: String) -> OSStatus {
        writeCredential(value, account: AppSettings.chatOpsSlackBotTokenKey, label: "Slack bot token", keyPath: \.slackBotToken)
    }

    /// Deletes the Slack bot token. `errSecItemNotFound` = already absent, which counts as cleared.
    @discardableResult
    func clearSlackBotToken() -> OSStatus {
        writeCredential(nil, account: AppSettings.chatOpsSlackBotTokenKey, label: "Slack bot token", keyPath: \.slackBotToken)
    }

    /// Stores the Slack app-level token. Register KC-11 — see `writeCredential`.
    @discardableResult
    func storeSlackAppToken(_ value: String) -> OSStatus {
        writeCredential(value, account: AppSettings.chatOpsSlackAppTokenKey, label: "Slack app token", keyPath: \.slackAppToken)
    }

    /// Deletes the Slack app-level token. `errSecItemNotFound` = already absent, which counts as cleared.
    @discardableResult
    func clearSlackAppToken() -> OSStatus {
        writeCredential(nil, account: AppSettings.chatOpsSlackAppTokenKey, label: "Slack app token", keyPath: \.slackAppToken)
    }

    /// Shown when a pairing's token write was refused by the Keychain. A SEPARATE literal from
    /// `unreadableMessage`, deliberately: that one says "do not re-pair" about a credential that
    /// exists and is intact; this one is the opposite case — nothing was saved, and trying again
    /// is exactly the right advice. A test pins that the two never collapse.
    static let credentialSaveFailedMessage =
        "The bot token could not be saved to the Keychain, so nothing was paired and nothing was "
        + "overwritten. Unlock your login keychain — or click Allow if macOS asked for access — and try again."

    /// The error copy for a disconnect whose credential delete failed. Register KC-12.
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

    /// Resets all Telegram ChatOps state (used on disconnect). Register KC-12.
    /// - Returns: what the credential wipe actually did — the caller must log the failures
    ///   instead of "credentials cleared". When a delete failed, the connection is left in
    ///   `.error`, never `.disconnected` — reporting a clean disconnect over a stored token is
    ///   the same lie `unreadableMessage` exists to prevent, one direction over.
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

    /// Resets all Discord ChatOps state (used on disconnect). Register KC-12 — see `reset()`.
    @discardableResult
    func resetDiscord() -> ChatOpsCredentialClearSummary {
        var summary = ChatOpsCredentialClearSummary()
        recordClear(clearDiscordBotToken(), label: "the Discord bot token", into: &summary)
        discordAuthorizedUserID = nil
        // ⚠️ The tier goes with the pairing — a new one must start at Read Only, not inherit Full Access.
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
    /// Resets all Slack ChatOps state (used on disconnect). Register KC-12 — see `reset()`.
    /// Slack folds TWO credentials; a failure on either one keeps the bridge in `.error`.
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

    // MARK: - Keychain Service Migration

    /// Keychain `service` strings earlier builds stored ChatOps credentials under, newest first.
    ///
    /// ⚠️⚠️ WHY THIS LIST EXISTS AT ALL. `keychainService` is `Bundle.main.bundleIdentifier`, and
    /// commit `2faad1c` changed that identifier from `com.dev.devgentic` to `app.devgentic.macos`
    /// as part of public-release prep. A Keychain item is addressed by (service, account), so on the
    /// first launch after that build EVERY ChatOps credential became unreachable at once: all four
    /// reads returned nothing, `isConfigured` went false, all three bridges declined to start, and
    /// the Settings UI offered "Start Pairing" as though the user had never paired. Nothing was
    /// deleted — the items were still there, addressed by a name no code asked for any more — so the
    /// three live third-party bot tokens would have sat in the user's Keychain forever.
    ///
    /// ⚠️ A RENAME IS NOT A ONE-OFF. Any future bundle-id change (a rebrand, a separate beta
    /// identifier, an Xcode target split) reproduces this exactly. Prepend the outgoing identifier
    /// here in the same commit that changes it, and this stays a migration rather than a data loss.
    ///
    /// ⚠️ Non-ChatOps state keys off the same identifier and has its OWN migration paths, which
    /// already exist and are tested: `VectorStoreService.legacyBundleIdentifiers` adopts a
    /// pre-rename vector-db, and `StoreRecovery` enumerates the legacy store locations for the
    /// reset dialog. A future rename must update THIS list and BOTH of those in the same commit —
    /// do not build a second adoption path here, and do not assume the others do not exist.
    nonisolated private static let legacyKeychainServices = ["com.dev.devgentic"]

    /// Every account this manager stores under `keychainService`.
    ///
    /// ⚠️ THE MIGRATION'S COVERAGE IS THIS LIST, so a credential added without adding it here is a
    /// credential the next rename silently drops.
    nonisolated private static let credentialAccounts = [
        AppSettings.chatOpsBotTokenKey,
        AppSettings.chatOpsDiscordBotTokenKey,
        AppSettings.chatOpsSlackBotTokenKey,
        AppSettings.chatOpsSlackAppTokenKey
    ]

    /// Moves credentials written under a previous bundle identifier onto the current one.
    ///
    /// Idempotent, and safe to run on every launch: an account already present under the current
    /// service is never overwritten, and a legacy item is only removed once its value is readable
    /// under the current service.
    ///
    /// ⚠️⚠️ `read` RATHER THAN `retrieve`, AND THE DIFFERENCE IS THE WHOLE SAFETY ARGUMENT.
    /// `retrieve` collapses "the Keychain refused to answer" into `nil`, which here would read as
    /// "nothing is stored under the current service" — and this function's response to that is to
    /// copy a legacy value forward and then DELETE it. Run that against a locked or re-signed
    /// Keychain (`errSecInteractionNotAllowed`) and the migration destroys the only copy. Every
    /// branch below therefore acts on `.found` / `.notFound` and bails loudly on `.failed`.
    @discardableResult
    nonisolated static func migrateCredentialsFromLegacyServices(
        keychain: KeychainAccessing,
        logger: DGLogger = DGLogger(category: "ChatOpsConfig")
    ) -> Int {
        var migrated = 0

        for account in credentialAccounts {
            switch keychain.read(service: keychainService, account: account) {
            case .found:
                // Already current. Sweep any stale legacy copy so a rotated token cannot linger.
                for legacy in legacyKeychainServices {
                    guard case .found = keychain.read(service: legacy, account: account) else { continue }
                    let status = keychain.delete(service: legacy, account: account)
                    if status == errSecSuccess {
                        logger.info("[CHATOPS] Removed the stale '\(account)' credential left under the previous Keychain service '\(legacy)'. CONSEQUENCE: the superseded copy no longer sits in the user's Keychain; the live credential under '\(keychainService)' is untouched.")
                    } else {
                        logger.error("[CHATOPS] Could not delete the stale '\(account)' credential under the previous Keychain service '\(legacy)' (OSStatus \(status)). CONSEQUENCE: a superseded third-party token stays in the user's Keychain indefinitely; ChatOps itself is unaffected because the current service already holds the live value.")
                    }
                }

            case .failed(let status):
                // ⚠️ NOT a migration trigger. See this function's header.
                logger.error("[CHATOPS] Could not read '\(account)' under the current Keychain service '\(keychainService)' (OSStatus \(status)). CONSEQUENCE: the legacy-service migration is SKIPPED for this credential rather than guessed at — copying a legacy value forward on an unreadable Keychain and then deleting it would destroy the only copy. ChatOps may report itself unconfigured until the Keychain is readable again.")

            case .notFound:
                for legacy in legacyKeychainServices {
                    guard case .found(let value) = keychain.read(service: legacy, account: account) else { continue }

                    let saveStatus = keychain.save(value: value, service: keychainService, account: account)
                    guard saveStatus == errSecSuccess else {
                        logger.error("[CHATOPS] Failed to migrate '\(account)' from the previous Keychain service '\(legacy)' to '\(keychainService)' (OSStatus \(saveStatus)). CONSEQUENCE: the credential stays readable ONLY under the old service, so this ChatOps provider will present as unconfigured and the user is asked to pair again; the legacy item is deliberately NOT deleted, so retrying after the Keychain is writable still recovers it.")
                        break
                    }

                    migrated += 1
                    let deleteStatus = keychain.delete(service: legacy, account: account)
                    if deleteStatus == errSecSuccess {
                        logger.info("[CHATOPS] Migrated '\(account)' from the previous Keychain service '\(legacy)' to '\(keychainService)'. CONSEQUENCE: the credential survives the bundle-identifier change, so a paired provider keeps working across the upgrade instead of silently presenting as never configured.")
                    } else {
                        logger.error("[CHATOPS] Migrated '\(account)' to '\(keychainService)' but could not delete the old item under '\(legacy)' (OSStatus \(deleteStatus)). CONSEQUENCE: ChatOps works correctly — the migration itself succeeded — but a duplicate copy of a live third-party token remains in the user's Keychain.")
                    }
                    break
                }
            }
        }

        return migrated
    }

    private init() {
        // ⚠️ FIRST, BEFORE ANY CREDENTIAL IS READ. Every restore check below reads a token, and a
        // token that has not yet been moved onto the current Keychain service reads as absent —
        // which would leave all three providers "disconnected" on the one launch that matters.
        Self.migrateCredentialsFromLegacyServices(keychain: keychain)
        // The migration wrote through the backend directly, outside the read cache.
        refreshCredentialCache()

        // ⚠️ AFTER the credential migration, because it reads whether a provider is paired.
        seedPerProviderTiers()

        // ⚠️⚠️ "IS PAIRED" AND "IS SWITCHED ON" ARE DIFFERENT QUESTIONS, AND CONFLATING THEM MADE THE
        // OFF SWITCH A ONE-WAY DOOR. These three conditions used to include `isEnabled`, so a user
        // who turned ChatOps off — which the toggle's own description invites, "Start the Telegram
        // long-polling listener… while this is on" — and then quit, came back to a
        // `.disconnected` state, a Pairing card offering "Start Pairing", and an Enable toggle
        // greyed out by `.disabled(!config.connectionState.isConnected)`. Nothing in the app could
        // turn it back on: the only other writer of `isEnabled = true` is a pairing service. Their
        // credentials and chat id were intact the whole time; the only way back was to re-do the
        // pairing they never undid, on all three platforms identically.
        //
        // ⚠️ `connectionState` describes whether a PAIRING EXISTS — credentials plus a chat or
        // channel id. Whether the listener is currently running is `isEnabled`, which
        // `ChatOpsCoordinator.bootstrap()` already consults separately; the two concerns are
        // correctly separated everywhere except here.
        //
        // ⚠️⚠️ AND "A PAIRING EXISTS" IS STILL NOT "SOMEONE IS AUTHORIZED TO USE IT" — the third
        // question, added with per-sender authorization (invariant 38). `authorizedUserID` is written
        // ONLY by a pairing service and nothing backfills it, so every pairing made before that build
        // restores with it nil and `senderIsAuthorized` refuses every inbound message. Reading only
        // the address here painted `.connected` — a green dot — over a bridge that could not answer
        // anything. `ChatOpsPairingRestore.state` asks all three questions; see it for why a log line
        // was not an adequate substitute for saying so in the UI.
        // ⚠️ The derivation lives in `restoreStates` so it can be tested; this only stores it.
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
