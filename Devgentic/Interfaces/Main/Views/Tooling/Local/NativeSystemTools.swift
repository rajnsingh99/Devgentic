//
//  NativeSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//

import Foundation
import AppKit
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - Terminal Tool

struct TerminalTool: OpenFoundationModels.Tool {
    let name = "execute_shell"
    let description = "Executes a shell command (zsh) and returns the output. Useful for checking file details (ls -lh), system state, or running scripts."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let command: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            guard let cmd = props["command"] else { throw GeneratedContentError.missingProperty("command") }
            self.command = try String(cmd)
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
        // Run blocking process in a detached task to avoid freezing the Swift Concurrency pool
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            
            process.standardOutput = pipe
            process.standardError = pipe
            process.arguments = ["-c", arguments.command]
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                if process.terminationStatus == 0 {
                    return output.isEmpty ? "Success (No Output)" : output
                } else {
                    return "Exit Code \(process.terminationStatus): \(output)"
                }
            } catch {
                return "Command failed: \(error.localizedDescription)"
            }
        }.value
    }
}

// MARK: - Open Application Tool

struct OpenApplicationTool: OpenFoundationModels.Tool {
    let name = "open_application"
    let description = "Launches an app by Bundle ID (e.g., 'com.apple.Safari')."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let bundle_identifier: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            guard let val = props["bundle_identifier"] else { throw GeneratedContentError.missingProperty("bundle_identifier") }
            self.bundle_identifier = try String(val)
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

struct RunAppleScriptTool: OpenFoundationModels.Tool {
    let name = "run_applescript"
    let description = "Executes arbitrary AppleScript code."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let script: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            guard let val = props["script"] else { throw GeneratedContentError.missingProperty("script") }
            self.script = try String(val)
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
        await MainActor.run {
            var errorInfo: NSDictionary?
            guard let scriptObject = NSAppleScript(source: arguments.script) else {
                return "Failed to init script."
            }
            let descriptor = scriptObject.executeAndReturnError(&errorInfo)
            if let err = errorInfo {
                return "AppleScript Error: \(err)"
            }
            return descriptor.stringValue ?? descriptor.description
        }
    }
}

// MARK: - Get System Stats Tool

struct GetSystemStatsTool: OpenFoundationModels.Tool {
    let name = "get_system_stats"
    let description = "Returns basic macOS system info."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        init(_ content: GeneratedContent) throws {}
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(name: "Arguments", properties: [])
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
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
            let pageSize = vm_kernel_page_size
            let free = Double(vmStats.free_count) * Double(pageSize) / 1024 / 1024 / 1024
            memInfo = String(format: ", Free Memory: %.2f GB", free)
        }
        
        return "OS: \(osVersion), User: \(userName)\(memInfo)"
    }
}
