// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AutomationTools.swift
//  Devgentic
//
//  Created by Raj Singh.
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
        
        
        do {
            // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe
            // only after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
            //
            // combinedOutput, not standardOutput: this site set `standardError = outPipe`,
            // so its single read returned both. The `shortcuts` CLI reports a missing or
            // failed shortcut on stderr — reading stdout alone reports "Shortcut executed"
            // with empty output for a shortcut that never ran.
            let output = try ProcessRunner.run(process).combinedOutput
            return "Shortcut executed. Output:\n\(output)"
        } catch {
            return "Error running shortcut: \(error.localizedDescription)"
        }
    }
}
