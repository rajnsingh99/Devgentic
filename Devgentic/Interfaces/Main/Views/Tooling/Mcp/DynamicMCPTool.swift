// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DynamicMCPTool.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  MIGRATION: Updated to native DevgenticTool protocol.
//

import Foundation

private let logger = DGLogger(category: "DynamicMCPTool")

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
        } catch let error as MCPManagerError {
            // A tool that ran and reported failure is NOT a broken connection. Tearing
            // the server down and respawning it three times would destroy a healthy
            // session over a bad argument, cost ~7s of backoff, and still end in the
            // same error. Surface it to the agent immediately so it can correct itself.
            if case .toolReportedFailure = error {
                logger.info("""
                    [MCP-TOOL] '\(name)' on '\(source.serverName)' failed at the tool level; \
                    session left intact, no reconnect. \(error.localizedDescription)
                    """)
                throw error
            }
            return try await reconnectAndRetry(arguments: arguments, initialError: error)
        } catch {
            return try await reconnectAndRetry(arguments: arguments, initialError: error)
        }
    }

    /// Transport-level recovery: the session looks dead, so rebuild it with exponential
    /// backoff and re-issue the call.
    ///
    /// Every exit path here THROWS rather than returning a message. A returned string is
    /// indistinguishable from a successful result to `ToolExecutionMediator`, which scores
    /// output as failure only when it is empty or begins with "error" — so returning
    /// `"Execution Failed: …"` used to be recorded as `.success`, complete with a green
    /// trace span and a `recordToolReliability(isSuccess: true)`.
    @MainActor
    private func reconnectAndRetry(arguments: Arguments, initialError: Error) async throws -> String {
        guard let serverDef = self.source.serverDefinition else {
            logger.error("""
                [MCP-TOOL] '\(name)' cannot run and cannot recover: source \(source.id) \
                ('\(source.serverName)') has no persisted serverDefinition, so there is nothing \
                to reconnect to. The agent loses this capability for the rest of the run. \
                Underlying: \(initialError.localizedDescription)
                """)
            throw MCPManagerError.connectionFailed(initialError)
        }

        let maxRetries = 3
        var lastError = initialError

        for attempt in 1...maxRetries {
            let backoffSeconds = Double(1 << (attempt - 1)) // 1s, 2s, 4s
            logger.warning("""
                [MCP-TOOL] Reconnect \(attempt)/\(maxRetries) for '\(source.serverName)' \
                (source \(source.id)) after \(backoffSeconds)s backoff — tool '\(name)' is \
                blocked until this succeeds. Last error: \(lastError.localizedDescription)
                """)

            MCPClientService.shared.connectionStates[source.id] = .reconnecting(attempt: attempt)

            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

            // Reactive OAuth refresh on the first retry only. If the initial failure was a
            // 401 / token-expired, refreshing the bundle here means the subsequent `connect`
            // materializes a fresh access token via `MCPRuntimeSecrets.materialize`. We only
            // try once — if the refresh itself fails (revoked refresh token, etc.) the user
            // has to re-authenticate via the form.
            if attempt == 1, case .oauth = serverDef.auth {
                do {
                    _ = try await MCPOAuthCoordinator.refresh(sourceID: self.source.id)
                } catch let refreshError {
                    // Best effort: let the regular reconnect run anyway, since some
                    // transports recover with a stale token, and the original tool error is
                    // more useful to surface than the refresh error.
                    logger.error("""
                        [MCP-TOOL] OAuth refresh FAILED for '\(source.serverName)' \
                        (source \(source.id)): \(refreshError.localizedDescription). Continuing \
                        the reconnect with the existing token; if it is genuinely expired this \
                        will fail as 401 and the user must re-authenticate from the server form.
                        """)
                }
            }

            do {
                _ = try await MCPClientService.shared.connect(sourceId: self.source.id, config: serverDef)
                return try await MCPClientService.shared.executeTool(
                    sourceId: self.source.id,
                    name: self.name,
                    arguments: arguments.rawDictionary
                )
            } catch let error as MCPManagerError {
                // Reconnect worked and the tool ran — it just failed. Stop retrying.
                if case .toolReportedFailure = error {
                    logger.info("""
                        [MCP-TOOL] '\(name)' reconnected on attempt \(attempt) and the tool \
                        reported failure; not retrying further.
                        """)
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
        }

        MCPClientService.shared.connectionStates[source.id] = .error(lastError.localizedDescription)
        logger.error("""
            [MCP-TOOL] '\(name)' on '\(source.serverName)' (source \(source.id)) FAILED after \
            \(maxRetries) reconnect attempts — the agent will proceed without this tool's result. \
            Last error: \(lastError.localizedDescription)
            """)
        throw MCPManagerError.connectionFailed(lastError)
    }
}
