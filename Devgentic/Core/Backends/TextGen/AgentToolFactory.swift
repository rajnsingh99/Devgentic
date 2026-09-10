// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AgentToolFactory.swift
//  Devgentic
//
//  Turns a concrete `DevgenticTool` into the type-erased `AgentTool` the executor runs.
//
//  This was `AgentConnect.wrapTool`, a private method, which meant the only way to obtain an
//  `AgentTool` was to be inside `AgentConnect` — which is why the tool list had to be a switch
//  there, and why a second list had to exist elsewhere for the UI. Lifting it out is what lets
//  `NativeToolCatalog` be the single source of truth for both.
//
//  It is a free enum rather than a method because it uses no instance state: it reads the tool's
//  own name, description and schema, and closes over the concrete `T` so `T.Arguments` can be
//  decoded at call time. That capture of `T` is the whole reason a catalogue entry has to store a
//  CLOSURE rather than an `any DevgenticTool` — type erasure would lose the argument type.
//

import Foundation

/// Same category as the `logToolExecution` declared file-private in `AgentConnect`,
/// `ReActAgentExecutor` and `ToolExecutionMediator`, so argument-decoding failures keep landing
/// in the one stream an operator greps for tool problems.
private let logToolExecution = DGLogger(category: "ToolExecution")

enum AgentToolFactory {

    /// Wraps a concrete tool, erasing its `Arguments` type behind a JSON-decoding closure.
    static func wrap<T: DevgenticTool>(
        _ tool: T,
        requiresConfirmation: Bool,
        timeout: TimeInterval? = nil,
        timeoutMessage: String? = nil
    ) -> AgentTool {
        let toolName = tool.name
        let requiredKeys = tool.parameterSchema.required

        return AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameterSchema,
            requiresConfirmation: requiresConfirmation,
            timeout: timeout,
            timeoutMessage: timeoutMessage,
            contentMayLookLikeError: tool.outputMayContainErrorText
        ) { dataArgs in
            let args: T.Arguments
            do {
                args = try JSONDecoder().decode(T.Arguments.self, from: dataArgs)
            } catch let decodingError as DecodingError {
                // The raw payload and the required keys are both in the message on purpose: a
                // decoding failure is the model's mistake to fix, and it can only fix it if the
                // observation says what it sent and what was expected.
                let paramHint = requiredKeys.isEmpty ? "" : " Required parameters: [\(requiredKeys.joined(separator: ", "))]."
                let rawJSON = String(data: dataArgs, encoding: .utf8) ?? "{}"

                logToolExecution.error("❌ Tool Argument Decoding Failed. Tool: \(toolName). Expected Keys: \(requiredKeys). Raw Payload: \(rawJSON). Error: \(decodingError.localizedDescription)")

                throw ToolArgumentError(
                    toolName: toolName,
                    detail: "Argument decoding failed for '\(toolName)'.\(paramHint) Received: \(rawJSON). Underlying: \(decodingError.localizedDescription)"
                )
            }
            return try await tool.execute(arguments: args)
        }
    }

    /// Re-wraps an already-erased `AgentTool` (the MCP path) so it can carry different
    /// per-profile confirmation and timeout settings. Separate overload because the generic one
    /// cannot infer `T` for a tool that has already lost its argument type.
    static func rewrap(
        _ tool: AgentTool,
        requiresConfirmation: Bool,
        timeout: TimeInterval? = nil,
        timeoutMessage: String? = nil
    ) -> AgentTool {
        return AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters,
            requiresConfirmation: requiresConfirmation,
            timeout: timeout,
            timeoutMessage: timeoutMessage,
            contentMayLookLikeError: tool.contentMayLookLikeError,
            run: tool.run
        )
    }
}
