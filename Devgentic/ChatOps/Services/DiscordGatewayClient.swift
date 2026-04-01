//
//  DiscordGatewayClient.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import os

/// Actor managing the Discord WebSocket Gateway lifecycle.
///
/// Handles the full connection flow:
/// 1. Connect to `wss://gateway.discord.gg/?v=10&encoding=json`
/// 2. Receive HELLO (opcode 10) with heartbeat interval
/// 3. Send IDENTIFY (opcode 2) with bot token + intents
/// 4. Maintain heartbeat loop
/// 5. Receive MESSAGE_CREATE, INTERACTION_CREATE events
/// 6. Handle reconnect/resume on disconnect
actor DiscordGatewayClient {

    private let botToken: String
    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    private let logger = Logger(subsystem: "com.devgentic", category: "DiscordGateway")

    // MARK: - Gateway State

    private var heartbeatTask: Task<Void, Never>?
    private var lastSequence: Int?
    private var sessionID: String?
    private var resumeGatewayURL: String?
    private(set) var applicationID: String?
    private(set) var isConnected: Bool = false

    // Heartbeat tracking
    private var heartbeatAckReceived: Bool = true
    private var heartbeatInterval: Int = 41250

    // Reconnect backoff
    private var backoffSeconds: Double = 1.0
    private let maxBackoff: Double = 60.0

    private static let gatewayURL = "wss://gateway.discord.gg/?v=10&encoding=json"

    init(botToken: String) {
        self.botToken = botToken
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Start / Stop

    /// Starts the Gateway connection and returns an `AsyncStream` of typed events.
    /// Each call cancels any previous connection.
    func start() -> AsyncStream<DiscordGatewayEvent> {
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

    /// Stops the Gateway connection and cleans up.
    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
        logger.info("Discord Gateway stopped.")
    }

    // MARK: - Connection Loop

    private func connectAndListen(continuation: AsyncStream<DiscordGatewayEvent>.Continuation) async {
        while !Task.isCancelled {
            do {
                try await connect()
                try await receiveLoop(continuation: continuation)
            } catch is CancellationError {
                break
            } catch {
                isConnected = false
                let delay = backoffSeconds
                logger.error("Gateway error: \(error.localizedDescription). Reconnecting in \(delay)s...")
                continuation.yield(.disconnected(error))

                increaseBackoff()

                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    break // Cancelled during sleep
                }
            }
        }

        continuation.finish()
        markStopped()
    }

    private func connect() async throws {
        let urlString = resumeGatewayURL ?? Self.gatewayURL
        guard let url = URL(string: urlString) else {
            throw DiscordAPIError.gatewayDisconnected(reason: "Invalid Gateway URL")
        }

        let ws = session.webSocketTask(with: url)
        ws.resume()
        self.webSocket = ws
        self.heartbeatAckReceived = true

        logger.info("Connecting to Discord Gateway: \(urlString)")
    }

    // MARK: - Receive Loop

    private func receiveLoop(continuation: AsyncStream<DiscordGatewayEvent>.Continuation) async throws {
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

    private func handlePayload(data: Data, continuation: AsyncStream<DiscordGatewayEvent>.Continuation) async throws {
        guard let payload = try? JSONDecoder().decode(DiscordGatewayPayload.self, from: data) else {
            logger.warning("Failed to decode Gateway payload.")
            return
        }

        // Update sequence number for heartbeats
        if let seq = payload.s {
            lastSequence = seq
        }

        guard let opcode = DiscordGatewayOpcode(rawValue: payload.op) else {
            logger.debug("Unknown Gateway opcode: \(payload.op)")
            return
        }

        switch opcode {
        case .hello:
            guard let d = payload.d, let hello = try? d.decode(DiscordHelloPayload.self) else { return }
            heartbeatInterval = hello.heartbeat_interval
            startHeartbeatLoop()

            // Identify or resume
            if let sid = sessionID, let seq = lastSequence {
                try await sendResume(sessionID: sid, sequence: seq)
            } else {
                try await sendIdentify()
            }

        case .heartbeat:
            // Server requesting immediate heartbeat
            try await sendHeartbeat()

        case .heartbeatAck:
            heartbeatAckReceived = true

        case .dispatch:
            resetBackoff()
            isConnected = true
            try handleDispatch(eventName: payload.t, data: payload.d, continuation: continuation)

        case .reconnect:
            logger.info("Gateway requested reconnect.")
            webSocket?.cancel(with: .goingAway, reason: nil)
            throw DiscordAPIError.gatewayDisconnected(reason: "Server requested reconnect")

        case .invalidSession:
            // Check if session is resumable
            let resumable = (try? payload.d?.decode(Bool.self)) ?? false
            if !resumable {
                sessionID = nil
                lastSequence = nil
                resumeGatewayURL = nil
            }
            logger.info("Invalid session (resumable: \(resumable)). Reconnecting...")
            webSocket?.cancel(with: .goingAway, reason: nil)
            throw DiscordAPIError.gatewayDisconnected(reason: "Invalid session")

        default:
            break
        }
    }

    // MARK: - Dispatch Events

    private func handleDispatch(eventName: String?, data: DiscordRawJSON?, continuation: AsyncStream<DiscordGatewayEvent>.Continuation) throws {
        guard let eventName, let data else { return }

        switch eventName {
        case "READY":
            guard let ready = try? data.decode(DiscordReadyPayload.self) else { return }
            sessionID = ready.session_id
            resumeGatewayURL = ready.resume_gateway_url
            applicationID = ready.application.id
            logger.info("Discord Gateway READY. Bot: \(ready.user.username), App ID: \(ready.application.id)")
            continuation.yield(.ready(ready))

        case "RESUMED":
            logger.info("Discord Gateway resumed successfully.")
            continuation.yield(.resumed)

        case "MESSAGE_CREATE":
            guard let message = try? data.decode(DiscordMessage.self) else { return }
            continuation.yield(.messageCreate(message))

        case "INTERACTION_CREATE":
            guard let interaction = try? data.decode(DiscordInteraction.self) else { return }
            continuation.yield(.interactionCreate(interaction))

        default:
            // Ignore other dispatch events (GUILD_CREATE, PRESENCE_UPDATE, etc.)
            break
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()

        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            guard let self else { return }

            // First heartbeat: jitter (random delay within interval)
            let jitter = Double.random(in: 0..<Double(interval)) / 1000.0
            try? await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))

            while !Task.isCancelled {
                let ackReceived = await self.heartbeatAckReceived
                if !ackReceived {
                    // Zombie connection — no ACK for last heartbeat
                    await self.logWarning("No heartbeat ACK received. Closing connection.")
                    await self.closeWebSocket()
                    return
                }

                await self.setHeartbeatAckReceived(false)

                do {
                    try await self.sendHeartbeat()
                } catch {
                    await self.logWarning("Failed to send heartbeat: \(error.localizedDescription)")
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                } catch {
                    return // Cancelled
                }
            }
        }
    }

    private func sendHeartbeat() async throws {
        let json: [String: Any?] = ["op": 1, "d": lastSequence]
        let data = try JSONSerialization.data(withJSONObject: json.compactMapValues { $0 ?? NSNull() })
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await webSocket?.send(.string(text))
    }

    // MARK: - Identify / Resume

    private func sendIdentify() async throws {
        let identify = DiscordIdentifyPayload(
            token: botToken,
            intents: DiscordIdentifyPayload.defaultIntents,
            properties: .default
        )
        let payload: [String: Any] = [
            "op": DiscordGatewayOpcode.identify.rawValue,
            "d": [
                "token": identify.token,
                "intents": identify.intents,
                "properties": [
                    "$os": identify.properties.os,
                    "$browser": identify.properties.browser,
                    "$device": identify.properties.device
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await webSocket?.send(.string(text))
        logger.info("Sent IDENTIFY to Discord Gateway.")
    }

    private func sendResume(sessionID: String, sequence: Int) async throws {
        let payload: [String: Any] = [
            "op": DiscordGatewayOpcode.resume.rawValue,
            "d": [
                "token": botToken,
                "session_id": sessionID,
                "seq": sequence
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await webSocket?.send(.string(text))
        logger.info("Sent RESUME to Discord Gateway (session: \(sessionID), seq: \(sequence)).")
    }

    // MARK: - Backoff

    private func resetBackoff() {
        backoffSeconds = 1.0
    }

    private func increaseBackoff() {
        backoffSeconds = min(backoffSeconds * 2, maxBackoff)
    }

    // MARK: - State Helpers

    private func markStopped() {
        isConnected = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func setHeartbeatAckReceived(_ value: Bool) {
        heartbeatAckReceived = value
    }

    private func closeWebSocket() {
        webSocket?.cancel(with: .abnormalClosure, reason: nil)
    }

    private func logWarning(_ message: String) {
        logger.warning("\(message)")
    }
}
