// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackSocketClient.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Actor managing the Slack Socket Mode WebSocket lifecycle.
/// Opens a wss URL via `apps.connections.open`, receives `events_api`, `interactive` and `slash_commands` envelopes,
/// acknowledges each within 3 seconds with `{ "envelope_id": "<id>" }`, and reconnects on `disconnect`.
actor SlackSocketClient {

    private let appToken: String
    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private let logger = DGLogger(category: "SlackSocket")

    // MARK: - State

    private(set) var isConnected: Bool = false
    private var backoffSeconds: Double = 1.0
    private let maxBackoff: Double = 60.0

    // Why: a rejected token must not share the generic reconnect arm: it would retry on backoff forever, surfacing nothing.
    /// Why the connect loop gave up for good, or nil when it stopped because it was asked to.
    /// Set before `continuation.finish()`, so the bridge can tell a rejected token from a dropped connection.
    private(set) var terminalFailure: String?

    // Why: not a catch-all on "auth": `ratelimited` and transient server errors also arrive as `apiError` and must reconnect.
    /// Slack error codes that mean the app token will never work again without the user acting.
    /// `nonisolated static` so the mapping is testable without a live socket while the loop calls this same function.
    nonisolated static func terminalReason(slackErrorCode code: String) -> String? {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "token_expired":
            return "Slack rejected the app-level token (\(code)) — it has been revoked, regenerated or has expired."
        case "account_inactive":
            return "Slack reports the app's account as inactive (\(code)) — the app may have been uninstalled from the workspace."
        case "no_permission", "missing_scope":
            return "Slack refused the connection for lack of permission (\(code)) — the app is missing the connections:write scope."
        default:
            return nil
        }
    }

    /// The loop's own handle, so `stop()` can end it rather than merely interrupting it. [SL-7]
    private var connectTask: Task<Void, Never>?

    /// Whether teardown was ASKED FOR. [SL-7] Distinguishes a deliberate stop from a socket that died.
    private var isStopping = false

    init(appToken: String) {
        self.appToken = appToken
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Start / Stop

    /// Starts the Socket Mode connection and returns an `AsyncStream` of typed events.
    func start() -> AsyncStream<SlackSocketEvent> {
        stop()

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

                await self.connectAndListen(continuation: continuation)
            }

            // `stop()` must be able to stop this loop: teardown makes the in-flight `receive()` throw, which would reconnect.
            // Stored through an actor hop (as `TelegramListener.storePollingTask` does) since this closure is @Sendable.
            Task { await self.storeConnectTask(task) }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // Why: set `isStopping` before teardown so the catch arm can tell a requested stop from a failure;
    // cancelling the task alone is not enough, as the in-flight `receive()` throws first.
    /// Stops the Socket Mode connection.
    func stop() {
        isStopping = true
        connectTask?.cancel()
        connectTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
        logger.info("Slack Socket Mode stopped.")
    }

    private func storeConnectTask(_ task: Task<Void, Never>) {
        connectTask = task
    }

    // MARK: - Connection Loop

    private func connectAndListen(continuation: AsyncStream<SlackSocketEvent>.Continuation) async {
        isStopping = false
        while !Task.isCancelled {
            do {
                // The socket is threaded through, never re-read from `self` after a suspension.
                let ws = try await connect()
                try await receiveLoop(on: ws, continuation: continuation)
            } catch {
                isConnected = false

                // Order is the contract: 1. `isStopping` (never a failure), 2. terminal (report a rejected token even mid-teardown),
                // 3. cancellation (`URLError(.cancelled)`, not `CancellationError`). Checking it before terminal hides rejected tokens.
                if isStopping {
                    logger.info("[CHATOPS] The Slack connect loop ended because it was stopped. CONSEQUENCE: none — no reconnect is attempted and no `.disconnected` event is yielded; this is a deliberate shutdown and is no longer reported as a failure.")
                    break
                }

                // A rejected token is not a network blip: retrying it can never succeed, so classify first and reconnect only for
                // failures a reconnect could clear.
                if case SlackAPIError.apiError(_, let code) = error,
                   let reason = Self.terminalReason(slackErrorCode: code) {
                    terminalFailure = reason
                    logger.error("[CHATOPS] Slack Socket Mode gave up: \(reason) CONSEQUENCE: the connect loop STOPS rather than reconnecting forever — remote control over Slack is dead until the user supplies a working app token, and the Settings connection status now shows this reason in red instead of a green 'Active' dot.")
                    continuation.yield(.disconnected(error))
                    break
                }

                if RemoteLoopCancellation.isCancellation(error) {
                    logger.info("[CHATOPS] The Slack connect loop ended because its call was cancelled. CONSEQUENCE: none — a deliberate stop, not a failure. It previously wrote a 'Reconnecting in Ns' error that never happened.")
                    break
                }

                let delay = backoffSeconds
                logger.warning("[CHATOPS] Slack Socket Mode error: \(error.localizedDescription). Reconnecting in \(delay)s. CONSEQUENCE: Slack is unreachable until a reconnect succeeds — no command is received and no notification is announced in the meantime, and the backoff grows toward its ceiling with each failure.")
                continuation.yield(.disconnected(error))

                increaseBackoff()

                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    break
                }
            }
        }

        continuation.finish()
        isConnected = false
    }

    // Why: a `stop()` during the `apps.connections.open` await must not leave a resurrected connection nothing can cancel.
    /// Opens the Socket Mode connection and returns the socket.
    /// Returned, not published, so no code after a suspension re-reads `self.webSocket`; it is only `stop()`'s handle.
    private func connect() async throws -> URLSessionWebSocketTask {
        // Get a fresh WebSocket URL from Slack
        let wsURL = try await SlackAPIClient.openConnection(appToken: appToken)

        // After the await, before the socket exists: a socket that must not exist is never constructed rather than orphaned.
        try Task.checkCancellation()

        guard let url = URL(string: wsURL) else {
            throw SlackAPIError.socketDisconnected(reason: "Invalid WebSocket URL")
        }

        let ws = session.webSocketTask(with: url)
        ws.resume()
        self.webSocket = ws

        logger.info("Connecting to Slack Socket Mode: \(wsURL.prefix(60))...")
        return ws
    }

    // MARK: - Receive Loop

    /// Takes the socket it must read rather than re-reading `self.webSocket`,
    /// which could by then be another connection, or nil after a `stop()`.
    private func receiveLoop(on ws: URLSessionWebSocketTask,
                             continuation: AsyncStream<SlackSocketEvent>.Continuation) async throws {

        while !Task.isCancelled {
            let message = try await ws.receive()

            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8) else { continue }
                try await handlePayload(data: data, on: ws, continuation: continuation)
            case .data(let data):
                try await handlePayload(data: data, on: ws, continuation: continuation)
            @unknown default:
                // A frame kind this build cannot model: dropping it silently would leave the connection partly deaf with no trace.
                logger.warning("[CHATOPS/SILENT] A Slack WebSocket frame of an unmodelled kind was received and dropped. CONSEQUENCE: whatever it carried never reached the handler — if the platform has introduced a new frame type, commands sent in it are being ignored with no other trace.")
            }
        }
    }

    private func handlePayload(data: Data, on ws: URLSessionWebSocketTask, continuation: AsyncStream<SlackSocketEvent>.Continuation) async throws {
        // The envelope carries the ack id: failing here leaves it unacknowledged, so Slack retries up to three times
        // and then treats the app as failing.
        let payload: SlackSocketPayload
        do {
            payload = try JSONDecoder().decode(SlackSocketPayload.self, from: data)
        } catch {
            logger.error("[CHATOPS] Could not decode a Slack Socket Mode envelope: \(error.localizedDescription). CONSEQUENCE: the event inside is dropped AND its envelope is never acked, so Slack retries it and eventually reports the app as failing; to the user every command sent in this window simply does nothing.")
            return
        }

        // Acknowledge the envelope immediately (within 3 seconds)
        if let envelopeID = payload.envelope_id {
            try await acknowledge(envelopeID: envelopeID, on: ws)
        }

        switch payload.type {
        case "hello":
            isConnected = true
            resetBackoff()
            logger.info("Slack Socket Mode connected (hello received).")
            continuation.yield(.connected)

        case "events_api":
            // A missing payload is the bot going deaf silently, the same class as Discord's MESSAGE_CREATE drop; log it.
            guard let rawPayload = payload.payload else {
                logger.error("[CHATOPS] A Slack events_api envelope carried no payload. CONSEQUENCE: the user's message is dropped before the command parser sees it; they get no reply and no error, and the bot appears to be ignoring them.")
                return
            }
            let eventPayload: SlackEventPayload
            do {
                eventPayload = try rawPayload.decode(SlackEventPayload.self)
            } catch {
                logger.error("[CHATOPS] Could not decode a Slack events_api payload: \(error.localizedDescription). CONSEQUENCE: the user's typed message is DROPPED before it reaches the command parser — no reply, no error, the bot looks dead to them. If this repeats, Slack's event shape has moved past what SlackEventPayload models.")
                return
            }
            continuation.yield(.message(eventPayload.event))

        case "interactive":
            // Button taps and modal submissions both arrive here; dropping a view_submission silently loses a typed clarification
            // answer while the run stays parked.
            guard let rawPayload = payload.payload else {
                logger.error("[CHATOPS] A Slack interactive envelope carried no payload. CONSEQUENCE: a button tap or modal submission is dropped; if it was a clarification answer the run stays parked and the user's typed text is lost with no trace.")
                return
            }
            let interactive: SlackInteractivePayload
            do {
                interactive = try rawPayload.decode(SlackInteractivePayload.self)
            } catch {
                logger.error("[CHATOPS] Could not decode a Slack interactive payload: \(error.localizedDescription). CONSEQUENCE: the button tap or modal submission is DROPPED — the message does not change, no reply appears, and if it was a clarification answer the run stays parked and the typed text is lost. If this repeats, the interactive shape has moved past what SlackInteractivePayload models.")
                return
            }
            continuation.yield(.interaction(interactive))

        case "slash_commands":
            guard let rawPayload = payload.payload else {
                logger.error("[CHATOPS] A Slack slash_commands envelope carried no payload. CONSEQUENCE: the slash command is dropped and the user sees no response to a command they invoked from Slack's own menu.")
                return
            }
            let slashCommand: SlackSlashCommandPayload
            do {
                slashCommand = try rawPayload.decode(SlackSlashCommandPayload.self)
            } catch {
                logger.error("[CHATOPS] Could not decode a Slack slash_commands payload: \(error.localizedDescription). CONSEQUENCE: the slash command is DROPPED before the bridge sees it, so a command invoked from Slack's own menu produces no reply at all. If this repeats, the payload shape has moved past what SlackSlashCommandPayload models.")
                return
            }
            continuation.yield(.slashCommand(slashCommand))

        case "disconnect":
            logger.info("Slack sent disconnect. Reconnecting with new URL...")
            isConnected = false
            webSocket?.cancel(with: .goingAway, reason: nil)
            throw SlackAPIError.socketDisconnected(reason: "Server requested disconnect")

        default:
            logger.debug("Unknown Socket Mode type: \(payload.type)")
        }
    }

    // MARK: - Acknowledgment

    // Why: the socket is a parameter, not an optional chain: a nil socket would drop the ack silently and Slack would redeliver.
    /// Acknowledges receipt of an envelope by sending back the envelope_id.
    private func acknowledge(envelopeID: String, on ws: URLSessionWebSocketTask) async throws {
        let ack = SlackSocketAck(envelope_id: envelopeID)
        let data = try JSONEncoder().encode(ack)
        guard let text = String(data: data, encoding: .utf8) else {
            logger.warning("[CHATOPS/SILENT] Could not encode a Slack ack for envelope \(envelopeID). CONSEQUENCE: the envelope is never acknowledged, so Slack redelivers it up to three times — the command may run repeatedly — and then marks this app unhealthy.")
            return
        }
        try await ws.send(.string(text))
    }

    // MARK: - Backoff

    private func resetBackoff() {
        backoffSeconds = 1.0
    }

    private func increaseBackoff() {
        backoffSeconds = min(backoffSeconds * 2, maxBackoff)
    }
}
