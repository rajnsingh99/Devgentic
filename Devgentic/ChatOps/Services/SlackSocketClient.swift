// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackSocketClient.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import os

/// Actor managing the Slack Socket Mode WebSocket lifecycle.
///
/// Socket Mode flow:
/// 1. Call `apps.connections.open` with app-level token to get a wss URL
/// 2. Connect to the wss URL
/// 3. Receive `hello` message confirming connection
/// 4. Receive `events_api`, `interactive`, `slash_commands` envelopes
/// 5. **Acknowledge each envelope** by sending `{ "envelope_id": "<id>" }` within 3 seconds
/// 6. On `disconnect` type, reconnect (get new wss URL)
actor SlackSocketClient {

    private let appToken: String
    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private let logger = DGLogger(category: "SlackSocket")

    // MARK: - State

    private(set) var isConnected: Bool = false
    private var backoffSeconds: Double = 1.0
    private let maxBackoff: Double = 60.0

    /// Why the connect loop gave up for good, or nil when it stopped because it was asked to.
    ///
    /// ⚠️⚠️ THIS LOOP HAD EXACTLY ONE CATCH-ALL ARM, WHICH MADE A REJECTED TOKEN INDISTINGUISHABLE
    /// FROM A DROPPED WI-FI. Both reconnected on the same growing backoff, forever, and both
    /// reported themselves through the same `.disconnected(error)` event that `SlackChatOpsBridge`
    /// answers with a `logger.error` and nothing else — no state change, no user-visible signal.
    /// Invariant 26 records this exact failure being fixed for the Discord Gateway ("the old
    /// catch-all reconnect retried a rejected token every backoff interval forever while the user
    /// was told nothing"); Slack never received the same treatment. Set BEFORE `continuation.finish()`.
    private(set) var terminalFailure: String?

    /// Slack error codes that mean the app token will never work again without the user acting.
    ///
    /// ⚠️ `nonisolated` and `static` so the classification is assertable without a live socket,
    /// while the loop below calls this same function — a pinned mapping cannot drift from production.
    /// ⚠️ Deliberately NOT a catch-all on "anything containing auth": `ratelimited` and transient
    /// server errors also arrive as `apiError`, and treating one of those as terminal would take
    /// down a connection that was going to recover by itself.
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

            // ⚠️⚠️ [SL-7] `stop()` COULD NOT STOP THIS LOOP. It tore down the socket, which made the
            // in-flight `receive()` throw — and the loop caught that, slept its backoff and RECONNECTED.
            // Correctness depended entirely on the CONSUMER abandoning its iterator so
            // `onTermination` fired, which every current caller happens to do and none is required to.
            // The handle is stored through the same actor hop `TelegramListener.storePollingTask`
            // already uses, because this closure is @Sendable and not actor-isolated.
            Task { await self.storeConnectTask(task) }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Stops the Socket Mode connection.
    ///
    /// ⚠️ [SL-7] `isStopping` is set BEFORE anything is torn down, so the loop's catch arm can tell a
    /// teardown it asked for from one that happened to it. Cancelling the task alone is not enough:
    /// the in-flight `receive()` throws first, and the catch arm runs before cancellation is observed.
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
                // ⚠️ [CONC-5] The socket is THREADED, never re-read from `self` after a suspension.
                let ws = try await connect()
                try await receiveLoop(on: ws, continuation: continuation)
            } catch {
                isConnected = false

                // ⚠️⚠️ [SL-7/TG-6] THE ORDER OF THESE THREE CHECKS IS THE CONTRACT.
                //   1. `isStopping` — a teardown we asked for is never a failure and never reconnects.
                //   2. TERMINAL — a rejected app token must be reported even mid-teardown, or the
                //      Settings pane never learns why the bridge died.
                //   3. CANCELLATION — `catch is CancellationError` (which used to sit above this
                //      block) never matches a cancelled URLSession call: it throws
                //      `URLError(.cancelled)`. So every deliberate stop fell through to the generic
                //      arm below and logged a reconnect that never happened, at a level the exported
                //      diagnostic bundle keeps.
                // Reversing 2 and 3 would silently gut the terminal classifier.
                if isStopping {
                    logger.info("[CHATOPS] The Slack connect loop ended because it was stopped. CONSEQUENCE: none — no reconnect is attempted and no `.disconnected` event is yielded; this is a deliberate shutdown and is no longer reported as a failure.")
                    break
                }

                // ⚠️ A REJECTED TOKEN IS NOT A NETWORK BLIP. Retrying it burns a request per backoff
                // interval forever and can never succeed, while the user is shown a bridge that
                // looks merely flaky. Classify first, and only fall through to the reconnect when
                // the failure is one a reconnect could actually clear.
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

    /// ⚠️⚠️ [CONC-5] RETURNS THE SOCKET RATHER THAN PUBLISHING IT. `apps.connections.open` is an
    /// await, and a `stop()` landing during it used to nil a socket that this function then replaced
    /// a line later — resurrecting a connection AFTER everything had been torn down, with nothing
    /// left holding a reference that could cancel it. Threading the value means no code after a
    /// suspension re-reads `self.webSocket` to decide what to act on; the stored property survives
    /// only as the handle `stop()` cancels.
    private func connect() async throws -> URLSessionWebSocketTask {
        // Get a fresh WebSocket URL from Slack
        let wsURL = try await SlackAPIClient.openConnection(appToken: appToken)

        // ⚠️ AFTER the await, BEFORE the socket exists: a socket that must not exist is never
        //   constructed, rather than constructed and orphaned.
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

    /// ⚠️ [CONC-5] Takes the socket it must read, rather than re-reading `self.webSocket` — which
    /// could by then be a DIFFERENT connection, or nil after a `stop()`.
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
                // ⚠️ A FRAME KIND THIS BUILD CANNOT MODEL. Dropping it in silence means a URLSession
                // that grows a new case makes the Slack connection go partially deaf with nothing
                // anywhere saying so. One line, at a level a bug report carries.
                logger.warning("[CHATOPS/SILENT] A Slack WebSocket frame of an unmodelled kind was received and dropped. CONSEQUENCE: whatever it carried never reached the handler — if the platform has introduced a new frame type, commands sent in it are being ignored with no other trace.")
            }
        }
    }

    private func handlePayload(data: Data, on ws: URLSessionWebSocketTask, continuation: AsyncStream<SlackSocketEvent>.Continuation) async throws {
        // ⚠️ THE ENVELOPE CARRIES THE ACK ID. Failing here means the envelope is never
        // acknowledged either, so Slack retries it up to three times and then treats this app as
        // failing — the log line said only "Failed to decode", which named neither.
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
            // ⚠️⚠️ THIS IS THE BOT GOING DEAF, SILENTLY — the same class as Discord's
            // MESSAGE_CREATE drop. A typed message this build cannot model vanished with no log.
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
            // ⚠️ BUTTON TAPS AND MODAL SUBMISSIONS BOTH ARRIVE HERE. Dropping a view_submission
            // silently is how a user's typed clarification answer disappears with the run still
            // parked — the failure slice 4.3 was built to remove, reappearing one layer lower.
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

    /// Acknowledges receipt of an envelope by sending back the envelope_id.
    ///
    /// ⚠️⚠️ [SL-4] THE SOCKET IS A PARAMETER BECAUSE THE OPTIONAL CHAIN WAS THE BUG. This was
    /// `try await webSocket?.send(...)`: when the socket had been nil'd, the ack simply evaporated —
    /// no send, no throw, no log — on the one path the file's own header calls critical. Slack then
    /// redelivers the envelope up to three times and finally treats the app as unhealthy. A
    /// non-optional parameter makes the silent version unwritable.
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
