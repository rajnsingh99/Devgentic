// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// ⚠️⚠️ SHARED, BECAUSE A PAIRING WINDOW OUTLIVES THE VIEW THAT STARTS IT. This was
    /// `@State private var` in `ChatOpsSettingsView`, so the service died with the pane while its
    /// `pairingTask` did not — `pollForPairing` is an instance method, so the task retains `self`
    /// for the full 300-second window and no pairing service has a `deinit`. Clicking Chat, or any
    /// other settings category, tore the view down (`MainApplicationView` renders the settings
    /// container inside an `if !router.isShowingChat` gate). Coming back rebuilt a FRESH, idle
    /// service while `connectionState` — which lives on the shared config — still said
    /// `.awaitingPairing`, so the PIN card rendered with a Cancel button that cancelled a nil task.
    /// Starting again then ran TWO windows against one bot token, and the user's correct PIN was
    /// consumed by whichever poll held the connection — counted as a FAILED attempt against their
    /// own origin by the orphan. One instance means `cancelPairing()` and `startPairing()` always
    /// reach the window that is actually running.
    static let shared = ChatOpsPairingService()


    private let logger = DGLogger(category: "ChatOpsPairing")
    private let config = ChatOpsConfigManager.shared

    /// Called after pairing succeeds so the caller can start the ChatOps bridge.
    var onPairingComplete: (() -> Void)?

    private var pairingTask: Task<Void, Never>?

    /// A wall-clock watchdog for the pairing window.
    ///
    /// ⚠️⚠️ THE DEADLINE CANNOT LIVE INSIDE THE EVENT LOOP, WHICH IS WHERE IT USED TO LIVE ON TWO OF
    /// THE THREE PLATFORMS. Discord and Slack tested `Date() < deadline` as the first statement of a
    /// `for await` BODY, so it could only run when the stream yielded — and neither stream emits
    /// anything periodic (heartbeats and ACKs are consumed internally and yield nothing). On a quiet
    /// channel the loop simply parked in `next()`: hours later the PIN was still live, the WebSocket
    /// still open, and the credentials still sitting there with no owning session. Worse, the first
    /// message to arrive AFTER the deadline was consumed by the expiry check and discarded — so a
    /// user returning twenty minutes later and typing the correct PIN saw it silently do nothing.
    /// Telegram got this right by bounding the LOOP (`while … && Date() < deadline`) rather than its
    /// body; this watchdog gives all three the same guarantee independently of traffic.
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

        // ⚠️ THE PIN IS NOT LOGGED. `PairingAttemptPolicy` already refuses to record ATTEMPTED
        // digits because a near-miss is one character from the real PIN; logging the real one is
        // strictly worse, and these lines reach exported diagnostic bundles.
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

        // ⚠️ Register KC-33: capture the credential state BEFORE the reset. A failed Keychain
        // read collapses to nil in `config.botToken`, which used to make the farewell silently
        // skip AND the reset report a clean, verified disconnect — while the user's only notice
        // that the bot was gone was precisely the farewell that never sent.
        let credentialStateBeforeReset = ChatOpsConfigManager.credentialState(
            AppSettings.chatOpsBotTokenKey, keychain: config.keychain, logger: logger)

        // Send farewell message if we have a valid connection
        if let token = config.botToken, let chatID = config.authorizedChatID {
            let client = TelegramAPIClient(botToken: token)
            // ⚠️ THE USER'S ONLY NOTICE THAT THE BOT IS GONE, and it is sent before the credentials
            // are wiped — there is no second chance after this line.
            // ⚠️ This copy was already correct; it routes through the shared seam anyway so the
            //   three platforms cannot drift back apart. See `ChatOpsFarewell`.
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
                    // ⚠️⚠️ TWO QUESTIONS, TWO VALUES — AND FUSING THEM WAS A REAL DEFECT. `origin`
                    // answers "who do I count this attempt against"; `senderID` answers "who am I
                    // binding this Mac to". Falling back to the chat id is right for the FORMER —
                    // channel posts have no sender, and refusing to count them at all would leave a
                    // gap the lockout is meant to close — and wrong for the LATTER, because a chat id
                    // is not an account.
                    //
                    // ⚠️ Until this split, the single fused `origin` was stored as `authorizedUserID`
                    // below. A PIN arriving on a message with no `from` therefore paired
                    // "successfully" against a CHAT id, while `ChatOpsSecurityGate` compares against
                    // `update.message?.from?.id` with no such fallback — so every later message, which
                    // does carry a `from`, was refused forever, naming an account the user never used.
                    let senderID = update.message?.from?.id.description
                    let origin = senderID ?? String(chatID)

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
                    // ⚠️ THE SENDER IS RECORDED HERE AND NOWHERE ELSE. `origin` is the same value the
                    //   lockout ledger above already computed, so the account that proved it knew the
                    //   PIN is the account authorized from now on. ChatOps is a single-user remote
                    //   control; without this the chat id was the whole check, and in a GROUP chat
                    //   that authorizes every member.
                    // ⚠️ ATTRIBUTABLE OR NOT AT ALL. A single-user binding cannot be made to a
                    // message nobody sent; the same reasoning `senderIsAuthorized` applies on the
                    // read side, applied here on the write side. The window deliberately stays OPEN
                    // (`continue`, not a failure) so the user can simply send the PIN again from a
                    // normal message.
                    guard let senderID else {
                        logger.error("[CHATOPS] A correct Telegram PIN arrived on a message with NO sender id, so pairing was refused. CONSEQUENCE: pairing did not complete and the window stays open — send the PIN again from a normal chat message rather than a channel post. Recording the chat id here instead would pair against something that is not an account, and every later message WOULD carry a sender id and be refused forever.")
                        continue
                    }

                    config.authorizedUserID = senderID
                    config.authorizedChatID = chatID
                    config.isEnabled = true
                    // ⚠️ THE WINDOW IS OVER THE MOMENT IT SUCCEEDS. `PairingWindowExpiry` would no-op anyway —
                    // the state no longer names this PIN — but leaving the watchdog armed keeps a task alive for
                    // the rest of the five minutes and writes a puzzling "no longer the live one" line when it
                    // fires. Disarming here says what actually happened.
                    deadlineTask?.cancel()
                    deadlineTask = nil
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
            } catch {
                // ⚠️⚠️ [TG-6] THE FOURTH COPY OF THE DEAD ARM. `catch is CancellationError` above this
                // block never matched a cancelled `getUpdates`, which throws `URLError(.cancelled)` —
                // so cancelling a pairing window (the user pressing Cancel, or the watchdog firing)
                // logged "Pairing poll error: cancelled" as a failure. That line is the one an
                // operator reads when pairing did not work, and it was being written by pairing
                // working exactly as asked.
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

    /// Arms the wall-clock watchdog for this window. See `deadlineTask`.
    ///
    /// ⚠️ It CANCELS the polling task rather than trying to unwind it from the outside: cancellation
    /// is what makes an `AsyncStream`'s `next()` return, which is the only way to get a loop parked
    /// on a silent channel to move at all. Expiry is then reported here, because the cancelled loop's
    /// own terminal arm deliberately does nothing when `Task.isCancelled` — it cannot tell a timeout
    /// from the user pressing Cancel, and `PairingWindowExpiry` is what knows the difference.
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
