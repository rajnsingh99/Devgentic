// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsSecurityGate.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Enforces chat_id whitelisting, rate limiting, and security tier permissions
/// for all incoming Telegram updates.
actor ChatOpsSecurityGate {

    private let logger = DGLogger(category: "ChatOpsSecurity")

    // MARK: - Rate Limiter State

    /// Token bucket: 1 token per second, burst 30; a sender may send 30 commands at once and then one per second.
    /// One bucket spans all three providers: ChatOps is single-user, so the limit bounds what one operator can drive.
    private var tokens: Double = 30.0
    private let maxTokens: Double = 30.0
    private let refillRate: Double = 1.0

    // Why: wall-clock time can move backwards (NTP, timezone, clock change), giving a negative elapsed that removes tokens;
    // `max(0,…)` stays as a second guard
    /// Monotonic timestamp of the last refill (`systemUptime`), not `Date()`.
    private var lastRefill: TimeInterval

    /// Injected clock so backward-clock and refill behaviour can be tested over time.
    private let now: @Sendable () -> TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.lastRefill = now()
    }

    // MARK: - Authorization

    /// Checks whether an incoming update is authorized to be processed.
    /// - Returns: `true` if the update passes all security checks.
    func authorize(_ update: TelegramUpdate, config: ChatOpsConfigManager) async -> RemoteAuthorization {
        guard let chatID = update.chatID else {
            // `.debug` on purpose: an update with no chat id is a non-event (Telegram sends channel-post edits and poll state
            // on every poll), not a dropped command. Everything below refuses something addressed to us and is logged.
            logger.debug("Dropped a Telegram update carrying no chat id — not addressed to any chat.")
            return .refused(RemoteRefusal(reason: .unattributable,
                                          consequence: "nothing was routed; an update with no chat id is not addressed to this Mac and cannot be answered"))
        }

        // 1. Chat ID whitelist
        let authorizedID = await config.authorizedChatID
        guard chatID == authorizedID else {
            logger.warning("[CHATOPS] A Telegram message from unauthorized chat \(chatID) was refused. CONSEQUENCE: it was dropped and NOT answered — deliberately. Replying would confirm to an unpaired chat that a Devgentic Mac is listening here, and hand it free amplification.")
            return .refused(RemoteRefusal(reason: .unauthorizedChannel,
                                          consequence: "dropped in silence; answering an unpaired chat confirms this Mac is listening"))
        }

        // 1b. Sender whitelist: the chat is the room, this is the person; in a group chat the chat check alone
        // authorizes every member. A callback query's `from` is always present, a message's is optional; both are read.
        let sender = update.message?.from?.id.description
            ?? update.callback_query.map { $0.from.id.description }
        let expectedSender = await config.authorizedUserID
        guard senderIsAuthorized(sender, expected: expectedSender, platform: "Telegram") else {
            return .refused(RemoteRefusal(reason: expectedSender == nil ? .pairingPredatesAuthorization : .unauthorizedSender,
                                          consequence: "dropped in silence; the sender is not the paired account, and answering a bystander in a shared chat would confirm this Mac is listening"))
        }

        // 2. Rate limit, after identity: the sender has proved to be the paired operator, so a throttle refusal can be answered.
        refillTokens()
        guard tokens >= 1.0 else {
            let retry = retryInterval()
            logger.warning("[CHATOPS] A Telegram command from the paired operator was refused by the rate limiter (retry in \(String(format: "%.1f", retry))s). CONSEQUENCE: the command did NOT run. Unlike every other refusal here the operator IS told, because they have already proved who they are — before this they saw exactly what an intruder saw: silence.")
            return .refused(RemoteRefusal(reason: .rateLimited(retryIn: retry),
                                          consequence: "the command did not run and the operator is told, once per window"))
        }
        tokens -= 1.0

        return .authorized
    }

    // MARK: - Tier Enforcement

    /// Checks whether a parsed command is allowed under the current security tier.
    func canExecute(_ command: ChatOpsCommand, tier: ChatOpsSecurityTier) -> Bool {
        switch command {
        // Always allowed at any tier. `.conversationPage` is a page of `.conversations`; `.searchConversations` is a
        // title-only filter of it. Message bodies are gated separately, under `.conversationHistory`.
        case .conversations, .conversationPage, .searchConversations,
             .status, .help, .profiles, .unknown:
            return true

        // Requires at least `.standard`: state-changing verbs, incl. profile rebinding and clarification answers.
        // `.conversationHistory` is here, not in the always-allowed arm: it returns full message bodies, not just titles.
        case .newConversation, .freeText, .cancel, .switchConversation, .clarificationResponse,
             .answerClarification, .selectProfile, .useProfile, .conversationHistory:
            return tier == .standard || tier == .full

        // Requires .full — a gate choice unblocks downstream execution, like a tool approval.
        case .approveHITL, .denyHITL, .gateChoiceHITL:  // operationID ignored for tier check
            return tier == .full

        // Pairing is always allowed (handled before normal command flow)
        case .pairingAttempt:
            return true
        }
    }

    /// Returns a user-friendly denial message for the given command.
    func denialMessage(for command: ChatOpsCommand, tier: ChatOpsSecurityTier) -> String {
        switch command {
        case .approveHITL, .denyHITL, .gateChoiceHITL:  // operationID ignored for tier check
            return "Tool approval requires *Full Access* security tier.\nChange this in Devgentic → Settings → ChatOps."
        case .newConversation, .freeText, .cancel, .switchConversation, .clarificationResponse,
             .answerClarification, .selectProfile, .useProfile, .conversationHistory:
            return "This action requires at least *Standard* security tier.\nChange this in Devgentic → Settings → ChatOps."
        default:
            return "This action is not permitted under the current security tier."
        }
    }

    // MARK: - Discord Authorization

    /// Checks whether an incoming Discord message is from the authorized channel.
    /// - Returns: `true` if the message passes all security checks.
    func authorizeDiscord(channelID: String, senderID: String?, config: ChatOpsConfigManager) async -> RemoteAuthorization {
        // 1. Channel whitelist
        let authorizedChannel = await config.discordAuthorizedChannelID
        guard channelID == authorizedChannel else {
            logger.warning("[CHATOPS] A Discord message from unauthorized channel \(channelID) was refused. CONSEQUENCE: it was dropped and NOT answered — deliberately. Replying would confirm to an unpaired channel that a Devgentic Mac is listening here.")
            return .refused(RemoteRefusal(reason: .unauthorizedChannel,
                                          consequence: "dropped in silence; answering an unpaired channel confirms this Mac is listening"))
        }

        // 1b. Sender whitelist: a Discord channel id is a room inside a guild, never a person.
        let expectedSender = await config.discordAuthorizedUserID
        guard senderIsAuthorized(senderID, expected: expectedSender, platform: "Discord") else {
            return .refused(RemoteRefusal(reason: expectedSender == nil ? .pairingPredatesAuthorization : .unauthorizedSender,
                                          consequence: "dropped in silence; the sender is not the paired account, and answering a bystander in a shared channel would confirm this Mac is listening"))
        }

        // 2. Rate limit (shared bucket)
        refillTokens()
        guard tokens >= 1.0 else {
            let retry = retryInterval()
            logger.warning("[CHATOPS] A Discord command from the paired operator was refused by the rate limiter (retry in \(String(format: "%.1f", retry))s). CONSEQUENCE: the command did NOT run; the operator IS told, because by this point they have proved who they are.")
            return .refused(RemoteRefusal(reason: .rateLimited(retryIn: retry),
                                          consequence: "the command did not run and the operator is told, once per window"))
        }
        tokens -= 1.0

        return .authorized
    }

    // MARK: - Slack Authorization

    /// Checks whether an incoming Slack message is from the authorized channel.
    func authorizeSlack(channelID: String, senderID: String?, config: ChatOpsConfigManager) async -> RemoteAuthorization {
        let authorizedChannel = await config.slackAuthorizedChannelID
        guard channelID == authorizedChannel else {
            logger.warning("[CHATOPS] A Slack message from unauthorized channel \(channelID) was refused. CONSEQUENCE: it was dropped and NOT answered — deliberately. Replying would confirm to an unpaired channel that a Devgentic Mac is listening here.")
            return .refused(RemoteRefusal(reason: .unauthorizedChannel,
                                          consequence: "dropped in silence; answering an unpaired channel confirms this Mac is listening"))
        }

        // 1b. Sender whitelist: a Slack channel id is a room, never a person.
        let expectedSender = await config.slackAuthorizedUserID
        guard senderIsAuthorized(senderID, expected: expectedSender, platform: "Slack") else {
            return .refused(RemoteRefusal(reason: expectedSender == nil ? .pairingPredatesAuthorization : .unauthorizedSender,
                                          consequence: "dropped in silence; the sender is not the paired account, and answering a bystander in a shared channel would confirm this Mac is listening"))
        }

        refillTokens()
        guard tokens >= 1.0 else {
            let retry = retryInterval()
            logger.warning("[CHATOPS] A Slack command from the paired operator was refused by the rate limiter (retry in \(String(format: "%.1f", retry))s). CONSEQUENCE: the command did NOT run; the operator IS told, because by this point they have proved who they are.")
            return .refused(RemoteRefusal(reason: .rateLimited(retryIn: retry),
                                          consequence: "the command did not run and the operator is told, once per window"))
        }
        tokens -= 1.0

        return .authorized
    }

    // MARK: - Sender Authorization

    /// Whether this message came from the one account that completed pairing; a room check is an address, not an identity.
    /// Both nil cases fail closed: `expected == nil` (paired before the sender was recorded; re-pairing fixes it) and
    /// `sender == nil` (unattributable, so it cannot be trusted).
    func senderIsAuthorized(_ sender: String?, expected: String?, platform: String) -> Bool {
        guard let expected else {
            logger.error("[CHATOPS] A \(platform) message was refused because this pairing predates per-sender authorization and recorded no account. CONSEQUENCE: every remote command is refused until the user re-pairs from Settings — deliberately, because accepting an unverified sender is exactly the hole this check closes. Re-pairing records the account that proves it knows the PIN.")
            return false
        }
        guard let sender else {
            logger.error("[CHATOPS] A \(platform) message arrived with no sender id, so it cannot be attributed to the paired account. CONSEQUENCE: it is refused; an unattributable message is one whose authorization cannot be checked at all.")
            return false
        }
        guard sender == expected else {
            logger.error("[CHATOPS] A \(platform) message from account \(sender) was refused — it is not the account this Mac is paired with. CONSEQUENCE: the command did nothing. ChatOps authorizes ONE account; anyone else in a shared channel or group is a bystander, not an operator.")
            return false
        }
        return true
    }

    // MARK: - Token Bucket Internals

    // MARK: - Test seams
    // Test seams exposing only what tests need; the bucket is time-dependent and its policy stays private.

    func refillForTesting() { refillTokens() }
    func availableTokensForTesting() -> Double { tokens }
    @discardableResult
    func consumeTokenForTesting() -> Bool {
        refillTokens()
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    private func refillTokens() {
        let instant = now()
        // `max(0,…)` is applied to the elapsed time, not the total: a negative elapsed contributes nothing.
        let elapsed = max(0, instant - lastRefill)
        tokens = min(maxTokens, tokens + elapsed * refillRate)
        lastRefill = instant
    }

    /// Seconds until at least one token is available; shown in the user-facing copy so a throttled operator is told when.
    private func retryInterval() -> TimeInterval {
        tokens >= 1 ? 0 : (1 - tokens) / refillRate
    }
}
