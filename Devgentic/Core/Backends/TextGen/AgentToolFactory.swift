// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentToolFactory.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Same category as the `logToolExecution` declared file-private in `AgentConnect`,
/// `ReActAgentExecutor` and `ToolExecutionMediator`, so argument-decoding failures keep landing
/// in the one stream an operator greps for tool problems.
private let logToolExecution = DGLogger(category: "ToolExecution")

/// Turns a concrete `DevgenticTool` into the type-erased `AgentTool` the executor runs, so `NativeToolCatalog` can be
/// the single source of truth. A free enum that closes over the concrete `T` so `T.Arguments` can be decoded at call
/// time; that is why catalogue entries store a closure rather than an `any DevgenticTool`.
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
            contentMayLookLikeError: tool.outputMayContainErrorText,
            selfBoundCeiling: tool.selfBoundCeiling
        ) { dataArgs in
            let args: T.Arguments
            do {
                args = try JSONDecoder().decode(T.Arguments.self, from: dataArgs)
            } catch let decodingError as DecodingError {
                // The raw payload and required keys are both in the message so the model can fix a decoding failure, which needs
                // what it sent and what was expected.
                let paramHint = requiredKeys.isEmpty ? "" : " Required parameters: [\(requiredKeys.joined(separator: ", "))]."
                let rawJSON = String(data: dataArgs, encoding: .utf8) ?? "{}"

                // The log carries the payload size and the keys sent, not `rawJSON`: a `write_file` payload is the whole file. The
                // model still gets the raw payload.
                let sentKeys = ((try? JSONSerialization.jsonObject(with: dataArgs)) as? [String: Any]).map { $0.keys.sorted() }
                logToolExecution.error("❌ Tool Argument Decoding Failed. Tool: \(toolName). Expected Keys: \(requiredKeys). Sent keys: \(sentKeys.map { "\($0)" } ?? "not a JSON object") (\(dataArgs.count) bytes). Error: \(decodingError.localizedDescription). CONSEQUENCE: the call does not run; the model is shown what it sent and what was expected, and retries.")

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
            selfBoundCeiling: tool.selfBoundCeiling,
            run: tool.run
        )
    }
}
