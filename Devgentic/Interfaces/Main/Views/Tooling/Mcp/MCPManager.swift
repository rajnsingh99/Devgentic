//
//  MCPManager.swift
//  Devgentic
//
//  Created by Raj Singh on 27/09/25.
//
//  Refactored on 11/10/25 to consistently use ToolDefinition for tool discovery.
//  Fixed on 11/10/25 to resolve type ambiguity with MCP.Tool.
//  Final Fix on 11/10/25 to use the correct 'inputSchema' property.
//  Updated on 17/10/25 to support remote servers and correct authentication flow.
//  Fixed on 20/10/25 to use the user's full shell PATH for command discovery.
//  Final Fix on 20/10/25 to add logging and correct the shell environment for command lookups.
//  Updated on 20/10/25 to add a smart command resolver for different executable types.
//  Final Fix on 20/10/25 to use 'which' for resolving uvx path.
//  Final Fix on 20/10/25 to force a login shell to load the user's full PATH.
//  Final Fix on 20/10/25 by surgically extracting and injecting the login shell's PATH.
//  Definitive Fix on 20/10/25 to implement self-sufficient, in-app path resolution.
//  Final Fix on 20/10/25 to add termination handling for immediate process error reporting.
//  REVISED on 21/10/25 to properly source shell environment for subprocesses.
//

import SwiftUI
import MCP
import os
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

// Add a dedicated logger for this manager.
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MCPManager")


// MARK: - Custom Error Type

// Provides detailed, user-friendly error descriptions for different failure scenarios.
enum MCPManagerError: LocalizedError {
    case invalidJSONConfiguration(String)
    case noServersDefined
    case commandNotFound(String)
    case shellCommandFailed(command: String, output: String)
    case connectionTimedOut(TimeInterval)
    case connectionFailed(Error)
    case authenticationFailed(String)
    case processFailedToStart(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidJSONConfiguration(let details):
            return "The provided JSON is not valid. Details: \(details)"
        case .noServersDefined:
            return "No servers are defined in the JSON configuration."
        case .commandNotFound(let command):
            return "Command '\(command)' could not be found in any standard locations. Please ensure it is installed or provide the absolute path to the executable."
        case .shellCommandFailed(let command, let output):
            return "A shell command failed.\nCommand: \(command)\nOutput: \(output)"
        case .connectionTimedOut(let seconds):
            return "Connection timed out after \(seconds) seconds. The server might not be running or is unreachable."
        case .connectionFailed(let underlyingError):
            return "Failed to connect to the server. Details: \(underlyingError.localizedDescription)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .processFailedToStart(let details):
            return "The server process failed to start. Details:\n\(details)"
        case .unknown:
            return "An unexpected error occurred."
        }
    }
}


// MARK: - Data Models (Standardized)

struct SuccessfulToolResult {
    let serverName: String
    let serverDefinition: ServerDefinition
    let tools: [ToolDefinition]
}


// MARK: - MCPManager Class

@MainActor
class MCPManager: ObservableObject {
    @Published var activeServer: (name: String, config: ServerDefinition)? = nil
    @Published var statusMessage: (text: String, isError: Bool)? = nil
    @Published var successfulConnectionResult: SuccessfulToolResult? = nil

    @Published var availableTools: [ToolDefinition] = []
    
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
        successfulConnectionResult = nil
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
                
                let transport: any Transport
                if let urlString = server.config.url {
                    transport = try self.setupRemoteTransport(urlString: urlString, config: server.config)
                } else if let _ = server.config.command {
                    transport = try await self.setupProcessTransport(config: server.config)
                } else {
                    throw MCPManagerError.invalidJSONConfiguration("Server definition must include either a 'command' or a 'url'.")
                }
                
                try await client.connect(transport: transport)
                                
                self.statusMessage = (text: "Fetching tools from server...", isError: false)
                let result = try await client.listTools()
                
                await MainActor.run {
                    let tools: [ToolDefinition] = result.tools.compactMap { (mcpTool: MCP.Tool) -> ToolDefinition? in
                        do {
                            let paramsData = try JSONEncoder().encode(mcpTool.inputSchema)
                            let decodedParameters = try JSONDecoder().decode(ToolParameters.self, from: paramsData)
                            
                            return ToolDefinition(
                                name: mcpTool.name,
                                description: mcpTool.description ?? "No description available.",
                                parameters: decodedParameters
                            )
                        } catch {
                            logger.warning("Error decoding parameters for tool '\(mcpTool.name)': \(error)")
                            return nil
                        }
                    }
                    
                    self.successfulConnectionResult = SuccessfulToolResult(
                        serverName: server.name,
                        serverDefinition: server.config,
                        tools: tools
                    )
                    
                    self.availableTools = tools
                    self.statusMessage = (text: "Successfully connected and fetched \(tools.count) tools from \(server.name).", isError: false)
                }
            }
        } catch {
            handle(error: error)
        }
    }
    
    private func handle(error: Error) {
        let managerError: MCPManagerError
        if let mcpError = error as? MCPError {
            // Check for authentication failures indicated by the transport layer.
            if mcpError.localizedDescription.contains("Authentication required") {
                managerError = .authenticationFailed("Invalid credentials provided.")
            } else {
                managerError = .connectionFailed(mcpError)
            }
        } else if let error = error as? MCPManagerError {
            managerError = error
        } else if let decodingError = error as? DecodingError {
            managerError = .invalidJSONConfiguration(decodingError.localizedDescription)
        } else {
            managerError = .connectionFailed(error)
        }
        
        // LOGGING FIX: Add explicit logging for all handled errors.
        logger.error("Connection failed: \(managerError.localizedDescription)")
        
        self.successfulConnectionResult = nil
        self.statusMessage = (text: "Error: \(managerError.localizedDescription)", isError: true)
        self.activeServer = nil
        self.availableTools = []
    }

    /// Creates and configures a transport for a remote server using the provided HTTPClientTransport.
    private func setupRemoteTransport(urlString: String, config: ServerDefinition) throws -> any Transport {
        guard let url = URL(string: urlString) else {
            throw MCPManagerError.invalidJSONConfiguration("The provided server URL is not valid: \(urlString)")
        }

        // The requestModifier closure is the correct way to add authentication headers.
        let transport = HTTPClientTransport(endpoint: url, requestModifier: { request in
            var modifiedRequest = request
            // Check for authentication details in the config
            if let authToken = config.authentication?["token"] {
                modifiedRequest.addValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            return modifiedRequest
        })
        
        return transport
    }

    /// Creates and configures a transport for a local process-based MCP server.
    private func setupProcessTransport(config: ServerDefinition) async throws -> any Transport {
        guard let command = config.command else {
            throw MCPManagerError.invalidJSONConfiguration("Process-based server is missing the 'command' field.")
        }

        guard let commandURL = findExecutable(named: command) else {
             throw MCPManagerError.commandNotFound(command)
        }
        
        let process = Process()
        process.executableURL = commandURL
        process.arguments = config.args ?? []
        
        // --- ADDED: Load the full shell environment ---
        // This is the critical fix. It ensures that the launched process
        // inherits the user's full PATH and other environment variables,
        // which is necessary for child processes like 'git' to function correctly.
        let shellPath = getShellPath()
        let shellEnvironment = try await getShellEnvironment(shellPath: shellPath)
        process.environment = shellEnvironment.merging(config.env ?? [:]) { (_, new) in new }
        // --- END ADDED ---

        let stdInPipe = Pipe(), stdOutPipe = Pipe(), stdErrPipe = Pipe()
        process.standardInput = stdInPipe
        process.standardOutput = stdOutPipe
        process.standardError = stdErrPipe
        
        // Set up the termination handler to catch premature exits.
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self = self, self.isConnecting else { return }
                
                if process.terminationStatus != 0 {
                    let errorData = (try? stdErrPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown process error"
                    
                    logger.error("MCP process terminated with error: \(errorOutput)")
                    self.handle(error: MCPManagerError.processFailedToStart(errorOutput))
                }
            }
        }
        
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
                // Only throw timeout if the process is still running.
                if await self.activeProcess?.isRunning == true {
                    throw MCPManagerError.connectionTimedOut(seconds)
                } else {
                    // If the process has already terminated, it's not a timeout.
                    // The terminationHandler will have set the real error.
                    // We can just cancel to let the other task finish.
                    throw CancellationError()
                }
            }
            guard let result = try await group.next() else { throw MCPManagerError.unknown }
            group.cancelAll()
            return result
        }
    }
    
    // MARK: - Self-Sufficient Path Resolution
    
    /// Finds an executable by searching a prioritized list of common installation locations.
    private func findExecutable(named executableName: String) -> URL? {
        // If the user provides an absolute path, use it directly.
        if executableName.starts(with: "/") {
            return URL(fileURLWithPath: executableName)
        }
        
        logger.info("Searching for executable '\(executableName)'...")
        
        var searchPaths: [String] = []
        
        // 1. User-specific binary directories
        if let homeDir = ProcessInfo.processInfo.environment["HOME"] {
            searchPaths.append(homeDir + "/.local/bin")
        }
        
        // 2. Homebrew binary directory (architecture-dependent)
        #if arch(arm64)
            searchPaths.append("/opt/homebrew/bin") // Apple Silicon
        #else
            searchPaths.append("/usr/local/bin") // Intel
        #endif
        
        // 3. Standard system binary directories
        searchPaths.append(contentsOf: ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])

//        logger.info("Searching in paths: \(searchPaths.joined(separator: \":\"))")
        
        let fileManager = FileManager.default
        for path in searchPaths {
            let executableURL = URL(fileURLWithPath: path).appendingPathComponent(executableName)
            if fileManager.isExecutableFile(atPath: executableURL.path) {
                logger.info("Found executable at: \(executableURL.path)")
                return executableURL
            }
        }
        
        logger.error("Executable '\(executableName)' not found in any of the search paths.")
        return nil
    }

    // MARK: - ADDED: Shell Environment Helpers
    
    private func getShellPath() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
    
    private func getShellEnvironment(shellPath: String) async throws -> [String: String] {
        let output = try shell(shellPath, "env")
        var environment = [String: String]()
        output.split(separator: "\n").forEach { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                environment[String(parts[0])] = String(parts[1])
            }
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
            throw MCPManagerError.shellCommandFailed(command: args.joined(separator: " "), output: errorOutput)
        }
        
        let outputData = stdOutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

