// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TelegramListener.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import os

/// Actor that manages a long-polling loop against the Telegram Bot API.
/// Yields `TelegramUpdate` values via an `AsyncStream` for the `ChatOpsBridge` to consume.
actor TelegramListener {

    private let apiClient: TelegramAPIClient
    private let logger = DGLogger(category: "TelegramListener")

    private var pollingTask: Task<Void, Never>?
    private var lastUpdateID: Int = 0
    private var backoffSeconds: Double = 1.0
    private let maxBackoff: Double = 60.0

    /// Whether the listener is currently polling.
    private(set) var isPolling: Bool = false

    /// Why the poll loop stopped for good, or nil when it stopped because it was asked to.
    ///
    /// ⚠️⚠️ THE STREAM ENDING IS NOT THE SAME EVENT AS THE STREAM DYING, AND NOTHING COULD TELL THEM
    /// APART. A terminal error `break`s the loop, finishes the continuation and marks the listener
    /// stopped — byte-identical, from the consumer's side, to `stop()` being called. `ChatOpsBridge`
    /// therefore logged one `.info` line and flipped `isRunning` for both, and nothing in the app
    /// ever wrote `ChatOpsConnectionState.error` even though the Settings UI has a red arm waiting
    /// for it. The result: a revoked or rotated bot token killed remote control for the life of the
    /// process while the Pairing card kept a green dot and the word "Active", and the only recovery
    /// was quitting the app. Set BEFORE `continuation.finish()` so a consumer that reads it the
    /// moment its `for await` ends cannot see a stale nil.
    private(set) var terminalFailure: String?

    init(apiClient: TelegramAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Start / Stop

    /// Starts the long-polling loop and returns an `AsyncStream` of updates.
    /// Each call to `start()` cancels any previous polling task.
    func start() -> AsyncStream<TelegramUpdate> {
        stop()

        isPolling = true
        logger.info("Telegram long-polling started.")

        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                while !Task.isCancelled {
                    do {
                        let updates = try await self.apiClient.getUpdates(
                            offset: await self.getNextOffset(),
                            timeout: 60
                        )

                        // Reset backoff on successful poll
                        await self.resetBackoff()

                        for update in updates {
                            await self.updateLastID(update.update_id)
                            continuation.yield(update)
                        }

                    } catch {
                        // ⚠️⚠️ [TG-6] THE ORDER OF THESE THREE CHECKS IS THE CONTRACT.
                        //   1. TERMINAL first — a revoked token must be reported even if the loop is
                        //      also being torn down, or the Settings pane never learns why it died.
                        //   2. CANCELLATION second — a deliberate stop is not a failure.
                        //   3. Backoff last — everything else is transient.
                        // Reversing 1 and 2 would silently gut the terminal classifiers: a stop that
                        // races a 401 would exit quietly and the bridge would look stopped rather
                        // than broken, which is the invisibility those classifiers were added to end.
                        let delay = await self.getBackoffDelay()
                        await self.increaseBackoff()

                        // Check if this is a terminal error — one that retrying cannot clear,
                        // because it needs the USER to do something.
                        //
                        // ⚠️ 409 IS TERMINAL TOO, AND ITS ABSENCE WAS THE QUIETER BUG. Telegram
                        // answers `getUpdates` with 409 Conflict whenever a webhook is registered on
                        // the bot or a second client is polling it — neither of which resolves on
                        // its own. It fell through to the generic arm below and retried at the 60s
                        // backoff ceiling forever, so the bridge looked alive, burned a request a
                        // minute, and delivered nothing.
                        if let apiError = error as? TelegramAPIError,
                           case .apiError(let code, let description) = apiError,
                           let reason = Self.terminalReason(code: code, description: description) {
                            await self.recordTerminalFailure(reason)
                            await self.logError("\(reason) Stopping listener.")
                            break
                        }

                        // ⚠️⚠️ [TG-6] THIS ARM USED TO BE UNREACHABLE FOR A DELIBERATE STOP AND
                        // REPORTED ONE ANYWAY. `catch is CancellationError` — which sat above this
                        // block — never matches a cancelled URLSession call: it throws
                        // `URLError(.cancelled)`, an ordinary error. So `stop()` fell through to the
                        // line below, which claimed a polling failure and a retry that never
                        // happened, at a level `DGLogger.shouldPersist` writes into the exported
                        // diagnostic bundle. Every normal ChatOps shutdown left a false failure in
                        // the one artefact a field debugger reads.
                        if RemoteLoopCancellation.isCancellation(error) {
                            await self.logStopped()
                            break
                        }

                        await self.logError("Polling error: \(error.localizedDescription). Retrying in \(delay)s...")

                        do {
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        } catch {
                            break // Cancelled during sleep
                        }
                    }
                }

                continuation.finish()
                await self.markStopped()
            }

            // Store the task so we can cancel it later
            Task { await self.storePollingTask(task) }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Stops the long-polling loop.
    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
        logger.info("Telegram long-polling stopped.")
    }

    // MARK: - Internal State Management

    private func getNextOffset() -> Int {
        lastUpdateID + 1
    }

    private func updateLastID(_ id: Int) {
        lastUpdateID = max(lastUpdateID, id)
    }

    private func resetBackoff() {
        backoffSeconds = 1.0
    }

    private func getBackoffDelay() -> Double {
        backoffSeconds
    }

    private func increaseBackoff() {
        backoffSeconds = min(backoffSeconds * 2, maxBackoff)
    }

    private func storePollingTask(_ task: Task<Void, Never>) {
        pollingTask = task
    }

    private func markStopped() {
        isPolling = false
    }

    private func recordTerminalFailure(_ reason: String) {
        terminalFailure = reason
    }

    /// Whether a Telegram API error ends the poll loop, and what to tell the user if so.
    ///
    /// Returns nil for anything a retry can clear (network blips, 5xx, 429), which stays on the
    /// existing backoff.
    ///
    /// ⚠️ `nonisolated` and `static` so a test can assert the CLASSIFICATION without standing up a
    /// listener, an actor hop or a live socket — while the poll loop above still calls this exact
    /// function, so a test that pins the mapping cannot drift from what production does.
    nonisolated static func terminalReason(code: Int, description: String) -> String? {
        switch code {
        case 401:
            return "Telegram rejected the bot token (401 Unauthorized) — it has been revoked or regenerated."
        case 403:
            return "Telegram refused the bot (403 Forbidden) — it may have been blocked or removed from the chat."
        case 409:
            // ⚠️ The description carries which of the two causes it is; Telegram's text is stable
            // enough to be worth passing through, and a user who set a webhook needs to know that.
            return "Telegram refused to poll (409 Conflict) — a webhook is registered on this bot, or another copy of the app is polling it. \(description)"
        default:
            return nil
        }
    }

    private func logError(_ message: String) {
        logger.error("\(message)")
    }

    /// ⚠️ `.info`, not `.error`: a deliberate stop is a routine success. The whole point of TG-6 is
    /// that this event was being reported as a failure.
    private func logStopped() {
        logger.info("[CHATOPS] The Telegram poll loop ended because it was cancelled. CONSEQUENCE: none — this is a deliberate stop, and no reconnect is attempted. It previously fell through to the generic error arm and wrote a false 'Polling error … Retrying' line into the diagnostic bundle.")
    }
}
