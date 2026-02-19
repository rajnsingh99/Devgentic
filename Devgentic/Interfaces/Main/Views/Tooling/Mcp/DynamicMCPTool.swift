//
//  DynamicMCPTool.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  MIGRATION: Updated to native DevgenticTool protocol.
//

import Foundation
import SwiftAgent

/// A generic wrapper that adapts any MCP ToolDefinition into an executable DevgenticTool.
/// This allows the native SwiftAgent to execute tools defined dynamically by MCP servers.
struct DynamicMCPTool: DevgenticTool {
    
    // MARK: - Properties
    
    let name: String
    let description: String
    
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
    
    /// A generic arguments structure that can decode ANY JSON object using AnyCodable.
    struct Arguments: Decodable, Sendable {
        let payload: [String: AnyCodable]
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            
            // Safely attempt to decode a dictionary; default to empty if the tool takes no args
            if let dict = try? container.decode([String: AnyCodable].self) {
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
        // 1. Attempt Execution via V2 Service
        // This ensures we use ShellProcess with the correct PATH injection.
        do {
            return try await MCPClientService.shared.executeTool(
                sourceId: self.source.id,
                name: self.name,
                arguments: arguments.rawDictionary
            )
        } catch {
            // 2. Auto-Reconnection Logic
            // If the V2 service threw an error, it might mean the session isn't active
            // (e.g., app was restarted, or connection dropped).
            
            // Check if we have a definition to reconnect with
            guard let serverDef = self.source.serverDefinition else {
                return "Execution Failed: No active connection and no server definition found to reconnect."
            }
            
            print("DynamicMCPTool: Session missing or failed. Attempting auto-reconnect for \(source.serverName)...")
            
            do {
                // Attempt to reconnect using the stored definition
                _ = try await MCPClientService.shared.connect(sourceId: self.source.id, config: serverDef)
                
                // Retry execution immediately after successful connection
                return try await MCPClientService.shared.executeTool(
                    sourceId: self.source.id,
                    name: self.name,
                    arguments: arguments.rawDictionary
                )
            } catch {
                // If reconnection or retry fails, return the error to the Agent
                return "Error executing tool '\(name)': \(error.localizedDescription)"
            }
        }
    }
}
