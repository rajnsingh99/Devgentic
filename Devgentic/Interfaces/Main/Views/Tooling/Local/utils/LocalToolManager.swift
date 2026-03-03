//
//  LocalToolManager.swift
//  LocalServer
//
//  Created by Raj Singh on 20/09/25.
//  Updated on 19/02/26 to support native DevgenticTool architecture.
//  MIGRATION: Removed OFM dependencies, simplified NativeToolWrapper.
//  Updated for Phase 5: Bridged category grouping.
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
    
    // Bridge the category (Assuming you add 'var category: String { get }' to DevgenticTool)
    // Alternatively, you can default to "System Automation" if not defined.
    var category: String {
        // Using Reflection guarantees this compiles right now as a drop-in replacement,
        // even before the DevgenticTool protocol and tools are updated in Step 3.
        let mirror = Mirror(reflecting: nativeTool)
        if let cat = mirror.children.first(where: { $0.label == "category" })?.value as? String {
            return cat
        }
        return "System Automation"
    }
    
    /// Natively bridges the parameter schema without JSON hacks!
    var parameters: ToolParameters {
        return nativeTool.parameterSchema
    }
    
    var requiresConfirmation: Bool {
        // A whitelist of strictly read-only tools that do not alter state or execute arbitrary code.
        let safeTools: Set<String> = [
            "list_directory",
            "read_file",
            "get_system_stats",
            "fs_watch_folder",
            "fs_smart_search",
            "fs_read_metadata",
            "read_session_history"
        ]
        // If the tool is NOT in the safe list, it requires confirmation.
        return !safeTools.contains(nativeTool.name)
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
        
        // Register Vision & Workspace Tools
        registerNative(ReadScreenStateTool())
        registerNative(ClickUIElementTool())
        registerNative(ManageWindowsTool())
        registerNative(ManageClipboardTool())
        registerNative(PushLocalNotificationTool())
        
        // Register Action & Automations
        registerNative(RunMacShortcutTool())
        
        // Register Native PIM Tools
        registerNative(ManageCalendarTool())
        registerNative(ManageRemindersTool())
        registerNative(ReadContactsTool())
        
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
