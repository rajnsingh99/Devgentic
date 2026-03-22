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
        let process = Process()
        let outPipe = Pipe()
        process.standardOutput = outPipe

        if arguments.action == "list_top" {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "ps -eo pid,pcpu,pmem,comm | sort -k 2 -nr | head -n 10"]
        } else if arguments.action == "kill" {
            guard let target = arguments.target else {
                return "Error: target required for kill."
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            if let pid = Int(target) {
                process.executableURL = URL(fileURLWithPath: "/bin/kill")
                process.arguments = ["-9", String(pid)]
            } else {
                process.arguments = ["-9", target]
            }
        } else {
            return "Error: Unknown action."
        }

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return "Result:\n\(output)"
        } catch {
            return "Error executing process command: \(error)"
        }
    }
}

struct XcodeOrchestratorTool: DevgenticTool {
    let name = "xcode_orchestrator"
    let category = "Developer & Diagnostics"
    let description = "Performs Xcode tasks: clear DerivedData, build project, run tests, list schemes, open file in Xcode, or read build errors."

    struct Arguments: Decodable, Sendable {
        let action: String
        let scheme: String?
        let project: String?
        let file_path: String?
        let line: Int?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.action = try container.decode(String.self, forKey: DynamicKey(stringValue: "action")!)
            self.scheme = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "scheme")!))
            self.project = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "project")!))
            self.file_path = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "file_path")!))
            self.line = (try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "line")!))
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'clear_derived_data', 'build', 'test', 'list_schemes', 'open_file', 'read_build_errors'"),
                ("scheme", "string", "Xcode scheme name (for build/test)"),
                ("project", "string", "Path to .xcodeproj (for build/test/list_schemes)"),
                ("file_path", "string", "File path to open in Xcode (for open_file)"),
                ("line", "integer", "Line number to jump to (for open_file)")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        switch arguments.action {
        case "clear_derived_data":
            let path = NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
            do {
                try FileManager.default.removeItem(atPath: path)
                return "Cleared DerivedData successfully at \(path)."
            } catch {
                if (error as NSError).code == NSFileNoSuchFileError {
                    return "DerivedData already clean/empty."
                }
                return "Error clearing DerivedData: \(error)"
            }

        case "build":
            guard let scheme = arguments.scheme else {
                return "Error: 'scheme' required for build."
            }
            var cmd = "xcodebuild -scheme \"\(scheme)\" build 2>&1 | tail -30"
            if let project = arguments.project {
                cmd = "xcodebuild -project \"\(project)\" -scheme \"\(scheme)\" build 2>&1 | tail -30"
            }
            return await xcodeShell(cmd)

        case "test":
            guard let scheme = arguments.scheme else {
                return "Error: 'scheme' required for test."
            }
            var cmd = "xcodebuild -scheme \"\(scheme)\" test 2>&1 | tail -50"
            if let project = arguments.project {
                cmd = "xcodebuild -project \"\(project)\" -scheme \"\(scheme)\" test 2>&1 | tail -50"
            }
            return await xcodeShell(cmd)

        case "list_schemes":
            var cmd = "xcodebuild -list 2>&1"
            if let project = arguments.project {
                cmd = "xcodebuild -project \"\(project)\" -list 2>&1"
            }
            return await xcodeShell(cmd)

        case "open_file":
            guard let filePath = arguments.file_path else {
                return "Error: 'file_path' required for open_file."
            }
            let expandedPath = (filePath as NSString).expandingTildeInPath
            var cmd = "xed \"\(expandedPath)\""
            if let line = arguments.line {
                cmd = "xed --line \(line) \"\(expandedPath)\""
            }
            return await xcodeShell(cmd)

        case "read_build_errors":
            let cmd = """
            find ~/Library/Developer/Xcode/DerivedData -name "*.xcactivitylog" -maxdepth 5 -type f -print0 | xargs -0 ls -t 2>/dev/null | head -1 | xargs -I{} gunzip -c {} 2>/dev/null | strings | grep -E "(error:|warning:)" | head -30
            """
            return await xcodeShell(cmd)

        default:
            return "Unknown action '\(arguments.action)'."
        }
    }

    private func xcodeShell(_ cmd: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let maxOutput = 6000
            let result = output.count > maxOutput ? String(output.prefix(maxOutput)) + "\n...[Truncated]" : output
            return result
        } catch {
            return "Error: \(error.localizedDescription)"
        }
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
            return "Power State:\n\(output)"
        } catch {
            return "Error retrieving power state: \(error)"
        }
    }
}
