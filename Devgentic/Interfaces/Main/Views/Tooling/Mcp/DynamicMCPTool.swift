//
//  DynamicMCPTool.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore
import SwiftAgent

/// A generic wrapper that adapts any MCP ToolDefinition into an executable OpenFoundationModels.Tool.
/// This allows the native SwiftAgent to execute tools defined dynamically by MCP servers.
struct DynamicMCPTool: OpenFoundationModels.Tool {
    
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
    
    /// A generic arguments structure that can decode ANY JSON object.
    struct Arguments: OpenFoundationModelsCore.ConvertibleFromGeneratedContent {
        let rawDictionary: [String: Any]
        
        init(_ content: OpenFoundationModelsCore.GeneratedContent) throws {
            let properties = try content.properties()
            self.rawDictionary = try Arguments.unwrapDictionary(properties)
        }
        
        private static func unwrapDictionary(_ dict: [String: OpenFoundationModelsCore.GeneratedContent]) throws -> [String: Any] {
            var result: [String: Any] = [:]
            
            for (key, content) in dict {
                if let stringVal = try? String(content) {
                    result[key] = stringVal
                } else if let intVal = try? Int(content) {
                    result[key] = intVal
                } else if let doubleVal = try? Double(content) {
                    result[key] = doubleVal
                } else if let boolVal = try? Bool(content) {
                    result[key] = boolVal
                } else {
                    result[key] = String(describing: content)
                }
            }
            return result
        }
    }
    
    typealias Output = String
    
    // MARK: - Schema Generation
    
    var parameters: OpenFoundationModelsCore.GenerationSchema {
        var properties: [OpenFoundationModelsCore.DynamicGenerationSchema.Property] = []
        
        for (key, prop) in toolDefinition.parameters.properties {
            let propSchema: OpenFoundationModelsCore.DynamicGenerationSchema
            
            switch prop.type {
            case "string":
                propSchema = OpenFoundationModelsCore.DynamicGenerationSchema(type: String.self)
            case "integer":
                propSchema = OpenFoundationModelsCore.DynamicGenerationSchema(type: Int.self)
            case "number":
                propSchema = OpenFoundationModelsCore.DynamicGenerationSchema(type: Double.self)
            case "boolean":
                propSchema = OpenFoundationModelsCore.DynamicGenerationSchema(type: Bool.self)
            default:
                propSchema = OpenFoundationModelsCore.DynamicGenerationSchema(type: String.self)
            }
            
            let isRequired = toolDefinition.parameters.required.contains(key)
            
            let property = OpenFoundationModelsCore.DynamicGenerationSchema.Property(
                name: key,
                description: prop.description ?? "",
                schema: propSchema,
                isOptional: !isRequired
            )
            
            properties.append(property)
        }
        
        let root = OpenFoundationModelsCore.DynamicGenerationSchema(
            name: "Arguments",
            properties: properties
        )
        
        do {
            return try OpenFoundationModelsCore.GenerationSchema(root: root, dependencies: [])
        } catch {
            print("Error creating schema for MCP tool \(name): \(error)")
            let emptyRoot = OpenFoundationModelsCore.DynamicGenerationSchema(name: "Arguments", properties: [])
            return try! OpenFoundationModelsCore.GenerationSchema(root: emptyRoot, dependencies: [])
        }
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
