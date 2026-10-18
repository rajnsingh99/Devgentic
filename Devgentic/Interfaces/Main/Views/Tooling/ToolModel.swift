// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - API Data Models

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

// MARK: - Lenient JSON Schema decoding

// Decodes leniently because MCP servers emit arbitrary JSON Schema; a strict decode would silently drop the tool.
// Both inits are in extensions so the synthesized memberwise init (used by local tools) is not suppressed.

extension ToolParameters {

    private enum LenientKeys: String, CodingKey {
        case type, properties, required
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LenientKeys.self)
        // A schema that omits `type` is an object schema by convention.
        self.type = (try? container.decode(String.self, forKey: .type)) ?? "object"
        self.properties = (try? container.decode([String: ToolParameterProperty].self, forKey: .properties)) ?? [:]
        // Absent `required` means "nothing is required" — not "this tool is invalid".
        self.required = (try? container.decode([String].self, forKey: .required)) ?? []
    }
}

extension ToolParameterProperty {

    private enum LenientKeys: String, CodingKey {
        case type, description, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LenientKeys.self)

        // `type` may be a string, a union array (`["string","null"]`) or absent; take the first meaningful union entry,
        // falling back to "string", the safest thing to advertise to a model.
        if let single = try? container.decode(String.self, forKey: .type) {
            self.type = single
        } else if let union = try? container.decode([String].self, forKey: .type),
                  let first = union.first(where: { $0 != "null" }) ?? union.first {
            self.type = first
        } else {
            self.type = "string"
        }

        self.description = try? container.decode(String.self, forKey: .description)

        // `items` is modelled as [String: String]; a nested object schema keeps its string-valued entries (including `type`)
        // and drops the nested structure rather than failing.
        if let flat = try? container.decode([String: String].self, forKey: .items) {
            self.items = flat
        } else if let rich = try? container.decode([String: JSONValue].self, forKey: .items) {
            let flattened = rich.compactMapValues { value -> String? in
                if case .string(let s) = value { return s }
                return nil
            }
            self.items = flattened.isEmpty ? nil : flattened
        } else {
            self.items = nil
        }
    }
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

    /// The fixed identity of the built-in tool catalogue; any other `sourceId` belongs to an MCP server.
    /// Tool dispatch keys off that distinction, so the literal is not re-spelled at each site.
    static let builtInSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    let id: UUID
    let type: ToolSourceType
    let serverName: String // For local, this is "Built-in Tools"
    let tools: [ToolDefinition]

    // This is optional because local tools don't have a server definition.
    let serverDefinition: ServerDefinition?

    /// Whether Devgentic may connect to this server. Always `true` for the built-in
    /// catalogue, which has nothing to connect to.
    var isEnabled: Bool = true

    /// True when `mcpConfigData` could not be decoded, so a nil `serverDefinition` means unreadable bytes, not no config.
    /// Deleting an unreadable source orphans its Keychain secrets, since the `envKeys` naming them live in that blob.
    /// Describes this read, not the source; false for the built-in catalogue.
    var isConfigurationUnreadable: Bool = false
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
    
    /// Runs the tool's core logic with `arguments` conforming to the `parameters` schema.
    /// Returns the tool's output as a string; throws if execution fails.
    func execute(arguments: [String: Any]) async throws -> String
}

// MARK: - MCP Configuration Data Models

/// The top-level configuration structure that holds a dictionary of server definitions.
struct MCPConfiguration: Codable {
    let mcpServers: [String: ServerDefinition]
}

/// How the app talks to a remote MCP server: Streamable HTTP with an SSE stream, or plain HTTP for servers
/// that do not implement the SSE GET stream.
enum MCPTransportMode: String, Codable, Hashable, CaseIterable, Identifiable {
    /// Streamable HTTP with an SSE stream for server→client push. The current standard and
    /// the right default: server-initiated notifications (`tools/list_changed`, logging,
    /// sampling, elicitation) only arrive over this.
    case streamableHTTP

    /// Plain HTTP request/response, no SSE stream. Compatible with servers that only
    /// implement POST, at the cost of every server-initiated feature.
    case httpNoStreaming

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .streamableHTTP:  return "Streamable HTTP (recommended)"
        case .httpNoStreaming: return "HTTP request/response only"
        }
    }

    var explanation: String {
        switch self {
        case .streamableHTTP:
            return "Standard transport. Required for server-initiated features: live tool-list updates, server logs, sampling and elicitation."
        case .httpNoStreaming:
            return "Use only if the server does not support the SSE stream. Server-initiated features will not work."
        }
    }
}

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
    /// secret (if any) lives in Keychain. Defaults to `.none`.
    let auth: MCPAuthenticationScheme

    /// Remote transport selection. Ignored for local-process servers, which are always
    /// stdio. Defaults to the standard for new entries and for anything persisted before
    /// the setting existed.
    let transport: MCPTransportMode

    init(
        command: String? = nil,
        args: [String]? = nil,
        envKeys: [String]? = nil,
        url: String? = nil,
        auth: MCPAuthenticationScheme = .none,
        transport: MCPTransportMode = .streamableHTTP
    ) {
        self.command = command
        self.args = args
        self.envKeys = envKeys
        self.url = url
        self.auth = auth
        self.transport = transport
    }

    // MARK: - Codable (forward-compatible)

    /// Custom decode so JSON without an `auth` field loads as `auth = .none`.
    private enum CodingKeys: String, CodingKey {
        case command, args, envKeys, url, auth, transport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.command = try container.decodeIfPresent(String.self, forKey: .command)
        self.args = try container.decodeIfPresent([String].self, forKey: .args)
        self.envKeys = try container.decodeIfPresent([String].self, forKey: .envKeys)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.auth = try container.decodeIfPresent(MCPAuthenticationScheme.self, forKey: .auth) ?? .none
        // Absent for every server saved before the transport picker existed — those were
        // all streaming, so that is the correct default rather than a guess.
        self.transport = try container.decodeIfPresent(MCPTransportMode.self, forKey: .transport) ?? .streamableHTTP
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(args, forKey: .args)
        try container.encodeIfPresent(envKeys, forKey: .envKeys)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(auth, forKey: .auth)
        try container.encode(transport, forKey: .transport)
    }
}

/// Runtime secret bundle passed into `MCPClientService.connect`: env-var values and the auth header the session needs,
/// never persisted inside `ServerDefinition`. Built from form data, or materialized from Keychain for a persisted source.
struct MCPRuntimeSecrets: Sendable {
    var env: [String: String] = [:]
    /// The fully-formed authorization header to attach to remote requests, or
    /// nil for local / unauthenticated transports.
    var authorizationHeader: (name: String, value: String)? = nil
}

extension MCPRuntimeSecrets {

    /// Logger for the attach-refusal line, the only log line this extension emits.
    private static let attachRefusalLogger = DGLogger(category: "MCPRuntimeSecrets")

    /// Test seam: when set, receives exactly the refusal lines `materialize` logs when a credential read fails,
    /// one message for the sink and the logger alike so the seam cannot drift from the log.
    nonisolated(unsafe) static var refusalLogSinkForTesting: (@Sendable (String) -> Void)?

    /// Logs one credential refusal; an unreadable env value or auth header must be logged, or a server launches
    /// with no credential and the only hint is an authentication failure from the server itself.
    private static func logRefusal(_ message: String) {
        if let sink = refusalLogSinkForTesting {
            sink(message)
            return
        }
        attachRefusalLogger.error(message)
    }

    private static func refusal(_ what: String, sourceID: UUID, status: OSStatus) -> String {
        return "[SECRETS] Refusing to materialize \(what) for source \(sourceID.uuidString): the "
            + "Keychain read FAILED (\(SecureKeyStorage.osStatusName(status))). CONSEQUENCE: the "
            + "server starts WITHOUT this credential and will fail authentication or miss the "
            + "variable — the stored value itself is untouched, and no empty or placeholder value "
            + "is substituted."
    }

    @MainActor
    static func materialize(for sourceID: UUID, definition: ServerDefinition) -> MCPRuntimeSecrets {
        var bundle = MCPRuntimeSecrets()

        // Env vars: read each key's value from Keychain. Missing values are skipped silently (the secret may have been removed;
        // `ShellProcess` surfaces it if required). Failed reads are not silent: launching without the value must be visible.
        if let keys = definition.envKeys {
            for key in keys {
                switch MCPSecretStore.shared.read(.envValue(key: key), sourceID: sourceID) {
                case .found(let value):
                    bundle.env[key] = value
                case .notFound:
                    break
                case .failed(let status):
                    logRefusal(refusal("env variable '\(key)'", sourceID: sourceID, status: status))
                }
            }
        }

        // Auth header for remote transports.
        switch definition.auth {
        case .none:
            break
        case .bearer:
            switch MCPSecretStore.shared.read(.bearerToken, sourceID: sourceID) {
            case .found(let token):
                bundle.authorizationHeader = ("Authorization", "Bearer \(token)")
            case .notFound:
                break
            case .failed(let status):
                logRefusal(refusal("the bearer token", sourceID: sourceID, status: status))
            }
        case .apiKeyHeader(let headerName):
            switch MCPSecretStore.shared.read(.apiKeyHeaderValue, sourceID: sourceID) {
            case .found(let value):
                bundle.authorizationHeader = (headerName, value)
            case .notFound:
                break
            case .failed(let status):
                logRefusal(refusal("the '\(headerName)' header value", sourceID: sourceID, status: status))
            }
        case .oauth:
            // Reads the OAuth credential bundle from Keychain and attaches its (possibly stale) access token;
            // a stale token surfaces as a 401 from the transport.
            if let oauthBundle = MCPOAuthCoordinator.loadBundle(sourceID: sourceID) {
                // The token is attached only to the URL the sign-in was performed for; a bundle bound to a different server must not
                // ride along to a new host. Legacy bundles carry no binding and attach.
                if MCPOAuthBinding.shouldAttach(oauthBundle, to: definition.url) {
                    bundle.authorizationHeader = ("Authorization", "Bearer \(oauthBundle.accessToken)")
                } else {
                    logRefusal(
                        "[MCP-OAUTH] Refused to attach the OAuth token for source \(sourceID.uuidString): it is bound to '\(oauthBundle.serverURL?.absoluteString ?? "—")' but the server is now '\(MCPRedaction.redact(url: definition.url ?? "—"))'. CONSEQUENCE: requests go out WITHOUT credentials and fail authentication — the user must sign in again from the server's editor. The stored bundle is intentionally left in place."
                    )
                }
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

    /// The server ran the tool and the tool itself reported failure (`isError: true` on the `tools/call` result).
    /// A tool failure, not a transport failure: the session is healthy and must not be torn down.
    case toolReportedFailure(tool: String, detail: String)

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
        case .toolReportedFailure(let tool, let detail):
            return "Tool '\(tool)' failed: \(detail)"
        case .unknown:
            return "An unexpected error occurred."
        }
    }
}
