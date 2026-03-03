//
//  NativeSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  Updated for Robust JSON Parsing & Schema Injection.
//

import Foundation
import AppKit

// MARK: - Terminal Tool

struct TerminalTool: DevgenticTool {
    let name = "execute_shell"
    let category = "System & Shell"
    let description = "Executes a non-interactive ZSH shell command on the host. Do not use sudo or interactive commands."
    
    // NEW: Session Context injected by AgentConnect
    let conversationID: UUID?
    
    init(conversationID: UUID? = nil) {
        self.conversationID = conversationID
    }
    
    struct Arguments: Decodable, Sendable {
        let command: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // ROBUST PARSING: Aliases
            var foundCmd: String? = nil
            let keys = [
                "command", "cmd", "script", "code", "exec",
                "shell_command", "shellCommand", "bash" // CamelCase & Synonyms
            ]
            
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundCmd = val
                    break
                }
            }
            
            guard let cmd = foundCmd else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'command'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }
            
            self.command = cmd
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("command", "string", "The shell command to execute.")
            ],
            required: ["command"]
        )
    }
    
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

struct OpenApplicationTool: DevgenticTool {
    let name = "open_application"
    let category = "System & Shell"
    let description = "Launches a macOS application using its Bundle Identifier."
    
    struct Arguments: Decodable, Sendable {
        let bundle_identifier: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // ROBUST PARSING: Aliases
            var foundID: String? = nil
            let keys = [
                "bundle_identifier", "app_id", "id", "bundleId",
                "identifier", "bundleID", "appId" // CamelCase & Common Variations
            ]
            
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundID = val
                    break
                }
            }
            
            guard let val = foundID else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'bundle_identifier'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }
            
            self.bundle_identifier = val
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("bundle_identifier", "string", "The App Bundle ID.")
            ],
            required: ["bundle_identifier"]
        )
    }
    
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

struct RunAppleScriptTool: DevgenticTool {
    let name = "run_applescript"
    let category = "System & Shell"
    let description = "Executes an AppleScript code block for application or system automation."
    
    struct Arguments: Decodable, Sendable {
        let script: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // ROBUST PARSING: Aliases
            var foundScript: String? = nil
            let keys = [
                "script", "code", "source", "applescript", "appleScript", "sourceCode"
            ]
            
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundScript = val
                    break
                }
            }
            
            guard let val = foundScript else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'script'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }
            
            self.script = val
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("script", "string", "AppleScript source.")
            ],
            required: ["script"]
        )
    }
    
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

struct GetSystemStatsTool: DevgenticTool {
    let name = "get_system_stats"
    let category = "System & Shell"
    let description = "Retrieves basic system metrics including OS version, user, and free memory."
    
    struct Arguments: Decodable, Sendable {
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            _ = try decoder.container(keyedBy: DynamicKey.self)
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }
    
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
