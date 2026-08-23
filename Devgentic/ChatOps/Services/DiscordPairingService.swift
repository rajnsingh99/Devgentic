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

                let text = message.content.uppercased().trimmingCharacters(in: .whitespaces)
                guard text == "PAIR \(pin)" else { continue }

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
                _ = try? await apiClient.sendMessage(
                    channelID: channelID,
                    content: "✅ Paired with Devgentic! Use /help to see available commands."
                )

                // Register slash commands if we have guild info
                if let guildID, let appID = applicationID {
                    try? await apiClient.registerSlashCommands(applicationID: appID, guildID: guildID)
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
