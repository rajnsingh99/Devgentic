//
//  MCPManager.swift
//  Devgentic
//
//  Created by Raj Singh on 27/09/25.
//

import SwiftUI
import MCP
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

// MARK: - Custom Error Type

// Provides detailed, user-friendly error descriptions for different failure scenarios.
enum MCPManagerError: LocalizedError {
    case invalidJSONConfiguration(String)
    case noServersDefined
    case commandNotFound(String)
    case shellCommandFailed(command: String, output: String)
    case connectionTimedOut(TimeInterval)
    case connectionFailed(Error)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidJSONConfiguration(let details):
            return "The provided JSON is not valid. Details: \(details)"
        case .noServersDefined:
            return "No servers are defined in the JSON configuration."
        case .commandNotFound(let command):
            return "Command '\(command)' not found in your system's PATH. Please ensure it is installed or provide the absolute path to the executable."
        case .shellCommandFailed(let command, let output):
            return "A shell command failed.\nCommand: \(command)\nOutput: \(output)"
        case .connectionTimedOut(let seconds):
            return "Connection timed out after \(seconds) seconds. The server might not be running or is unreachable."
        case .connectionFailed(let underlyingError):
            return "Failed to connect to the server. Details: \(underlyingError.localizedDescription)"
        case .unknown:
            return "An unexpected error occurred."
        }
    }
}


// MARK: - Data Models (Standardized)

// New top-level configuration structure that holds a dictionary of server definitions.
struct MCPConfiguration: Decodable {
    let mcpServers: [String: ServerDefinition]
}

// Unified server definition that works for any process-based server (stdio, docker, etc.).
struct ServerDefinition: Codable, Hashable {
    let command: String
    let args: [String]?
    let env: [String: String]?
}

// Model to hold the result of a successful connection, making it ready for the library.
struct SuccessfulToolResult {
    let serverName: String
    let serverDefinition: ServerDefinition
    let tools: [ToolDefinition] // List of tools provided by the server
}


// MARK: - MCPManager Class

@MainActor
class MCPManager: ObservableObject {
    @Published var activeServer: (name: String, config: ServerDefinition)? = nil
    @Published var statusMessage: (text: String, isError: Bool)? = nil
    
    // RENAMED/REPURPOSED: Holds the result of a successful connection (server config + tool details).
    @Published var successfulConnectionResult: SuccessfulToolResult? = nil
    
    @Published var availableTools: [ToolDefinition] = [] // Updated to hold detailed tool info.
    @Published var isConnecting: Bool = false
    
    private var mcpClient: MCP.Client?
    private var activeProcess: Process?

    func configureAndConnect(jsonString: String) {
        Task {
            // Disconnect first if already connected, and reset the successful result
            await disconnect()

            self.isConnecting = true
            self.statusMessage = (text: "Connecting...", isError: false)
            
            do {
                guard let data = jsonString.data(using: .utf8) else {
                    throw MCPManagerError.invalidJSONConfiguration("Could not encode string to data.")
                }
                
                let config = try JSONDecoder().decode(MCPConfiguration.self, from: data)
                
                guard let firstServer = config.mcpServers.first else {
                    throw MCPManagerError.noServersDefined
                }
                
                let serverName = firstServer.key
                let serverDefinition = firstServer.value
                
                let newServer = (name: serverName, config: serverDefinition)
                self.activeServer = newServer
                
                self.statusMessage = (text: "Connecting to \(newServer.name)...", isError: false)
                
                await connectAndFetchTools(server: newServer)
                
            } catch {
                handle(error: error)
            }
            
            self.isConnecting = false
        }
    }

    func disconnect() async {
        await mcpClient?.disconnect()
        activeProcess?.terminate()
        activeProcess = nil
        mcpClient = nil
        activeServer = nil
        availableTools = []
        successfulConnectionResult = nil // IMPORTANT: Clear the result on disconnect
        isConnecting = false
        if statusMessage?.text != "Disconnected." {
             statusMessage = (text: "Disconnected.", isError: false)
        }
    }

    private func connectAndFetchTools(server: (name: String, config: ServerDefinition)) async {
        do {
            try await withTimeout(seconds: 30.0) {
                let client = MCP.Client(name: "MCPDemoApp", version: "1.0.0")
                self.mcpClient = client
                
                let transport = try await self.setupProcessTransport(config: server.config)
                
                try await client.connect(transport: transport)
                
                let result = try await client.listTools()
                
                await MainActor.run {
                    // Extract both name and description for each tool
                    let tools = result.tools.map { ToolDefinition(name: $0.name, description: $0.description ?? "No description available.") }
                    
                    // Populate the new result property for the library view to use
                    self.successfulConnectionResult = SuccessfulToolResult(
                        serverName: server.name,
                        serverDefinition: server.config,
                        tools: tools
                    )
                    
                    self.availableTools = tools
                    self.statusMessage = (text: "Successfully connected and fetched \(tools.count) tools from \(server.name). Ready to add to library.", isError: false)
                }
            }
        } catch {
            handle(error: error)
        }
    }
    
    private func handle(error: Error) {
        let managerError: MCPManagerError
        if let error = error as? MCPManagerError {
            managerError = error
        } else if let decodingError = error as? DecodingError {
            managerError = .invalidJSONConfiguration(decodingError.localizedDescription)
        } else {
            managerError = .connectionFailed(error)
        }
        
        // Ensure successfulConnectionResult is cleared on error
        self.successfulConnectionResult = nil
        self.statusMessage = (text: "Error: \(managerError.localizedDescription)", isError: true)
        self.activeServer = nil
        self.availableTools = []
    }

    private func setupProcessTransport(config: ServerDefinition) async throws -> any Transport {
        let commandPath = try findExecutable(named: config.command)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: commandPath)
        process.arguments = config.args ?? []

        let shellPath = getShellPath()
        let shellEnvironment = try await getShellEnvironment(shellPath: shellPath)
        // Merge the provided environment variables, overwriting any shell variables with the same name.
        process.environment = shellEnvironment.merging(config.env ?? [:]) { (_, new) in new }

        let stdInPipe = Pipe(), stdOutPipe = Pipe()
        process.standardInput = stdInPipe
        process.standardOutput = stdOutPipe
        
        try process.run()
        self.activeProcess = process
        
        return StdioTransport(
            input: .init(rawValue: stdOutPipe.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: stdInPipe.fileHandleForWriting.fileDescriptor)
        )
    }
    
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { return try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MCPManagerError.connectionTimedOut(seconds)
            }
            guard let result = try await group.next() else { throw MCPManagerError.unknown }
            group.cancelAll()
            return result
        }
    }
    
    private func findExecutable(named command: String) throws -> String {
        // If it's already a full path, just return it.
        if command.starts(with: "/") || command.starts(with: ".") { return command }
        
        let shellPath = getShellPath()
        do {
            // Using "command -v" is a reliable POSIX-compliant way to find an executable's path.
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
        
        // --- SMART PATH RESOLUTION ---
        // Prepend common binary locations for tools like Homebrew to the PATH.
        // This allows the app to find commands like 'python' or 'docker' without
        // the user needing to provide the full absolute path.
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
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown shell error"
            throw MCPManagerError.shellCommandFailed(command: args.joined(separator: " "), output: errorOutput)
        }
        
        let outputData = stdOutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
