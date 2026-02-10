//
//  LocalToolManager.swift
//  LocalServer
//
//  Created by Raj Singh on 20/09/25.
//  Updated on 26/01/26 to support swiftAgents Native Tools.
//

import Foundation
import os
import OpenFoundationModels
import OpenFoundationModelsCore

// Define a specific logger for this subsystem.
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LocalToolManager")

// MARK: - Native Tool Adapter

/// A wrapper that adapts the new `OpenFoundationModels.Tool` protocol to the legacy `ExecutableTool` protocol
/// used by the rest of the application (UI, Store, etc.).
struct NativeToolWrapper<T: OpenFoundationModels.Tool>: ExecutableTool where T.Output == String, T.Arguments: Codable {
    
    let nativeTool: T
    
    // MARK: - ExecutableTool Conformance
    
    var name: String {
        return nativeTool.name
    }
    
    var description: String {
        return nativeTool.description
    }
    
    /// Converts the `GenerationSchema` from the native tool into the `ToolParameters` expected by the UI.
    var parameters: ToolParameters {
        let schema = nativeTool.parameters
        
        do {
            // Attempt to bridge via JSON serialization since we cannot access internal properties (like .root) of GenerationSchema directly.
            // This assumes GenerationSchema conforms to Encodable, which is standard for AI tool schemas.
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(schema)
            
            // Try decoding directly into ToolParameters if the structure matches exactly
            if let directParams = try? JSONDecoder().decode(ToolParameters.self, from: jsonData) {
                return directParams
            }
            
            // Fallback: Manually map from dictionary to handle potential structure mismatches
            guard let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
                logger.error("Could not deserialize schema JSON for \(nativeTool.name)")
                return ToolParameters(type: "object", properties: [:], required: [])
            }
            
            let type = json["type"] as? String ?? "object"
            let required = json["required"] as? [String] ?? []
            
            var properties: [String: ToolParameterProperty] = [:]
            if let propsDict = json["properties"] as? [String: [String: Any]] {
                for (key, val) in propsDict {
                    let pType = val["type"] as? String ?? "string"
                    let pDesc = val["description"] as? String
                    properties[key] = ToolParameterProperty(type: pType, description: pDesc)
                }
            }
            
            return ToolParameters(type: type, properties: properties, required: required)
            
        } catch {
            logger.error("Failed to convert parameters for tool \(nativeTool.name): \(error.localizedDescription)")
            // Return empty parameters on failure to prevent crash
            return ToolParameters(type: "object", properties: [:], required: [])
        }
    }
    
    /// Bridges the untyped execution call to the strongly-typed native tool call.
    func execute(arguments: [String: Any]) async throws -> String {
        do {
            // 1. Serialize the dictionary arguments to JSON Data
            let jsonData = try JSONSerialization.data(withJSONObject: arguments, options: [])
            
            // 2. Decode the JSON Data into the Native Tool's Argument struct
            let decodedArgs = try JSONDecoder().decode(T.Arguments.self, from: jsonData)
            
            // 3. Call the native tool
            return try await nativeTool.call(arguments: decodedArgs)
            
        } catch {
            let errorMsg = "Argument conversion failed for tool '\(name)': \(error.localizedDescription)"
            logger.error("\(errorMsg)")
            throw NSError(domain: "LocalToolManager", code: 400, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
    }
}

// MARK: - Manager

@MainActor
final class LocalToolManager {
    
    static let shared = LocalToolManager()
    
    // The registry holds types that conform to ExecutableTool (our wrappers)
    private var toolRegistry: [String: ExecutableTool] = [:]

    private init() {
        // Register Native File System Tools
        registerNative(ListDirectoryTool())
        registerNative(ReadFileTool())
        registerNative(WriteFileTool())
        registerNative(DeleteFileTool())
        
        // NEW: Register File Manipulation Primitives
        registerNative(MoveFileTool())
        registerNative(CopyFileTool())
        registerNative(CreateFolderTool())
        
        // Register Native System Tools
        registerNative(TerminalTool())
        registerNative(OpenApplicationTool())
        registerNative(RunAppleScriptTool())
        registerNative(GetSystemStatsTool())
        
        // Register Advanced File System Tools
        registerNative(WatchFolderTool())
        registerNative(SmartSearchTool())
        registerNative(ReadMetadataTool())
        registerNative(OrganizeBatchTool())
        
        // Note: Clipboard tools are omitted as they were not present in the native toolset update.
        
        logger.info("LocalToolManager initialized with \(self.toolRegistry.count) native tools.")
    }

    /// Helper to wrap and register a native tool.
    private func registerNative<T: OpenFoundationModels.Tool>(_ tool: T) where T.Output == String, T.Arguments: Codable {
        let wrapper = NativeToolWrapper(nativeTool: tool)
        toolRegistry[wrapper.name] = wrapper
    }

    func availableTools() -> [ExecutableTool] {
        return Array(toolRegistry.values)
    }

    func execute(name: String, arguments: [String: Any]) async -> String {
        logger.info("--- executing local tool (native) ---")
        logger.info("Tool: '\(name)'")
        logger.info("Arguments: \(String(describing: arguments))")
        
        guard let tool = toolRegistry[name] else {
            let errorMsg = "Error: Tool '\(name)' not found in the client-side registry."
            logger.error("\(errorMsg)")
            return errorMsg
        }
        
        do {
            let result = try await tool.execute(arguments: arguments)
            logger.info("-> Local tool '\(name)' executed successfully.")
            return result
        } catch {
            let errorMsg = "Error executing local tool '\(name)': \(error.localizedDescription)"
            logger.error("\(errorMsg)")
            return errorMsg
        }
    }
}
