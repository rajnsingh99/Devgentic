//
//  MCPClientService.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//

import Foundation
import MCP
import os.log

private let logger = DGLogger(category: "MCPClientService")

/// Observable connection lifecycle state for each MCP server.
enum MCPConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case error(String)

    var isActive: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// What a server told us about itself during `initialize`.
///
/// The whole `Initialize.Result` used to be discarded at the `client.connect` call site.
/// That threw away three things we cannot get back later: the negotiated protocol version,
/// the server's capability set (so every optional feature had to be attempted blindly and
/// fail), and `instructions` — the server's own guidance on how to use it, which the SDK
/// stores privately with no accessor, making the connect return value the only chance to
/// read it.
struct MCPServerInfo: Sendable {
    let protocolVersion: String
    let serverName: String
    let serverVersion: String
    /// Server-authored usage guidance, surfaced to the agent as system context.
    let instructions: String?

    /// Wall-clock milliseconds the `initialize` handshake took. The only latency figure the
    /// UI has for a server, and the one that explains a slow first tool call.
    var handshakeMS: Int = 0

    let supportsResources: Bool
    let supportsResourceSubscribe: Bool
    let supportsResourceListChanged: Bool
    let supportsPrompts: Bool
    let supportsPromptListChanged: Bool
    let supportsTools: Bool
    let supportsLogging: Bool
}

/// Represents an active connection to an MCP server.
struct MCPSession {
    let id: UUID
    let client: MCP.Client
    let transport: any Transport
    let process: ShellProcess?
    /// Nil only for sessions created before the handshake result was captured.
    let serverInfo: MCPServerInfo?
}

@Observable @MainActor
final class MCPClientService {

    static let shared = MCPClientService()

    private(set) var activeSessions: [UUID: MCPSession] = [:]
    var connectionStates: [UUID: MCPConnectionState] = [:]

    /// Tracks health monitor tasks so they can be cancelled on disconnect.
    private var healthMonitorTasks: [UUID: Task<Void, Never>] = [:]

    /// In-flight `connect` calls, keyed by source.
    ///
    /// Without this, two concurrent connects for one source both passed the
    /// "is there an existing session?" check (neither had stored one yet), both
    /// spawned a `ShellProcess`, and the second overwrote the first in
    /// `activeSessions` — orphaning a live child process that nothing would ever
    /// terminate. An agent issuing parallel tool calls hits this directly.
    /// Callers now coalesce onto the first connect instead of racing it.
    private var connectionTasks: [UUID: Task<(client: MCP.Client, tools: [ToolDefinition]), Error>] = [:]

    /// How long to wait for the SDK handshake, by transport.
    ///
    /// A cold `npx -y <pkg>` downloads the package before the server even starts,
    /// which routinely exceeds 15s on a first run — the old single budget turned an
    /// ordinary first launch into a timeout on a server that would have worked.
    /// Remote transports do no such setup, so they keep a tight budget.
    ///
    /// ⚠️ `var` **only** so `MCPHarness` can shorten them; nothing in the app writes either.
    /// Testing the timeout path against a server that hangs at `initialize` is otherwise a
    /// 90-second test, which means in practice it is a test nobody runs.
    static var localHandshakeTimeout: TimeInterval = 90
    static var remoteHandshakeTimeout: TimeInterval = 20

    /// Cached `resources/list` and `prompts/list` results, invalidated by the matching
    /// `*/list_changed` notification. Both lists are re-read on every agent call otherwise,
    /// and they change rarely.
    private var resourceCache: [UUID: [MCP.Resource]] = [:]
    private var promptCache: [UUID: [MCP.Prompt]] = [:]

    /// Debounce timers for `tools/list_changed`, keyed by source. Servers emit the
    /// notification in bursts at startup; without this each one cost a full `tools/list`
    /// plus a SwiftData write.
    private var toolListRefreshTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}
    
    // MARK: - Connection Methods
    
    /// Connect to an MCP server. Secrets (env values, auth tokens) are passed
    /// as a separate `secrets` bundle and never live inside `config` — config
    /// is persisted in SwiftData while secrets live in Keychain. When the
    /// caller has a persisted `sourceID` + `definition` but no live secrets
    /// (e.g. tool-execution reconnect), pass `secrets: nil` to have the
    /// service materialize them from Keychain itself.
    func connect(
        sourceId: UUID,
        config: ServerDefinition,
        secrets: MCPRuntimeSecrets? = nil
    ) async throws -> (client: MCP.Client, tools: [ToolDefinition]) {
        // Coalesce concurrent connects for the same source onto one attempt. Two
        // callers racing here used to spawn two child processes and orphan one.
        if let inFlight = connectionTasks[sourceId] {
            logger.info("""
                [MCP-CONNECT] Connect already in flight for source \(sourceId); joining it \
                instead of spawning a second server process.
                """)
            return try await inFlight.value
        }

        let task = Task { [weak self] () throws -> (client: MCP.Client, tools: [ToolDefinition]) in
            guard let self else { throw MCPManagerError.unknown }
            return try await self.performConnect(sourceId: sourceId, config: config, secrets: secrets)
        }
        connectionTasks[sourceId] = task
        defer { connectionTasks[sourceId] = nil }

        return try await task.value
    }

    private func performConnect(
        sourceId: UUID,
        config: ServerDefinition,
        secrets: MCPRuntimeSecrets? = nil
    ) async throws -> (client: MCP.Client, tools: [ToolDefinition]) {
        // 1. Cleanup existing session
        if activeSessions[sourceId] != nil {
            logger.info("Disconnecting existing session for source \(sourceId)")
            await disconnect(sourceId: sourceId)
        }

        connectionStates[sourceId] = .connecting

        logger.info("Initializing new MCP Client for source \(sourceId)")

        // Declare what WE can do for the server. The client used to be constructed with the
        // SDK's empty default, so `initialize` advertised no sampling, no roots and no
        // elicitation — servers correctly concluded those were unavailable and either
        // disabled the features that need them or failed at call time.
        let client = MCP.Client(
            name: "Devgentic",
            version: "2.0.0",
            capabilities: MCP.Client.Capabilities(
                sampling: .init(),
                elicitation: .init(form: .init()),
                roots: .init(listChanged: true)
            )
        )

        // Register the server→client request handlers. These must be attached BEFORE
        // `connect`, otherwise an eager server can issue a request we would answer with
        // `methodNotFound` during startup.
        let serverLabel = config.command ?? config.url ?? "MCP server"
        await registerClientHandlers(on: client, sourceId: sourceId, serverLabel: serverLabel)

        // Materialize secrets from Keychain when the caller didn't supply them
        // (i.e. background reconnects rather than form-driven connects).
        let resolvedSecrets = secrets ?? MCPRuntimeSecrets.materialize(for: sourceId, definition: config)

        let transport: any Transport
        var shellProcess: ShellProcess? = nil
        var handshakeTimeout = Self.remoteHandshakeTimeout

        do {
            // 2. Transport Setup
            if let urlString = config.url {
                transport = try setupRemoteTransport(urlString: urlString, config: config, secrets: resolvedSecrets)
                // Strip userinfo and secret-named query params before logging — users
                // sometimes paste URLs with embedded credentials or `?api_key=…`.
                logger.info("Transport type: Remote (\(MCPRedaction.redact(url: urlString)))")
            } else if let command = config.command {
                logger.info("Transport type: Local Process (\(command))")
                let (localTransport, process) = try setupLocalTransport(config: config, secrets: resolvedSecrets)
                transport = localTransport
                shellProcess = process
                // A cold `npx -y` fetches the package before the server starts.
                handshakeTimeout = Self.localHandshakeTimeout

                // 2a. FAIL FAST CHECK
                try await Task.sleep(nanoseconds: 500_000_000)

                if !process.process.isRunning {
                    let stderr = MCPRedaction.redact(text: process.readStdErr())
                    throw MCPManagerError.processFailedToStart(
                        stderr.isEmpty ? "Process exited immediately with code \(process.process.terminationStatus)." : stderr
                    )
                }
            } else {
                throw MCPManagerError.invalidJSONConfiguration("Server definition missing 'command' or 'url'.")
            }

            logger.info("[MCP-CONNECT] Transport ready for source \(sourceId). SDK handshake, budget \(handshakeTimeout)s...")

            // 3. Connect via SDK with Timeout. KEEP the handshake result — it is the only
            //    place the server's capabilities, protocol version and `instructions` are
            //    exposed.
            let handshakeStart = Date()
            let initializeResult = try await withTimeout(seconds: handshakeTimeout) {
                try await client.connect(transport: transport)
            }
            var serverInfo = Self.makeServerInfo(from: initializeResult)
            serverInfo.handshakeMS = Int(Date().timeIntervalSince(handshakeStart) * 1000)
            lastVerified[sourceId] = Date()

            logger.info("""
                [MCP-CONNECT] Handshake OK for source \(sourceId): \
                \(serverInfo.serverName) v\(serverInfo.serverVersion), protocol \
                \(serverInfo.protocolVersion). Capabilities — tools:\(serverInfo.supportsTools) \
                resources:\(serverInfo.supportsResources) prompts:\(serverInfo.supportsPrompts) \
                logging:\(serverInfo.supportsLogging). Instructions: \
                \(serverInfo.instructions?.isEmpty == false ? "\(serverInfo.instructions!.count) chars" : "none").
                """)

            // 3a. Subscribe to `tools/list_changed`. When the server adds or
            //     removes tools at runtime, refetch and update the persisted
            //     set so the UI and the agent both see the new surface area.
            //     Capture weakly to avoid keeping the service alive forever.
            await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleToolListChanged(sourceID: sourceId)
                }
            }

            // 3b. The same treatment for resources and prompts. Only tools were subscribed
            //     before, so a server that added a resource or prompt at runtime left the
            //     agent looking at a stale list with nothing to indicate it.
            if serverInfo.supportsResourceListChanged {
                await client.onNotification(ResourceListChangedNotification.self) { (_: Message<ResourceListChangedNotification>) in
                    Task { @MainActor in
                        logger.info("[MCP-NOTIFY] Source \(sourceId) reports resources/list_changed; cached resource list invalidated.")
                        MCPClientService.shared.invalidateResourceCache(sourceID: sourceId)
                    }
                }
            }
            if serverInfo.supportsPromptListChanged {
                await client.onNotification(PromptListChangedNotification.self) { (_: Message<PromptListChangedNotification>) in
                    Task { @MainActor in
                        logger.info("[MCP-NOTIFY] Source \(sourceId) reports prompts/list_changed; cached prompt list invalidated.")
                        MCPClientService.shared.invalidatePromptCache(sourceID: sourceId)
                    }
                }
            }

            // 3c. Server-emitted log messages. Previously unsubscribed, so a server
            //     reporting its own errors through the protocol was talking into a void.
            await client.onNotification(LogMessageNotification.self) { (message: Message<LogMessageNotification>) in
                Task { @MainActor in
                    let text = (try? JSONEncoder().encode(message.params.data))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "<unencodable>"
                    logger.info("[MCP-SERVERLOG] source=\(sourceId) level=\(message.params.level.rawValue) \(MCPRedaction.redact(text: text))")
                }
            }

            // 4. Store Session
            let session = MCPSession(
                id: sourceId, client: client, transport: transport,
                process: shellProcess, serverInfo: serverInfo
            )
            activeSessions[sourceId] = session
            connectionStates[sourceId] = .connected

            // 5. Health monitoring. Local sessions watch the child process; remote sessions
            //    are pinged, because nothing else would ever notice them going away.
            if shellProcess != nil {
                startHealthMonitor(for: sourceId)
            } else {
                startRemoteHealthMonitor(for: sourceId)
            }

            // 6. Tool discovery — server tools plus the synthetic resource/prompt surface.
            //    Composed in one shared place so the `tools/list_changed` refresh cannot
            //    drift from this and drop half the list.
            logger.info("Fetching tools...")
            let tools = try await composeToolList(client: client, serverInfo: serverInfo)
            let syntheticCount = MCPSyntheticTool.definitions(
                for: serverInfo,
                serverName: serverInfo.serverName.isEmpty ? serverLabel : serverInfo.serverName
            ).count

            logger.info("""
                [MCP-TOOLS] Discovered \(tools.count) tool(s) for source \(sourceId): \
                \(tools.count - syntheticCount) from the server + \(syntheticCount) synthetic \
                (resource/prompt surface).
                """)

            return (client, tools)

        } catch {
            logger.error("[MCP-CONNECT] Connection failed for source \(sourceId): \(error.localizedDescription)")

            var finalError = error
            var serverOutput: String? = nil

            if let shell = shellProcess {
                let stderr = MCPRedaction.redact(text: shell.readStdErr())
                // ⚠️ Whether the child is STILL RUNNING is what decides the diagnosis, and it
                // has to be read before `terminate()`.
                //
                // This branch used to substitute `processFailedToStart(stderr)` for whatever
                // error had actually occurred, unconditionally, whenever stderr was non-empty.
                // But stderr is the ONLY channel a stdio server may use for human output, so a
                // perfectly healthy server writes to it during startup — meaning every later
                // local failure was reported as "The server process failed to start", quoting
                // the server's own healthy banner as the cause. A server that started in 40 ms
                // and then hung at `initialize` for 90 seconds was reported as a start failure,
                // which sends the user to check the command they typed instead of the server
                // that is not answering.
                let processIsAlive = shell.process.isRunning

                if !stderr.isEmpty {
                    logger.error("""
                        [MCP-CONNECT] Last captured stderr for \(sourceId) (process \
                        \(processIsAlive ? "STILL RUNNING" : "exited, status \(shell.process.terminationStatus)")): \
                        \(stderr)
                        """)
                }

                if !processIsAlive, !stderr.isEmpty {
                    // The child is gone: stderr IS the diagnosis.
                    finalError = MCPManagerError.processFailedToStart(stderr)
                } else if !stderr.isEmpty {
                    // The child is alive, so the failure is in the protocol, not the launch.
                    // Keep the real error — callers key off its case — and carry stderr through
                    // as context on the message the user sees.
                    serverOutput = stderr
                }
                shell.terminate()
            } else {
                // REMOTE failure. Only the child process was being torn down here, so a failed
                // remote connect left the SDK client and its SSE stream alive with no session
                // to own them — observed as repeated `nw_read_request_report … Operation timed
                // out` long after the connect had already reported failure.
                await client.disconnect()
                logger.info("[MCP-CONNECT] Tore down the remote client for \(sourceId) after a failed handshake.")
            }

            let message = Self.actionableConnectionMessage(
                for: finalError, config: config, serverOutput: serverOutput
            )
            connectionStates[sourceId] = .error(message)
            throw finalError
        }
    }
    
    func disconnect(sourceId: UUID) async {
        healthMonitorTasks[sourceId]?.cancel()
        healthMonitorTasks.removeValue(forKey: sourceId)

        // A debounced `tools/list_changed` refresh can still be sleeping out its 400 ms when
        // the user disconnects. It was not cancelled, so it woke up, found no session, and
        // logged "tools/list_changed … with no active session; ignoring" — on an ORDINARY
        // teardown. A warning that fires during normal operation is a warning people learn to
        // scroll past, which costs the line its value for the case it was written for (a
        // notification arriving after a server died on its own).
        toolListRefreshTasks[sourceId]?.cancel()
        toolListRefreshTasks.removeValue(forKey: sourceId)

        guard let session = activeSessions[sourceId] else { return }
        await session.client.disconnect()
        session.process?.terminate()
        activeSessions.removeValue(forKey: sourceId)
        connectionStates[sourceId] = .disconnected
        logger.info("Disconnected session \(sourceId). Process terminated.")
    }
    
    func disconnectAll() async {
        // Snapshot keys before iterating: `disconnect` mutates `activeSessions`,
        // and modifying a Dictionary while iterating its `.keys` view is undefined.
        let ids = Array(activeSessions.keys)
        guard !ids.isEmpty else { return }

        // Concurrently, not sequentially. This runs inside AppDelegate's 3s quit
        // watchdog: serialised, a single server hanging in `client.disconnect()` ate the
        // whole budget and every server after it kept its child process alive, which then
        // got re-parented to launchd as an orphan.
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { @MainActor [weak self] in
                    await self?.disconnect(sourceId: id)
                }
            }
            await group.waitForAll()
        }
        logger.info("[MCP-LIFECYCLE] Disconnected \(ids.count) MCP session(s).")
    }

    /// Last-resort synchronous teardown for app termination.
    ///
    /// `ShellProcess.terminate()` escalates SIGTERM → SIGKILL on a 2-second
    /// `asyncAfter`, which can never fire at quit: the process is gone long before the
    /// timer. A child that ignores SIGTERM therefore survived as an orphan. This sends
    /// SIGKILL inline so nothing outlives the app.
    func killAllChildProcessesNow() {
        var killed = 0
        for (id, session) in activeSessions {
            guard let process = session.process?.process, process.isRunning else { continue }
            kill(process.processIdentifier, SIGKILL)
            killed += 1
            logger.warning("[MCP-LIFECYCLE] SIGKILLed surviving child pid \(process.processIdentifier) for source \(id) at quit.")
        }
        if killed > 0 {
            logger.info("[MCP-LIFECYCLE] Force-killed \(killed) MCP child process(es) that outlived graceful teardown.")
        }
    }
    
    // MARK: - tools/list_changed

    /// Called when the SDK delivers a `notifications/tools/list_changed`
    /// notification for an active session. Re-runs `listTools` and hands the
    /// fresh set off to `MCPToolStore` so persistence + UI both update. Best
    /// effort — failures log and leave the prior list in place rather than
    /// blanking it on a transient error.
    private func handleToolListChanged(sourceID: UUID) async {
        // Coalesce bursts. The reference server emits this four times within a second of
        // startup, and each one was a full `tools/list` round-trip plus a SwiftData write —
        // wasteful with one server, and multiplied by every chatty server connected.
        toolListRefreshTasks[sourceID]?.cancel()
        toolListRefreshTasks[sourceID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.performToolListRefresh(sourceID: sourceID)
            self.toolListRefreshTasks[sourceID] = nil
        }
    }

    private func performToolListRefresh(sourceID: UUID) async {
        guard let session = activeSessions[sourceID] else {
            logger.warning("""
                [MCP-TOOLS] tools/list_changed for source \(sourceID) with no active session; \
                ignoring. Its persisted tool list stays as it was.
                """)
            return
        }
        do {
            // MUST go through the same composition as connect. Calling `listTools` directly
            // here returned ONLY the server's own tools, so every `tools/list_changed`
            // silently deleted the synthetic resource/prompt tools that connect had added —
            // a server that emits the notification on startup (the reference server fires it
            // repeatedly) wiped them within a second of them appearing.
            let tools = try await composeToolList(client: session.client, serverInfo: session.serverInfo)
            // Routed through the host bridge rather than straight into `MCPToolStore` — see
            // MCPHostBridge.swift. A nil sink is loud, not silent: the accessor logs that the
            // refreshed list was dropped and that the UI keeps a stale one.
            MCPHostBridge.requireToolListSink(context: "tools/list_changed for source \(sourceID)")?
                .replaceTools(forSourceID: sourceID, with: tools)
            logger.info("[MCP-TOOLS] Refreshed \(tools.count) tool(s) for source \(sourceID) on list_changed.")
        } catch {
            logger.warning("""
                [MCP-TOOLS] Failed to refresh tools on list_changed for \(sourceID): \
                \(error.localizedDescription). The previously known list is left in place \
                rather than blanked.
                """)
        }
    }

    /// The complete tool list for a session: the server's own tools plus the synthetic
    /// resource/prompt tools its capabilities justify.
    ///
    /// Single source of truth for both connect and `tools/list_changed` — they diverged
    /// once and the refresh path quietly dropped the synthetic half.
    private func composeToolList(client: MCP.Client, serverInfo: MCPServerInfo?) async throws -> [ToolDefinition] {
        var tools = (serverInfo?.supportsTools ?? true) ? try await listTools(client: client) : []

        let label = serverInfo?.serverName.isEmpty == false ? serverInfo!.serverName : "MCP server"
        let synthetic = MCPSyntheticTool.definitions(for: serverInfo, serverName: label)
        tools.append(contentsOf: synthetic)
        return tools
    }

    // MARK: - Tool Execution
    
    func executeTool(sourceId: UUID, name: String, arguments: [String: Any]) async throws -> String {
        guard let session = activeSessions[sourceId] else {
            throw MCPManagerError.connectionFailed(NSError(domain: "MCPClientService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active session."]))
        }
        
        let argsData = try JSONSerialization.data(withJSONObject: arguments)
        let decoder = JSONDecoder()
        let mcpArgs = try decoder.decode([String: MCP.Value].self, from: argsData)

        // Use the RequestContext overload rather than the `(content:isError:)` convenience:
        // it carries `structuredContent` (dropped by the tuple form) and exposes the
        // JSON-RPC `requestID`, which is the correlation ID tying this log line to the
        // transport and to the server's own logs.
        // `await` is required even though this overload is synchronous — `Client` is an
        // actor, so the hop is what makes the call legal from the MainActor.
        let context: RequestContext<CallTool.Result> =
            try await session.client.callTool(name: name, arguments: mcpArgs)
        let requestID = context.requestID

        logger.info("[MCP-CALL] req=\(String(describing: requestID)) tool='\(name)' source=\(sourceId) dispatched.")

        let result = try await context.value

        // A completed round-trip is the strongest liveness evidence there is — better than
        // any ping, and it keeps the status readout honest between ping intervals.
        lastVerified[sourceId] = Date()

        var rendered = result.content.map(Self.render(content:))

        // `structuredContent` is the machine-readable twin of the text content when
        // the tool declares an `outputSchema`. Append it only when the tool returned
        // nothing else, so well-behaved servers that send both do not get duplicated
        // into the model's context.
        if rendered.isEmpty, let structured = result.structuredContent,
           let data = try? JSONEncoder().encode(structured),
           let json = String(data: data, encoding: .utf8) {
            rendered.append(json)
        }

        let output = rendered.joined(separator: "\n")

        // A failed MCP tool returns NORMALLY with `isError: true` — it does not throw.
        // Reading this is what separates a tool failure from a tool result: without it
        // the failure text is handed to the model as a successful result, the mediator
        // scores the call `.success`, and reliability metrics count it as a win.
        if result.isError == true {
            let detail = output.isEmpty ? "Server reported isError with no content." : output
            logger.error("""
                [MCP-CALL] req=\(String(describing: requestID)) tool='\(name)' source=\(sourceId) \
                reported FAILURE (isError: true) — surfacing as a tool error so the agent can \
                react instead of treating the message as a result. Detail: \(detail)
                """)
            throw MCPManagerError.toolReportedFailure(tool: name, detail: detail)
        }

        if output.isEmpty {
            logger.warning("""
                [MCP-CALL] req=\(String(describing: requestID)) tool='\(name)' source=\(sourceId) \
                returned no renderable content (\(result.content.count) part(s), \
                structuredContent: \(result.structuredContent != nil)) — the agent will receive \
                an empty result and may retry or hallucinate a value.
                """)
        }

        // Cap at ingress. An MCP server is an untrusted remote that can return an
        // arbitrarily large body, and this string flows on into the timeline and the
        // persistence layer. Bounding it here — at the boundary where the untrusted data
        // arrives — protects every downstream consumer at once, rather than relying on
        // each one to defend itself. The limit matches the documented timeline cap
        // (architecture_readme.md §3) so nothing downstream sees more than it already handles.
        if output.count > Self.maxToolOutputChars {
            let dropped = output.count - Self.maxToolOutputChars
            logger.warning("""
                [MCP-CALL] req=\(String(describing: requestID)) tool='\(name)' source=\(sourceId) \
                returned \(output.count) chars — TRUNCATED to \(Self.maxToolOutputChars), \
                \(dropped) chars dropped. The agent sees a loss marker and may need to request \
                a narrower query.
                """)
            return String(output.prefix(Self.maxToolOutputChars))
                + "\n… [truncated: \(dropped) more characters from this MCP tool]"
        }

        return output
    }

    /// Matches the timeline/resume cap documented in `architecture_readme.md` §3.
    private static let maxToolOutputChars = 32_768

    /// Renders one MCP content part into the text the agent sees.
    ///
    /// Every non-text case used to collapse to a fixed placeholder (`"[Image Output]"`),
    /// which discarded the payload AND made two different results indistinguishable.
    /// Carry the identifying detail through instead — mime type, URI, name — so the
    /// model can at least reason about what it got and ask for it another way.
    /// `Tool` is qualified because the app declares its own `Tool` (BackendProfile.swift),
    /// which would otherwise shadow the SDK's inside this file.
    private static func render(content: MCP.Tool.Content) -> String {
        switch content {
        case .text(let text, _, _):
            return text

        case .image(let data, let mimeType, _, _):
            // TODO: route into the existing vision-input pipeline rather than
            // describing the payload. Tracked in MCP_Production_Readiness.md (#6).
            return "[image: \(mimeType), \(data.count) base64 chars]"

        case .audio(let data, let mimeType, _, _):
            return "[audio: \(mimeType), \(data.count) base64 chars]"

        case .resource(let resource, _, _):
            // Embedded resources carry their payload inline — surface text content
            // directly, since that is the common case for docs/config servers.
            if let text = resource.text, !text.isEmpty {
                return text
            }
            return "[resource: \(resource.uri)\(resource.mimeType.map { " (\($0))" } ?? "")]"

        case .resourceLink(let uri, let name, let title, let description, let mimeType, _):
            let label = title ?? name
            let detail = [description, mimeType].compactMap { $0 }.joined(separator: ", ")
            return detail.isEmpty
                ? "[resource link: \(label) — \(uri)]"
                : "[resource link: \(label) — \(uri) (\(detail))]"

        @unknown default:
            return "[unsupported content type — this Devgentic build predates it]"
        }
    }
    
    // MARK: - Resources (MCP `resources/*`)

    func invalidateResourceCache(sourceID: UUID) { resourceCache[sourceID] = nil }
    func invalidatePromptCache(sourceID: UUID) { promptCache[sourceID] = nil }

    /// Tells every connected server that the workspace roots changed.
    func notifyRootsChangedEverywhere() async {
        for (sourceID, session) in activeSessions {
            do {
                try await session.client.notifyRootsChanged()
            } catch {
                logger.warning("""
                    [MCP-ROOTS] Could not notify source \(sourceID) of the roots change: \
                    \(error.localizedDescription). That server keeps operating against the previous \
                    boundary until it reconnects.
                    """)
            }
        }
    }

    /// What the connected server said it can do, for callers deciding whether to offer a
    /// resource/prompt affordance at all.
    func serverInfo(for sourceID: UUID) -> MCPServerInfo? {
        activeSessions[sourceID]?.serverInfo
    }

    /// When each session was last PROVEN alive — set at handshake and refreshed by every
    /// successful ping or tool call.
    ///
    /// A remote server used to sit on `.connected` forever: the health monitor only watched
    /// local child processes, so a remote endpoint that went away still showed green until
    /// the user tried to use it. This is what makes "connected" mean something for them.
    private(set) var lastVerified: [UUID: Date] = [:]

    func markVerified(sourceID: UUID) {
        lastVerified[sourceID] = Date()
    }

    /// Server-authored usage guidance from every connected server, ready for the system
    /// prompt. Empty when nothing is connected or no server supplied instructions.
    ///
    /// Capped per server: `instructions` is server-controlled text that lands in EVERY
    /// request's system prefix, so an oversized one would silently eat the context window
    /// on all subsequent turns.
    func connectedServerInstructions() -> String {
        let blocks: [String] = activeSessions.values.compactMap { session in
            guard let info = session.serverInfo,
                  let instructions = info.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !instructions.isEmpty else { return nil }

            let name = info.serverName.isEmpty ? "MCP server" : info.serverName
            guard instructions.count <= Self.maxInstructionChars else {
                logger.warning("""
                    [MCP-INSTRUCTIONS] '\(name)' supplied \(instructions.count) chars of \
                    instructions — TRUNCATED to \(Self.maxInstructionChars). This text ships in \
                    every request's system prefix, so the rest would cost the context window on \
                    every turn.
                    """)
                return "**\(name)**\n\(instructions.prefix(Self.maxInstructionChars))\n… [truncated]"
            }
            return "**\(name)**\n\(instructions)"
        }
        return blocks.sorted().joined(separator: "\n\n")
    }

    /// Per-server ceiling on `instructions`. Generous for real guidance, bounded against a
    /// server that would rather own the whole system prompt.
    private static let maxInstructionChars = 4000

    /// Every resource the server exposes, following pagination to the end.
    func listResources(sourceId: UUID) async throws -> [MCP.Resource] {
        let session = try requireSession(sourceId)
        guard session.serverInfo?.supportsResources ?? true else {
            throw MCPManagerError.toolReportedFailure(
                tool: "list_resources",
                detail: "This server does not advertise the `resources` capability."
            )
        }
        if let cached = resourceCache[sourceId] { return cached }

        var all: [MCP.Resource] = []
        var cursor: String? = nil
        var page = 0
        repeat {
            let result = try await session.client.listResources(cursor: cursor)
            all.append(contentsOf: result.resources)
            page += 1
            if let next = result.nextCursor, next == cursor { break }
            cursor = result.nextCursor
            if cursor != nil && page >= Self.maxPages {
                logger.warning("[MCP-RESOURCES] Page cap hit for source \(sourceId); list truncated at \(all.count) — the agent will not see the rest.")
                break
            }
        } while cursor != nil

        resourceCache[sourceId] = all
        logger.info("[MCP-RESOURCES] Listed \(all.count) resource(s) for source \(sourceId) across \(page) page(s).")
        return all
    }

    /// Reads one resource by URI and renders its contents as text for the agent.
    func readResource(sourceId: UUID, uri: String) async throws -> String {
        let session = try requireSession(sourceId)
        let contents = try await session.client.readResource(uri: uri)
        let rendered = contents.map { content -> String in
            if let text = content.text, !text.isEmpty { return text }
            if content.blob != nil {
                return "[binary resource \(content.uri)\(content.mimeType.map { " (\($0))" } ?? "")]"
            }
            return "[empty resource \(content.uri)]"
        }.joined(separator: "\n")

        return Self.capped(rendered, label: "resource '\(uri)'")
    }

    // MARK: - Prompts (MCP `prompts/*`)

    func listPrompts(sourceId: UUID) async throws -> [MCP.Prompt] {
        let session = try requireSession(sourceId)
        guard session.serverInfo?.supportsPrompts ?? true else {
            throw MCPManagerError.toolReportedFailure(
                tool: "list_prompts",
                detail: "This server does not advertise the `prompts` capability."
            )
        }
        if let cached = promptCache[sourceId] { return cached }

        var all: [MCP.Prompt] = []
        var cursor: String? = nil
        var page = 0
        repeat {
            let result = try await session.client.listPrompts(cursor: cursor)
            all.append(contentsOf: result.prompts)
            page += 1
            if let next = result.nextCursor, next == cursor { break }
            cursor = result.nextCursor
            if cursor != nil && page >= Self.maxPages {
                logger.warning("[MCP-PROMPTS] Page cap hit for source \(sourceId); list truncated at \(all.count) — the agent will not see the rest.")
                break
            }
        } while cursor != nil

        promptCache[sourceId] = all
        logger.info("[MCP-PROMPTS] Listed \(all.count) prompt(s) for source \(sourceId) across \(page) page(s).")
        return all
    }

    /// Expands a server-authored prompt into text the agent can act on.
    func getPrompt(sourceId: UUID, name: String, arguments: [String: String]?) async throws -> String {
        let session = try requireSession(sourceId)
        let result = try await session.client.getPrompt(name: name, arguments: arguments)
        var lines: [String] = []
        if let description = result.description, !description.isEmpty {
            lines.append(description)
        }
        for message in result.messages {
            lines.append("[\(message.role.rawValue)] \(Self.renderPromptContent(message.content))")
        }
        return Self.capped(lines.joined(separator: "\n"), label: "prompt '\(name)'")
    }

    private static func renderPromptContent(_ content: Prompt.Message.Content) -> String {
        switch content {
        case .text(let text):
            return text
        case .image(let data, let mimeType):
            return "[image: \(mimeType), \(data.count) base64 chars]"
        case .audio(let data, let mimeType):
            return "[audio: \(mimeType), \(data.count) base64 chars]"
        case .resource(let resource, _, _):
            if let text = resource.text, !text.isEmpty { return text }
            return "[resource: \(resource.uri)\(resource.mimeType.map { " (\($0))" } ?? "")]"
        case .resourceLink(let uri, let name, let title, _, let mimeType, _):
            return "[resource link: \(title ?? name) — \(uri)\(mimeType.map { " (\($0))" } ?? "")]"
        @unknown default:
            return "[unsupported prompt content]"
        }
    }

    // MARK: - Shared helpers

    /// Runaway guard for every paginated `*/list` call — a server returning a
    /// non-advancing cursor would otherwise loop forever on the MainActor.
    private static let maxPages = 50

    private func requireSession(_ sourceId: UUID) throws -> MCPSession {
        guard let session = activeSessions[sourceId] else {
            throw MCPManagerError.connectionFailed(NSError(
                domain: "MCPClientService", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No active session."]
            ))
        }
        return session
    }

    /// Same ingress cap as tool output — this text reaches the model and the timeline.
    private static func capped(_ text: String, label: String) -> String {
        guard text.count > maxToolOutputChars else { return text }
        let dropped = text.count - maxToolOutputChars
        logger.warning("[MCP-CALL] \(label) is \(text.count) chars — TRUNCATED to \(maxToolOutputChars), \(dropped) dropped. The agent sees a loss marker.")
        return String(text.prefix(maxToolOutputChars)) + "\n… [truncated: \(dropped) more characters]"
    }

    /// Turns a raw connect failure into something the user can act on.
    ///
    /// The state string is what the Tool Library shows verbatim, and raw SDK text is often
    /// a dead end: a registry-added remote server that needs sign-in surfaces only
    /// "Internal error: Authentication required", which does not tell the user that the fix
    /// is to edit the server and pick an auth scheme. Registry entries carry no auth
    /// metadata at all, so this is the first point at which the requirement is knowable.
    ///
    /// - Parameter serverOutput: stderr from a child that is **still running**. Appended as
    ///   context rather than substituted for the error, because a live process means the
    ///   failure is in the protocol, not the launch — see the catch block in `performConnect`.
    private static func actionableConnectionMessage(
        for error: Error,
        config: ServerDefinition,
        serverOutput: String? = nil
    ) -> String {
        let base = Self.baseConnectionMessage(for: error, config: config)

        guard let serverOutput, !serverOutput.isEmpty else { return base }

        // Tail, not head: a server that logged for a while before failing has the useful
        // part at the end, and the whole buffer can be megabytes on a chatty server.
        let tail = serverOutput.count > maxStderrContextChars
            ? "…\n" + String(serverOutput.suffix(maxStderrContextChars))
            : serverOutput

        return """
            \(base)

            The server process was still running, so this is not a launch failure. Its most \
            recent output was:

            \(tail.trimmingCharacters(in: .whitespacesAndNewlines))
            """
    }

    /// How much of a live server's stderr to show alongside a connect failure. Enough for a
    /// stack trace or the last few log lines; bounded because this string is rendered in a
    /// popover and a chatty server's buffer is unbounded in principle.
    private static let maxStderrContextChars = 2_000

    private static func baseConnectionMessage(for error: Error, config: ServerDefinition) -> String {
        let raw = error.localizedDescription
        let lowered = raw.lowercased()

        let looksLikeAuth = lowered.contains("authentication required")
            || lowered.contains("unauthorized")
            || lowered.contains("401")
            || lowered.contains("invalid_token")

        if looksLikeAuth, config.url != nil {
            if case .none = config.auth {
                return """
                    \(raw)

                    This server requires sign-in, but no authentication is configured. \
                    Edit the server and choose an authentication method — most hosted MCP \
                    servers use OAuth.
                    """
            }
            return """
                \(raw)

                Authentication was rejected. The saved credential may have expired or been \
                revoked — edit the server and sign in again.
                """
        }

        return raw
    }

    /// Maps the SDK's `Initialize.Result` into the subset we act on.
    private static func makeServerInfo(from result: Initialize.Result) -> MCPServerInfo {
        let capabilities = result.capabilities
        return MCPServerInfo(
            protocolVersion: result.protocolVersion,
            serverName: result.serverInfo.name,
            serverVersion: result.serverInfo.version,
            instructions: result.instructions,
            supportsResources: capabilities.resources != nil,
            supportsResourceSubscribe: capabilities.resources?.subscribe ?? false,
            supportsResourceListChanged: capabilities.resources?.listChanged ?? false,
            supportsPrompts: capabilities.prompts != nil,
            supportsPromptListChanged: capabilities.prompts?.listChanged ?? false,
            supportsTools: capabilities.tools != nil,
            supportsLogging: capabilities.logging != nil
        )
    }

    /// Attaches the server→client request handlers (roots, sampling, elicitation).
    ///
    /// Without these the SDK answers every such request with `methodNotFound`, which is why
    /// filesystem-shaped servers got no workspace boundary and sampling-dependent servers
    /// could not function at all.
    /// Sampling and elicitation are reached through `MCPHostBridge` rather than their
    /// concrete brokers: both pull in the agent stack and the InteractionCenter, which is
    /// what kept this whole path untestable outside a running app. Roots stay direct —
    /// `MCPRootsProvider` is Foundation-only and has no host dependency to break.
    private func registerClientHandlers(on client: MCP.Client, sourceId: UUID, serverLabel: String) async {
        _ = await client
            .withRootsHandler {
                await MCPRootsProvider.currentRoots()
            }
            .withSamplingHandler { parameters in
                guard let handler = await MCPHostBridge.samplingHandler else {
                    logger.error("""
                        [MCP-SAMPLING] '\(serverLabel)' (source \(sourceId)) requested sampling but \
                        no host handler is installed — REFUSED. The server is told the host cannot \
                        service sampling; it will disable the feature or fail its own call. In the \
                        app this means the launch-time bridge install never ran.
                        """)
                    throw MCPError.internalError("Devgentic cannot service sampling requests right now.")
                }
                return try await handler.handle(
                    parameters: parameters, sourceID: sourceId, serverLabel: serverLabel
                )
            }
            .withElicitationHandler { parameters in
                guard let handler = await MCPHostBridge.elicitationHandler else {
                    logger.error("""
                        [MCP-ELICIT] '\(serverLabel)' (source \(sourceId)) asked the user a question \
                        but no host handler is installed — DECLINED rather than parked, since \
                        waiting would hang the server's call forever. In the app this means the \
                        launch-time bridge install never ran.
                        """)
                    return CreateElicitation.Result(action: .cancel, content: nil)
                }
                return try await handler.handle(
                    parameters: parameters, sourceID: sourceId, serverLabel: serverLabel
                )
            }
    }


    // MARK: - Private Helpers
    
    private func listTools(client: MCP.Client) async throws -> [ToolDefinition] {
        // `tools/list` is paginated. Reading only the first page silently truncated
        // every server that pages its tool list — the missing tools looked to the user
        // like the server simply did not offer them.
        //
        // The page cap is a runaway guard, not a product limit: a server that returns
        // a non-advancing cursor would otherwise loop here forever, on the MainActor.
        let maxPages = 50
        var mcpTools: [MCP.Tool] = []
        var cursor: String? = nil
        var page = 0

        repeat {
            let result = try await client.listTools(cursor: cursor)
            mcpTools.append(contentsOf: result.tools)
            page += 1

            // A server that echoes the same cursor back would spin forever.
            if let next = result.nextCursor, next == cursor {
                logger.warning("""
                    [MCP-TOOLS] Server repeated cursor '\(next)' on page \(page) — stopping pagination. \
                    Tool list may be incomplete (\(mcpTools.count) collected).
                    """)
                break
            }
            cursor = result.nextCursor

            if cursor != nil && page >= maxPages {
                logger.warning("""
                    [MCP-TOOLS] Hit the \(maxPages)-page cap with a cursor still pending — \
                    stopping. The agent will see only the first \(mcpTools.count) tool(s) \
                    from this server.
                    """)
                break
            }
        } while cursor != nil

        if page > 1 {
            logger.info("[MCP-TOOLS] Collected \(mcpTools.count) tool(s) across \(page) page(s).")
        }

        var undecodable: [String] = []

        let definitions: [ToolDefinition] = mcpTools.compactMap { mcpTool in
            guard let paramsData = try? JSONEncoder().encode(mcpTool.inputSchema),
                  let parameters = try? JSONDecoder().decode(ToolParameters.self, from: paramsData) else {
                // `ToolParameters` now decodes leniently, so reaching here means the
                // schema was not even a JSON object. Record the name so the caller can
                // say how many tools were lost instead of the list just being short.
                undecodable.append(mcpTool.name)
                return nil
            }

            // Map SDK icons → local ToolIcon structs
            let icons: [ToolIcon]? = mcpTool.icons?.map { sdkIcon in
                ToolIcon(
                    src: sdkIcon.src,
                    mimeType: sdkIcon.mimeType,
                    sizes: sdkIcon.sizes,
                    theme: sdkIcon.theme.flatMap { $0 == .light ? .light : .dark }
                )
            }

            // Map SDK annotations → local ToolAnnotations
            let annotations: ToolAnnotations? = {
                let a = mcpTool.annotations
                guard !a.isEmpty else { return nil }
                return ToolAnnotations(
                    destructiveHint: a.destructiveHint,
                    idempotentHint: a.idempotentHint,
                    openWorldHint: a.openWorldHint,
                    readOnlyHint: a.readOnlyHint
                )
            }()

            // Prefer annotations.title → top-level title → nil
            let displayTitle = mcpTool.annotations.title ?? mcpTool.title

            return ToolDefinition(
                name: mcpTool.name,
                description: mcpTool.description ?? "",
                category: "",
                parameters: parameters,
                title: displayTitle,
                icons: icons,
                annotations: annotations
            )
        }

        if !undecodable.isEmpty {
            logger.error("""
                [MCP-TOOLS] ⚠️ \(undecodable.count) of \(mcpTools.count) tool(s) had an \
                unreadable input schema and are NOT available to the agent — the server will \
                appear to be missing them: \(undecodable.joined(separator: ", ")).
                """)
        }

        return definitions
    }

    /// Monitors the health of a local process-based MCP session.
    /// If the process exits unexpectedly, invalidates the session and publishes an error state.
    /// Liveness for REMOTE sessions, which have no child process to watch.
    ///
    /// Without this a remote server showed `.connected` for the rest of the session no
    /// matter what happened to it — the endpoint could be down, the token revoked, the
    /// tunnel closed, and the UI still said green until the user tried a tool and got a
    /// failure with no warning. `ping` is the protocol's own cheap liveness check.
    private func startRemoteHealthMonitor(for sourceId: UUID) {
        healthMonitorTasks[sourceId]?.cancel()

        healthMonitorTasks[sourceId] = Task { [weak self] in
            while !Task.isCancelled {
                // 30s: frequent enough that a dead endpoint is noticed within a turn or two,
                // infrequent enough not to be traffic of note against a metered endpoint.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard let session = self.activeSessions[sourceId] else { return }

                do {
                    try await session.client.ping()
                    self.lastVerified[sourceId] = Date()
                    if case .error = self.connectionStates[sourceId] {
                        // Recovered on its own — say so rather than leaving a stale error.
                        self.connectionStates[sourceId] = .connected
                        logger.info("[MCP-HEALTH] Remote source \(sourceId) responded to ping again; state restored to connected.")
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.connectionStates[sourceId] = .error("Server stopped responding: \(error.localizedDescription)")
                    logger.warning("""
                        [MCP-HEALTH] Remote source \(sourceId) failed a liveness ping: \
                        \(error.localizedDescription). Marked as errored so the UI stops claiming \
                        it is connected; the next tool call will attempt a reconnect.
                        """)
                }
            }
        }
    }

    private func startHealthMonitor(for sourceId: UUID) {
        healthMonitorTasks[sourceId]?.cancel()

        healthMonitorTasks[sourceId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                guard !Task.isCancelled else { return }
                guard let self = self else { return }

                guard let session = self.activeSessions[sourceId],
                      let process = session.process else { return }

                if !process.process.isRunning {
                    let stderr = MCPRedaction.redact(text: process.readStdErr())
                    let exitCode = process.process.terminationStatus
                    self.connectionStates[sourceId] = .error(
                        stderr.isEmpty
                            ? "Process exited unexpectedly (code \(exitCode))"
                            : stderr
                    )

                    // Retire the session BEFORE the await. `client.disconnect()` is async and,
                    // against a dead transport, is exactly the call that can take a while — and
                    // for as long as it did, `activeSessions` still held a session the monitor
                    // had already declared dead. `executeTool` and `requireSession` look the
                    // caller up there, so a tool call landing in that window was dispatched into
                    // a corpse and failed with a transport error instead of the actionable
                    // "server exited" state the UI was already showing.
                    self.activeSessions.removeValue(forKey: sourceId)
                    self.healthMonitorTasks.removeValue(forKey: sourceId)

                    // Tear the SDK client down too. Dropping the session without this
                    // leaked the `MCP.Client` and left its message loop running against a
                    // dead transport for the rest of the app's lifetime.
                    await session.client.disconnect()
                    logger.error("""
                        [MCP-HEALTH] Server process for source \(sourceId) exited unexpectedly \
                        (code \(exitCode)) — session torn down and client disconnected. Every tool \
                        from this server is now unavailable until the next call triggers a \
                        reconnect. Stderr: \(stderr.isEmpty ? "<none>" : stderr)
                        """)
                    return
                }
            }
        }
    }
    
    private func setupLocalTransport(
        config: ServerDefinition,
        secrets: MCPRuntimeSecrets
    ) throws -> (any Transport, ShellProcess) {
        guard let command = config.command else {
            throw MCPManagerError.invalidJSONConfiguration("Missing command.")
        }

        let shell = try ShellProcess(
            command: command,
            arguments: config.args ?? [],
            environment: secrets.env  // env values come from Keychain via secrets bundle
        )

        try shell.run()

        let transport = StdioTransport(
            input: .init(rawValue: shell.stdOutPipe.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: shell.stdInPipe.fileHandleForWriting.fileDescriptor)
        )

        return (transport, shell)
    }

    private func setupRemoteTransport(
        urlString: String,
        config: ServerDefinition,
        secrets: MCPRuntimeSecrets
    ) throws -> any Transport {
        guard let url = URL(string: urlString) else {
            throw MCPManagerError.invalidJSONConfiguration("Invalid URL.")
        }

        // HTTPS enforcement: when the user has configured *any* auth scheme,
        // refuse to send credentials in cleartext over plain HTTP. Localhost
        // is allowed because OAuth 2.1 (RFC 8252) explicitly permits it for
        // loopback flows during development.
        if config.auth != .none {
            let scheme = url.scheme?.lowercased() ?? ""
            let isHTTPS = scheme == "https" || scheme == "wss"
            let isLoopback = url.host.map { $0 == "localhost" || $0 == "127.0.0.1" || $0 == "::1" } ?? false
            if !isHTTPS && !isLoopback {
                throw MCPManagerError.invalidJSONConfiguration(
                    "Refusing to send credentials over plaintext '\(scheme)://'. Use https:// (or localhost for development)."
                )
            }
        }

        let header = secrets.authorizationHeader

        // `streaming` decides whether the transport opens the SSE GET stream. It was
        // hard-wired on, which is right for the Streamable HTTP standard but left no
        // recourse for a server that only implements POST — those simply failed to connect.
        let isStreaming = config.transport == .streamableHTTP
        logger.info("""
            [MCP-TRANSPORT] Remote transport for \(MCPRedaction.redact(url: urlString)): \
            \(config.transport.rawValue)\(isStreaming ? "" : " — server-initiated features (list_changed, server logs, sampling, elicitation) will NOT be delivered").
            """)

        return HTTPClientTransport(
            endpoint: url,
            streaming: isStreaming,
            requestModifier: { req in
                var r = req
                if let header {
                    r.addValue(header.value, forHTTPHeaderField: header.name)
                }
                return r
            }
        )
    }
    
    /// Bounds `operation` in WALL-CLOCK time, even when the operation ignores cancellation.
    ///
    /// The previous implementation used `withThrowingTaskGroup` and looked correct, but
    /// could not actually time anything out: a task group awaits ALL of its children
    /// before the scope returns, so `cancelAll()` on a child blocked in a non-cancellable
    /// read leaves the whole `withThrowingTaskGroup` hanging — the timeout branch wins the
    /// race and then waits forever for the loser it just cancelled. `connect` never
    /// returned, the Test Connection spinner span the rest of the session, and the caller
    /// had no way out.
    ///
    /// Racing two *unstructured* tasks through a continuation fixes that: whichever
    /// settles first resumes the caller, and a stuck loser drains in the background
    /// instead of pinning the caller to it. The loser is cancelled best-effort; for the
    /// local-process case `performConnect`'s `catch` also terminates the child, which is
    /// what actually unblocks a wedged stdio read.
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = SettleOnce<T>()

        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do { box.settle(.success(try await operation()), with: continuation) }
                catch { box.settle(.failure(error), with: continuation) }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                let didTimeOut = box.settle(
                    .failure(MCPManagerError.connectionTimedOut(seconds)),
                    with: continuation
                )
                if didTimeOut {
                    // Best effort — a non-cancellable operation will ignore this, which is
                    // precisely why we no longer wait for it.
                    work.cancel()
                    logger.error("""
                        [MCP-CONNECT] Operation exceeded its \(seconds)s budget and was abandoned. \
                        If the underlying handshake is not cancellable it is still draining in the \
                        background; the child process is terminated by the caller's error path.
                        """)
                }
            }
        }
    }
}

/// One-shot resolver for a `CheckedContinuation` raced between two tasks.
/// Resuming a checked continuation twice is a runtime trap, so the first settle wins
/// and every later one is dropped.
private final class SettleOnce<T: Sendable>: @unchecked Sendable {
    private var settled = false
    private let lock = NSLock()

    /// - Returns: `true` if this call is the one that resumed the continuation.
    @discardableResult
    func settle(_ result: Result<T, Error>, with continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if settled {
            lock.unlock()
            return false
        }
        settled = true
        lock.unlock()

        continuation.resume(with: result)
        return true
    }
}
