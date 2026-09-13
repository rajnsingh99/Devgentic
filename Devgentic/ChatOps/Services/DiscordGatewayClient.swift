// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    private let logger = DGLogger(category: "DiscordGateway")

    // MARK: - Gateway State

    private var heartbeatTask: Task<Void, Never>?

    /// The connect loop's own handle, so `stop()` can end it. [DC-7]
    private var connectTask: Task<Void, Never>?

    /// Whether teardown was ASKED FOR — a deliberate stop is not a failure and must not reconnect. [DC-7]
    private var isStopping = false

    /// Why the Gateway stopped for good, or nil when it stopped because it was asked to. [DC-7]
    ///
    /// ⚠️ Discord was the ONE platform with no such property: Telegram and Slack both gained one with
    /// their terminal classifiers, so a revoked Discord token killed remote control while the Settings
    /// pane kept a green dot. Set BEFORE the continuation finishes, so a consumer reading it the
    /// moment its `for await` ends cannot see a stale nil.
    private(set) var terminalFailure: String?
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

            // ⚠️ [DC-7] See `stop()` — without this handle, stopping the Gateway depended on the
            //   CONSUMER abandoning its iterator.
            Task { await self.storeConnectTask(task) }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Stops the Gateway connection and cleans up.
    ///
    /// ⚠️⚠️ [DC-7] THIS COULD NOT STOP THE CONNECT LOOP. There was no handle for it at all: the only
    /// cancellation lived in `continuation.onTermination`, so the loop ended only when the CONSUMER
    /// stopped iterating. Every present caller happens to do that; none is required to. Tearing the
    /// socket down without ending the loop just made `receive()` throw, which the catch arm treated
    /// as a network fault and RECONNECTED — and logged a red "Reconnecting" error on every
    /// deliberate shutdown and every successful pairing.
    func stop() {
        isStopping = true
        connectTask?.cancel()
        connectTask = nil
        teardownConnection()
        logger.info("Discord Gateway stopped.")
    }

    private func storeConnectTask(_ task: Task<Void, Never>) {
        connectTask = task
    }

    /// Releases everything belonging to ONE connection.
    ///
    /// ⚠️⚠️ [DC-6] THE HEARTBEAT TASK OUTLIVED ITS SOCKET. `connect()` installed a new socket without
    /// cancelling the previous connection's heartbeat, and that surviving task reads the ACTOR's
    /// CURRENT socket — so between the new socket being installed and its HELLO arriving, a stale
    /// tick could write op-1 to a brand-new, not-yet-identified connection and flip
    /// `heartbeatAckReceived` behind the new loop's back.
    ///
    /// ⚠️⚠️ NEVER CALL THIS FROM THE CATCH ARM. That arm reads `webSocket?.closeCode` to classify the
    /// failure, and a nil socket reads as close code 0 — which `DiscordGatewayClosePolicy` maps to
    /// `.reconnect`. Tearing down first would therefore turn every 4004/4014 into an infinite
    /// reconnect, silently undoing the fatal-close work. `DiscordGatewayClientLifecycleTests` pins this.
    private func teardownConnection() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
    }

    // MARK: - Connection Loop

    private func connectAndListen(continuation: AsyncStream<DiscordGatewayEvent>.Continuation) async {
        isStopping = false
        connectLoop: while !Task.isCancelled {
            do {
                try await connect()
                try await receiveLoop(continuation: continuation)
            } catch {
                isConnected = false

                // ⚠️⚠️ [DC-7] A TEARDOWN WE ASKED FOR IS NOT A FAILURE — checked FIRST, and before the
                // close code is read, because a deliberate stop has no close code worth classifying.
                // This is what stopped every normal shutdown and every successful pairing from writing
                // a red "Reconnecting in 1.0s" error.
                if isStopping {
                    logger.info("[CHATOPS] The Discord Gateway loop ended because it was stopped. CONSEQUENCE: none — no reconnect is attempted; this is a deliberate shutdown and is no longer reported as a failure.")
                    break connectLoop
                }

                // ⚠️ THE THROWN ERROR IS NOT DIAGNOSTIC. A server-side close arrives here as a
                // generic `NSPOSIXErrorDomain` 57 ("Socket is not connected") whether Discord
                // rejected the bot token or the Wi-Fi dropped, which is why this loop used to
                // retry a rejected token every backoff interval forever while the user was told
                // nothing. The close CODE is the only thing that separates those cases, and it
                // lives on the TASK rather than on the error.
                //
                // ⚠️ Reading it works even though `NSURLSessionWebSocketCloseCode` declares no
                // case above 1015 — measured against a server closing with 4004, `rawValue` is
                // 4004. See `DiscordGatewayClosePolicy` for the measurement note.
                let closeCode = webSocket?.closeCode.rawValue ?? 0
                let closeReason = webSocket?.closeReason
                    .flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let reported = (closeReason?.isEmpty == false) ? " Discord said: \(closeReason!)." : ""

                switch DiscordGatewayClosePolicy.disposition(forCloseCode: closeCode) {
                case .fatal(let explanation):
                    // ⚠️ [DC-7] RECORDED, not merely logged. Telegram and Slack both expose a
                    //   `terminalFailure` their bridge turns into a red Settings state; Discord was
                    //   the one platform where a permanent close left the UI showing a green dot.
                    terminalFailure = "Discord closed the Gateway permanently (code \(closeCode)). \(explanation)"
                    logger.error("[CHATOPS] Discord Gateway closed permanently with code \(closeCode).\(reported) \(explanation) CONSEQUENCE: the Discord bridge is STOPPING and will NOT retry, because reconnecting cannot fix this. Discord commands, HITL prompts and mirroring stay off until the cause is corrected and ChatOps is restarted.")
                    continuation.yield(.disconnected(
                        DiscordAPIError.gatewayClosedPermanently(code: closeCode, reason: explanation)
                    ))
                    break connectLoop

                case .reconnectWithNewSession:
                    // ⚠️ Clear the session BEFORE reconnecting. `handlePayload` sends a RESUME
                    // whenever `sessionID` and `lastSequence` are set, so reconnecting without
                    // clearing them replays the sequence Discord just rejected and is closed
                    // again at once — a tight loop that reads as a transient network fault.
                    logger.info("[CHATOPS] Discord Gateway closed with code \(closeCode) — the session is no longer valid.\(reported) CONSEQUENCE: the session id and sequence are discarded and the next connection re-identifies from scratch rather than resuming; queued events since the last sequence are lost.")
                    sessionID = nil
                    lastSequence = nil
                    resumeGatewayURL = nil
                    continuation.yield(.disconnected(error))

                case .reconnect:
                    // ⚠️⚠️ [TG-6] A CANCELLED SOCKET ALWAYS LANDS HERE, because it has no close code
                    // and code 0 maps to `.reconnect`. `catch is CancellationError` — which used to
                    // sit above this block — never matched it: a cancelled URLSession call throws
                    // `URLError(.cancelled)`, an ordinary error. Checked HERE rather than before the
                    // switch so the `.fatal` arm can never be bypassed by a misclassification.
                    if RemoteLoopCancellation.isCancellation(error) {
                        logger.info("[CHATOPS] The Discord Gateway loop ended because its call was cancelled. CONSEQUENCE: none — a deliberate stop. It previously logged a reconnect that never happened.")
                        break connectLoop
                    }

                    let nextDelay = backoffSeconds
                    let ceiling = maxBackoff
                    logger.error("[CHATOPS] Discord Gateway error (close code \(closeCode)): \(error.localizedDescription).\(reported) Reconnecting in \(nextDelay)s. CONSEQUENCE: Discord is unreachable until the reconnect succeeds; the backoff grows toward \(ceiling)s.")
                    continuation.yield(.disconnected(error))
                }

                let delay = backoffSeconds
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

        // ⚠️⚠️ [DC-6] RELEASE THE PREVIOUS CONNECTION BEFORE INSTALLING THIS ONE. Without this the
        // old heartbeat task survived, and it reads the ACTOR's current socket — so it could write
        // op-1 to this brand-new, not-yet-identified connection and flip `heartbeatAckReceived`
        // behind the new loop's back. Placed BEFORE the assignment: after it, this would cancel the
        // socket it just installed.
        teardownConnection()

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
                // ⚠️ A FRAME KIND THIS BUILD CANNOT MODEL. Dropping it in silence means a URLSession
                // that grows a new case makes the Discord connection go partially deaf with nothing
                // anywhere saying so. One line, at a level a bug report carries.
                logger.warning("[CHATOPS/SILENT] A Discord WebSocket frame of an unmodelled kind was received and dropped. CONSEQUENCE: whatever it carried never reached the handler — if the platform has introduced a new frame type, commands sent in it are being ignored with no other trace.")
            }
        }
    }

    private func handlePayload(data: Data, continuation: AsyncStream<DiscordGatewayEvent>.Continuation) async throws {
        // ⚠️ THE ENVELOPE CARRIES THE SEQUENCE NUMBER. Losing it is not just a lost event: `s` is
        // what heartbeats and RESUME replay from, so a run of undecodable envelopes degrades the
        // next resume into a full reconnect and re-delivers or skips events either side of the gap.
        // The old line said only "Failed to decode Gateway payload" — no opcode, no consequence.
        let payload: DiscordGatewayPayload
        do {
            payload = try JSONDecoder().decode(DiscordGatewayPayload.self, from: data)
        } catch {
            logger.error("[CHATOPS] Could not decode a Discord Gateway envelope (\(data.count) bytes): \(error.localizedDescription). CONSEQUENCE: the event inside is dropped AND its sequence number is never recorded, so a later RESUME replays from a stale point — the user may see a command silently ignored, or an old one acted on twice.")
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
            // ⚠️ A DROPPED HELLO IS A DEAD CONNECTION, NOT A DROPPED MESSAGE. The heartbeat
            // interval arrives only here, so returning silently means the heartbeat loop never
            // starts and Discord closes the socket ~45s later as unresponsive — which surfaces as
            // an unexplained reconnect cycle rather than as a decode problem.
            guard let d = payload.d else {
                logger.error("[CHATOPS] Discord HELLO arrived with no `d` payload. CONSEQUENCE: no heartbeat interval, so the heartbeat loop never starts and Discord closes this connection as unresponsive within about a minute; the bridge then reconnects and the user sees intermittent unavailability with no stated cause.")
                return
            }
            let hello: DiscordHelloPayload
            do {
                hello = try d.decode(DiscordHelloPayload.self)
            } catch {
                logger.error("[CHATOPS] Could not decode Discord HELLO: \(error.localizedDescription). CONSEQUENCE: no heartbeat interval, so the heartbeat loop never starts and Discord closes this connection as unresponsive within about a minute; the bridge reconnects in a loop and Discord appears intermittently dead with nothing naming the cause.")
                return
            }
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
            // ⚠️ READY CARRIES THE APPLICATION ID, and nothing else does. Without it
            // `editInteractionResponse` cannot address a deferred reply, so every slash command
            // falls back to a channel post and leaves its "thinking…" placeholder unresolved.
            let ready: DiscordReadyPayload
            do {
                ready = try data.decode(DiscordReadyPayload.self)
            } catch {
                logger.error("[CHATOPS] Could not decode Discord READY: \(error.localizedDescription). CONSEQUENCE: no session id, no resume URL and NO APPLICATION ID for this session — so slash commands cannot edit their deferred response and every one of them leaves a permanent \"thinking…\" placeholder, while resumes degrade to full reconnects.")
                return
            }
            sessionID = ready.session_id
            resumeGatewayURL = ready.resume_gateway_url
            applicationID = ready.application.id
            logger.info("Discord Gateway READY. Bot: \(ready.user.username), App ID: \(ready.application.id)")
            continuation.yield(.ready(ready))

        case "RESUMED":
            logger.info("Discord Gateway resumed successfully.")
            continuation.yield(.resumed)

        case "MESSAGE_CREATE":
            // ⚠️⚠️ THIS IS THE BOT GOING DEAF, SILENTLY. A MESSAGE_CREATE this build cannot model
            // was dropped here with no log at all, so a Discord schema change — or one unexpected
            // field — turned every typed command into "the bot ignored me", on both sides.
            let message: DiscordMessage
            do {
                message = try data.decode(DiscordMessage.self)
            } catch {
                logger.error("[CHATOPS] Could not decode a Discord MESSAGE_CREATE: \(error.localizedDescription). CONSEQUENCE: the user's typed message is DROPPED before it ever reaches the command parser — they get no reply and no error, and the bot appears to be ignoring them. If this line repeats, Discord's payload shape has moved past what DiscordMessage models.")
                return
            }
            continuation.yield(.messageCreate(message))

        case "INTERACTION_CREATE":
            // ⚠️⚠️ WORSE THAN A DROPPED MESSAGE: an unacked interaction shows the user Discord's red
            // "This interaction failed" three seconds later, so they see a definite failure with
            // nothing anywhere explaining it.
            let interaction: DiscordInteraction
            do {
                interaction = try data.decode(DiscordInteraction.self)
            } catch {
                logger.error("[CHATOPS] Could not decode a Discord INTERACTION_CREATE: \(error.localizedDescription). CONSEQUENCE: the button tap or slash command is dropped before the bridge sees it, so nothing acknowledges it and Discord shows the user \"This interaction failed\" after three seconds. If this line repeats, the interaction payload has moved past what DiscordInteraction models.")
                return
            }
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
                    await self.logWarning("[CHATOPS] No Discord heartbeat ACK received; closing the connection. CONSEQUENCE: this socket is a zombie — Discord stopped responding but never closed it, so commands sent in this window were silently going nowhere. Closing forces the reconnect that restores them.")
                    await self.closeWebSocket()
                    return
                }

                await self.setHeartbeatAckReceived(false)

                do {
                    try await self.sendHeartbeat()
                } catch {
                    // ⚠️ THIS `return` ENDS THE HEARTBEAT LOOP FOR GOOD. Without a heartbeat Discord
                    // closes the session within about a minute, so a failed send is the start of an
                    // outage, not a blip — and the old line named neither that nor the recovery.
                    await self.logWarning("[CHATOPS] Failed to send a Discord heartbeat: \(error.localizedDescription). CONSEQUENCE: the heartbeat loop STOPS here, so Discord closes this session as unresponsive within about a minute and every command sent meanwhile is lost; recovery depends entirely on the reconnect that close triggers.")
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

    /// ⚠️ [DC-8] Typed for the same reason as `sendResume`. ⚠️ `d` is deliberately OPTIONAL: before
    /// the first dispatch there is no sequence, and Discord expects a literal `null` there — which is
    /// what `Optional<Int>` encodes to, where the old `compactMapValues { $0 ?? NSNull() }` dance was
    /// reproducing that by hand.
    private func sendHeartbeat() async throws {
        let frame = DiscordGatewayFrame(op: DiscordGatewayOpcode.heartbeat.rawValue, d: lastSequence)
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await webSocket?.send(.string(text))
    }

    // MARK: - Identify / Resume

    /// ⚠️⚠️ [DC-8] DELIBERATELY NOT CONVERTED TO A TYPED FRAME, unlike RESUME and HEARTBEAT. Discord's
    /// IDENTIFY nests its connection properties under the keys `$os`, `$browser` and `$device` — a
    /// leading `$` that a Swift property name cannot carry, so a `Codable` struct would need a
    /// `CodingKeys` enum whose only job is to re-add three dollar signs. That is more moving parts
    /// than the dictionary it would replace, on the one frame that must be byte-exact or the gateway
    /// refuses the connection. The dictionary IS the clearer expression here; recorded so the next
    /// reader does not "finish the job" and reintroduce the risk.
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

    /// ⚠️ [DC-8] TYPED, so `DiscordResumePayload` is actually what goes on the wire. It previously had
    /// two references in the entire repo — both in a TEST that encoded and decoded it — while this
    /// function hand-built a dictionary. A model nothing sends is a model whose test proves nothing.
    private func sendResume(sessionID: String, sequence: Int) async throws {
        let frame = DiscordGatewayFrame(
            op: DiscordGatewayOpcode.resume.rawValue,
            d: DiscordResumePayload(token: botToken, session_id: sessionID, seq: sequence)
        )
        let data = try JSONEncoder().encode(frame)
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
