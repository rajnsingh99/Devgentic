// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    /// Never surfaced in the Tool Library — this tool is injected by `AgentConnect` for the
    /// run itself, not chosen by a user. The category is required by `DevgenticTool` and
    /// exists so no tool can silently fall into a default bucket.
    let category = "Internal"
    let description = "Writes or updates the project-level context file (.devgentic/context.md). Use this to persist architecture patterns, naming conventions, build commands, and key file locations you discover. The content is injected into your system prompt on every subsequent message."
    let projectPath: String

    // MARK: - Initialization

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // MARK: - Type Definitions

    /// Content argument aliases, IN PRIORITY ORDER — first match wins, exactly as the decoder
    /// below walks them.
    ///
    /// ⚠️ The approval banner reads the proposed content with this same list. A preview that
    /// accepted a key the decoder does not (or picked a different one when several are present)
    /// would render a confident diff of text the tool is not about to write.
    static let contentArgumentAliases = ["content", "text", "body", "data", "markdown", "context"]

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
            let keys = UpdateProjectContextTool.contentArgumentAliases

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

    // MARK: - Target

    /// The file this tool writes, for a given project.
    ///
    /// ⚠️ The approval banner previews the change by reading THIS path off disk and diffing it
    /// against the proposed content. A second, separately-derived copy of the path would let the
    /// banner show a confident diff of one file while the tool overwrote another — the worst
    /// possible failure for a control whose entire job is "what you approve is what runs".
    /// One definition; `call` uses it too.
    static func contextFilePath(inProject projectPath: String) -> String {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".devgentic")
            .appendingPathComponent("context.md")
            .path
    }

    // MARK: - Execution

    func call(arguments: Arguments) async throws -> String {
        let contextFile = URL(fileURLWithPath: Self.contextFilePath(inProject: projectPath))
        let devgenticDir = contextFile.deletingLastPathComponent()

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
