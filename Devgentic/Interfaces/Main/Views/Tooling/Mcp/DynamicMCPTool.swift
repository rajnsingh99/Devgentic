//
//  DynamicMCPTool.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  MIGRATION: Updated to native DevgenticTool protocol.
//

import Foundation

/// A generic wrapper that adapts any MCP ToolDefinition into an executable DevgenticTool.
struct DynamicMCPTool: DevgenticTool {
    
    // MARK: - Properties
    
    let name: String
    let description: String

    /// Carried through from the server's own tool definition rather than invented here — an MCP
    /// tool's group is whatever its server said it was. Required by `DevgenticTool` since
    /// 2026-07-31; this type never reaches the Tool Library (the UI reads `ToolDefinition`
    /// directly from `UnifiedToolStore`), so the value is for completeness and logging.
    var category: String { toolDefinition.category }

    /// The source configuration (connection details) for the MCP server.
    private let source: ToolSource
    
    /// The original definition from the MCP server (contains parameter schema).
    private let toolDefinition: ToolDefinition
    
    // MARK: - Initialization
    
    init(source: ToolSource, toolDefinition: ToolDefinition) {
        self.source = source
        self.toolDefinition = toolDefinition
        self.name = toolDefinition.name
        self.description = toolDefinition.description
    }
    
    // MARK: - Arguments Structure
    
    /// A generic arguments structure that can decode ANY JSON object using JSONValue.
    struct Arguments: Decodable, Sendable {
        let payload: [String: JSONValue]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            // Safely attempt to decode a dictionary; default to empty if the tool takes no args
            if let dict = try? container.decode([String: JSONValue].self) {
                self.payload = dict
            } else {
                self.payload = [:]
            }
        }
        
        /// Safely converts the Codable payload back into a raw [String: Any] dictionary
        /// for the MCPClientService using JSON serialization as a bridge.
        var rawDictionary: [String: Any] {
            guard let data = try? JSONEncoder().encode(payload),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return dict
        }
    }
    
    // MARK: - Schema Generation
    
    var parameterSchema: ToolParameters {
        // Because toolDefinition.parameters is natively a ToolParameters object,
        // we can return it directly without the manual dictionary mapping required by OFM.
        return toolDefinition.parameters
    }
    
    // MARK: - Execution (V2 Router)
    
    @MainActor
    func call(arguments: Arguments) async throws -> String {
        // 1. Attempt execution via active session
        do {
            return try await MCPClientService.shared.executeTool(
                sourceId: self.source.id,
                name: self.name,
                arguments: arguments.rawDictionary
            )
        } catch {
            // 2. Auto-reconnection with exponential backoff
            guard let serverDef = self.source.serverDefinition else {
                return "Execution Failed: No active connection and no server definition found to reconnect."
            }

            let maxRetries = 3
            var lastError = error

            for attempt in 1...maxRetries {
                let backoffSeconds = Double(1 << (attempt - 1)) // 1s, 2s, 4s
                print("DynamicMCPTool: Retry \(attempt)/\(maxRetries) for \(source.serverName) after \(backoffSeconds)s backoff...")

                MCPClientService.shared.connectionStates[source.id] = .reconnecting(attempt: attempt)

                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

                // Reactive OAuth refresh on the first retry only. If the
                // initial failure was a 401 / token-expired, refreshing the
                // bundle here means the subsequent `connect` materializes a
                // fresh access token via `MCPRuntimeSecrets.materialize`. We
                // only try once — if the refresh itself fails (revoked
                // refresh token, etc.) the user has to re-authenticate via
                // the form.
                if attempt == 1, case .oauth = serverDef.auth {
                    do {
                        _ = try await MCPOAuthCoordinator.refresh(sourceID: self.source.id)
                    } catch {
                        // Best-effort: log via the existing connection state
                        // and let the regular reconnect attempt run anyway.
                        // Even with a stale token the SDK may reconnect on
                        // some transports, and surfacing the original tool
                        // error is more useful than the refresh error.
                        print("DynamicMCPTool: OAuth refresh failed for \(source.serverName): \(error.localizedDescription)")
                    }
                }

                do {
                    _ = try await MCPClientService.shared.connect(sourceId: self.source.id, config: serverDef)
                    return try await MCPClientService.shared.executeTool(
                        sourceId: self.source.id,
                        name: self.name,
                        arguments: arguments.rawDictionary
                    )
                } catch {
                    lastError = error
                }
            }

            // All retries exhausted
            MCPClientService.shared.connectionStates[source.id] = .error(lastError.localizedDescription)
            return "Error executing tool '\(name)' after \(maxRetries) retries: \(lastError.localizedDescription)"
        }
    }
}
