//
//  AskUserTool.swift
//  Devgentic
//
//  Created by Devgentic Architect
//
//  A system tool that allows the Agent to ask the user for clarification mid-execution.
//  Uses the ExecutionSuspensionService to pause the cognitive loop and wait for user input.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "AskUserTool")

/// A tool that pauses agent execution and asks the user a question.
/// The agent's cognitive loop is suspended until the user responds via the UI.
///
/// Integration:
/// - The ReActAgentExecutor intercepts this tool BEFORE normal dispatch.
/// - It yields a `.requestClarification(question:)` stream event.
/// - The UI renders an input card for the user.
/// - The user's response is returned as the tool's observation in the scratchpad.
struct AskUserTool: DevgenticTool {

    // MARK: - Properties

    let name = "ask_user"
    /// Never surfaced in the Tool Library — this tool is injected by `AgentConnect` for the
    /// run itself, not chosen by a user. The category is required by `DevgenticTool` and
    /// exists so no tool can silently fall into a default bucket.
    let category = "Internal"
    let description = "Asks the user a clarifying question and waits for their response."

    /// Whether to advertise the optional `options`/`multiline` fields in the schema. Disabled for
    /// small/tiny local models, which tend to fumble the extra fields — truncating `question` to
    /// dump the subject into `options`, or emitting `multiline` as a string. Capable models keep them.
    let richFields: Bool

    init(richFields: Bool = true) {
        self.richFields = richFields
    }

    // MARK: - Type Definitions

    struct Arguments: Decodable, Sendable {
        let question: String

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            // ROBUST PARSING: Accept common aliases
            var foundQuestion: String? = nil
            let keys = ["question", "prompt", "message", "query", "text"]

            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundQuestion = val
                    break
                }
            }

            guard let validQuestion = foundQuestion else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'question'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }

            self.question = validQuestion
        }
    }

    // MARK: - Schema

    var parameterSchema: ToolParameters {
        var properties: [(String, String, String)] = [
            ("question", "string", "The clarifying question to ask the user.")
        ]
        if richFields {
            properties.append(("options", "array", "Optional suggested answers shown as one-tap choice buttons (e.g. [\"Yes\",\"No\"]). Omit for a free-form answer."))
            properties.append(("multiline", "boolean", "Set true when a long / multi-line answer is expected."))
        }
        return SchemaBuilder.object(properties: properties, required: ["question"])
    }

    // MARK: - Execution

    /// NOTE: This is a placeholder. The ReActAgentExecutor intercepts `ask_user` calls
    /// BEFORE they reach this method, using the suspension service instead.
    /// This implementation exists as a safety fallback.
    func call(arguments: Arguments) async throws -> String {
        logger.warning("AskUserTool.call() invoked directly — this should be intercepted by the executor.")
        return "System: The ask_user tool was not handled by the executor. Please provide your response in the next message."
    }
}
