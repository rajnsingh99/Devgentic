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

    private let logger = DGLogger(category: "ChatOpsSecurity")

    // MARK: - Rate Limiter State

    /// Token bucket: **1 token per second, burst 30** — so a sender may send 30 commands at once and
    /// then one per second, and a fully-spent bucket is clear again after 30 seconds.
    ///
    /// ⚠️⚠️ THE THREE COMMENTS THIS REPLACES CONTRADICTED EACH OTHER AND THE CODE. They claimed
    /// "30 tokens/minute", "refilled every 2 seconds" and "30 per 30s ≈ 1/s" — three different rates
    /// over one implementation, none of them matching `refillRate = 1.0` with `maxTokens = 30`. A
    /// constant whose comment is wrong is worse than one with no comment: the next reader tunes the
    /// number the comment describes.
    ///
    /// ⚠️ ONE BUCKET ACROSS ALL THREE PROVIDERS, DELIBERATELY. ChatOps is single-user, so the limit
    /// exists to bound what ONE operator can drive — not to be fair between platforms. A per-provider
    /// bucket would let the same person spend three budgets at once.
    private var tokens: Double = 30.0
    private let maxTokens: Double = 30.0
    private let refillRate: Double = 1.0

    /// ⚠️⚠️ MONOTONIC, NOT `Date()`. Wall-clock time moves backwards — NTP correction, a timezone
    /// change, the user setting their clock — and `timeIntervalSince` then returns a NEGATIVE elapsed,
    /// which *removes* tokens from the bucket. `systemUptime` cannot go backwards.
    ///
    /// ⚠️ `max(0,…)` IS KEPT AS THE BELT anyway: a clamp that can never fire costs nothing, and the
    /// one that could is the reason this row was filed.
    private var lastRefill: TimeInterval

    /// ⚠️ INJECTED so the backward-clock and refill cases are testable at all; without a seam there is
    /// no way to assert a bucket's behaviour over time in a unit test.
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
            // ⚠️⚠️ `.debug` DELIBERATELY, AND THIS IS THE ONE DECISION TWO ROWS DISAGREED ABOUT.
            // An update with no chat id is a NON-EVENT, not a dropped command: Telegram sends
            // several such shapes (channel post edits, poll state) on every poll of a busy bot. This
            // is the `PairingAttemptPolicy.unrelated` precedent — a line per non-event buries the one
            // event that matters, and these arrive continuously. Everything BELOW this point is a
            // refusal of something addressed to us, and every one of those is logged.
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

        // 1b. Sender whitelist. ⚠️ The chat is the ROOM; this is the PERSON. In a Telegram DM the two
        //     coincide, which is why the chat check alone looked sufficient — in a GROUP chat it
        //     authorizes every member.
        //     ⚠️ A callback query's `from` is NON-optional on the wire — Telegram always attributes a
        //     button tap — while a message's is optional (channel posts carry none). Both are read,
        //     because a tap is as much a command as a typed line.
        let sender = update.message?.from?.id.description
            ?? update.callback_query.map { $0.from.id.description }
        let expectedSender = await config.authorizedUserID
        guard senderIsAuthorized(sender, expected: expectedSender, platform: "Telegram") else {
            return .refused(RemoteRefusal(reason: expectedSender == nil ? .pairingPredatesAuthorization : .unauthorizedSender,
                                          consequence: "dropped in silence; the sender is not the paired account, and answering a bystander in a shared chat would confirm this Mac is listening"))
        }

        // 2. Rate limit
        // ⚠️ AFTER identity, which is what makes a throttle refusal answerable: by here the sender has
        //   PROVED they are the paired operator, so telling them costs nothing.
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
        // Always allowed at any tier
        // ⚠️ `.conversationPage` sits with `.conversations` because it IS one — the same read,
        // from a different offset. Anything stricter would let a user list their conversations and
        // then be refused the second page of the same list.
        // ⚠️ `.searchConversations` stays here because it is a FILTERED LIST, not a new disclosure:
        // `ConversationReading.searchConversations` matches on `title` alone
        // (`ConversationSearchPolicy.matches(title:query:)`), and every title it can return is
        // already in the `/conversations` output this tier serves. Message BODIES are a different
        // question — see `.conversationHistory` below.
        case .conversations, .conversationPage, .searchConversations,
             .status, .help, .profiles, .unknown:
            return true

        // Requires at least .standard
        // ⚠️ `.selectProfile` / `.useProfile` REBIND the conversation's agent, so they sit with the
        // other state-changing verbs rather than with the read-only ones. They deliberately do NOT
        // need `.full`: choosing which configured profile answers is not tool approval.
        // ⚠️ `.answerClarification` sits with `.clarificationResponse` because it IS one — the same
        // act reached through a modal instead of a typed reply. Putting it with the `.full` group
        // would make the button openable and the answer refusable, which reads as a broken modal.
        //
        // ⚠️⚠️ `.conversationHistory` IS NOT A LIST COMMAND, WHICH IS WHY IT MOVED HERE (2026-09-10).
        // It sat in the always-allowed arm above, and `ChatOpsCommandService.conversationHistory`
        // renders `row.text` — the full body of every message it returns. `.readOnly` is the
        // SHIPPED DEFAULT (`ChatOpsConfigManager.securityTier` falls back to it when the key is
        // absent) and its own UI string promises "Can only view status and list conversations", so
        // the tier served complete private transcripts to anyone who could reach the channel while
        // telling the user it could not. Read access to bodies is a strictly larger disclosure than
        // read access to titles, and it belongs with the verbs that assume a trusted operator.
        // ⚠️ It sits at `.standard` rather than `.full` deliberately: a `.standard` user can already
        // send a message into the conversation and read the reply, so history reveals nothing they
        // could not obtain by asking. `.full` is about approving TOOLS, not about reading text.
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

        // 1b. Sender whitelist. ⚠️ A Discord channel id is a ROOM inside a guild — never a person.
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

        // 1b. Sender whitelist. ⚠️ A Slack channel id is a ROOM — never a person.
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

    /// Whether this message came from the ONE account that completed pairing.
    ///
    /// ⚠️⚠️ CHATOPS IS A SINGLE-USER REMOTE CONTROL. The channel or chat check above answers "did this
    /// arrive where I expect", which is an ADDRESS, not an identity — a Telegram group, a Discord
    /// channel and a Slack channel are all rooms with members. Comparing only the room let every
    /// member send commands, answer clarifications and, at `.full`, tap Approve on a mirrored tool
    /// call. The sender id was decoded on all three platforms and used only to skip the bot's own
    /// messages.
    ///
    /// ⚠️ BOTH NIL CASES FAIL CLOSED, and they are different failures worth telling apart in the log:
    ///   • `expected == nil` — paired before this check existed, so nothing was recorded. Treating
    ///     "unknown" as "anyone" would be the original hole with extra steps. Re-pairing fixes it,
    ///     and the log says so.
    ///   • `sender == nil` — an unattributable message. Nothing about it can be checked, so it cannot
    ///     be trusted; `PairingAttemptPolicy` refuses to count these for the same reason.
    /// ⚠️ INTERNAL, not private, so `ChatOpsSingleUserAuthorizationTests` can exercise the real
    /// comparison rather than a copy of its logic. The three `authorize*` methods above are the only
    /// production callers.
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
    //
    // ⚠️ The bucket's whole behaviour is time-dependent, and a time-dependent rule with no seam is a
    //   rule nobody can assert. These expose only what the tests need; the policy stays private.

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
        // ⚠️ `max(0,…)` on the ELAPSED, not on the total: a negative elapsed must contribute nothing
        //   rather than draining the bucket. See `lastRefill` for why it can be negative at all.
        let elapsed = max(0, instant - lastRefill)
        tokens = min(maxTokens, tokens + elapsed * refillRate)
        lastRefill = instant
    }

    /// Seconds until at least one token is available. ⚠️ Carried into the user-facing copy, so a
    /// throttled operator is told WHEN rather than merely that they were refused.
    private func retryInterval() -> TimeInterval {
        tokens >= 1 ? 0 : (1 - tokens) / refillRate
    }
}
