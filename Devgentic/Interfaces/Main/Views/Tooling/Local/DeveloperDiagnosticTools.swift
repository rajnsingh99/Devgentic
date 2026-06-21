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
    // #19: build/test/read_build_errors return raw compiler output that routinely begins with
    // "error:" — surfacing those IS the tool's job, not a failure. Opt out of content-sniffing.
    let outputMayContainErrorText = true

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
        // #19: this tool opts out of content-sniffing (`outputMayContainErrorText`) because its
        // build/test/read_build_errors OUTPUT legitimately contains "error:". So its OWN
        // operational / argument failures must THROW (not return an "Error:" string) — otherwise
        // they'd be misread as success and never counted by the circuit breaker.
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
                throw NSError(domain: "XcodeOrchestratorTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to clear DerivedData: \(error.localizedDescription)"])
            }

        case "build":
            guard let scheme = arguments.scheme else {
                throw NSError(domain: "XcodeOrchestratorTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "'scheme' is required for the 'build' action."])
            }
            var cmd = "xcodebuild -scheme \"\(scheme)\" build 2>&1 | tail -30"
            if let project = arguments.project {
                cmd = "xcodebuild -project \"\(project)\" -scheme \"\(scheme)\" build 2>&1 | tail -30"
            }
            return try await xcodeShell(cmd)

        case "test":
            guard let scheme = arguments.scheme else {
                throw NSError(domain: "XcodeOrchestratorTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "'scheme' is required for the 'test' action."])
            }
            var cmd = "xcodebuild -scheme \"\(scheme)\" test 2>&1 | tail -50"
            if let project = arguments.project {
                cmd = "xcodebuild -project \"\(project)\" -scheme \"\(scheme)\" test 2>&1 | tail -50"
            }
            return try await xcodeShell(cmd)

        case "list_schemes":
            var cmd = "xcodebuild -list 2>&1"
            if let project = arguments.project {
                cmd = "xcodebuild -project \"\(project)\" -list 2>&1"
            }
            return try await xcodeShell(cmd)

        case "open_file":
            guard let filePath = arguments.file_path else {
                throw NSError(domain: "XcodeOrchestratorTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "'file_path' is required for the 'open_file' action."])
            }
            let expandedPath = (filePath as NSString).expandingTildeInPath
            var cmd = "xed \"\(expandedPath)\""
            if let line = arguments.line {
                cmd = "xed --line \(line) \"\(expandedPath)\""
            }
            return try await xcodeShell(cmd)

        case "read_build_errors":
            let cmd = """
            find ~/Library/Developer/Xcode/DerivedData -name "*.xcactivitylog" -maxdepth 5 -type f -print0 | xargs -0 ls -t 2>/dev/null | head -1 | xargs -I{} gunzip -c {} 2>/dev/null | strings | grep -E "(error:|warning:)" | head -30
            """
            return try await xcodeShell(cmd)

        default:
            throw NSError(domain: "XcodeOrchestratorTool", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unknown action '\(arguments.action)'. Valid actions: clear_derived_data, build, test, list_schemes, open_file, read_build_errors."])
        }
    }

    private func xcodeShell(_ cmd: String) async throws -> String {
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
            // Process couldn't launch — a genuine operational failure (throw, don't return,
            // so the opted-out tool's real failures are still counted; #19).
            throw error
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
