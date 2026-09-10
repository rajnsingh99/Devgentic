// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  NativeSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  Updated for Robust JSON Parsing & Schema Injection.
//

@preconcurrency import Foundation
import AppKit
import os

private let logger = DGLogger(category: "NativeSystemTools")

// MARK: - Terminal Tool

struct TerminalTool: DevgenticTool {
    let name = "execute_shell"
    let category = "System & Shell"
    let description = "Executes a non-interactive ZSH shell command on the host. Do not use sudo or interactive commands."
    // #19: a successful command can legitimately emit stderr beginning with "error" (tsc,
    // git, a failing build) — that's a result, not a tool failure. Opt out of content-sniffing.
    let outputMayContainErrorText = true
    
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
        // Deliberately NOT wrapped in do/catch. This tool sets `outputMayContainErrorText`,
        // which switches off the mediator's output sniffing, so a returned string can never
        // be classified as a failure — throwing is the ONLY channel a tool-level failure has.
        // The previous `catch { return "Command failed: …" }` closed it, and "Command failed:"
        // does not even match the sniffer's "error"-prefix shape, so a failure to launch the
        // shell at all was recorded as a successful tool call.
        //
        // A stateful conversation ID persists `cd` across calls; bot / legacy mode gets an
        // ephemeral one, which simply means no directory memory.
        let sessionID = conversationID ?? UUID()
        return try await ShellSessionManager.shared.execute(command: arguments.command, conversationID: sessionID)
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
        // Wait for actual completion to report success/failure accurately
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: arguments.bundle_identifier) else {
                    continuation.resume(returning: "Error: App with bundle ID '\(arguments.bundle_identifier)' not found.")
                    return
                }

                let config = NSWorkspace.OpenConfiguration()
                config.activates = true

                NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                    if let error = error {
                        continuation.resume(returning: "Error launching app: \(error.localizedDescription)")
                    } else {
                        continuation.resume(returning: "Successfully launched \(app?.localizedName ?? arguments.bundle_identifier)")
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
        return await MainActor.run {
            var errorInfo: NSDictionary?

            // Both failure paths are prefixed "Error:" so `ToolExecutionMediator.isSemanticFailure`
            // actually classifies them. They previously read "Failed to init script." and
            // "AppleScript Error: …", and the sniffer requires the word "error" at the START of
            // the output followed by `:` or whitespace — so a script that failed to compile, or
            // one that threw, was reported accurately and then recorded as a SUCCESSFUL tool
            // call. The agent went on to reason about a result that never existed.
            //
            // This is the same defect as `git_tool`'s "Git error:" and `diff_files`'s
            // "Diff error:", both fixed for the same reason: the detection was right and the
            // prefix missed by one word.
            guard let scriptObject = NSAppleScript(source: arguments.script) else {
                logger.error("[APPLESCRIPT] NSAppleScript(source:) returned nil — the script could not be compiled, so nothing ran. Reported to the model as a failure.")
                return "Error: the AppleScript could not be compiled. Check for unbalanced quotes, "
                    + "parentheses or `tell` blocks."
            }

            let descriptor = scriptObject.executeAndReturnError(&errorInfo)

            if let err = errorInfo {
                // The raw NSDictionary dump is unreadable and unactionable. AppleScript supplies
                // a human message and an error number; surface those and keep the rest out.
                let message = (err[NSAppleScript.errorMessage] as? String)
                    ?? (err[NSAppleScript.errorBriefMessage] as? String)
                    ?? "\(err)"
                let number = (err[NSAppleScript.errorNumber] as? Int).map { " (error \($0))" } ?? ""
                logger.error("[APPLESCRIPT] execution failed\(number): \(message) — reported to the model as a failure; no result was produced.")
                return "Error: AppleScript failed\(number) — \(message)"
            }

            return descriptor.stringValue ?? descriptor.description
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
            let free = Double(vmStats.free_count) * Double(vm_page_size) / 1024 / 1024 / 1024
            memInfo = String(format: ", Free Memory: %.2f GB", free)
        }
        
        return "OS: \(osVersion), User: \(userName)\(memInfo)"
    }
}
