//
//  NativeSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  Updated for Robust JSON Parsing & Schema Injection.
//

import Foundation
import AppKit
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - Terminal Tool

struct TerminalTool: OpenFoundationModels.Tool {
    let name = "execute_shell"
    let description = "Executes a shell command (zsh). Non-interactive. Example: { \"command\": \"ls -lah /tmp\" }"
    
    // NEW: Session Context injected by AgentConnect
    let conversationID: UUID?
    
    init(conversationID: UUID? = nil) {
        self.conversationID = conversationID
    }
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let command: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // ROBUST PARSING: Aliases
            var foundCmd: String? = nil
            let keys = [
                "command", "cmd", "script", "code", "exec",
                "shell_command", "shellCommand", "bash" // CamelCase & Synonyms
            ]
            
            for key in keys {
                if let val = props[key], let str = try? String(val) {
                    foundCmd = str
                    break
                }
            }
            
            guard let cmd = foundCmd else { throw GeneratedContentError.missingProperty("command (checked aliases: \(keys.joined(separator: ", ")))") }
            self.command = cmd
        }
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "command",
                    description: "The shell command to execute.",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Executed shell command",
            operations: [
                ["command": arguments.command, "status": "attempted"]
            ]
        )
        // -------------------------------
        
        do {
            if let id = conversationID {
                // ✅ Stateful Execution via ShellSessionManager
                // Uses the Conversation ID to persist 'cd' changes.
                let output = try await ShellSessionManager.shared.execute(command: arguments.command, conversationID: id)
                return "\(output)\n(Audit Ref: \(logID))"
            } else {
                // Fallback: Stateless Execution (Legacy/Bot Mode)
                let output = try await ShellSessionManager.shared.execute(command: arguments.command, conversationID: UUID()) // Ephemeral ID
                return "\(output)\n(Audit Ref: \(logID))"
            }
        } catch {
            return "Command failed: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    } 
}

// MARK: - Open Application Tool

struct OpenApplicationTool: OpenFoundationModels.Tool {
    let name = "open_application"
    let description = "Launches an app by Bundle ID. Example: { \"bundle_identifier\": \"com.apple.Safari\" }"
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let bundle_identifier: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // ROBUST PARSING: Aliases
            var foundID: String? = nil
            let keys = [
                "bundle_identifier", "app_id", "id", "bundleId",
                "identifier", "bundleID", "appId" // CamelCase & Common Variations
            ]
            
            for key in keys {
                if let val = props[key], let str = try? String(val) {
                    foundID = str
                    break
                }
            }
            
            guard let val = foundID else { throw GeneratedContentError.missingProperty("bundle_identifier (checked aliases: \(keys.joined(separator: ", ")))") }
            self.bundle_identifier = val
        }
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "bundle_identifier",
                    description: "The App Bundle ID.",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Launched App: \(arguments.bundle_identifier)",
            operations: [
                ["app_id": arguments.bundle_identifier, "action": "launch"]
            ]
        )
        // -------------------------------
        
        // Wait for actual completion to report success/failure accurately
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: arguments.bundle_identifier) else {
                    continuation.resume(returning: "Error: App with bundle ID '\(arguments.bundle_identifier)' not found. (Audit Ref: \(logID))")
                    return
                }
                
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                
                NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                    if let error = error {
                        continuation.resume(returning: "Error launching app: \(error.localizedDescription) (Audit Ref: \(logID))")
                    } else {
                        continuation.resume(returning: "Successfully launched \(app?.localizedName ?? arguments.bundle_identifier) (Audit Ref: \(logID))")
                    }
                }
            }
        }
    }
}

// MARK: - Run AppleScript Tool

struct RunAppleScriptTool: OpenFoundationModels.Tool {
    let name = "run_applescript"
    let description = "Executes AppleScript. Example: { \"script\": \"tell application \\\"Finder\\\" to activate\" }"
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let script: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // ROBUST PARSING: Aliases
            var foundScript: String? = nil
            let keys = [
                "script", "code", "source", "applescript", "appleScript", "sourceCode"
            ]
            
            for key in keys {
                if let val = props[key], let str = try? String(val) {
                    foundScript = str
                    break
                }
            }
            
            guard let val = foundScript else { throw GeneratedContentError.missingProperty("script (checked aliases: \(keys.joined(separator: ", ")))") }
            self.script = val
        }
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "script", description: "AppleScript source.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Ran AppleScript",
            operations: [
                ["script_preview": String(arguments.script.prefix(200))]
            ]
        )
        // -------------------------------
        
        return await MainActor.run {
            var errorInfo: NSDictionary?
            guard let scriptObject = NSAppleScript(source: arguments.script) else {
                return "Failed to init script. (Audit Ref: \(logID))"
            }
            let descriptor = scriptObject.executeAndReturnError(&errorInfo)
            if let err = errorInfo {
                return "AppleScript Error: \(err) (Audit Ref: \(logID))"
            }
            return (descriptor.stringValue ?? descriptor.description) + " (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Get System Stats Tool

struct GetSystemStatsTool: OpenFoundationModels.Tool {
    let name = "get_system_stats"
    let description = "Returns basic macOS system info. Example: {}"
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        init(_ content: GeneratedContent) throws {}
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(name: "Arguments", properties: [])
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Retrieved System Stats",
            operations: []
        )
        // -------------------------------
        
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let userName = ProcessInfo.processInfo.fullUserName
        
        // Basic memory info
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics_data_t>.stride / MemoryLayout<integer_t>.stride)
        var vmStats = vm_statistics_data_t()
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_VM_INFO, $0, &size)
            }
        }
        
        var memInfo = ""
        if result == KERN_SUCCESS {
            let pageSize = vm_kernel_page_size
            let free = Double(vmStats.free_count) * Double(pageSize) / 1024 / 1024 / 1024
            memInfo = String(format: ", Free Memory: %.2f GB", free)
        }
        
        return "OS: \(osVersion), User: \(userName)\(memInfo) (Audit Ref: \(logID))"
    }
}
