//
//  DeveloperDiagnosticTools.swift
//  Devgentic
//

import Foundation

struct ManageProcessesTool: DevgenticTool {
    let name = "manage_processes"
    let category = "Developer & Diagnostics"
    let description = "Lists top processes or kills a specific process by name/PID."
    
    struct Arguments: Decodable, Sendable {
        let action: String
        let target: String?
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action ('list_top', 'kill')"),
                ("target", "string", "Process ID or Name to kill (required for 'kill')")
            ],
            required: ["action"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Process management: \(arguments.action)",
            operations: [["action": arguments.action]]
        )
        
        let process = Process()
        let outPipe = Pipe()
        process.standardOutput = outPipe
        
        if arguments.action == "list_top" {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "ps -eo pid,pcpu,pmem,comm | sort -k 2 -nr | head -n 10"]
        } else if arguments.action == "kill" {
            guard let target = arguments.target else {
                return "Error: target required for kill. (Audit Ref: \(logID))"
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            if let pid = Int(target) {
                process.executableURL = URL(fileURLWithPath: "/bin/kill")
                process.arguments = ["-9", String(pid)]
            } else {
                process.arguments = ["-9", target]
            }
        } else {
            return "Error: Unknown action. (Audit Ref: \(logID))"
        }
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return "Result:\n\(output)\n(Audit Ref: \(logID))"
        } catch {
            return "Error executing process command: \(error) (Audit Ref: \(logID))"
        }
    }
}

struct XcodeOrchestratorTool: DevgenticTool {
    let name = "xcode_orchestrator"
    let category = "Developer & Diagnostics"
    let description = "Performs Xcode tasks like clearing DerivedData."
    
    struct Arguments: Decodable, Sendable {
        let action: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action to perform (e.g., 'clear_derived_data')")
            ],
            required: ["action"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Xcode Orchestrator: \(arguments.action)",
            operations: [["action": arguments.action]]
        )
        
        if arguments.action == "clear_derived_data" {
            let path = NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
            do {
                try FileManager.default.removeItem(atPath: path)
                return "Cleared DerivedData successfully at \(path). (Audit Ref: \(logID))"
            } catch {
                if (error as NSError).code == NSFileNoSuchFileError {
                   return "DerivedData already clean/empty. (Audit Ref: \(logID))"
                }
                return "Error clearing DerivedData: \(error) (Audit Ref: \(logID))"
            }
        }
        return "Unknown action or not implemented yet. (Audit Ref: \(logID))"
    }
}

struct GetPowerStateTool: DevgenticTool {
    let name = "get_power_state"
    let category = "Developer & Diagnostics"
    let description = "Retrieves battery percentage and charging state."
    
    struct Arguments: Decodable, Sendable {}
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Get Power State",
            operations: []
        )
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return "Power State:\n\(output)\n(Audit Ref: \(logID))"
        } catch {
            return "Error retrieving power state: \(error) (Audit Ref: \(logID))"
        }
    }
}
