// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
private let logger = DGLogger(category: "LocalToolManager")

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
    
    // "Step 3" — completed 2026-07-31. `category` is now a `DevgenticTool` requirement, so this
    // reads it directly instead of digging it out with `Mirror`. The reflection was a migration
    // shim that outlived its migration: it could not fail, so a tool that omitted the property
    // silently became "System Automation" and nothing said so. Verified before removal that no
    // registered tool relied on that fallback.
    var category: String {
        return nativeTool.category
    }
    
    /// Natively bridges the parameter schema without JSON hacks!
    var parameters: ToolParameters {
        return nativeTool.parameterSchema
    }
    
    /// The DEFAULT confirmation setting a tool carries when it first appears in the Tool Library.
    ///
    /// A default, not a gate: `Tool.requiresConfirmation` on the profile is what the executor
    /// reads, and the user's choice always wins. This only decides where a freshly-offered tool
    /// starts.
    var requiresConfirmation: Bool {
        // Strictly read-only tools: they alter no state and execute no caller-supplied code.
        //
        // `fs_watch_folder` was in this list until 2026-08-01 and does not belong: its `start`
        // action opens a file descriptor and arms a dispatch source that lives until something
        // stops it, which is state by any reading. `HITLRiskTier.classify` has always called it
        // `.moderate`, alongside `write_file` and `move_file`, so the app was describing the same
        // tool two different ways depending on which code path you asked. Only `list` is
        // read-only, and the list is per-TOOL, not per-action.
        let safeTools: Set<String> = [
            "list_directory",
            "read_file",
            "get_system_stats",
            "fs_smart_search",
            "spotlight_search",
            "fs_read_metadata",
            "read_file_metadata",
            "project_tree",
            "codebase_map",
            "glob_files",
            "find_definition",
            "file_overview",
            "code_search_text",
            "code_search_symbol",
            "code_search_files",
            "diff_files",
            "git",
            "git_tool",
            "get_task_output",
            "command_output",
            "stop_background_task",
            "command_stop"
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
        // Built from `NativeToolCatalog`, which is also what `AgentConnect.resolveNativeTool`
        // reads. Before 2026-07-31 this was ~90 lines of `registerNative(…)` — a second
        // hand-maintained copy of the tool list, and the source of every tool bug the audit
        // found. Registration is now a PROJECTION: a tool appears here because its catalogue
        // entry says `.library`, not because someone remembered to add a line.
        for entry in NativeToolCatalog.libraryTools {
            let tool = entry.executable()
            toolRegistry[tool.name] = tool
        }
        // Tagged + broken down so one startup line proves WHICH projection ran, not just that
        // one did. A bare count cannot distinguish "the catalogue shrank" from "the projection
        // filtered wrongly" — the exact ambiguity that let 25 tools sit invisible for months.
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

    // `execute(name:arguments:)` was removed 2026-07-31: it was called by nothing. Every real
    // tool call goes through `AgentTool.run` at `ToolExecutionMediator`, resolved by
    // `AgentConnect.resolveNativeTool`. Its presence made this type read as a second execution
    // engine competing with that one, when it is a CATALOGUE — it answers "what tools exist and
    // how should they be displayed", not "run this".
}
