//
//  UpdateProjectContextTool.swift
//  Devgentic
//
//  Tool that allows the agent to persist project-level context to
//  `.devgentic/context.md`. This file is automatically injected into
//  the system prompt on subsequent messages, giving the agent durable
//  memory about architecture patterns, naming conventions, build
//  commands, and key file locations.
//

import Foundation

struct UpdateProjectContextTool: DevgenticTool {

    // MARK: - Properties

    let name = "update_project_context"
    let description = "Writes or updates the project-level context file (.devgentic/context.md). Use this to persist architecture patterns, naming conventions, build commands, and key file locations you discover. The content is injected into your system prompt on every subsequent message."
    let projectPath: String

    // MARK: - Initialization

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // MARK: - Type Definitions

    struct Arguments: Decodable, Sendable {
        let content: String

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            var foundContent: String? = nil
            let keys = ["content", "text", "body", "data", "markdown", "context"]

            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundContent = val
                    break
                }
            }

            guard let validContent = foundContent else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'content'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }

            self.content = validContent
        }
    }

    // MARK: - Schema

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("content", "string", "The full markdown content for the project context file. This overwrites the existing file — include all relevant information, not just new findings.")
            ],
            required: ["content"]
        )
    }

    // MARK: - Execution

    func call(arguments: Arguments) async throws -> String {
        let devgenticDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".devgentic")
        let contextFile = devgenticDir.appendingPathComponent("context.md")

        do {
            // Ensure .devgentic/ directory exists
            if !FileManager.default.fileExists(atPath: devgenticDir.path) {
                try FileManager.default.createDirectory(at: devgenticDir, withIntermediateDirectories: true)
            }

            // Write atomically
            guard let data = arguments.content.data(using: .utf8) else {
                return "Error: Could not encode content as UTF-8."
            }
            try data.write(to: contextFile, options: .atomic)

            return "Successfully updated project context at \(contextFile.path) (\(arguments.content.count) chars). This content will be included in your system prompt on the next message."
        } catch {
            return "Error writing project context: \(error.localizedDescription)"
        }
    }
}
