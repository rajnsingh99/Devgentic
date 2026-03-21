//
//  GitIntegrationTool.swift
//  Devgentic
//

import Foundation

// MARK: - Git Tool

/// Result of resolving a git action to a command string.
enum GitCommandResolution {
    case command(String)
    case error(String)
}

/// Pure logic for building git commands from action + args. Extracted for testability.
enum GitCommandBuilder {
    static func resolve(action: String, repoPath: String, extraArgs: String) -> GitCommandResolution {
        switch action {
        case "status":
            return .command("git -C \"\(repoPath)\" status --short")
        case "log":
            let logArgs = extraArgs.isEmpty ? "-n 10 --oneline" : extraArgs
            return .command("git -C \"\(repoPath)\" log \(logArgs)")
        case "diff":
            return .command("git -C \"\(repoPath)\" diff \(extraArgs)")
        case "branch":
            return .command("git -C \"\(repoPath)\" branch -a \(extraArgs)")
        case "stash_list":
            return .command("git -C \"\(repoPath)\" stash list")
        case "blame":
            guard !extraArgs.isEmpty else {
                return .error("Error: 'args' must contain the filename for blame.")
            }
            return .command("git -C \"\(repoPath)\" blame \(extraArgs)")
        case "show":
            let showArgs = extraArgs.isEmpty ? "HEAD" : extraArgs
            return .command("git -C \"\(repoPath)\" show \(showArgs) --stat")
        default:
            return .error("Error: Unknown git action '\(action)'. Use status/log/diff/branch/stash_list/blame/show.")
        }
    }
}

struct GitTool: DevgenticTool {
    let name = "git_tool"
    let category = "Developer & Diagnostics"
    let description = "Performs Git operations with structured output: status, log, diff, branch, stash, and blame."

    struct Arguments: Decodable, Sendable {
        let action: String
        let path: String?
        let args: String?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            var foundAction: String? = nil
            for key in ["action", "command", "cmd", "op"] {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundAction = val
                    break
                }
            }
            guard let a = foundAction else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'action'"))
            }
            self.action = a
            self.path = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "path")!))
            self.args = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "args")!))
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Git action: 'status', 'log', 'diff', 'branch', 'stash_list', 'blame', 'show'"),
                ("path", "string", "Repository path (default: current directory)"),
                ("args", "string", "Additional arguments (e.g., '-n 5' for log, filename for blame)")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Git \(arguments.action)",
            operations: [["action": arguments.action]]
        )

        let repoPath = (arguments.path as NSString?)?.expandingTildeInPath ?? FileManager.default.currentDirectoryPath
        let extraArgs = arguments.args ?? ""

        let resolution = GitCommandBuilder.resolve(action: arguments.action, repoPath: repoPath, extraArgs: extraArgs)
        let gitCommand: String
        switch resolution {
        case .command(let cmd):
            gitCommand = cmd
        case .error(let msg):
            return "\(msg) (Audit Ref: \(logID))"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", gitCommand]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let errOutput = String(data: errData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 && !errOutput.isEmpty {
                return "Git error:\n\(errOutput)\n(Audit Ref: \(logID))"
            }

            let maxOutput = 6000
            let result = output.count > maxOutput ? String(output.prefix(maxOutput)) + "\n...[Truncated]" : output

            return "git \(arguments.action):\n\(result)\n(Audit Ref: \(logID))"
        } catch {
            return "Error: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}
