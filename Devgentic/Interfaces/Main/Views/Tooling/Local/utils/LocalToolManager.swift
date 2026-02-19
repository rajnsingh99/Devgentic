//
//  LocalToolManager.swift
//  LocalServer
//
//  Created by Raj Singh on 20/09/25.
//  Updated on 19/02/26 to support native DevgenticTool architecture.
//  MIGRATION: Removed OFM dependencies, simplified NativeToolWrapper.
//

import Foundation
import os

// Define a specific logger for this subsystem.
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LocalToolManager")

// MARK: - Native Tool Adapter

/// A wrapper that adapts the new `DevgenticTool` protocol to the legacy `ExecutableTool` protocol
/// used by the rest of the application (UI, Store, etc.).
struct NativeToolWrapper<T: DevgenticTool>: ExecutableTool {
    
    let nativeTool: T
    
    // MARK: - ExecutableTool Conformance
    
    var name: String {
        return nativeTool.name
    }
    
    var description: String {
        return nativeTool.description
    }
    
    /// Natively bridges the parameter schema without JSON hacks!
    var parameters: ToolParameters {
        return nativeTool.parameterSchema
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
        
        // Register File Manipulation Primitives
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
        
        logger.info("LocalToolManager initialized with \(self.toolRegistry.count) native tools.")
    }

    /// Helper to wrap and register a native tool.
    private func registerNative<T: DevgenticTool>(_ tool: T) {
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
