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
    private let logger = Logger(subsystem: DGLogger.subsystem, category: "SlackSocket")

    // MARK: - State

    private(set) var isConnected: Bool = false
    private var backoffSeconds: Double = 1.0
    private let maxBackoff: Double = 60.0

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

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Stops the Socket Mode connection.
    func stop() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
        logger.info("Slack Socket Mode stopped.")
    }

    // MARK: - Connection Loop

    private func connectAndListen(continuation: AsyncStream<SlackSocketEvent>.Continuation) async {
        while !Task.isCancelled {
            do {
                try await connect()
                try await receiveLoop(continuation: continuation)
            } catch is CancellationError {
                break
            } catch {
                isConnected = false
                let delay = backoffSeconds
                logger.error("Socket Mode error: \(error.localizedDescription). Reconnecting in \(delay)s...")
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

    private func connect() async throws {
        // Get a fresh WebSocket URL from Slack
        let wsURL = try await SlackAPIClient.openConnection(appToken: appToken)
        guard let url = URL(string: wsURL) else {
            throw SlackAPIError.socketDisconnected(reason: "Invalid WebSocket URL")
        }

        let ws = session.webSocketTask(with: url)
        ws.resume()
        self.webSocket = ws

        logger.info("Connecting to Slack Socket Mode: \(wsURL.prefix(60))...")
    }

    // MARK: - Receive Loop

    private func receiveLoop(continuation: AsyncStream<SlackSocketEvent>.Continuation) async throws {
        guard let ws = webSocket else { return }

        while !Task.isCancelled {
            let message = try await ws.receive()

            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8) else { continue }
                try await handlePayload(data: data, continuation: continuation)
            case .data(let data):
                try await handlePayload(data: data, continuation: continuation)
            @unknown default:
                break
            }
        }
    }

    private func handlePayload(data: Data, continuation: AsyncStream<SlackSocketEvent>.Continuation) async throws {
        guard let payload = try? JSONDecoder().decode(SlackSocketPayload.self, from: data) else {
            logger.warning("Failed to decode Socket Mode payload.")
            return
        }

        // Acknowledge the envelope immediately (within 3 seconds)
        if let envelopeID = payload.envelope_id {
            try await acknowledge(envelopeID: envelopeID)
        }

        switch payload.type {
        case "hello":
            isConnected = true
            resetBackoff()
            logger.info("Slack Socket Mode connected (hello received).")
            continuation.yield(.connected)

        case "events_api":
            guard let rawPayload = payload.payload,
                  let eventPayload = try? rawPayload.decode(SlackEventPayload.self) else { return }
            continuation.yield(.message(eventPayload.event))

        case "interactive":
            guard let rawPayload = payload.payload,
                  let interactive = try? rawPayload.decode(SlackInteractivePayload.self) else { return }
            continuation.yield(.interaction(interactive))

        case "slash_commands":
            guard let rawPayload = payload.payload,
                  let slashCommand = try? rawPayload.decode(SlackSlashCommandPayload.self) else { return }
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
    private func acknowledge(envelopeID: String) async throws {
        let ack = SlackSocketAck(envelope_id: envelopeID)
        let data = try JSONEncoder().encode(ack)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await webSocket?.send(.string(text))
    }

    // MARK: - Backoff

    private func resetBackoff() {
        backoffSeconds = 1.0
    }

    private func increaseBackoff() {
        backoffSeconds = min(backoffSeconds * 2, maxBackoff)
    }
}
