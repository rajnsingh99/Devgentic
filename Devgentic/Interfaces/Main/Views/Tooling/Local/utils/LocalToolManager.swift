// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalToolManager.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

// Define a specific logger for this subsystem.
private let logger = DGLogger(category: "LocalToolManager")

// MARK: - Native Tool Adapter

/// Which built-in tools start in the Tool Library WITHOUT confirmation. Two lists, two reasons.
enum ToolConfirmationDefaults {

    static func startsWithoutConfirmation(_ name: String) -> Bool {
        readOnlyTools.contains(name) || ownWorkOnlyTools.contains(name)
    }

    // Why: confirming before an agent stops its own dev server is a prompt people approve without reading, which defeats
    // the purpose of confirmation.
    /// Tools that change state but start without confirmation: they can only touch work this agent started here.
    /// Kept apart from `readOnlyTools`: these are not read-only (`HITLRiskTier` calls them `.moderate`).
    /// `stop_background_task` can only stop a task its own conversation launched (the registry keys lookups by conversation).
    static let ownWorkOnlyTools: Set<String> = [
        "stop_background_task",
    ]

    static let readOnlyTools: Set<String> = {
        // Strictly read-only tools: they alter no state and execute no caller-supplied code.
        // The list is per tool, not per action, so `fs_watch_folder` (whose `start` arms a dispatch source) is excluded.
        let safeTools: Set<String> = [
            "list_directory",
            "read_file",
            "get_system_stats",
            "spotlight_search",
            "read_file_metadata",
            "project_tree",
            "glob_files",
            "find_definition",
            "file_overview",
            "code_search_text",
            "code_search_symbol",
            "code_search_files",
            "diff_files",
            "git",
            "get_task_output",
            // Changes no state on this machine; the query leaving the device IS the feature, and
            // the user opted in by choosing a provider in Settings → Web Search.
            "web_search",
            // `stop_background_task` is not here: it changes state. See `ownWorkOnlyTools`.
        ]
        return safeTools
    }()
}

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
    
    // `category` is a `DevgenticTool` requirement, so it is read directly rather than through `Mirror`.
    var category: String {
        return nativeTool.category
    }
    
    /// Natively bridges the parameter schema without JSON hacks!
    var parameters: ToolParameters {
        return nativeTool.parameterSchema
    }
    
    /// The default confirmation setting a tool carries when it first appears in the Tool Library.
    /// A default, not a gate: the executor reads `Tool.requiresConfirmation` on the profile, and the user's choice wins.
    var requiresConfirmation: Bool {
        !ToolConfirmationDefaults.startsWithoutConfirmation(nativeTool.name)
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
        // Built from `NativeToolCatalog`, which `AgentConnect.resolveNativeTool` also reads: registration is a projection, so a
        // tool appears here because its catalogue entry says `.library`, not because a line was added by hand.
        for entry in NativeToolCatalog.libraryTools {
            let tool = entry.executable()
            toolRegistry[tool.name] = tool
        }
        // Tagged and broken down so one startup line proves which projection ran: a bare count cannot distinguish a shrunk
        // catalogue from a wrongly filtering projection.
        let lib = NativeToolCatalog.entries.filter { $0.visibility == .library }.count
        let exceptCode = NativeToolCatalog.hiddenFromCodeLibrary.count
        let codeOnly = NativeToolCatalog.codeOnlyTools.count
        logger.info("""
            [TOOLCATALOG] Library registered \(self.toolRegistry.count) of \(NativeToolCatalog.entries.count) \
            catalogue entries — \(lib) library + \(exceptCode) library-except-code; \
            \(codeOnly) code-only withheld (Code profiles get them from CodeToolPreset).
            """)
        if self.toolRegistry.count != lib + exceptCode {
            logger.error("[TOOLCATALOG] ⚠️ Registered \(self.toolRegistry.count) but expected \(lib + exceptCode) — a duplicate tool NAME collapsed an entry, so a tool the catalogue declares is NOT offered.")
        }
    }

    func availableTools() -> [ExecutableTool] {
        return Array(toolRegistry.values)
    }

    // This type is a catalogue (what tools exist and how they display), not an execution engine: every real tool call goes
    // through `AgentTool.run` at `ToolExecutionMediator`, resolved by `AgentConnect.resolveNativeTool`.
}
