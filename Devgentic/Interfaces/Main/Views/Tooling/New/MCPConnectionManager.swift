//
//  MCPConnectionManager.swift
//  Devgentic
//
//  Created by Raj Singh on 28/09/25.
//

import Foundation
import MCP
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

/// A singleton manager responsible for the on-demand lifecycle of MCP tool servers.
///
/// This class acts as a connection pool. It launches, connects to, and caches connections
/// to external MCP server processes only when a tool from that server is requested for
/// execution. It ensures that system resources are used efficiently by only running
/// processes that are actively needed.
@MainActor
class MCPConnectionManager {
    
    /// The shared singleton instance.
    static let shared = MCPConnectionManager()
    
    /// A cache to hold live connections. The key is the ToolSource's unique ID,
    /// and the value is a tuple containing the active MCP client and its running process.
    private var activeConnections: [UUID: (client: MCP.Client, process: Process)] = [:]
    
    /// Private initializer to enforce singleton pattern.
    private init() {}

    /// The main public entry point for executing an MCP tool.
    /// - Parameters:
    ///   - toolName: The name of the tool to execute.
    ///   - arguments: The arguments for the tool.
    ///   - source: The `ToolSource` that provides this tool.
    /// - Returns: A string containing the result of the tool's execution or an error message.
    func execute(toolName: String, arguments: [String: Any], source: ToolSource) async -> String {
        do {
            // Step 1: Get a live connection, either from cache or by launching a new process.
            let client = try await getConnection(for: source)
            
            // Step 2: Convert arguments from [String: Any] to [String: MCP.Value] via JSON.
            let argumentsData = try JSONSerialization.data(withJSONObject: arguments)
            let decoder = JSONDecoder()
            let mcpArguments = try decoder.decode([String: MCP.Value].self, from: argumentsData)

            // Step 3: Execute the tool using the 'callTool' method.
            let result = try await client.callTool(name: toolName, arguments: mcpArguments)
            
            // Step 4: Process the [Tool.Content] array from the result into a single readable string.
            let resultParts = result.content.map { contentPart -> String in
                // Handle the content based on the available cases in your SDK version.
                switch contentPart {
                case .text(let text):
                    return text
                @unknown default:
                    // This handles any future cases that might be added to the SDK
                    // and prevents compiler errors if the enum is non-exhaustive.
                    return "Unsupported tool content type received."
                }
            }
            
            // Join multiple content parts with newlines.
            return resultParts.joined(separator: "\n")
            
        } catch {
            return "Error executing MCP tool '\(toolName)': \(error.localizedDescription)"
        }
    }
    
    /// Retrieves a live MCP client for a given tool source, creating one if it doesn't exist.
    private func getConnection(for source: ToolSource) async throws -> MCP.Client {
        // If a connection is already cached, return it.
        if let existingConnection = activeConnections[source.id] {
            return existingConnection.client
        }
        
        // Ensure the source has a server definition to launch.
        guard let serverDef = source.serverDefinition else {
            // This is a logic error if we get here for an MCP tool.
            throw MCPManagerError.invalidJSONConfiguration("Server definition missing for MCP tool source.")
        }
        
        // --- LAUNCH AND CONNECT ---
        let commandPath = try findExecutable(named: serverDef.command)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: commandPath)
        process.arguments = serverDef.args ?? []

        let shellPath = getShellPath()
        let shellEnvironment = try await getShellEnvironment(shellPath: shellPath)
        process.environment = shellEnvironment.merging(serverDef.env ?? [:]) { (_, new) in new }

        let stdInPipe = Pipe(), stdOutPipe = Pipe()
        process.standardInput = stdInPipe
        process.standardOutput = stdOutPipe
        
        try process.run()
        
        let transport = StdioTransport(
            input: .init(rawValue: stdOutPipe.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: stdInPipe.fileHandleForWriting.fileDescriptor)
        )
        
        let client = MCP.Client(name: "DevgenticAppClient", version: "1.0.0")
        try await client.connect(transport: transport)
        
        // Cache the new connection and process for future use.
        activeConnections[source.id] = (client, process)
        
        print("MCPConnectionManager: Activated and cached new connection for \(source.serverName).")
        
        return client
    }
    
    // MARK: - Process & Shell Helpers (Adapted from MCPManager)
    
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
        let richPath = "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH;"
        let command = richPath + " " + args.joined(separator: " ")
        process.arguments = ["-c", command]
        
        let stdOutPipe = Pipe(), stdErrPipe = Pipe()
        process.standardOutput = stdOutPipe
        process.standardError = stdErrPipe
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            let errorData = stdErrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MCPManagerError.shellCommandFailed(command: args.joined(separator: " "), output: errorOutput)
        }
        
        let outputData = stdOutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

