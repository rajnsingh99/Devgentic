// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolExecutionMediator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logToolExecution = DGLogger(category: "ToolExecution")

/// A concrete implementation of `ToolDispatching`.
/// Encapsulates the serialization of tool parameters, metric recording,
/// hallucination catching, Human-In-The-Loop (HITL) suspension, and Pre-flight Permissions.
struct ToolExecutionMediator: ToolDispatching {

    /// The global per-tool timeout in seconds when the user has set no override: 15 minutes.
    /// Injectable so tests can exercise the default path without a real-time wait.
    static let globalDefaultToolTimeout: TimeInterval = 15 * 60
    var defaultToolTimeout: TimeInterval = ToolExecutionMediator.globalDefaultToolTimeout

    /// How long a timed-out tool gets, after it is cancelled, to hand back what it had. Covers the
    /// shell's SIGTERM→SIGKILL grace (2 s) plus reading its log. Work still running after this is
    /// reported as still running, never waited for.
    var stopGrace: TimeInterval = 5

    /// Headroom above a self-bounding tool's own ceiling, so the tool's kill — which returns its
    /// partial output — always lands before the dispatcher's.
    static let selfBoundHeadroom: TimeInterval = 30

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
                    // No "System Error:" prefix: the `.systemError` template adds its own. The "Missing required macOS permissions"
                    // marker is matched by `failureCategory`.
                    let msg = "Missing required macOS permissions. Please ask the user to grant access in System Settings -> Privacy & Security."
                    // Synthetic classification for a detected condition; `.toolPermissionDenied` drives dashboards toward the
                    // grant-permission remediation.
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
            
            // Pre-flight argument validation: catches empty, null and missing required values before dispatch so the model can
            // self-correct.
            let validationErrors = Self.validateRequiredArguments(
                arguments: arguments,
                schema: tool.parameters,
                toolName: sanitizedName
            )
            if !validationErrors.isEmpty {
                let errorMsg = validationErrors.joined(separator: " ")
                // Synthetic classification for a pre-dispatch rejection; `.toolArgInvalid` is not retryable because the arguments
                // are wrong, not transient.
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

                // Every tool call is bounded, and `DeadlineRace` returns at the bound even for tools that ignore cancellation,
                // keeping output within the grace; shortened to fit an enclosing limit.
                let fitted = await ExecutionBudget.clamp(
                    Self.effectiveTimeout(for: tool, defaultTimeout: defaultToolTimeout),
                    what: "Tool '\(toolName)'")
                let effectiveTimeout = fitted.limit
                // `parkScope`: a human answering inside the call (an MCP question, a permission
                // prompt) does not count against the tool's limit (HITL Waiting Contract, decision 1).
                let outcome = try await DeadlineRace.run(limit: effectiveTimeout, stopGrace: stopGrace,
                                                         parkScope: UUID()) {
                    try await tool.run(paramData)
                }
                switch outcome {
                case .finished(let finished):
                    toolResult = try finished.get()
                case .timedOut(let elapsed, let afterStop):
                    throw PerToolTimeoutError(toolName: toolName, limit: effectiveTimeout,
                                              elapsed: elapsed, afterStop: afterStop,
                                              shortenedBy: fitted.shortenedBy, reserve: fitted.reserve)
                }

                // Tools whose legitimate output surfaces error text opt out of content-sniffing; a non-throwing return is success
                // and real failures still throw.
                let isSemanticFailure = tool.contentMayLookLikeError
                    ? false
                    : Self.isSemanticFailure(toolResult.output)

                if isSemanticFailure {
                    // Enriches with recovery hints only for errors matching a registered (tool, pattern) row whose suggested tools are
                    // enabled (`ToolRecoveryHints.enrich`).
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
                // A timeout is a FAILURE even when a custom `timeoutMessage` is set (#20): the
                // result stays `.timedOut` so the circuit breaker, timeline, and trace record it.
                let customMessage = (tool.timeoutMessage?.isEmpty == false) ? tool.timeoutMessage : nil
                let observation = Self.timeoutObservation(timeoutError, customMessage: customMessage)
                logToolExecution.warning("[TOOL_TIMEOUT] Tool '\(toolName)' passed its \(Self.describe(timeoutError.limit)) limit after \(Self.describe(timeoutError.elapsed)). CONSEQUENCE: \(timeoutError.stopped ? "it was stopped and its partial result (\(timeoutError.partialOutput?.count ?? 0) chars) goes to the model" : "it did not stop within \(Int(stopGrace))s of being cancelled and may still be running; its result will not reach this turn").")
                result = .timedOut(toolName: toolName, duration: timeoutError.limit, message: observation)
                errorDescriptionForMetrics = "Per-tool timeout after \(Int(timeoutError.limit))s"

            } catch ShellCommandError.timedOut(let limit, let observation) {
                // The command's own bound: a timeout, with the partial output for the model.
                logToolExecution.warning("[TOOL_TIMEOUT] Tool '\(toolName)' hit its own \(Self.describe(limit)) limit and was killed. CONSEQUENCE: recorded as a timeout (it used to count as a success); its partial output goes to the model.")
                result = .timedOut(toolName: toolName, duration: limit, message: observation)
                errorDescriptionForMetrics = "Command timed out after \(Int(limit))s"

            } catch ShellCommandError.stopped(let observation) where !Task.isCancelled {
                // Stopped while the run goes on (the user stopped just this command): not the tool's failure, and the model still
                // needs its output.
                logToolExecution.info("[CANCELLED] reason=command-stopped — '\(toolName)' was stopped while its run continues. CONSEQUENCE: recorded as cancelled, not as a success; its partial output goes to the model.")
                result = .cancelled(toolName: toolName, message: observation)

            } catch _ where Task.isCancelled {
                // Stop or an outer limit reached a running tool: not the tool's failure, so it is recorded as cancelled, not a
                // crash.
                logToolExecution.info("[CANCELLED] reason=stopped — tool '\(toolName)' was cancelled because its run was stopped. CONSEQUENCE: recorded as cancelled, not as a tool failure.")
                result = .cancelled(toolName: toolName)

            } catch {
                // Classifies the error into the canonical taxonomy so analytics can dedupe and filter by category; developer mode
                // captures extra diagnostics.
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

        // A cancelled call says nothing about the tool's reliability.
        if case .cancelled = result { return result }

        // Fire-and-forget metrics recording
        Task { @MainActor in
            MetricsManager.shared.recordToolReliability(toolName: sanitizedName, isSuccess: result.isSuccess, errorType: errorDescriptionForMetrics, durationMs: Int(duration * 1000), context: toolSpan,
                                                        failureCategory: result.failureCategory == .timeout ? .toolTimeout : nil)
            MetricsManager.shared.record(duration: duration, for: "tool_latency", context: toolSpan)
        }

        return result
    }
    
    // MARK: - Testable Static Helpers

    /// Upper bound in chars for the "error"-prefixed semantic-failure check.
    /// Soft-failure messages are short single lines; longer error-containing content (logs, build output) stays a
    /// success.
    static let maxSemanticErrorLength = 512

    /// Heuristic for tools that report failure by returning a string rather than throwing.
    /// Conservative: empty/"null"/"nil" mean no result; "error" counts only as a leading word on short output.
    /// Tools that legitimately surface error text opt out via `AgentTool.contentMayLookLikeError`.
    static func isSemanticFailure(_ rawOutput: String) -> Bool {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let lower = trimmed.lowercased()
        if lower == "null" || lower == "nil" { return true }

        // "error"-shaped and short enough to be a message; the bound is on the first line, since a long log has a long
        // first line.
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
        case "spotlight_search",
             "read_file_metadata",
             "watch_folder",
             "batch_move_files":
            return [.desktop, .documents, .downloads]
        case "run_applescript":
            return [.accessibility]
        default:
            return []
        }
    }
    
    /// Validates that all required parameters (per the tool's schema) are present and non-empty.
    /// Returns human-readable errors, one per violation; empty means valid. Empty strings/arrays/objects, null and
    /// missing values fail.
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

// MARK: - Per-Tool Timeout

extension ToolExecutionMediator {

    /// The bound for one call: the user's override if usable, else just above a self-bounding tool's ceiling, else the
    /// global default.
    /// Never 0, negative or infinite.
    static func effectiveTimeout(for tool: AgentTool, defaultTimeout: TimeInterval) -> TimeInterval {
        if let override = tool.timeout {
            if override.isFinite, override > 0 { return override }
            logToolExecution.warning("[TOOL_TIMEOUT] Tool '\(tool.name)' carries an unusable timeout override (\(override)s). CONSEQUENCE: ignored — the tool's normal bound applies instead of an instant timeout.")
        }
        if let ceiling = tool.selfBoundCeiling, ceiling.isFinite, ceiling > 0 {
            return ceiling + selfBoundHeadroom
        }
        return defaultTimeout
    }

    /// What the model reads for a timed-out call: the real elapsed time, whether the work was stopped, and what it
    /// handed back.
    static func timeoutObservation(_ error: PerToolTimeoutError, customMessage: String?) -> String {
        var text: String
        if error.stopped {
            text = "System Error: Tool '\(error.toolName)' timed out after \(describe(error.elapsed)) (limit \(describe(error.limit))) and was stopped."
        } else {
            text = "System Error: Tool '\(error.toolName)' timed out after \(describe(error.elapsed)) (limit \(describe(error.limit))). It did not stop when cancelled and may still be running; its result will not be delivered."
        }
        if let owner = error.shortenedBy {
            // Nesting: the model must know why the limit was short and that it still has time to answer, or it retries a
            // command that cannot fit.
            text += "\nThe limit was shortened to fit \(owner); about \(describe(error.reserve)) remains to respond. Do not re-run it in this turn — report what you have."
        }
        if let customMessage { text += "\n\(customMessage)" }
        if let partial = error.partialOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !partial.isEmpty {
            text += "\nIts result before it stopped:\n\(partial)"
        }
        return text
    }

    /// "45 s", "15 min", "1 min 30 s".
    static func describe(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(max(total, 0)) s" }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}

struct PerToolTimeoutError: Error {
    let toolName: String
    let limit: TimeInterval
    let elapsed: TimeInterval
    /// What the tool returned after it was cancelled; nil when it was still running at the end of
    /// the stop grace.
    let afterStop: Result<(output: String, artifacts: [MediaArtifact]), Error>?
    /// Set when the limit was shortened to fit an enclosing one ("the turn's 10 min limit").
    var shortenedBy: String? = nil
    var reserve: TimeInterval = 0

    var stopped: Bool { afterStop != nil }
    var partialOutput: String? {
        switch afterStop {
        case .success(let value)?:
            return value.output
        case .failure(let error)?:
            // `run_command` throws its stopped or timed-out outcome; its partial output rides in the error and must survive
            // the dispatcher's limit.
            switch error as? ShellCommandError {
            case .stopped(let observation)?, .timedOut(_, let observation)?: return observation
            default: return nil
            }
        case nil:
            return nil
        }
    }
}
