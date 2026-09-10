// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "ChatOpsPairing")
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
            // ⚠️ THE USER'S ONLY NOTICE THAT THE BOT IS GONE, and it is sent before the credentials
            // are wiped — there is no second chance after this line.
            do {
                _ = try await client.sendMessage(
                    chatID: chatID,
                    text: "Devgentic ChatOps disconnected. Goodbye!"
                )
            } catch {
                logger.error("[CHATOPS] Failed to send the Telegram farewell before unpairing: \(error.localizedDescription). CONSEQUENCE: the credentials are wiped anyway, so the bot simply stops answering with no goodbye — the user is left unsure whether it is disconnected or broken, and nothing can retry because the token is gone a moment later.")
            }
        }

        config.reset()
        logger.info("ChatOps disconnected and credentials cleared.")
    }

    // MARK: - Private

    private func pollForPairing(botToken: String, pin: String) async {
        let client = TelegramAPIClient(botToken: botToken)
        var lastUpdateID = 0
        /// Per-origin failed attempts for THIS window only — see `PairingAttemptLedger`.
        var ledger = PairingAttemptLedger()
        let deadline = Date().addingTimeInterval(pairingTimeout)

        while !Task.isCancelled && Date() < deadline {
            do {
                let updates = try await client.getUpdates(offset: lastUpdateID + 1, timeout: 10)

                for update in updates {
                    lastUpdateID = max(lastUpdateID, update.update_id)

                    // ⚠️ CLASSIFY BEFORE SKIPPING. This was a bare `continue`, so a wrong PIN left
                    // no trace at all — you could not tell anyone had tried, and there was no data
                    // from which to set a lockout threshold.
                    guard let raw = update.message?.text else { continue }
                    let attempt = PairingAttemptPolicy.classify(raw, expectedPIN: pin)
                    guard attempt != .unrelated else { continue }

                    // ⚠️ THE ORIGIN IS THE UNIT OF THE LOCKOUT, so an update that cannot be
                    // attributed must not be counted against anyone — least of all everyone.
                    guard let chatID = update.chatID else {
                        logger.error("[CHATOPS] A pairing message arrived with no chat id, so it can neither be attributed nor authorized. CONSEQUENCE: it is ignored and NOT counted against any origin's attempts — counting it globally is what would let an unattributable message lock the user out.")
                        continue
                    }

                    // ⚠️ THE SENDER, NOT THE CHAT, MATCHING DISCORD AND SLACK. In a DM the two are
                    // the same thing, but in a GROUP every member shares one chat id — so counting
                    // per chat would let any member's guesses lock out everyone else in the group,
                    // including the person actually pairing. Authorization still binds the CHAT
                    // (`authorizedChatID` below); only the lockout is per person.
                    //
                    // ⚠️ Falling back to the chat id when `from` is absent is deliberate: channel
                    // posts have no sender, and refusing to count them at all would leave a gap the
                    // lockout is meant to close.
                    let origin = update.message?.from?.id.description ?? String(chatID)

                    // ⚠️ BEFORE THE PIN IS ACTED ON. A lockout that still honours a correct guess
                    // from a spent origin is not a lockout.
                    if ledger.isBlocked(origin) {
                        logger.info("[CHATOPS] Ignoring a pairing message from chat \(origin) — it has already spent its \(PairingAttemptLedger.attemptsPerOrigin) attempts this window. CONSEQUENCE: nothing further from that origin can pair, including a correct PIN. The window stays OPEN for every other chat, deliberately: aborting it would let a stranger stop the user pairing with ten messages.")
                        continue
                    }

                    if attempt == .wrongPIN {
                        switch ledger.recordFailure(from: origin) {
                        case .listening(let remaining):
                            logger.error("[CHATOPS] Failed pairing attempt from chat \(origin) (\(remaining) left before it is ignored; \(ledger.totalFailures) failures from \(ledger.distinctOrigins) origin(s) this window). CONSEQUENCE: pairing did NOT happen and the window stays open. One origin repeating is a typo; several origins guessing is not, and the PIN space is 900,000 against a 300-second window. The attempted digits are deliberately not recorded — see PairingAttemptPolicy.")
                        case .blocked:
                            logger.error("[CHATOPS] chat \(origin) has now spent all \(PairingAttemptLedger.attemptsPerOrigin) pairing attempts and will be IGNORED for the rest of this window, including a correct PIN. CONSEQUENCE: if this was the user mistyping, they must restart pairing from Settings to get a fresh window; if it was someone guessing, that origin can no longer reach the PIN. The window itself stays open for other chats.")
                        }
                        continue
                    }

                    // PIN matched — pairing successful
                    config.authorizedChatID = chatID
                    config.isEnabled = true
                    config.connectionState = .connected(chatID: chatID)

                    logger.info("Pairing successful with chat_id \(chatID)")

                    // Send confirmation and register bot commands
                    // ⚠️⚠️ THIS SEND CARRIES THE PERSISTENT KEYBOARD, which is the only way it is
                    // ever installed. Losing it is not a lost greeting — the user is paired but has
                    // no buttons at all, and nothing re-sends it on a later message.
                    do {
                        _ = try await client.sendMessage(
                            chatID: chatID,
                            text: "Paired with Devgentic! Use /help to see available commands.",
                            replyMarkup: .reply(Self.persistentKeyboard)
                        )
                    } catch {
                        logger.error("[CHATOPS] Pairing succeeded for chat \(chatID) but the confirmation could not be sent: \(error.localizedDescription). CONSEQUENCE: the user gets no confirmation AND no persistent reply keyboard — pairing worked, but the bot looks unresponsive and offers no buttons. Nothing re-sends it; only re-pairing installs the keyboard.")
                    }
                    do {
                        try await client.setMyCommands(Self.botCommands)
                    } catch {
                        logger.error("[CHATOPS] Pairing succeeded for chat \(chatID) but the command menu could not be registered: \(error.localizedDescription). CONSEQUENCE: Telegram's ☰ menu stays empty, so every command must be typed from memory. Nothing retries until the next pairing.")
                    }

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

    /// ⚠️ DERIVED FROM `ChatOpsVerbTable`, not hand-written. This was the THIRD hand-maintained copy
    /// of the verb list — after `/help` and Discord's slash registration — and like both of them it
    /// had drifted, offering five of eight.
    ///
    /// ⚠️ EVERY VERB IS OFFERED HERE, including argument-taking ones, and that is the difference
    /// from Discord. Telegram's menu inserts the command into the composer and the user types the
    /// rest, so `/search` arrives with its query; Discord's registration has no way to declare or
    /// carry a parameter, so argument-taking verbs are excluded there.
    static let botCommands: [BotCommand] = ChatOpsVerb.presentationOrder.map { verb in
        BotCommand(command: verb.canonicalName, description: verb.helpDescription)
    }

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
