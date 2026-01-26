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
    /// Since MCP tools have dynamic schemas, we capture the raw JSON dictionary.
    /// Note: We removed 'Codable' conformance as [String: Any] is not Codable,
    /// and the Tool protocol only requires ConvertibleFromGeneratedContent.
    struct Arguments: OpenFoundationModelsCore.ConvertibleFromGeneratedContent {
        let rawDictionary: [String: Any]
        
        init(_ content: OpenFoundationModelsCore.GeneratedContent) throws {
            // 1. Extract the raw properties dictionary from the generated content
            let properties = try content.properties()
            
            // 2. Convert [String: GeneratedContent] -> [String: Any]
            // We recursively unwrap the GeneratedContent to get raw Swift primitives (String, Int, Bool, etc.)
            self.rawDictionary = try Arguments.unwrapDictionary(properties)
        }
        
        private static func unwrapDictionary(_ dict: [String: OpenFoundationModelsCore.GeneratedContent]) throws -> [String: Any] {
            var result: [String: Any] = [:]
            
            for (key, content) in dict {
                // Handle the different content types supported by OpenFoundationModelsCore
                
                if let stringVal = try? String(content) {
                    result[key] = stringVal
                } else if let intVal = try? Int(content) {
                    result[key] = intVal
                } else if let doubleVal = try? Double(content) {
                    result[key] = doubleVal
                } else if let boolVal = try? Bool(content) {
                    result[key] = boolVal
                } else {
                    // Fallback for complex objects or arrays if needed.
                    result[key] = String(describing: content)
                }
            }
            return result
        }
    }
    
    typealias Output = String
    
    // MARK: - Schema Generation
    
    /// Converts the MCP JSON Schema (ToolParameters) into OpenFoundationModels GenerationSchema.
    var parameters: OpenFoundationModelsCore.GenerationSchema {
        var properties: [OpenFoundationModelsCore.DynamicGenerationSchema.Property] = []
        
        for (key, prop) in toolDefinition.parameters.properties {
            let propSchema: OpenFoundationModelsCore.DynamicGenerationSchema
            
            // FIXED: Instantiate DynamicGenerationSchema with concrete types inside the switch.
            // This satisfies the generic requirement <Value: Generable> of the initializer.
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
                // Default to string for unknown types to prevent crashes
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
            // Return an empty schema as fail-safe
            let emptyRoot = OpenFoundationModelsCore.DynamicGenerationSchema(name: "Arguments", properties: [])
            return try! OpenFoundationModelsCore.GenerationSchema(root: emptyRoot, dependencies: [])
        }
    }
    
    // MARK: - Execution
    
    @MainActor
    func call(arguments: Arguments) async throws -> String {
        // Delegate execution to the MCPConnectionManager
        return await MCPConnectionManager.shared.execute(
            toolName: self.name,
            arguments: arguments.rawDictionary,
            source: self.source
        )
    }
}
