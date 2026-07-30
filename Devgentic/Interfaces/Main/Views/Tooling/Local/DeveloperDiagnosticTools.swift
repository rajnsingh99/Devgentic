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
            // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe
            // only after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
            let output = try ProcessRunner.run(process).standardOutput
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

        // `scheme`, `project` and `file_path` are model-supplied and used to be interpolated
        // into a `zsh -c` string inside double quotes. A scheme name containing a double quote
        // closed it and the rest ran as shell syntax. `scheme` is the worst of the three: it is
        // a NAME, not a path, so no existence check could ever have blocked it — the `guard let`
        // above is a nil check and nothing more. They are argv elements now; see `xcodeRun`.
        case "build":
            guard let scheme = arguments.scheme else {
                throw NSError(domain: "XcodeOrchestratorTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "'scheme' is required for the 'build' action."])
            }
            return try await xcodeRun(Self.xcodebuild,
                                      Self.projectArgs(arguments.project) + ["-scheme", scheme, "build"],
                                      tailLines: 30)

        case "test":
            guard let scheme = arguments.scheme else {
                throw NSError(domain: "XcodeOrchestratorTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "'scheme' is required for the 'test' action."])
            }
            return try await xcodeRun(Self.xcodebuild,
                                      Self.projectArgs(arguments.project) + ["-scheme", scheme, "test"],
                                      tailLines: 50)

        case "list_schemes":
            return try await xcodeRun(Self.xcodebuild, Self.projectArgs(arguments.project) + ["-list"])

        case "open_file":
            guard let filePath = arguments.file_path else {
                throw NSError(domain: "XcodeOrchestratorTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "'file_path' is required for the 'open_file' action."])
            }
            let expandedPath = (filePath as NSString).expandingTildeInPath
            let lineArgs = arguments.line.map { ["--line", String($0)] } ?? []
            return try await xcodeRun(Self.xed, lineArgs + [expandedPath])

        case "read_build_errors":
            let cmd = """
            find ~/Library/Developer/Xcode/DerivedData -name "*.xcactivitylog" -maxdepth 5 -type f -print0 | xargs -0 ls -t 2>/dev/null | head -1 | xargs -I{} gunzip -c {} 2>/dev/null | strings | grep -E "(error:|warning:)" | head -30
            """
            return try await xcodeShell(cmd)

        default:
            throw NSError(domain: "XcodeOrchestratorTool", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unknown action '\(arguments.action)'. Valid actions: clear_derived_data, build, test, list_schemes, open_file, read_build_errors."])
        }
    }

    private static let xcodebuild = "/usr/bin/xcodebuild"
    private static let xed = "/usr/bin/xed"

    private static func projectArgs(_ project: String?) -> [String] {
        guard let project, !project.isEmpty else { return [] }
        return ["-project", project]
    }

    /// Runs a developer tool DIRECTLY, never through a shell — the argv form of what
    /// `xcodeShell` used to build by interpolation.
    ///
    /// `tailLines` replaces the `| tail -30` the pipeline used to do. Applied to the COMBINED
    /// output, which favours stderr when there is any, and that is the right bias here:
    /// `xcodebuild` writes progress to stdout and diagnostics to stderr, so the last N lines of
    /// the combination are the errors when a build fails and the summary when it does not.
    private func xcodeRun(_ executable: String, _ argv: [String], tailLines: Int? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argv

        do {
            let run = try ProcessRunner.run(process)
            var text = run.combinedOutput

            if let tailLines {
                let lines = text.components(separatedBy: "\n")
                if lines.count > tailLines {
                    text = lines.suffix(tailLines).joined(separator: "\n")
                }
            }

            let maxOutput = 6000
            return text.count > maxOutput ? String(text.prefix(maxOutput)) + "\n...[Truncated]" : text
        } catch {
            // Process couldn't launch — a genuine operational failure (throw, don't return,
            // so the opted-out tool's real failures are still counted; #19).
            throw error
        }
    }

    /// Shell form, kept for `read_build_errors` ALONE.
    ///
    /// That action is a fixed `find | xargs | gunzip | strings | grep` pipeline with no
    /// interpolation of any kind, so there is nothing for a caller to inject into. Every other
    /// action moved to `xcodeRun`. Do not route a new action through here without checking that
    /// its command is a constant.
    private func xcodeShell(_ cmd: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]

        do {
            // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe
            // only after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
            //
            // Before the migration this site pointed BOTH streams at one pipe, so the single
            // read it did returned stdout and stderr together. `xcodebuild` writes compiler
            // diagnostics to stderr — reading only
            // stdout hands the agent a build result with the errors stripped out, which is
            // worse than the hang: it reports a clean build that did not happen.
            //
            // stderr is appended AFTER stdout is truncated, not before. A verbose build
            // easily exceeds 6000 chars of stdout, and folding the streams first would push
            // the diagnostics — the only part worth reading — past the cap.
            let run = try ProcessRunner.run(process)
            let maxOutput = 6000
            let head = run.standardOutput.count > maxOutput
                ? String(run.standardOutput.prefix(maxOutput)) + "\n...[Truncated]"
                : run.standardOutput
            let result = run.standardError.isEmpty ? head : head + "\n[stderr]\n" + run.standardError
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

        do {
            // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe
            // only after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
            let output = try ProcessRunner.run(process).standardOutput
            return "Power State:\n\(output)"
        } catch {
            return "Error retrieving power state: \(error)"
        }
    }
}
