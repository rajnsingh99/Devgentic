//
//  TerminalTool.swift
//  LocalServer
//
//  Created by Raj Singh on 20/09/25.
//

import Foundation

/// An inbuilt tool for executing shell commands on the local machine.
///
/// This tool conforms to the `ExecutableTool` protocol and provides a safe way
/// to run terminal commands, capturing and returning their standard output.
struct TerminalTool: ExecutableTool {
    
    /// The unique programmatic name for this tool.
    var name: String = "execute_shell"
    
    /// A user-friendly description of the tool's capabilities.
    var description: String = "Executes a shell command on the local machine and returns its standard output. Use this for file system operations, running scripts, or system interactions."
    
    /// The schema defining the tool's required input arguments.
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [
            "command": ToolParameterProperty(type: "string", description: "The complete shell command to execute.")
        ],
        required: ["command"]
    )

    /// The core execution logic for the terminal tool.
    /// - Parameter arguments: A dictionary containing the "command" to be executed.
    /// - Returns: The standard output from the executed command as a string.
    /// - Throws: An error if the "command" argument is missing or if the process fails to run.
    func execute(arguments: [String: Any]) async throws -> String {
        guard let command = arguments["command"] as? String else {
            throw NSError(domain: "TerminalToolError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required 'command' argument or argument is not a string."])
        }

        let process = Process()
        let pipe = Pipe()
        
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh") // Using zsh as a common default on macOS.
        
        try process.run()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? "Error: Could not decode command output."
        
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
