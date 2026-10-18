// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordPairingService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Manages the pairing flow between the app and a Discord channel: validates the bot token, shows a 6-digit PIN,
/// and waits on a temporary Gateway connection for `PAIR <pin>`. On a match it stores channel_id and guild_id and
/// becomes `.connected`; after a 5-minute timeout it becomes `.disconnected`.
@Observable @MainActor
final class DiscordPairingService {

    // Why: a pairing window outlives the settings view, so a per-view instance would orphan its task and allow two
    // windows on one bot token.
    /// The shared pairing service instance, so `startPairing()` and `cancelPairing()` always reach the window that is
    /// actually running.
    static let shared = DiscordPairingService()


    private let logger = DGLogger(category: "DiscordPairing")
    private let config = ChatOpsConfigManager.shared

    /// Called after pairing succeeds so the caller can start the Discord bridge.
    var onPairingComplete: (() -> Void)?

    private var pairingTask: Task<Void, Never>?

    // Why: the deadline cannot live inside the event loop body: a quiet channel parks `next()` and the PIN would stay
    // live.
    /// A wall-clock watchdog for the pairing window, independent of stream traffic.
    private var deadlineTask: Task<Void, Never>?
    private var currentPIN: String?

    /// The timeout for the pairing window (5 minutes).
    private let pairingTimeout: TimeInterval = 300

    // MARK: - Validate Token

    /// Validates the bot token by calling Discord's GET /users/@me endpoint.
    /// - Returns: The bot's username on success.
    func validateToken(_ token: String) async throws -> String {
        let client = DiscordAPIClient(botToken: token)
        let user = try await client.getCurrentUser()
        return user.username
    }

    // MARK: - Start Pairing

    /// Begins the pairing flow: generates a PIN and starts a Gateway connection to listen for `PAIR <pin>`.
    func startPairing(botToken: String) {
        cancelPairing()

        let pin = generatePIN()
        currentPIN = pin

        config.discordBotToken = botToken
        config.discordConnectionState = .awaitingPairing(pin: pin)

        // The PIN is deliberately not logged.
        logger.info("Discord pairing window opened for \(self.pairingTimeout)s.")

        armDeadline(pin: pin)

        pairingTask = Task {
            await pollForPairing(botToken: botToken, pin: pin)
        }
    }

    /// Cancels any in-progress pairing attempt.
    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        currentPIN = nil
    }

    // MARK: - Disconnect

    /// Disconnects the Discord integration and clears stored credentials.
    func disconnect() async {
        cancelPairing()

        // Capture the credential state before the reset, as the Telegram pairing service does.
        let credentialStateBeforeReset = ChatOpsConfigManager.credentialState(
            AppSettings.chatOpsDiscordBotTokenKey, keychain: config.keychain, logger: logger)

        // Send farewell message if we have a valid connection
        if let token = config.discordBotToken, let channelID = config.discordAuthorizedChannelID {
            let client = DiscordAPIClient(botToken: token)
            await ChatOpsFarewell.send(provider: .discord, logger: logger) {
                _ = try await client.sendMessage(channelID: channelID, content: ChatOpsFarewell.message)
            }
        }

        let summary = config.resetDiscord()
        if !summary.allCleared {
            logger.error(
                "[SECRETS] Discord disconnect could not delete \(summary.failedLabels.joined(separator: ", ")) "
                + "from the Keychain. CONSEQUENCE: the bridge is left in .error naming what is still stored."
            )
        } else {
            logger.info("Discord ChatOps disconnected and credentials cleared.")
        }
        if case .unreadable = credentialStateBeforeReset {
            config.connectionState = .error(ChatOpsPairingRestore.unreadableMessage)
        }
    }

    // MARK: - Private

    private func pollForPairing(botToken: String, pin: String) async {
        let gatewayClient = DiscordGatewayClient(botToken: botToken)
        let deadline = Date().addingTimeInterval(pairingTimeout)

        let stream = await gatewayClient.start()
        var applicationID: String?
        /// Per-origin failed attempts for THIS window only — see `PairingAttemptLedger`.
        var ledger = PairingAttemptLedger()

        for await event in stream {
            // Check timeout
            guard Date() < deadline && !Task.isCancelled else {
                break
            }

            switch event {
            case .ready(let ready):
                applicationID = ready.application.id
                logger.info("Discord Gateway ready for pairing. Bot: \(ready.user.username)")

            case .messageCreate(let message):
                // Ignore bot messages
                guard message.author.bot != true else { continue }

                let attempt = PairingAttemptPolicy.classify(message.content, expectedPIN: pin)
                guard attempt != .unrelated else { continue }

                // Count attempts per author, not per channel: members share a channel id, so one member's guesses would lock out
                // the others.
                let origin = message.author.id

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

                // PIN matched, pairing successful. `origin` (the message author's id) is what proved knowledge of the PIN; a
                // channel id identifies a room, not a person.
                config.discordAuthorizedUserID = origin
                let channelID = message.channel_id
                let guildID = message.guild_id

                config.discordAuthorizedChannelID = channelID
                config.discordGuildID = guildID
                config.discordApplicationID = applicationID
                config.isDiscordEnabled = true
                // The window is over once it succeeds; disarm the watchdog rather than leave a task alive until it fires.
                deadlineTask?.cancel()
                deadlineTask = nil
                config.discordConnectionState = .connected(chatID: Int64(channelID) ?? 0)

                logger.info("Discord pairing successful with channel \(channelID) in guild \(guildID ?? "DM").")

                // Send confirmation
                let apiClient = DiscordAPIClient(botToken: botToken)
                do {
                    _ = try await apiClient.sendMessage(
                        channelID: channelID,
                        content: "✅ Paired with Devgentic! Use /help to see available commands."
                    )
                } catch {
                    logger.error("[CHATOPS] Discord pairing succeeded for channel \(channelID) but the confirmation could not be posted: \(error.localizedDescription). CONSEQUENCE: the user sees no acknowledgement that pairing worked and will reasonably try again, even though the app is now paired.")
                }

                // Register slash commands if we have guild info
                if let guildID, let appID = applicationID {
                    do {
                        try await apiClient.registerSlashCommands(applicationID: appID, guildID: guildID)
                    } catch {
                        logger.error("[CHATOPS] Discord pairing succeeded for guild \(guildID) but slash-command registration failed: \(error.localizedDescription). CONSEQUENCE: the user is paired but Devgentic's commands do not appear in Discord's \"/\" menu; they remain reachable only by typing them as ordinary messages, until the next gateway READY retries.")
                    }
                } else {
                    logger.error("[CHATOPS] Discord pairing completed with no guild id or no application id, so NO slash commands were registered. CONSEQUENCE: the \"/\" menu stays empty for this user and every command must be typed as an ordinary message.")
                }

                // Stop the pairing Gateway connection
                await gatewayClient.stop()

                // Auto-start the Discord ChatOps bridge
                onPairingComplete?()

                return

            case .disconnected(let error):
                if let error {
                    logger.error("Discord Gateway disconnected during pairing: \(error.localizedDescription)")
                }
                // Gateway will auto-reconnect, continue waiting

            case .resumed:
                break
            case .interactionCreate:
                break // Ignore interactions during pairing
            }
        }

        // Timeout or cancellation — pairing window expired
        await gatewayClient.stop()

        if !Task.isCancelled {
            PairingWindowExpiry.expire(pin: pin, platform: "Discord", timeout: pairingTimeout,
                                       state: \.discordConnectionState, config: config, logger: logger)
        }
    }

    /// Arms the wall-clock watchdog for this window (see `deadlineTask`). It cancels the polling task so a loop parked
    /// on a silent channel returns, and reports expiry itself because the cancelled loop cannot tell a timeout from the
    /// user pressing Cancel.
    private func armDeadline(pin: String) {
        deadlineTask?.cancel()
        let timeout = pairingTimeout
        deadlineTask = Task { [weak self] in
            await PairingWindowExpiry.waitOutWindow(timeout)
            guard !Task.isCancelled, let self else { return }

            self.pairingTask?.cancel()
            self.pairingTask = nil
            PairingWindowExpiry.expire(pin: pin, platform: "Discord", timeout: self.pairingTimeout,
                                       state: \.discordConnectionState, config: self.config, logger: self.logger)
        }
    }

    private func generatePIN() -> String {
        let pin = Int.random(in: 100_000...999_999)
        return "\(pin)"
    }
}
