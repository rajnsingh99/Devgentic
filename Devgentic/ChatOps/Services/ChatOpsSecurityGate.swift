// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsSecurityGate.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import os

/// Enforces chat_id whitelisting, rate limiting, and security tier permissions
/// for all incoming Telegram updates.
actor ChatOpsSecurityGate {

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "ChatOpsSecurity")

    // MARK: - Rate Limiter State

    /// Token bucket rate limiter: 30 tokens/minute, refilled every 2 seconds.
    private var tokens: Double = 30.0
    private let maxTokens: Double = 30.0
    private let refillRate: Double = 1.0 // tokens per second (30 per 30s ≈ 1/s)
    private var lastRefillTime: Date = Date()

    // MARK: - Authorization

    /// Checks whether an incoming update is authorized to be processed.
    /// - Returns: `true` if the update passes all security checks.
    func authorize(_ update: TelegramUpdate, config: ChatOpsConfigManager) async -> Bool {
        guard let chatID = update.chatID else {
            logger.debug("Dropped update with no chat ID.")
            return false
        }

        // 1. Chat ID whitelist
        let authorizedID = await config.authorizedChatID
        guard chatID == authorizedID else {
            logger.warning("Unauthorized chat_id \(chatID) attempted access. Dropping silently.")
            return false
        }

        // 2. Rate limit
        refillTokens()
        guard tokens >= 1.0 else {
            logger.warning("Rate limit exceeded for chat_id \(chatID). Dropping update.")
            return false
        }
        tokens -= 1.0

        return true
    }

    // MARK: - Tier Enforcement

    /// Checks whether a parsed command is allowed under the current security tier.
    func canExecute(_ command: ChatOpsCommand, tier: ChatOpsSecurityTier) -> Bool {
        switch command {
        // Always allowed at any tier
        // ⚠️ `.conversationPage` sits with `.conversations` because it IS one — the same read,
        // from a different offset. Anything stricter would let a user list their conversations and
        // then be refused the second page of the same list.
        case .conversations, .conversationPage, .searchConversations, .conversationHistory,
             .status, .help, .profiles, .unknown:
            return true

        // Requires at least .standard
        // ⚠️ `.selectProfile` / `.useProfile` REBIND the conversation's agent, so they sit with the
        // other state-changing verbs rather than with the read-only ones. They deliberately do NOT
        // need `.full`: choosing which configured profile answers is not tool approval.
        // ⚠️ `.answerClarification` sits with `.clarificationResponse` because it IS one — the same
        // act reached through a modal instead of a typed reply. Putting it with the `.full` group
        // would make the button openable and the answer refusable, which reads as a broken modal.
        case .newConversation, .freeText, .cancel, .switchConversation, .clarificationResponse,
             .answerClarification, .selectProfile, .useProfile:
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
             .answerClarification, .selectProfile, .useProfile:
            return "This action requires at least *Standard* security tier.\nChange this in Devgentic → Settings → ChatOps."
        default:
            return "This action is not permitted under the current security tier."
        }
    }

    // MARK: - Discord Authorization

    /// Checks whether an incoming Discord message is from the authorized channel.
    /// - Returns: `true` if the message passes all security checks.
    func authorizeDiscord(channelID: String, config: ChatOpsConfigManager) async -> Bool {
        // 1. Channel whitelist
        let authorizedChannel = await config.discordAuthorizedChannelID
        guard channelID == authorizedChannel else {
            logger.warning("Unauthorized Discord channel \(channelID) attempted access. Dropping silently.")
            return false
        }

        // 2. Rate limit (shared bucket)
        refillTokens()
        guard tokens >= 1.0 else {
            logger.warning("Rate limit exceeded for Discord channel \(channelID). Dropping update.")
            return false
        }
        tokens -= 1.0

        return true
    }

    // MARK: - Slack Authorization

    /// Checks whether an incoming Slack message is from the authorized channel.
    func authorizeSlack(channelID: String, config: ChatOpsConfigManager) async -> Bool {
        let authorizedChannel = await config.slackAuthorizedChannelID
        guard channelID == authorizedChannel else {
            logger.warning("Unauthorized Slack channel \(channelID) attempted access. Dropping silently.")
            return false
        }

        refillTokens()
        guard tokens >= 1.0 else {
            logger.warning("Rate limit exceeded for Slack channel \(channelID). Dropping update.")
            return false
        }
        tokens -= 1.0

        return true
    }

    // MARK: - Token Bucket Internals

    private func refillTokens() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefillTime)
        tokens = min(maxTokens, tokens + elapsed * refillRate)
        lastRefillTime = now
    }
}
