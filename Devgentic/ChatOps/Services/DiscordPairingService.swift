// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DiscordPairingService.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import os

/// Manages the pairing flow between the Devgentic app and a Discord channel.
///
/// Flow:
/// 1. User enters bot token in Settings → taps "Validate"
/// 2. Service validates token via `getCurrentUser()`
/// 3. Generates a 6-digit PIN → displayed in Settings UI
/// 4. Starts a temporary Gateway connection waiting for `PAIR <pin>` in any channel
/// 5. On match: stores channel_id + guild_id, transitions to `.connected`
/// 6. On timeout (5 min): transitions to `.disconnected`
///
/// Note: Unlike Telegram which uses HTTP long-polling, Discord requires a full
/// WebSocket Gateway connection even for pairing.
@Observable @MainActor
final class DiscordPairingService {

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "DiscordPairing")
    private let config = ChatOpsConfigManager.shared

    /// Called after pairing succeeds so the caller can start the Discord bridge.
    var onPairingComplete: (() -> Void)?

    private var pairingTask: Task<Void, Never>?
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

        logger.info("Discord pairing started. PIN: \(pin)")

        pairingTask = Task {
            await pollForPairing(botToken: botToken, pin: pin)
        }
    }

    /// Cancels any in-progress pairing attempt.
    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        currentPIN = nil
    }

    // MARK: - Disconnect

    /// Disconnects the Discord integration and clears stored credentials.
    func disconnect() async {
        cancelPairing()

        // Send farewell message if we have a valid connection
        if let token = config.discordBotToken, let channelID = config.discordAuthorizedChannelID {
            let client = DiscordAPIClient(botToken: token)
            _ = try? await client.sendMessage(
                channelID: channelID,
                content: "Devgentic ChatOps disconnected. Goodbye!"
            )
        }

        config.resetDiscord()
        logger.info("Discord ChatOps disconnected and credentials cleared.")
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

                // ⚠️ THE AUTHOR, NOT THE CHANNEL. Everyone in a Discord channel shares its id, so
                // counting per channel would let one member's guesses lock out every other member —
                // and the pairing user is one of those members.
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

                // PIN matched — pairing successful
                let channelID = message.channel_id
                let guildID = message.guild_id

                config.discordAuthorizedChannelID = channelID
                config.discordGuildID = guildID
                config.discordApplicationID = applicationID
                config.isDiscordEnabled = true
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
            config.discordConnectionState = .disconnected
            config.discordBotToken = nil
            logger.info("Discord pairing timed out after \(self.pairingTimeout)s.")
        }
    }

    private func generatePIN() -> String {
        let pin = Int.random(in: 100_000...999_999)
        return "\(pin)"
    }
}
