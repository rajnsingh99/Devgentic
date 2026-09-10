// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    private let logger = Logger(subsystem: DGLogger.subsystem, category: "TelegramListener")

    private var pollingTask: Task<Void, Never>?
    private var lastUpdateID: Int = 0
    private var backoffSeconds: Double = 1.0
    private let maxBackoff: Double = 60.0

    /// Whether the listener is currently polling.
    private(set) var isPolling: Bool = false

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

                    } catch is CancellationError {
                        break
                    } catch {
                        let delay = await self.getBackoffDelay()
                        await self.increaseBackoff()

                        // Check if this is a terminal error (invalid token)
                        if let apiError = error as? TelegramAPIError,
                           case .apiError(let code, _) = apiError, code == 401 {
                            await self.logError("Invalid bot token (401). Stopping listener.")
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

    private func logError(_ message: String) {
        logger.error("\(message)")
    }
}
