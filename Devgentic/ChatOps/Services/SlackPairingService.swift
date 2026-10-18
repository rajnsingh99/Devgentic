// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackPairingService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Manages the pairing flow between the Devgentic app and a Slack channel: validates the bot and app tokens, shows a
/// 6-digit PIN, and completes when the user sends `PAIR <pin>` in a channel. On match it stores the channel id and
/// becomes `.connected`; after 5 minutes it becomes `.disconnected`.
@Observable @MainActor
final class SlackPairingService {

    // Why: a pairing window outlives the view that starts it (its poll task retains `self` for 300 s), so a per-view instance
    // would orphan a window and let a second start consume the user's PIN.
    /// The shared pairing service; one instance means `cancelPairing()` and `startPairing()` always reach the window that
    /// is actually running.
    static let shared = SlackPairingService()


    private let logger = DGLogger(category: "SlackPairing")
    private let config = ChatOpsConfigManager.shared

    var onPairingComplete: (() -> Void)?

    private var pairingTask: Task<Void, Never>?

    // Why: the deadline cannot be checked inside the event loop: the stream yields nothing periodically, so on a quiet
    // channel the loop parks in `next()` and the PIN never expires.
    /// A wall-clock watchdog for the pairing window, independent of channel traffic.
    private var deadlineTask: Task<Void, Never>?
    private var currentPIN: String?
    private let pairingTimeout: TimeInterval = 300

    // MARK: - Validate Tokens

    /// Validates the bot token via auth.test.
    func validateBotToken(_ token: String) async throws -> String {
        let client = SlackAPIClient(botToken: token)
        let response = try await client.authTest()
        return response.user ?? response.bot_id ?? "Bot"
    }

    /// Validates the app token by attempting to open a Socket Mode connection.
    func validateAppToken(_ token: String) async throws {
        let _ = try await SlackAPIClient.openConnection(appToken: token)
    }

    // MARK: - Start Pairing

    func startPairing(botToken: String, appToken: String) {
        cancelPairing()

        let pin = generatePIN()
        currentPIN = pin

        config.slackBotToken = botToken
        config.slackAppToken = appToken
        config.slackConnectionState = .awaitingPairing(pin: pin)

        // The PIN is not logged; see the Telegram twin.
        logger.info("Slack pairing window opened for \(self.pairingTimeout)s.")

        armDeadline(pin: pin)

        pairingTask = Task {
            await pollForPairing(botToken: botToken, appToken: appToken, pin: pin)
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        currentPIN = nil
    }

    // MARK: - Disconnect

    func disconnect() async {
        cancelPairing()

        // Slack folds two credentials: either one unreadable is an outage.
        let botState = ChatOpsConfigManager.credentialState(
            AppSettings.chatOpsSlackBotTokenKey, keychain: config.keychain, logger: logger)
        let appState = ChatOpsConfigManager.credentialState(
            AppSettings.chatOpsSlackAppTokenKey, keychain: config.keychain, logger: logger)
        var anyUnreadable = false
        if case .unreadable = botState { anyUnreadable = true }
        if case .unreadable = appState { anyUnreadable = true }

        if let token = config.slackBotToken, let channelID = config.slackAuthorizedChannelID {
            let client = SlackAPIClient(botToken: token)
            await ChatOpsFarewell.send(provider: .slack, logger: logger) {
                _ = try await client.postMessage(channel: channelID, text: ChatOpsFarewell.message)
            }
        }

        let summary = config.resetSlack()
        if !summary.allCleared {
            logger.error(
                "[SECRETS] Slack disconnect could not delete \(summary.failedLabels.joined(separator: ", ")) "
                + "from the Keychain. CONSEQUENCE: the bridge is left in .error naming what is still stored."
            )
        } else {
            logger.info("Slack ChatOps disconnected and credentials cleared.")
        }
        if anyUnreadable {
            config.connectionState = .error(ChatOpsPairingRestore.unreadableMessage)
        }
    }

    // MARK: - Private

    private func pollForPairing(botToken: String, appToken: String, pin: String) async {
        let socketClient = SlackSocketClient(appToken: appToken)
        let deadline = Date().addingTimeInterval(pairingTimeout)

        let stream = await socketClient.start()
        /// Per-origin failed attempts for THIS window only — see `PairingAttemptLedger`.
        var ledger = PairingAttemptLedger()

        for await event in stream {
            guard Date() < deadline && !Task.isCancelled else { break }

            switch event {
            case .connected:
                logger.info("Slack Socket Mode connected for pairing.")

            case .message(let slackEvent):
                guard slackEvent.bot_id == nil else { continue }
                guard let text = slackEvent.text else { continue }

                let attempt = PairingAttemptPolicy.classify(text, expectedPIN: pin)
                guard attempt != .unrelated else { continue }

                // Counts the sender, not the channel (see `DiscordPairingService`): Slack's `user` is optional on a message event,
                // and an unattributable one must not be counted against everybody.
                guard let origin = slackEvent.user else {
                    logger.error("[CHATOPS] A Slack pairing message arrived with no sender, so it cannot be attributed. CONSEQUENCE: it is ignored and NOT counted against any origin's attempts — counting it globally is what would let an unattributable message lock the user out.")
                    continue
                }

                if ledger.isBlocked(origin) {
                    logger.info("[CHATOPS] Ignoring a pairing message from user \(origin) — it has already spent its \(PairingAttemptLedger.attemptsPerOrigin) attempts this window. CONSEQUENCE: nothing further from that origin can pair, including a correct PIN. The window stays OPEN for every other channel, deliberately: aborting it would let a stranger stop the user pairing with ten messages.")
                    continue
                }

                if attempt == .wrongPIN {
                    switch ledger.recordFailure(from: origin) {
                    case .listening(let remaining):
                        logger.error("[CHATOPS] Failed pairing attempt from user \(origin) (\(remaining) left before it is ignored; \(ledger.totalFailures) failures from \(ledger.distinctOrigins) origin(s) this window). CONSEQUENCE: pairing did NOT happen and the window stays open. One origin repeating is a typo; several origins guessing is not, and the PIN space is 900,000 against a 300-second window. The attempted digits are deliberately not recorded — see PairingAttemptPolicy.")
                    case .blocked:
                        logger.error("[CHATOPS] user \(origin) has now spent all \(PairingAttemptLedger.attemptsPerOrigin) pairing attempts and will be IGNORED for the rest of this window, including a correct PIN. CONSEQUENCE: if this was the user mistyping, they must restart pairing from Settings to get a fresh window; if it was someone guessing, that origin can no longer reach the PIN. The window itself stays open for other channels.")
                    }
                    continue
                }

                // The message already matched the PIN, so a missing channel means pairing cannot complete; log the consequence
                // rather than drop a correct PIN silently. The window stays open for a resend.
                guard let channelID = slackEvent.channel else {
                    logger.error("[CHATOPS] A correct Slack PIN arrived on an event carrying NO channel, so pairing could not complete. CONSEQUENCE: nothing was paired and the window stays OPEN — send the PIN again as an ordinary channel message. Pairing needs a channel because that address is what the bridge listens on; recording the user alone would leave nowhere to receive commands.")
                    continue
                }

                // `origin` (the Slack `user`) proved knowledge of the PIN; a channel id identifies a room, not a person. See the
                // Telegram twin.
                config.slackAuthorizedUserID = origin
                config.slackAuthorizedChannelID = channelID
                config.isSlackEnabled = true
                // The window is over once it succeeds; disarm the watchdog so it does not stay alive or log a confusing line when it
                // fires.
                deadlineTask?.cancel()
                deadlineTask = nil
                config.slackConnectionState = .connected(chatID: 0) // chatID not meaningful for Slack

                logger.info("Slack pairing successful with channel \(channelID).")

                let apiClient = SlackAPIClient(botToken: botToken)
                do {
                    _ = try await apiClient.postMessage(
                        channel: channelID,
                        text: "✅ Paired with Devgentic! Use /help to see available commands."
                    )
                } catch {
                    logger.error("[CHATOPS] Slack pairing succeeded for channel \(channelID) but the confirmation could not be posted: \(error.localizedDescription). CONSEQUENCE: the user sees no acknowledgement that pairing worked and will reasonably try again, even though the app is now paired.")
                }

                await socketClient.stop()
                onPairingComplete?()
                return

            case .disconnected(let error):
                if let error {
                    logger.error("Slack Socket disconnected during pairing: \(error.localizedDescription)")
                }

            case .interaction, .slashCommand:
                break
            }
        }

        await socketClient.stop()

        if !Task.isCancelled {
            PairingWindowExpiry.expire(pin: pin, platform: "Slack", timeout: pairingTimeout,
                                       state: \.slackConnectionState, config: config, logger: logger)
        }
    }

    /// Arms the wall-clock watchdog for this window. See `deadlineTask`. It cancels the polling task, which is what makes
    /// a parked `AsyncStream` `next()` return; expiry is reported here because the cancelled loop cannot tell a timeout
    /// from the user pressing Cancel.
    private func armDeadline(pin: String) {
        deadlineTask?.cancel()
        let timeout = pairingTimeout
        deadlineTask = Task { [weak self] in
            await PairingWindowExpiry.waitOutWindow(timeout)
            guard !Task.isCancelled, let self else { return }

            self.pairingTask?.cancel()
            self.pairingTask = nil
            PairingWindowExpiry.expire(pin: pin, platform: "Slack", timeout: self.pairingTimeout,
                                       state: \.slackConnectionState, config: self.config, logger: self.logger)
        }
    }

    private func generatePIN() -> String {
        let pin = Int.random(in: 100_000...999_999)
        return "\(pin)"
    }
}
