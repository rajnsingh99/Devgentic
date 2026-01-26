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
    let description = "Executes a shell command (zsh) and returns the output. Use strictly for system operations."
    
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
        let process = Process()
        let pipe = Pipe()
        
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", arguments.command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return "Command failed: \(error.localizedDescription)"
        }
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
        await MainActor.run {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: arguments.bundle_identifier) else {
                return "App not found."
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            return "Launched \(arguments.bundle_identifier)"
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
        // NSAppleScript must run on Main Actor usually, or requires careful threading.
        // We use MainActor.run to be safe.
        await MainActor.run {
            var errorInfo: NSDictionary?
            guard let scriptObject = NSAppleScript(source: arguments.script) else {
                return "Failed to init script."
            }
            let descriptor = scriptObject.executeAndReturnError(&errorInfo)
            if let err = errorInfo {
                return "AppleScript Error: \(err)"
            }
            return descriptor.stringValue ?? "Success (No Output)"
        }
    }
}

// MARK: - Get System Stats Tool

struct GetSystemStatsTool: OpenFoundationModels.Tool {
    let name = "get_system_stats"
    let description = "Returns basic macOS system info."
    
    // No arguments needed, but protocol requires an Argument type.
    // We use a dummy struct that accepts empty content.
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        init(_ content: GeneratedContent) throws {}
    }
    
    var parameters: GenerationSchema {
        // Empty schema
        let root = DynamicGenerationSchema(name: "Arguments", properties: [])
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let userName = ProcessInfo.processInfo.fullUserName
        return "OS: \(osVersion), User: \(userName)"
    }
}
