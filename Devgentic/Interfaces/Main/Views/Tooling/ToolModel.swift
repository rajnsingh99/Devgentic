//
//  ToolModel.swift
//  Devgentic
//
//  Created by Raj Singh on 20/09/25.
//
//  Centralized on 10/10/25 to act as a single source of truth for tool-related data models.
//

import Foundation

// MARK: - API Data Models

/// The JSON request body sent to execute a tool.
struct ExecuteToolRequest: Decodable {
    let name: String
    let arguments: [String: AnyCodable]
}

// MARK: - Client-Side Tooling Foundation & Models

/// Defines the JSON schema for a single property within a tool's parameters.
struct ToolParameterProperty: Codable, Hashable {
    let type: String
    let description: String?
}

/// Defines the JSON schema for a tool's parameters, following a standard format.
struct ToolParameters: Codable, Hashable {
    let type: String
    let properties: [String: ToolParameterProperty]
    let required: [String]
}

/// A generic representation of a single tool's complete definition, regardless of its source.
/// This includes its name, description, and the all-important parameter schema.
struct ToolDefinition: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    let description: String
    let parameters: ToolParameters
}

/// An enum to differentiate between the origins of a tool source (local vs. remote).
enum ToolSourceType: Hashable, Codable {
    case local
    case mcp
}

/// A unified structure representing a source of tools, which can be either the
/// built-in local tools or a configured remote MCP server.
struct ToolSource: Identifiable, Hashable {
    let id: UUID
    let type: ToolSourceType
    let serverName: String // For local, this is "Built-in Tools"
    let tools: [ToolDefinition]
    
    // This is optional because local tools don't have a server definition.
    let serverDefinition: ServerDefinition?
}

/// A universal protocol for any tool that the Swift client application can run directly.
/// This ensures a consistent structure for defining, displaying, and executing tools.
protocol ExecutableTool {
    /// A unique, programmatic name for the tool (e.g., "execute_shell").
    var name: String { get }
    
    /// A user-friendly description of what the tool does, for display in the UI.
    var description: String { get }
    
    /// The schema defining the tool's required input arguments.
    var parameters: ToolParameters { get }
    
    /// The asynchronous method that contains the tool's core logic.
    /// - Parameter arguments: A dictionary containing the arguments, conforming to the `parameters` schema.
    /// - Returns: A `String` representing the output or result of the tool's execution.
    /// - Throws: An error if the tool execution fails.
    func execute(arguments: [String: Any]) async throws -> String
}

// MARK: - MCP Configuration Data Models

/// The top-level configuration structure that holds a dictionary of server definitions.
struct MCPConfiguration: Codable {
    let mcpServers: [String: ServerDefinition]
}

/// A unified server definition that works for both local and remote servers.
struct ServerDefinition: Codable, Hashable {
    // Properties for Local Process
    let command: String?
    let args: [String]?
    let env: [String: String]?
    
    // Properties for Remote URL
    let url: String?
    let authentication: [String: String]?

    /// A single, flexible initializer that provides default nil values for all optional properties.
    /// This allows us to create a ServerDefinition for either a local or remote type without causing compiler errors.
    init(command: String? = nil, args: [String]? = nil, env: [String: String]? = nil, url: String? = nil, authentication: [String: String]? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.authentication = authentication
    }
}

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
