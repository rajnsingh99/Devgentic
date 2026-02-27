//
//  MCPClientService.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//

import Foundation
import MCP
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "MCPClientService")

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

/// Represents an active connection to an MCP server.
struct MCPSession {
    let id: UUID
    let client: MCP.Client
    let transport: any Transport
    let process: ShellProcess?
}

@MainActor
class MCPClientService: ObservableObject {

    static let shared = MCPClientService()

    @Published private(set) var activeSessions: [UUID: MCPSession] = [:]
    @Published var connectionStates: [UUID: MCPConnectionState] = [:]

    /// Tracks health monitor tasks so they can be cancelled on disconnect.
    private var healthMonitorTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}
    
    // MARK: - Connection Methods
    
    func connect(sourceId: UUID, config: ServerDefinition) async throws -> (client: MCP.Client, tools: [ToolDefinition]) {
        // 1. Cleanup existing session
        if activeSessions[sourceId] != nil {
            logger.info("Disconnecting existing session for source \(sourceId)")
            await disconnect(sourceId: sourceId)
        }

        connectionStates[sourceId] = .connecting

        logger.info("Initializing new MCP Client for source \(sourceId)")
        let client = MCP.Client(name: "DevgenticClientV2", version: "2.0.0")

        let transport: any Transport
        var shellProcess: ShellProcess? = nil

        do {
            // 2. Transport Setup
            if let urlString = config.url {
                transport = try setupRemoteTransport(urlString: urlString, config: config)
                logger.info("Transport type: Remote (\(urlString))")
            } else if let command = config.command {
                logger.info("Transport type: Local Process (\(command))")
                let (localTransport, process) = try setupLocalTransport(config: config)
                transport = localTransport
                shellProcess = process

                // 2a. FAIL FAST CHECK
                try await Task.sleep(nanoseconds: 500_000_000)

                if !process.process.isRunning {
                    let stderr = process.readStdErr()
                    throw MCPManagerError.processFailedToStart(
                        stderr.isEmpty ? "Process exited immediately with code \(process.process.terminationStatus)." : stderr
                    )
                }
            } else {
                throw MCPManagerError.invalidJSONConfiguration("Server definition missing 'command' or 'url'.")
            }

            logger.info("Transport setup complete. Attempting SDK handshake (Timeout: 15s)...")

            // 3. Connect via SDK with Timeout
            try await withTimeout(seconds: 15) {
                try await client.connect(transport: transport)
            }

            logger.info("SDK handshake successful. Storing session.")

            // 4. Store Session
            let session = MCPSession(id: sourceId, client: client, transport: transport, process: shellProcess)
            activeSessions[sourceId] = session
            connectionStates[sourceId] = .connected

            // 5. Start health monitoring for local processes
            if shellProcess != nil {
                startHealthMonitor(for: sourceId)
            }

            // 6. Tool Discovery
            logger.info("Fetching tools...")
            let tools = try await listTools(client: client)
            logger.info("Successfully discovered \(tools.count) tools.")

            return (client, tools)

        } catch {
            logger.error("Connection failed for source \(sourceId): \(error.localizedDescription)")

            var finalError = error

            if let shell = shellProcess {
                let stderr = shell.readStdErr()
                if !stderr.isEmpty {
                    logger.error("Last captured Stderr: \(stderr)")
                    finalError = MCPManagerError.processFailedToStart(stderr)
                }
                shell.terminate()
            }

            connectionStates[sourceId] = .error(finalError.localizedDescription)
            throw finalError
        }
    }
    
    func disconnect(sourceId: UUID) async {
        healthMonitorTasks[sourceId]?.cancel()
        healthMonitorTasks.removeValue(forKey: sourceId)

        guard let session = activeSessions[sourceId] else { return }
        await session.client.disconnect()
        session.process?.terminate()
        activeSessions.removeValue(forKey: sourceId)
        connectionStates[sourceId] = .disconnected
        logger.info("Disconnected session \(sourceId). Process terminated.")
    }
    
    func disconnectAll() async {
        for id in activeSessions.keys {
            await disconnect(sourceId: id)
        }
    }
    
    // MARK: - Tool Execution
    
    func executeTool(sourceId: UUID, name: String, arguments: [String: Any]) async throws -> String {
        guard let session = activeSessions[sourceId] else {
            throw MCPManagerError.connectionFailed(NSError(domain: "MCPClientService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active session."]))
        }
        
        logger.info("Executing tool '\(name)'")
        
        let argsData = try JSONSerialization.data(withJSONObject: arguments)
        let decoder = JSONDecoder()
        let mcpArgs = try decoder.decode([String: MCP.Value].self, from: argsData)
        
        let result = try await session.client.callTool(name: name, arguments: mcpArgs)
        
        return result.content.map { contentPart -> String in
            switch contentPart {
            case .text(let text): return text
            case .image(_, _, _): return "[Image Output]"
            case .resource(_): return "[Resource Output]"
            @unknown default: return "[Unknown Output]"
            }
        }.joined(separator: "\n")
    }
    
    // MARK: - Private Helpers
    
    private func listTools(client: MCP.Client) async throws -> [ToolDefinition] {
        let result = try await client.listTools()
        return result.tools.compactMap { mcpTool in
            guard let paramsData = try? JSONEncoder().encode(mcpTool.inputSchema),
                  let parameters = try? JSONDecoder().decode(ToolParameters.self, from: paramsData) else {
                logger.warning("Failed to decode parameters for tool: \(mcpTool.name)")
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
                parameters: parameters,
                title: displayTitle,
                icons: icons,
                annotations: annotations
            )
        }
    }

    /// Monitors the health of a local process-based MCP session.
    /// If the process exits unexpectedly, invalidates the session and publishes an error state.
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
                    let stderr = process.readStdErr()
                    self.connectionStates[sourceId] = .error(
                        stderr.isEmpty
                            ? "Process exited unexpectedly (code \(process.process.terminationStatus))"
                            : stderr
                    )
                    self.activeSessions.removeValue(forKey: sourceId)
                    self.healthMonitorTasks.removeValue(forKey: sourceId)
                    logger.warning("Health monitor: process for \(sourceId) exited unexpectedly.")
                    return
                }
            }
        }
    }
    
    private func setupLocalTransport(config: ServerDefinition) throws -> (any Transport, ShellProcess) {
        guard let command = config.command else { throw MCPManagerError.invalidJSONConfiguration("Missing command.") }
        
        let shell = try ShellProcess(
            command: command,
            arguments: config.args ?? [],
            environment: config.env ?? [:]
        )
        
        try shell.run()
        
        let transport = StdioTransport(
            input: .init(rawValue: shell.stdOutPipe.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: shell.stdInPipe.fileHandleForWriting.fileDescriptor)
        )
        
        return (transport, shell)
    }
    
    private func setupRemoteTransport(urlString: String, config: ServerDefinition) throws -> any Transport {
        guard let url = URL(string: urlString) else { throw MCPManagerError.invalidJSONConfiguration("Invalid URL.") }
        return HTTPClientTransport(endpoint: url, requestModifier: { req in
            var r = req
            if let token = config.authentication?["token"] {
                r.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return r
        })
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MCPManagerError.connectionTimedOut(seconds)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
