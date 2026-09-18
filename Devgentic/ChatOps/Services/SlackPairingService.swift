// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
@Observable @MainActor
final class SlackPairingService {

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
    static let shared = SlackPairingService()


    private let logger = DGLogger(category: "SlackPairing")
    private let config = ChatOpsConfigManager.shared

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

        // ⚠️ THE PIN IS NOT LOGGED — see the Telegram twin.
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

        if let token = config.slackBotToken, let channelID = config.slackAuthorizedChannelID {
            let client = SlackAPIClient(botToken: token)
            await ChatOpsFarewell.send(provider: .slack, logger: logger) {
                _ = try await client.postMessage(channel: channelID, text: ChatOpsFarewell.message)
            }
        }

        config.resetSlack()
        logger.info("Slack ChatOps disconnected and credentials cleared.")
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

                // ⚠️ THE SENDER, NOT THE CHANNEL — see the note in DiscordPairingService. Slack's
                // `user` is optional on a message event, and an unattributable one must not be
                // counted against everybody.
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

                // ⚠️⚠️ [NEW-5] A BARE `continue` HERE DISCARDED A CORRECT PIN. By this line
                // `PairingAttemptPolicy.classify` has already ruled the message a MATCH — the
                // `.wrongPIN` arm returned above — so this is the user's real PIN being dropped with
                // no trace, three lines before the assignments that would have completed pairing.
                // Every neighbouring refusal in this loop names its consequence; this one said
                // nothing, so a user whose pairing silently failed had no way to tell it apart from
                // a bot that never received the message at all.
                //
                // ⚠️ STILL A `continue`, NOT A FAILURE: without a channel there is no address to
                // listen on, so pairing genuinely cannot complete — but the window stays open and the
                // user only has to send the PIN again from a normal channel message.
                guard let channelID = slackEvent.channel else {
                    logger.error("[CHATOPS] A correct Slack PIN arrived on an event carrying NO channel, so pairing could not complete. CONSEQUENCE: nothing was paired and the window stays OPEN — send the PIN again as an ordinary channel message. Pairing needs a channel because that address is what the bridge listens on; recording the user alone would leave nowhere to receive commands.")
                    continue
                }

                // ⚠️ See the Telegram twin: `origin` (the Slack `user`) is what proved it knew the
                //   PIN, and a Slack channel id identifies a ROOM, not a person.
                config.slackAuthorizedUserID = origin
                config.slackAuthorizedChannelID = channelID
                config.isSlackEnabled = true
                // ⚠️ THE WINDOW IS OVER THE MOMENT IT SUCCEEDS. `PairingWindowExpiry` would no-op anyway —
                // the state no longer names this PIN — but leaving the watchdog armed keeps a task alive for
                // the rest of the five minutes and writes a puzzling "no longer the live one" line when it
                // fires. Disarming here says what actually happened.
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

    /// Arms the wall-clock watchdog for this window. See `deadlineTask`.
    ///
    /// ⚠️ It CANCELS the polling task rather than trying to unwind it from the outside: cancellation
    /// is what makes an `AsyncStream`'s `next()` return, which is the only way to get a loop parked
    /// on a silent channel to move at all. Expiry is then reported here, because the cancelled loop's
    /// own terminal arm deliberately does nothing when `Task.isCancelled` — it cannot tell a timeout
    /// from the user pressing Cancel, and `PairingWindowExpiry` is what knows the difference.
    private func armDeadline(pin: String) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.pairingTimeout ?? 300 * 1_000_000_000))
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
