//
//  AutomationTools.swift
//  Devgentic
//

import Foundation

struct RunMacShortcutTool: DevgenticTool {
    let name = "run_mac_shortcut"
    let category = "System Automation"
    let description = "Triggers existing macOS Shortcuts by name to execute custom automations."
    
    struct Arguments: Decodable, Sendable {
        let shortcut_name: String
        let input_text: String?
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("shortcut_name", "string", "The exact name of the macOS Shortcut to run."),
                ("input_text", "string", "Optional input text to pass to the shortcut.")
            ],
            required: ["shortcut_name"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Ran shortcut: \(arguments.shortcut_name)",
            operations: [
                ["shortcut_name": arguments.shortcut_name]
            ]
        )
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", arguments.shortcut_name]
        
        if let input = arguments.input_text, !input.isEmpty {
            let pipe = Pipe()
            process.standardInput = pipe
            if let data = input.data(using: .utf8) {
                pipe.fileHandleForWriting.write(data)
                try? pipe.fileHandleForWriting.close()
            }
        }
        
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            return "Shortcut executed. Output:\n\(output)\n(Audit Ref: \(logID))"
        } catch {
            return "Error running shortcut: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}
