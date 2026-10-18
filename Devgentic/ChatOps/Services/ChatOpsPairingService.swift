// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsPairingService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Manages the pairing flow between the app and a Telegram chat.
/// Validates the bot token via `getMe()`, shows a 6-digit PIN and polls for `PAIR <pin>`; a match stores the chat id and
/// goes `.connected`, and a 5-minute timeout goes `.disconnected`.
@Observable @MainActor
final class ChatOpsPairingService {

    /// The shared pairing service: a pairing window outlives the view that starts it.
    /// The polling task retains the service for the full window, so a per-view instance would lose track of it.
    /// One instance means `cancelPairing()` and `startPairing()` always reach the running window.
    static let shared = ChatOpsPairingService()


    private let logger = DGLogger(category: "ChatOpsPairing")
    private let config = ChatOpsConfigManager.shared

    /// Called after pairing succeeds so the caller can start the ChatOps bridge.
    var onPairingComplete: (() -> Void)?

    private var pairingTask: Task<Void, Never>?

    // Why: a deadline checked inside a `for await` body only runs when the stream yields, and a quiet channel parks in
    // `next()`; this watchdog gives all three platforms the same expiry guarantee.
    /// A wall-clock watchdog for the pairing window, independent of channel traffic.
    private var deadlineTask: Task<Void, Never>?
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

        // The PIN is not logged: these lines reach exported diagnostic bundles, and `PairingAttemptPolicy` refuses to record
        // attempted digits.
        logger.info("Telegram pairing window opened for \(self.pairingTimeout)s.")

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

    /// Disconnects the Telegram integration and clears stored credentials.
    func disconnect() async {
        cancelPairing()

        // Capture the credential state before the reset: a failed Keychain read collapses to nil in `config.botToken`,
        // which would skip the farewell and report a clean disconnect.
        let credentialStateBeforeReset = ChatOpsConfigManager.credentialState(
            AppSettings.chatOpsBotTokenKey, keychain: config.keychain, logger: logger)

        // Send farewell message if we have a valid connection
        if let token = config.botToken, let chatID = config.authorizedChatID {
            let client = TelegramAPIClient(botToken: token)
            // The farewell is the user's only notice that the bot is gone, sent before the credentials are wiped;
            // it routes through the shared `ChatOpsFarewell` seam so the platforms cannot drift apart.
            await ChatOpsFarewell.send(provider: .telegram, logger: logger) {
                _ = try await client.sendMessage(chatID: chatID, text: ChatOpsFarewell.message)
            }
        }

        let summary = config.reset()
        if !summary.allCleared {
            logger.error(
                "[SECRETS] Telegram disconnect could not delete \(summary.failedLabels.joined(separator: ", ")) "
                + "from the Keychain. CONSEQUENCE: the bridge is left in .error naming what is still "
                + "stored — never a clean disconnected over a credential that survived."
            )
        } else {
            logger.info("ChatOps disconnected and credentials cleared.")
        }
        if case .unreadable = credentialStateBeforeReset {
            // The disconnect could not VERIFY the wipe. Report the outage, not "never paired" —
            // re-pairing over an unverified credential is exactly what `unreadableMessage` warns against.
            config.connectionState = .error(ChatOpsPairingRestore.unreadableMessage)
        }
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

                    // Classify before skipping: a wrong PIN must leave a trace, so lockout thresholds have data.
                    guard let raw = update.message?.text else { continue }
                    let attempt = PairingAttemptPolicy.classify(raw, expectedPIN: pin)
                    guard attempt != .unrelated else { continue }

                    // The origin is the unit of the lockout, so an update that cannot be attributed is not counted against anyone.
                    guard let chatID = update.chatID else {
                        logger.error("[CHATOPS] A pairing message arrived with no chat id, so it can neither be attributed nor authorized. CONSEQUENCE: it is ignored and NOT counted against any origin's attempts — counting it globally is what would let an unattributable message lock the user out.")
                        continue
                    }

                    // The sender, not the chat, matching Discord and Slack: in a group a per-chat count would let one member lock out all.
                    // `origin` (who to count) and `senderID` (who to bind) differ; falling back to the chat id is right only for the former.
                    let senderID = update.message?.from?.id.description
                    let origin = senderID ?? String(chatID)

                    // Checked before the PIN is acted on: a lockout that honours a correct guess from a spent origin is not a lockout.
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

                    // PIN matched: the sender is recorded here and nowhere else, so that account is authorized from now on.
                    // Attributable or not at all: with no sender the window stays open (`continue`) so the user can send the PIN again.
                    guard let senderID else {
                        logger.error("[CHATOPS] A correct Telegram PIN arrived on a message with NO sender id, so pairing was refused. CONSEQUENCE: pairing did not complete and the window stays open — send the PIN again from a normal chat message rather than a channel post. Recording the chat id here instead would pair against something that is not an account, and every later message WOULD carry a sender id and be refused forever.")
                        continue
                    }

                    config.authorizedUserID = senderID
                    config.authorizedChatID = chatID
                    config.isEnabled = true
                    // The window is over once it succeeds; disarm the watchdog so it does not stay alive or log a puzzling 'not the live
                    // one' line.
                    deadlineTask?.cancel()
                    deadlineTask = nil
                    config.connectionState = .connected(chatID: chatID)

                    logger.info("Pairing successful with chat_id \(chatID)")

                    // Send confirmation and register bot commands. This send carries the persistent keyboard, the only way it is installed:
                    // losing it leaves the user paired with no buttons, and nothing re-sends it.
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
            } catch {
                // A cancelled `getUpdates` throws `URLError(.cancelled)`, not `CancellationError`, so check `RemoteLoopCancellation`;
                // otherwise cancelling a pairing window logs 'Pairing poll error: cancelled' as a failure.
                if RemoteLoopCancellation.isCancellation(error) {
                    logger.info("[CHATOPS] The Telegram pairing poll ended because it was cancelled. CONSEQUENCE: none — the window was closed deliberately (the user pressed Cancel, or it timed out); no pairing is recorded and nothing retries.")
                    return
                }
                logger.warning("[CHATOPS] Telegram pairing poll error: \(error.localizedDescription). CONSEQUENCE: this poll produced no updates, so a PIN sent in this interval is re-read on the next poll — the window stays open and retries after a 2s backoff.")
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s backoff
            }
        }

        // Timeout — pairing window expired
        if !Task.isCancelled {
            PairingWindowExpiry.expire(pin: pin, platform: "Telegram", timeout: pairingTimeout,
                                       state: \.connectionState, config: config, logger: logger)
        }
    }

    // Why: it cancels the polling task rather than unwinding it: cancellation is what makes `AsyncStream.next()` return.
    // Expiry is reported here because the cancelled loop cannot tell a timeout from the user pressing Cancel.
    /// Arms the wall-clock watchdog for this window. See `deadlineTask`.
    private func armDeadline(pin: String) {
        deadlineTask?.cancel()
        let timeout = pairingTimeout
        deadlineTask = Task { [weak self] in
            await PairingWindowExpiry.waitOutWindow(timeout)
            guard !Task.isCancelled, let self else { return }

            self.pairingTask?.cancel()
            self.pairingTask = nil
            PairingWindowExpiry.expire(pin: pin, platform: "Telegram", timeout: self.pairingTimeout,
                                       state: \.connectionState, config: self.config, logger: self.logger)
        }
    }

    private func generatePIN() -> String {
        let pin = Int.random(in: 100_000...999_999)
        return "\(pin)"
    }

    // MARK: - Bot Menu Commands

    /// Derived from `ChatOpsVerbTable`, not hand-written, so the menu cannot drift from the verb list.
    /// Every verb is offered, including argument-taking ones: Telegram's menu inserts the command and the user types the
    /// rest.
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
