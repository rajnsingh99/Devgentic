// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// The global per-tool timeout (seconds) when the user has set no override for this tool —
    /// 15 minutes (HITL Waiting Contract, decision 2). Was 60 s, which cut in ahead of the terminal
    /// tools' own 900 s bound and discarded their output (Timeout inventory D-01).
    ///
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

                // Always bound a tool call (#20), and RETURN AT THE BOUND.
                //
                // ⚠️⚠️ This was a `withThrowingTaskGroup` race until 2026-09-26. A task group cannot
                // return before every child has, so for any tool that ignores cancellation — a
                // shell command, an MCP request, an AppleScript — the timeout fired and then WAITED
                // for the tool, discarded its finished output and told the model "timed out after
                // 60 seconds" (P1: a 1 s bound returned after 4.01 s, the build had exited 0).
                // `DeadlineRace` returns at the bound, cancels the tool (which fires stop hooks such
                // as the shell's process kill) and keeps whatever it hands back within the grace.
                // Nesting: shortened to fit an enclosing turn/run limit, keeping its reserve.
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
                // A timeout is a FAILURE even when a custom `timeoutMessage` is set (#20): the
                // result stays `.timedOut` so the circuit breaker, timeline, and trace record it.
                let customMessage = (tool.timeoutMessage?.isEmpty == false) ? tool.timeoutMessage : nil
                let observation = Self.timeoutObservation(timeoutError, customMessage: customMessage)
                logToolExecution.warning("[TOOL_TIMEOUT] Tool '\(toolName)' passed its \(Self.describe(timeoutError.limit)) limit after \(Self.describe(timeoutError.elapsed)). CONSEQUENCE: \(timeoutError.stopped ? "it was stopped and its partial result (\(timeoutError.partialOutput?.count ?? 0) chars) goes to the model" : "it did not stop within \(Int(stopGrace))s of being cancelled and may still be running; its result will not reach this turn").")
                result = .timedOut(toolName: toolName, duration: timeoutError.limit, message: observation)
                errorDescriptionForMetrics = "Per-tool timeout after \(Int(timeoutError.limit))s"

            } catch ShellCommandError.timedOut(let limit, let observation) {
                // D-17: the command's OWN bound — a timeout, with the partial output for the model.
                logToolExecution.warning("[TOOL_TIMEOUT] Tool '\(toolName)' hit its own \(Self.describe(limit)) limit and was killed. CONSEQUENCE: recorded as a timeout (it used to count as a success); its partial output goes to the model.")
                result = .timedOut(toolName: toolName, duration: limit, message: observation)
                errorDescriptionForMetrics = "Command timed out after \(Int(limit))s"

            } catch ShellCommandError.stopped(let observation) where !Task.isCancelled {
                // D-17: stopped while the run goes on (the user stopped just this command). Not the
                // tool's failure, and the model still needs what it printed.
                logToolExecution.info("[CANCELLED] reason=command-stopped — '\(toolName)' was stopped while its run continues. CONSEQUENCE: recorded as cancelled, not as a success; its partial output goes to the model.")
                result = .cancelled(toolName: toolName, message: observation)

            } catch _ where Task.isCancelled {
                // Stop / an outer limit reached a running tool. Not the tool's failure: it used to
                // land in the generic catch below as `.toolSystemCrash`, a reliability failure and
                // an "executionThrew" chip for every Stop (Timeout inventory D-04, P7).
                logToolExecution.info("[CANCELLED] reason=stopped — tool '\(toolName)' was cancelled because its run was stopped. CONSEQUENCE: recorded as cancelled, not as a tool failure.")
                result = .cancelled(toolName: toolName)

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
        case "spotlight_search", "fs_smart_search",
             "read_file_metadata", "fs_read_metadata",
             "watch_folder", "fs_watch_folder",
             "batch_move_files", "fs_organize_batch":
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

// MARK: - Per-Tool Timeout

extension ToolExecutionMediator {

    /// The bound applied to one call: the user's override if it is usable, else just above a
    /// self-bounding tool's own ceiling, else the global default. Never 0, negative or infinite —
    /// a 0 used to mean "time out instantly" (Timeout inventory D-05, P9).
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

    /// What the model reads for a timed-out call — the REAL elapsed time, whether the work was
    /// stopped, and what it handed back (HITL Waiting Contract §4). Replaces "timed out after
    /// <bound> seconds", which was also sent for work that had finished.
    static func timeoutObservation(_ error: PerToolTimeoutError, customMessage: String?) -> String {
        var text: String
        if error.stopped {
            text = "System Error: Tool '\(error.toolName)' timed out after \(describe(error.elapsed)) (limit \(describe(error.limit))) and was stopped."
        } else {
            text = "System Error: Tool '\(error.toolName)' timed out after \(describe(error.elapsed)) (limit \(describe(error.limit))). It did not stop when cancelled and may still be running; its result will not be delivered."
        }
        if let owner = error.shortenedBy {
            // ⚠️ Nesting: the model must know WHY the limit was short, and that it still has time
            // to answer — otherwise it retries a command that cannot fit.
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
            // `run_command` now THROWS its stopped/timed-out outcome (D-17) — its partial output
            // rides in the error and must not be lost when the dispatcher's own limit stops it.
            switch error as? ShellCommandError {
            case .stopped(let observation)?, .timedOut(_, let observation)?: return observation
            default: return nil
            }
        case nil:
            return nil
        }
    }
}
