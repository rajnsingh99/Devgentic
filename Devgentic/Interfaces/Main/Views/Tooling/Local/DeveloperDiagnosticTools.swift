//
//  DeveloperDiagnosticTools.swift
//  Devgentic
//

import Foundation
import os

private let logger = DGLogger(category: "DeveloperDiagnostics")

struct ManageProcessesTool: DevgenticTool {
    let name = "manage_processes"
    let category = "Developer & Diagnostics"
    let description = "Lists the top processes by CPU and memory. Killing a process is a separate tool."

    struct Arguments: Decodable, Sendable {
        let action: String?
        let target: String?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action ('list_top'). Optional — listing is the only action."),
                ("target", "string", "Unused here; killing a process is the `kill_process` tool.")
            ],
            required: []
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // `kill` was an action here until 2026-07-31. Listing processes is something an agent does
        // constantly while diagnosing; `kill -9` is irreversible and cannot be caught by the
        // target, so unsaved work is simply gone. One `requiresConfirmation` could not cover both
        // — prompting on every listing is what teaches a user to approve without reading.
        if let action = arguments.action, action == "kill" {
            return "Error: 'kill' has moved to the `kill_process` tool, so it can carry its own "
                + "confirmation setting. Call that tool with the pid or process name."
        }
        guard arguments.action == nil || arguments.action == "list_top" else {
            return "Error: Unknown action '\(arguments.action ?? "")'. This tool only lists processes."
        }

        let process = Process()
        // A constant command — no model input reaches this string (§3.5).
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "ps -eo pid,pcpu,pmem,comm | sort -k 2 -nr | head -n 10"]

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

/// Terminating a process, as its own tool — split from `manage_processes` on 2026-07-31.
///
/// `SIGKILL` cannot be caught, blocked or ignored by the target, so there is no cleanup and no
/// save. That is not the same kind of act as listing processes, and it should not inherit the same
/// confirmation setting. Classified `.destructive` in `HITLRiskTier`.
struct KillProcessTool: DevgenticTool {
    let name = "kill_process"
    let category = "Developer & Diagnostics"
    let description = "Force-terminates a process by PID or name (SIGKILL). Irreversible — unsaved work in that process is lost."

    struct Arguments: Decodable, Sendable {
        let target: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("target", "string", "Process ID (numeric) or process name to terminate.")
            ],
            required: ["target"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let target = arguments.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return "Error: 'target' must not be empty." }

        let process = Process()
        if let pid = Int(target) {
            // ⚠️ A pid must be POSITIVE. In POSIX `kill`, a non-positive pid is not a process:
            //   -1  → every process the user has permission to signal (the whole login session)
            //    0  → every process in the caller's process group (this app)
            //   -N  → every process in process group N
            // and `--` — added here so a process NAME beginning with `-` reaches the argv as a
            // target rather than a flag (invariant 12) — is exactly what makes `-1` unambiguously
            // a *target* instead of a malformed signal. The separator that fixes option injection
            // is what arms this, so the two belong together: keep `--`, and reject the pids that
            // are not one process. `target: "-1"` was a session-wide SIGKILL. (2026-07-31)
            guard pid > 0 else {
                logger.error("[KILLPROC] ⚠️ refused non-positive pid '\(target)' — this would have signalled a process GROUP (0 = this app's own group, -1 = every process the user owns), not one process. No signal sent.")
                return "Error: '\(target)' is not a process id. A pid must be positive — "
                    + "0 and negative values signal whole process groups (or every process you "
                    + "own), which this tool will not do. Pass a specific pid, or a process name."
            }
            process.executableURL = URL(fileURLWithPath: "/bin/kill")
            process.arguments = ["-9", "--", String(pid)]
        } else {
            // A name, not a number. `--` keeps a leading `-` from being read as a killall flag.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["-9", "--", target]
        }

        do {
            let run = try ProcessRunner.run(process)
            guard run.succeeded else {
                let detail = run.standardError.isEmpty ? run.standardOutput : run.standardError
                return "Error: could not terminate '\(target)' (exit \(run.exitCode))\n\(detail)"
            }
            return "Terminated '\(target)'."
        } catch {
            return "Error executing process command: \(error)"
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
