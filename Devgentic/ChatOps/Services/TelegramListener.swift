// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TelegramListener.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Why: set before `continuation.finish()` so a consumer reading it as its `for await` ends cannot see a stale nil.
    /// Why the poll loop stopped for good, or nil when it stopped because it was asked to.
    /// Lets consumers tell a terminal failure (e.g. a revoked token) from `stop()`, which look identical at stream end.
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
                        // The order of these checks is the contract: terminal first (a revoked token must be reported even during teardown),
                        // cancellation second (a deliberate stop is not a failure), backoff last (everything else is transient).
                        let delay = Self.retryDelay(backoff: await self.getBackoffDelay(), error: error)
                        await self.increaseBackoff()

                        // A terminal error is one retrying cannot clear because it needs the user to act. 409 Conflict is terminal too:
                        // a registered webhook or a second poller never resolves on its own, and retrying forever delivers nothing.
                        if let apiError = error as? TelegramAPIError,
                           case .apiError(let code, let description) = apiError,
                           let reason = Self.terminalReason(code: code, description: description) {
                            await self.recordTerminalFailure(reason)
                            await self.logError("\(reason) Stopping listener.")
                            break
                        }

                        // A cancelled URLSession call throws `URLError(.cancelled)`, not `CancellationError`, so it is checked here;
                        // otherwise a normal shutdown would be logged as a polling failure in the exported diagnostic bundle.
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

    /// Returns how long to wait before the next poll after `error`.
    /// Honours a 429's Telegram `retry_after`, never shorter than the backoff; non-finite or negative values fall back to
    /// the backoff and nothing waits more than an hour.
    nonisolated static func retryDelay(backoff: Double, error: Error) -> Double {
        guard let requested = (error as? TelegramAPIError)?.retryAfterSeconds,
              let wait = ProviderErrorClassifier.sanitizedRetryAfter(requested) else { return backoff }
        return max(backoff, wait)
    }

    /// Returns what to tell the user when a Telegram API error ends the poll loop, or nil for anything a retry can clear
    /// (network blips, 5xx, 429), which stays on the backoff.
    /// `nonisolated static` so tests can assert the classification without a listener; the loop calls this same function.
    nonisolated static func terminalReason(code: Int, description: String) -> String? {
        switch code {
        case 401:
            return "Telegram rejected the bot token (401 Unauthorized) — it has been revoked or regenerated."
        case 403:
            return "Telegram refused the bot (403 Forbidden) — it may have been blocked or removed from the chat."
        case 409:
            // The description says which of the two causes it is (webhook or second poller); passed through so the user knows.
            return "Telegram refused to poll (409 Conflict) — a webhook is registered on this bot, or another copy of the app is polling it. \(description)"
        default:
            return nil
        }
    }

    private func logError(_ message: String) {
        logger.error("\(message)")
    }

    /// Logs at `.info`: a deliberate stop is a routine success, not a failure.
    private func logStopped() {
        logger.info("[CHATOPS] The Telegram poll loop ended because it was cancelled. CONSEQUENCE: none — this is a deliberate stop, and no reconnect is attempted. It previously fell through to the generic error arm and wrote a false 'Polling error … Retrying' line into the diagnostic bundle.")
    }
}
