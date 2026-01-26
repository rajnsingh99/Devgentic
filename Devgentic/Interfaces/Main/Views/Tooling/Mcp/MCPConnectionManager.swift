//
//  MCPConnectionManager.swift
//  Devgentic
//
//  Created by Raj Singh on 28/09/25.
//
//  Updated on 17/10/25 to support both remote and local connections.
//  Fixed on 19/10/25 to safely unwrap the optional command property.
//

import Foundation
import MCP
import os
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif


private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MCPConnectionManager")

@MainActor
class MCPConnectionManager {
    
    static let shared = MCPConnectionManager()
    
    private var activeConnections: [UUID: (client: MCP.Client, process: Process?)] = [:]
    
    private init() {}

    func execute(toolName: String, arguments: [String: Any], source: ToolSource) async -> String {
        logger.info("--- executing mcp tool ---")
        logger.info("Tool: '\(toolName)' on source '\(source.serverName)'")
        logger.info("Arguments: \(String(describing: arguments))")
        
        do {
            let client = try await getConnection(for: source)
            
            logger.info("-> Connection established. Converting arguments to MCP.Value.")
            let argumentsData = try JSONSerialization.data(withJSONObject: arguments)
            let decoder = JSONDecoder()
            let mcpArguments = try decoder.decode([String: MCP.Value].self, from: argumentsData)

            logger.info("-> Calling remote tool via MCP.")
            let result = try await client.callTool(name: toolName, arguments: mcpArguments)
            
            let resultParts = result.content.map { contentPart -> String in
                switch contentPart {
                case .text(let text):
                    return text
                @unknown default:
                    return "Unsupported tool content type received."
                }
            }
            
            let finalResult = resultParts.joined(separator: "\n")
            logger.info("-> MCP tool execution successful.")
            return finalResult
            
        } catch {
            let errorMsg = "Error executing MCP tool '\(toolName)': \(error.localizedDescription)"
            logger.error("\(errorMsg)")
            return errorMsg
        }
    }
    
    private func getConnection(for source: ToolSource) async throws -> MCP.Client {
        if let existingConnection = activeConnections[source.id] {
            logger.info("Found cached connection for '\(source.serverName)'. Reusing.")
            return existingConnection.client
        }
        
        logger.info("No cached connection found for '\(source.serverName)'. Creating a new one.")
        guard let serverDef = source.serverDefinition else {
            throw MCPManagerError.invalidJSONConfiguration("Server definition missing for MCP tool source.")
        }
        
        let transport: any Transport
        var process: Process? = nil

        if let urlString = serverDef.url {
            transport = try self.setupRemoteTransport(urlString: urlString, config: serverDef)
        } else {
            let (localTransport, localProcess) = try await self.setupProcessTransport(config: serverDef)
            transport = localTransport
            process = localProcess
        }
        
        let client = MCP.Client(name: "DevgenticAppClient", version: "1.0.0")
        try await client.connect(transport: transport)
        
        activeConnections[source.id] = (client, process)
        logger.info("-> Successfully connected to and cached new connection for '\(source.serverName)'.")
        
        return client
    }

    private func setupRemoteTransport(urlString: String, config: ServerDefinition) throws -> any Transport {
        guard let url = URL(string: urlString) else {
            throw MCPManagerError.invalidJSONConfiguration("The provided server URL is not valid: \(urlString)")
        }
        let transport = HTTPClientTransport(endpoint: url, requestModifier: { request in
            var modifiedRequest = request
            if let authToken = config.authentication?["token"] {
                modifiedRequest.addValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            return modifiedRequest
        })
        return transport
    }
    
    private func setupProcessTransport(config: ServerDefinition) async throws -> (transport: any Transport, process: Process) {
        guard let command = config.command else {
            throw MCPManagerError.invalidJSONConfiguration("Process-based server is missing the 'command' field.")
        }
        let commandPath = try findExecutable(named: command)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: commandPath)
        process.arguments = config.args ?? []

        let shellPath = getShellPath()
        let shellEnvironment = try await getShellEnvironment(shellPath: shellPath)
        process.environment = shellEnvironment.merging(config.env ?? [:]) { (_, new) in new }
        
        logger.info("-> Launching process: \(commandPath) with args: \(process.arguments ?? [])")

        let stdInPipe = Pipe(), stdOutPipe = Pipe()
        process.standardInput = stdInPipe
        process.standardOutput = stdOutPipe
        
        try process.run()
        
        let transport = StdioTransport(
            input: .init(rawValue: stdOutPipe.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: stdInPipe.fileHandleForWriting.fileDescriptor)
        )
        
        return (transport, process)
    }
    
    private func findExecutable(named command: String) throws -> String {
        if command.starts(with: "/") || command.starts(with: ".") { return command }
        let shellPath = getShellPath()
        do {
            return try shell(shellPath, "command", "-v", command)
        } catch {
            throw MCPManagerError.commandNotFound(command)
        }
    }

    private func getShellPath() -> String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }
    
    private func getShellEnvironment(shellPath: String) async throws -> [String: String] {
        let output = try shell(shellPath, "env")
        var environment = [String: String]()
        output.split(separator: "\n").forEach { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { environment[String(parts[0])] = String(parts[1]) }
        }
        return environment
    }
    
    @discardableResult
    private func shell(_ shellPath: String, _ args: String...) throws -> String {
        let process = Process()
        process.launchPath = shellPath
        let command = args.joined(separator: " ")
        process.arguments = ["-c", command]
        
        let stdOutPipe = Pipe(), stdErrPipe = Pipe()
        process.standardOutput = stdOutPipe
        process.standardError = stdErrPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = stdErrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logger.error("""
            Shell command failed:
            - Command: \(command)
            - Exit Code: \(process.terminationStatus)
            - Stderr: \(errorOutput)
            """)
            throw MCPManagerError.shellCommandFailed(command: args.joined(separator: " "), output: errorOutput)
        }
        
        let outputData = stdOutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
