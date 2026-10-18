// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FinalAnswerTool.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Signal tool that ends the ReAct loop with the model's composed response; intercepted by
/// ToolExecutionLoop before dispatch. The executor sets the answer as the final thought and the
/// synthesizer's native fast-path surfaces it verbatim.
struct FinalAnswerTool: DevgenticTool {

    // MARK: - Properties

    let name = "final_answer"
    /// Never surfaced in the Tool Library — this tool is injected by `AgentConnect` for the
    /// run itself, not chosen by a user. The category is required by `DevgenticTool` and
    /// exists so no tool can silently fall into a default bucket.
    let category = "Internal"
    let description = """
    Call this tool when you have fully answered the user's request. This is the ONLY \
    way to end a task. Your `answer` is delivered verbatim to the user as markdown. \
    Rules: (1) call it exactly once, as the LAST action. (2) do NOT call any other \
    tool in the same step. (3) if you lack information, use `ask_user` instead — do \
    NOT call `final_answer` with a question.
    """

    // MARK: - Type Definitions

    struct Arguments: Decodable, Sendable {
        let answer: String

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            // ROBUST PARSING: accept common aliases local models fall back to.
            var found: String? = nil
            let keys = ["answer", "response", "content", "text", "message", "final_answer"]

            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    found = val
                    break
                }
            }

            guard let valid = found else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'answer'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }

            self.answer = valid
        }
    }

    // MARK: - Schema

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("answer", "string", "Your complete final response to the user as markdown. This is delivered verbatim — include everything the user needs to see.")
            ],
            required: ["answer"]
        )
    }

    // MARK: - Execution

    /// Placeholder: ToolExecutionLoop intercepts `final_answer` before this method and builds a terminal
    /// observation. Runs only as a safety fallback if interception is misconfigured.
    func call(arguments: Arguments) async throws -> String {
        return arguments.answer
    }
}
