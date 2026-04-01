//
//  SlackPairingService.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import os

/// Manages the pairing flow between the Devgentic app and a Slack channel.
///
/// Flow:
/// 1. User enters bot token (xoxb-) and app token (xapp-) in Settings -> taps "Validate"
/// 2. Service validates bot token via `auth.test`
/// 3. Validates app token by opening a Socket Mode connection
/// 4. Generates a 6-digit PIN -> displayed in Settings UI
/// 5. User types `PAIR <pin>` in their chosen Slack channel
/// 6. On match: stores channel_id, transitions to `.connected`
/// 7. On timeout (5 min): transitions to `.disconnected`
@MainActor
final class SlackPairingService: ObservableObject {

    private let logger = Logger(subsystem: "com.devgentic", category: "SlackPairing")
    private let config = ChatOpsConfigManager.shared

    var onPairingComplete: (() -> Void)?

    private var pairingTask: Task<Void, Never>?
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

        logger.info("Slack pairing started. PIN: \(pin)")

        pairingTask = Task {
            await pollForPairing(botToken: botToken, appToken: appToken, pin: pin)
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        currentPIN = nil
    }

    // MARK: - Disconnect

    func disconnect() async {
        cancelPairing()

        if let token = config.slackBotToken, let channelID = config.slackAuthorizedChannelID {
            let client = SlackAPIClient(botToken: token)
            _ = try? await client.postMessage(
                channel: channelID,
                text: "Devgentic ChatOps disconnected. Goodbye!"
            )
        }

        config.resetSlack()
        logger.info("Slack ChatOps disconnected and credentials cleared.")
    }

    // MARK: - Private

    private func pollForPairing(botToken: String, appToken: String, pin: String) async {
        let socketClient = SlackSocketClient(appToken: appToken)
        let deadline = Date().addingTimeInterval(pairingTimeout)

        let stream = await socketClient.start()

        for await event in stream {
            guard Date() < deadline && !Task.isCancelled else { break }

            switch event {
            case .connected:
                logger.info("Slack Socket Mode connected for pairing.")

            case .message(let slackEvent):
                guard slackEvent.bot_id == nil else { continue }
                guard let text = slackEvent.text else { continue }

                let normalized = text.uppercased().trimmingCharacters(in: .whitespaces)
                guard normalized == "PAIR \(pin)" else { continue }

                guard let channelID = slackEvent.channel else { continue }

                config.slackAuthorizedChannelID = channelID
                config.isSlackEnabled = true
                config.slackConnectionState = .connected(chatID: 0) // chatID not meaningful for Slack

                logger.info("Slack pairing successful with channel \(channelID).")

                let apiClient = SlackAPIClient(botToken: botToken)
                _ = try? await apiClient.postMessage(
                    channel: channelID,
                    text: "✅ Paired with Devgentic! Use /help to see available commands."
                )

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
            config.slackConnectionState = .disconnected
            config.slackBotToken = nil
            config.slackAppToken = nil
            logger.info("Slack pairing timed out after \(self.pairingTimeout)s.")
        }
    }

    private func generatePIN() -> String {
        let pin = Int.random(in: 100_000...999_999)
        return "\(pin)"
    }
}
