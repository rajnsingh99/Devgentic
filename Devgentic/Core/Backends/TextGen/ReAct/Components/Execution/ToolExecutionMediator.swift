//
//  ToolExecutionMediator.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logToolExecution = DGLogger(category: "ToolExecution")

/// A concrete implementation of `ToolDispatching`.
/// Encapsulates the serialization of tool parameters, metric recording,
/// hallucination catching, Human-In-The-Loop (HITL) suspension, and Pre-flight Permissions.
struct ToolExecutionMediator: ToolDispatching {

    /// Default per-tool timeout (seconds) for the agent path when a tool doesn't set its own.
    /// Bounds a hung tool so it can't stall the ReAct loop indefinitely (#20); mirrors the
    /// workflow path's hard-timeout default (workflow uses 120s; the agent uses 60s).
    /// Injectable so tests can exercise the default-timeout path without a real-time wait.
    var defaultToolTimeout: TimeInterval = 60

    // MARK: - Preparation & HITL
    
    func prepareDispatch(
        toolName: String,
        arguments: [String: JSONValue],
        availableTools: [AgentTool]
    ) -> ToolDispatchOutcome {
        let paramsString = serializeParams(arguments)
        
        guard let tool = availableTools.first(where: { $0.name == toolName }) else {
            let result = ToolExecutionResult.hallucinated(toolName: toolName, availableTools: availableTools.map(\.name))
            return .executed(result: result, paramsString: paramsString)
        }
        
        if tool.requiresConfirmation {
            return .requiresConfirmation(paramsString: paramsString)
        }
        
        return .executed(result: .systemError(reason: "Pending Execution"), paramsString: paramsString)
    }
    
    // MARK: - Execution & Metrics
    
    func executePreparedTool(
        toolName: String,
        arguments: [String: JSONValue],
        availableTools: [AgentTool],
        parentContext: TraceContext
    ) async -> ToolExecutionResult {
        
        var toolSpan = parentContext
        toolSpan.addMetadata("tool_name", value: toolName)
        let startTime = Date()
        var sanitizedName = toolName
        
        if !availableTools.contains(where: { $0.name == sanitizedName }) {
            if let clean = sanitizedName.components(separatedBy: CharacterSet(charactersIn: "<| ")).first {
                sanitizedName = clean
            }
        }

        let result: ToolExecutionResult
        var errorDescriptionForMetrics: String? = nil

        if let tool = availableTools.first(where: { $0.name == sanitizedName }) {
            
            // --- PRE-FLIGHT PERMISSION CHECK ---
            let requiredPermissions = Self.getRequiredPermissions(for: sanitizedName)
            if !requiredPermissions.isEmpty {
                let hasPermissions = await PermissionManager.shared.ensurePermissions(for: requiredPermissions)
                
                if !hasPermissions {
                    // No "System Error:" prefix here — `.systemError`'s llmObservation
                    // template prepends its own, and doubling it read as noise. The
                    // "Missing required macOS permissions" marker is load-bearing:
                    // `ToolExecutionResult.failureCategory` matches on it to classify
                    // this as `.permissionRejected`.
                    let msg = "Missing required macOS permissions. Please ask the user to grant access in System Settings -> Privacy & Security."
                    // Synthetic classification — no underlying Error to preserve, this is a
                    // detected condition. `.toolPermissionDenied` drives dashboards toward
                    // the "user needs to grant permission" remediation path.
                    let classified = ClassifiedAgentError.synthetic(
                        category: .toolPermissionDenied,
                        origin: "ToolExecutionMediator.preflightPermission",
                        message: msg,
                        context: [
                            "tool_name": sanitizedName,
                            "permissions": requiredPermissions.map { String(describing: $0) }.joined(separator: ",")
                        ]
                    )
                    logToolExecution.warning(
                        "⚠️ Pre-flight Permission Check Failed for '\(sanitizedName)'.",
                        category: classified.category
                    )
                    await TraceRecorder.shared.emitAgentError(span: toolSpan, error: classified)

                    let failResult = ToolExecutionResult.systemError(reason: msg)

                    // Fire-and-forget metrics recording for permission failure
                    let duration = Date().timeIntervalSince(startTime)
                    Task { @MainActor in
                        MetricsManager.shared.recordToolReliability(toolName: sanitizedName, isSuccess: false, errorType: "Missing Permissions", durationMs: Int(duration * 1000), context: toolSpan)
                        MetricsManager.shared.record(duration: duration, for: "tool_latency", context: toolSpan)
                    }
                    return failResult
                }
            }
            // -----------------------------------
            
            // --- PRE-FLIGHT ARGUMENT VALIDATION ---
            // Dynamically validates required parameters against the tool's schema.
            // Catches empty strings, null, and missing values BEFORE dispatch,
            // giving the model a clear, actionable error to self-correct.
            let validationErrors = Self.validateRequiredArguments(
                arguments: arguments,
                schema: tool.parameters,
                toolName: sanitizedName
            )
            if !validationErrors.isEmpty {
                let errorMsg = validationErrors.joined(separator: " ")
                // Synthetic classification — argument validation is a pre-dispatch rejection,
                // not a caught exception. `.toolArgInvalid` signals the model should retry
                // with corrected arguments (isRetryable=false since args are wrong, not transient).
                let classified = ClassifiedAgentError.synthetic(
                    category: .toolArgInvalid,
                    origin: "ToolExecutionMediator.argValidation",
                    message: errorMsg,
                    context: [
                        "tool_name": sanitizedName,
                        "validation_error_count": "\(validationErrors.count)"
                    ]
                )
                logToolExecution.warning(
                    "⚠️ Argument validation failed for '\(sanitizedName)': \(errorMsg)",
                    category: classified.category
                )
                await TraceRecorder.shared.emitAgentError(span: toolSpan, error: classified)

                result = .semanticFailure(toolName: sanitizedName, output: errorMsg)
                errorDescriptionForMetrics = errorMsg

                let duration = Date().timeIntervalSince(startTime)
                Task { @MainActor in
                    MetricsManager.shared.recordToolReliability(toolName: sanitizedName, isSuccess: false, errorType: errorMsg, durationMs: Int(duration * 1000), context: toolSpan)
                    MetricsManager.shared.record(duration: duration, for: "tool_latency", context: toolSpan)
                }
                return result
            }
            // -----------------------------------

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                let paramData = try encoder.encode(arguments)

                if let payloadStr = String(data: paramData, encoding: .utf8) {
                    logToolExecution.debug("▶️ Dispatching Tool '\(toolName)' with payload:\n\(payloadStr)")
                }

                let toolResult: (output: String, artifacts: [MediaArtifact])

                // Always bound a tool call: use the per-tool timeout if the user set one, else
                // the default — so a hung tool (e.g. an unresponsive MCP server) can't stall the
                // ReAct loop indefinitely. Workflow nodes already default to a hard timeout;
                // chat agents now match (#20).
                let effectiveTimeout = tool.timeout ?? defaultToolTimeout
                toolResult = try await withThrowingTaskGroup(of: (String, [MediaArtifact]).self) { group in
                    group.addTask {
                        try await tool.run(paramData)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(effectiveTimeout))
                        throw PerToolTimeoutError(toolName: toolName, duration: effectiveTimeout)
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }

                // #19 (B): tools whose legitimate output surfaces error text (shell stderr,
                // build-error readers) opt out of content-sniffing entirely — a non-throwing
                // return is success; their genuine failures still surface by throwing.
                let isSemanticFailure = tool.contentMayLookLikeError
                    ? false
                    : Self.isSemanticFailure(toolResult.output)

                if isSemanticFailure {
                    // Enrich with recovery hints ONLY for errors that match a registered
                    // (toolName, error-pattern) row AND whose suggested tools are enabled
                    // in the current request. Unmatched errors and MCP tools pass through
                    // unchanged — see `ToolRecoveryHints.enrich` for the safety guarantees.
                    let enrichedOutput = ToolRecoveryHints.enrich(
                        toolName: toolName,
                        originalError: toolResult.output,
                        availableToolNames: Set(availableTools.map(\.name))
                    )
                    result = .semanticFailure(toolName: toolName, output: enrichedOutput)
                    errorDescriptionForMetrics = toolResult.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty tool response" : toolResult.output
                } else {
                    result = .success(output: toolResult.output, artifacts: toolResult.artifacts)
                }

            } catch let timeoutError as PerToolTimeoutError {
                logToolExecution.warning("⏱️ Tool '\(toolName)' timed out after \(Int(timeoutError.duration))s")
                // A timeout is a FAILURE even when a custom `timeoutMessage` is set: the message
                // is surfaced to the LLM as the observation, but the result stays `.timedOut` so
                // the circuit breaker, timeline, and trace record the timeout instead of a
                // phantom success (#20).
                let customMessage = (tool.timeoutMessage?.isEmpty == false) ? tool.timeoutMessage : nil
                result = .timedOut(toolName: toolName, duration: timeoutError.duration, message: customMessage)
                errorDescriptionForMetrics = "Per-tool timeout after \(Int(timeoutError.duration))s"

            } catch {
                // Classify the underlying error into the canonical taxonomy so downstream
                // analytics can dedupe across the propagation chain and filter by category.
                // `.classify(...)` preserves the original Error object and — in developer mode —
                // captures NSError domain/code/userInfo keys + a stack signature in the emitted
                // SpanEvent (see `ClassifiedAgentError.Diagnostics`).
                let classified = error.classify(
                    as: .toolSystemCrash,
                    origin: "ToolExecutionMediator.toolRun",
                    context: ["tool_name": toolName]
                )
                logToolExecution.error(
                    "❌ Tool '\(toolName)' threw system error:\n\(classified.message)",
                    error: classified,
                    category: classified.category
                )
                await TraceRecorder.shared.emitAgentError(span: toolSpan, error: classified)

                // Enrich the user-facing error with recovery hints (same behavior as before).
                let enrichedReason = ToolRecoveryHints.enrich(
                    toolName: toolName,
                    originalError: classified.message,
                    availableToolNames: Set(availableTools.map(\.name))
                )
                result = .systemError(reason: enrichedReason)
                errorDescriptionForMetrics = classified.message
            }
        } else {
            result = .hallucinated(toolName: toolName, availableTools: availableTools.map(\.name))
            errorDescriptionForMetrics = "Tool not found"
            Task { @MainActor in MetricsManager.shared.recordHallucination(toolName: toolName, context: toolSpan) }
        }

        let duration = Date().timeIntervalSince(startTime)
        logToolExecution.info("⏱️ Tool '\(sanitizedName)' latency: \(String(format: "%.4f", duration))s")
        
        // Fire-and-forget metrics recording
        Task { @MainActor in
            MetricsManager.shared.recordToolReliability(toolName: sanitizedName, isSuccess: result.isSuccess, errorType: errorDescriptionForMetrics, durationMs: Int(duration * 1000), context: toolSpan)
            MetricsManager.shared.record(duration: duration, for: "tool_latency", context: toolSpan)
        }

        return result
    }
    
    // MARK: - Testable Static Helpers

    /// Upper bound (chars) for the "error"-prefixed semantic-failure check. Intentional
    /// soft-failure messages (e.g. `read_file` returning "Error: File not found") are short
    /// single lines; legitimate error-CONTAINING content (logs, build output, code hits) is
    /// typically far longer, so it stays classified as success. (#19)
    static let maxSemanticErrorLength = 512

    /// Heuristic for tools that report failure by RETURNING a string rather than throwing
    /// (e.g. `read_file` → "Error: File not found"). Kept deliberately CONSERVATIVE (#19):
    /// empty / "null" / "nil" are unambiguous "no result"; the "error" branch fires only on a
    /// SHORT output shaped like an actual error message — "error" as a leading WORD followed by
    /// ':' or whitespace ("Error:", "Error reading file: …"). So a successful read/search/log
    /// whose CONTENT merely begins with "error" (a multi-KB build log, a code hit, "errors: 0")
    /// is NOT misclassified. Tools that legitimately surface error text opt out earlier at the
    /// call site via `AgentTool.contentMayLookLikeError`.
    static func isSemanticFailure(_ rawOutput: String) -> Bool {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let lower = trimmed.lowercased()
        if lower == "null" || lower == "nil" { return true }

        // "error"-shaped AND short enough to be a message rather than error-bearing content.
        // The length bound is on the FIRST LINE, not the whole output: a real error message has
        // a short header even when it interpolates a long body ("Error: <header>\n<details>"),
        // whereas a multi-KB log that merely begins with "error" has a long first line. (#19)
        if lower.hasPrefix("error") {
            let firstLineLength = trimmed.prefix(while: { !$0.isNewline }).count
            if firstLineLength <= Self.maxSemanticErrorLength {
                let afterError = lower.dropFirst(5) // "error".count
                guard let next = afterError.first else { return true } // bare "error"
                return next == ":" || next.isWhitespace
            }
        }

        return false
    }

    static func getRequiredPermissions(for toolName: String) -> [SystemPermission] {
        switch toolName {
        case "fs_smart_search", "fs_read_metadata", "fs_watch_folder", "fs_organize_batch":
            return [.desktop, .documents, .downloads]
        case "run_applescript":
            return [.accessibility]
        default:
            return []
        }
    }
    
    /// Validates that all required parameters (per the tool's schema) are present and non-empty.
    /// Returns an array of human-readable error strings — one per violation.
    /// Empty array means all validations passed.
    ///
    /// Validation rules by type:
    /// - `string`: must not be empty (`""`) or null
    /// - `number`/`integer`: must not be null or missing
    /// - `array`: must not be empty or null
    /// - `object`: must not be empty or null
    /// - Any type: must not be missing entirely
    static func validateRequiredArguments(
        arguments: [String: JSONValue],
        schema: ToolParameters,
        toolName: String
    ) -> [String] {
        var errors: [String] = []

        for key in schema.required {
            let propType = schema.properties[key]?.type ?? "string"

            guard let value = arguments[key] else {
                errors.append("\(toolName): '\(key)' is required but was not provided.")
                continue
            }

            switch value {
            case .null:
                errors.append("\(toolName): '\(key)' cannot be null.")

            case .string(let s):
                if propType == "string" && s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append("\(toolName): '\(key)' cannot be empty. Provide a meaningful value.")
                }

            case .array(let arr):
                if propType == "array" && arr.isEmpty {
                    errors.append("\(toolName): '\(key)' cannot be an empty array.")
                }

            case .object(let dict):
                if propType == "object" && dict.isEmpty {
                    errors.append("\(toolName): '\(key)' cannot be an empty object.")
                }

            default:
                break // numbers, bools — presence is sufficient
            }
        }

        return errors
    }

    private func serializeParams(_ params: [String: JSONValue]) -> String {
        if let data = try? JSONEncoder().encode(params), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}

// MARK: - Per-Tool Timeout Error

private struct PerToolTimeoutError: Error {
    let toolName: String
    let duration: TimeInterval
}
