//
//  ToolModel.swift
//  Devgentic
//
//  Created by Raj Singh on 20/09/25.
//
//  Centralized on 10/10/25 to act as a single source of truth for tool-related data models.
//  Updated for Phase 1: Security & HITL - Added requiresConfirmation to ToolDefinition
//  Updated for Phase 2: Added requiresConfirmation to ExecutableTool protocol
//  Updated for Phase 5: Added category property for UI grouping
//

import Foundation

// MARK: - API Data Models

/// The JSON request body sent to execute a tool.
struct ExecuteToolRequest: Decodable {
    let name: String
    let arguments: [String: JSONValue]
}

// MARK: - MCP v0.11.0 Icon & Annotation Models

/// A lightweight, Codable representation of an MCP tool icon.
/// Decoupled from the SDK's `MCP.Icon` type for persistence and UI use.
struct ToolIcon: Codable, Hashable {
    let src: String              // URL string or base64 data URI
    let mimeType: String?
    let sizes: [String]?
    let theme: ToolIconTheme?

    enum ToolIconTheme: String, Codable, Hashable {
        case light, dark
    }
}

/// Behavioral hints about a tool, surfaced from MCP SDK v0.11.0.
/// All fields are optional hints — not guarantees.
struct ToolAnnotations: Codable, Hashable {
    var destructiveHint: Bool?
    var idempotentHint: Bool?
    var openWorldHint: Bool?
    var readOnlyHint: Bool?
}

// MARK: - Client-Side Tooling Foundation & Models

/// Defines the JSON schema for a single property within a tool's parameters.
struct ToolParameterProperty: Codable, Hashable {
    let type: String
    let description: String?
    let items: [String: String]? // For arrays: e.g. ["type": "string"]
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
    let category: String
    let parameters: ToolParameters

    var requiresConfirmation: Bool = true

    // MCP v0.11.0 fields
    /// Human-readable display title. Falls back to `name` when nil.
    var title: String? = nil
    /// Icons provided by the MCP server for this tool.
    var icons: [ToolIcon]? = nil
    /// Behavioral hints from the MCP server.
    var annotations: ToolAnnotations? = nil
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
protocol ExecutableTool: Sendable {
    /// A unique, programmatic name for the tool (e.g., "execute_shell").
    var name: String { get }
    
    /// A user-friendly description of what the tool does, for display in the UI.
    var description: String { get }
    
    /// The logical category this tool belongs to, for grouping in the UI.
    var category: String { get }
    
    /// The schema defining the tool's required input arguments.
    var parameters: ToolParameters { get }
    
    var requiresConfirmation: Bool { get }
    
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
///
/// **Secret-handling contract.** Nothing in this struct holds secret material.
/// - For local-process servers, `envKeys` lists the names of env vars the
///   server expects; their values live in Keychain at `MCPSecretScope.envValue(key:)`
///   for the source's UUID.
/// - For remote servers, `auth` describes the authentication shape; the actual
///   token / key / OAuth bundle lives in Keychain under the matching scope.
///
/// Callers materialize secrets at use time via `MCPRuntimeSecrets.materialize(...)`.
struct ServerDefinition: Codable, Hashable {
    // Properties for Local Process
    let command: String?
    let args: [String]?

    /// Names of env vars this server expects. Values are stored in Keychain
    /// (per source) at `MCPSecretScope.envValue(key:)`. Empty `nil` means none.
    let envKeys: [String]?

    // Properties for Remote URL
    let url: String?

    /// How the remote server authenticates this client. The corresponding
    /// secret (if any) lives in Keychain. Defaults to `.none` for new entries
    /// and for legacy data prior to the secrets migration.
    let auth: MCPAuthenticationScheme

    init(
        command: String? = nil,
        args: [String]? = nil,
        envKeys: [String]? = nil,
        url: String? = nil,
        auth: MCPAuthenticationScheme = .none
    ) {
        self.command = command
        self.args = args
        self.envKeys = envKeys
        self.url = url
        self.auth = auth
    }

    // MARK: - Codable (forward-compatible)

    /// Custom decode so older persisted JSON (no `auth` field) still loads as
    /// `auth = .none`. Migration takes care of promoting legacy `authentication`
    /// payloads up-front; this just guards against any blob that slips through.
    private enum CodingKeys: String, CodingKey {
        case command, args, envKeys, url, auth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.command = try container.decodeIfPresent(String.self, forKey: .command)
        self.args = try container.decodeIfPresent([String].self, forKey: .args)
        self.envKeys = try container.decodeIfPresent([String].self, forKey: .envKeys)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.auth = try container.decodeIfPresent(MCPAuthenticationScheme.self, forKey: .auth) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(args, forKey: .args)
        try container.encodeIfPresent(envKeys, forKey: .envKeys)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(auth, forKey: .auth)
    }
}

/// Pre-Phase-1 persisted shape. Used only by the secrets migration path —
/// reads legacy blobs, lifts secrets into Keychain, re-encodes as
/// `ServerDefinition`. Do not use for new code.
struct LegacyServerDefinition: Codable {
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let url: String?
    let authentication: [String: String]?
}

/// Runtime secret bundle passed into `MCPClientService.connect`. Carries the
/// env-var values and auth header that the session needs but which are never
/// persisted inside `ServerDefinition`. Two construction paths:
///
/// 1. **Form-driven (test connection / save):** the Add/Edit form holds env
///    values and auth tokens in @State; build directly from form data.
/// 2. **Persisted-source (tool call reconnect):** materialize from Keychain
///    via the source's UUID and its `ServerDefinition`.
struct MCPRuntimeSecrets: Sendable {
    var env: [String: String] = [:]
    /// The fully-formed authorization header to attach to remote requests, or
    /// nil for local / unauthenticated transports.
    var authorizationHeader: (name: String, value: String)? = nil
}

extension MCPRuntimeSecrets {

    /// Build a runtime-secrets bundle by reading the configured secrets out of
    /// Keychain. Used by the tool-execution reconnect path, where we have a
    /// `sourceID` + persisted `ServerDefinition` but no live form state.
    @MainActor
    static func materialize(for sourceID: UUID, definition: ServerDefinition) -> MCPRuntimeSecrets {
        var bundle = MCPRuntimeSecrets()

        // Env vars: read each key's value out of Keychain. Missing values are
        // skipped silently — the user may have removed the secret since the
        // server was added; ShellProcess will surface the failure if the
        // server requires it.
        if let keys = definition.envKeys {
            for key in keys {
                if let value = MCPSecretStore.shared.retrieve(.envValue(key: key), sourceID: sourceID) {
                    bundle.env[key] = value
                }
            }
        }

        // Auth header for remote transports.
        switch definition.auth {
        case .none:
            break
        case .bearer:
            if let token = MCPSecretStore.shared.retrieve(.bearerToken, sourceID: sourceID) {
                bundle.authorizationHeader = ("Authorization", "Bearer \(token)")
            }
        case .apiKeyHeader(let headerName):
            if let value = MCPSecretStore.shared.retrieve(.apiKeyHeaderValue, sourceID: sourceID) {
                bundle.authorizationHeader = (headerName, value)
            }
        case .oauth:
            // Read the OAuth credential bundle out of Keychain and attach its
            // (possibly stale) access token. Refresh-on-401 happens one layer
            // up in `DynamicMCPTool` once Phase 4 lands; for now a stale
            // token will surface as a 401 from the transport.
            if let oauthBundle = MCPOAuthCoordinator.loadBundle(sourceID: sourceID) {
                bundle.authorizationHeader = ("Authorization", "Bearer \(oauthBundle.accessToken)")
            }
        }

        return bundle
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
