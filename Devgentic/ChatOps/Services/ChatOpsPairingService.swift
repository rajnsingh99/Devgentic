//
//  ChatOpsPairingService.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import os

/// Manages the pairing flow between the Devgentic app and a Telegram chat.
///
/// Flow:
/// 1. User enters bot token in Settings → taps "Connect"
/// 2. Service validates token via `getMe()`
/// 3. Generates a 6-digit PIN → displayed in Settings UI
/// 4. Starts a temporary polling loop waiting for `PAIR <pin>`
/// 5. On match: stores chat_id, transitions to `.connected`
/// 6. On timeout (5 min): transitions to `.disconnected`
@Observable @MainActor
final class ChatOpsPairingService {

    private let logger = Logger(subsystem: "com.devgentic", category: "ChatOpsPairing")
    private let config = ChatOpsConfigManager.shared

    /// Called after pairing succeeds so the caller can start the ChatOps bridge.
    var onPairingComplete: (() -> Void)?

    private var pairingTask: Task<Void, Never>?
    private var currentPIN: String?

    /// The timeout for the pairing window (5 minutes).
    private let pairingTimeout: TimeInterval = 300

    // MARK: - Validate Token

    /// Validates the bot token by calling Telegram's `getMe` endpoint.
    /// - Returns: The bot's username on success.
    func validateToken(_ token: String) async throws -> String {
        let client = TelegramAPIClient(botToken: token)
        let botUser = try await client.getMe()
        return botUser.username ?? botUser.first_name
    }

    // MARK: - Start Pairing

    /// Begins the pairing flow: generates a PIN and starts polling for `PAIR <pin>`.
    func startPairing(botToken: String) {
        cancelPairing()

        let pin = generatePIN()
        currentPIN = pin

        config.botToken = botToken
        config.connectionState = .awaitingPairing(pin: pin)

        logger.info("Pairing started. PIN: \(pin)")

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

    /// Disconnects the Telegram integration and clears stored credentials.
    func disconnect() async {
        cancelPairing()

        // Send farewell message if we have a valid connection
        if let token = config.botToken, let chatID = config.authorizedChatID {
            let client = TelegramAPIClient(botToken: token)
            _ = try? await client.sendMessage(
                chatID: chatID,
                text: "Devgentic ChatOps disconnected. Goodbye!"
            )
        }

        config.reset()
        logger.info("ChatOps disconnected and credentials cleared.")
    }

    // MARK: - Private

    private func pollForPairing(botToken: String, pin: String) async {
        let client = TelegramAPIClient(botToken: botToken)
        var lastUpdateID = 0
        let deadline = Date().addingTimeInterval(pairingTimeout)

        while !Task.isCancelled && Date() < deadline {
            do {
                let updates = try await client.getUpdates(offset: lastUpdateID + 1, timeout: 10)

                for update in updates {
                    lastUpdateID = max(lastUpdateID, update.update_id)

                    guard let text = update.message?.text?.uppercased().trimmingCharacters(in: .whitespaces),
                          text == "PAIR \(pin)",
                          let chatID = update.chatID else {
                        continue
                    }

                    // PIN matched — pairing successful
                    config.authorizedChatID = chatID
                    config.isEnabled = true
                    config.connectionState = .connected(chatID: chatID)

                    logger.info("Pairing successful with chat_id \(chatID)")

                    // Send confirmation and register bot commands
                    _ = try? await client.sendMessage(
                        chatID: chatID,
                        text: "Paired with Devgentic! Use /help to see available commands.",
                        replyMarkup: .reply(Self.persistentKeyboard)
                    )
                    try? await client.setMyCommands(Self.botCommands)

                    // Auto-start the ChatOps bridge
                    onPairingComplete?()

                    return
                }
            } catch is CancellationError {
                return
            } catch {
                logger.error("Pairing poll error: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s backoff
            }
        }

        // Timeout — pairing window expired
        if !Task.isCancelled {
            config.connectionState = .disconnected
            config.botToken = nil
            logger.info("Pairing timed out after \(self.pairingTimeout)s.")
        }
    }

    private func generatePIN() -> String {
        let pin = Int.random(in: 100_000...999_999)
        return "\(pin)"
    }

    // MARK: - Bot Menu Commands

    static let botCommands: [BotCommand] = [
        BotCommand(command: "conversations", description: "List recent conversations"),
        BotCommand(command: "new", description: "Start a new conversation"),
        BotCommand(command: "status", description: "Show current agent status"),
        BotCommand(command: "cancel", description: "Stop the active agent"),
        BotCommand(command: "help", description: "Show available commands")
    ]

    // MARK: - Persistent Reply Keyboard

    static let persistentKeyboard = ReplyKeyboardMarkup(
        keyboard: [
            [KeyboardButton(text: "/conversations"), KeyboardButton(text: "/new")],
            [KeyboardButton(text: "/status"), KeyboardButton(text: "/cancel")]
        ],
        resize: true,
        persistent: true
    )
}
