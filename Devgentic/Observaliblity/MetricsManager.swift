// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MetricsManager.swift
//  Devgentic
//
//  Created by Raj Singh on 16/07/25.
//

import Foundation

@MainActor
class MetricsManager {
    static let shared = MetricsManager()
    
    private init() {}

    /// Records a performance metric using the detailed information from the TraceContext.
    ///
    /// ⚠️ Every emit below captures `at` BEFORE its `Task {}` hop. The recorder stamps events
    /// with the caller's clock (call-site-evaluated default parameter), but a default evaluated
    /// INSIDE an unstructured Task is the Task's start time — under MainActor load that skew
    /// landed tool events visibly late and scrambled the timeline's segment placement.
    func record(duration: TimeInterval, for key: String, context: TraceContext) {
        let at = Date()
        Task { await TraceRecorder.shared.emitMetric(span: context, key: key, valueMs: Int(duration * 1000), at: at) }
        logMetric(key: key, value: String(format: "%.4fs", duration), context: context)
    }
    
    /// Records the success or failure of the Planning Phase.
    func recordPlanOutcome(success: Bool, isAmbiguous: Bool, context: TraceContext) {
        var meta = context.metadata
        meta["ambiguous"] = String(isAmbiguous)
        meta["outcome"] = success ? "success" : "failure"
        
        let at = Date()
        Task { await TraceRecorder.shared.emitMetric(span: context, key: "plan_outcome", valueMs: success ? 1 : 0, at: at) }
        logMetric(key: "plan_outcome", value: success ? "1" : "0", context: context, extraMeta: meta)
    }
    
    /// Records the reliability of a specific tool execution.
    /// - Parameters:
    ///   - errorType: The raw error description (will be sanitized).
    func recordToolReliability(toolName: String, isSuccess: Bool, errorType: String?, durationMs: Int = 0, context: TraceContext) {
        var meta = context.metadata
        meta["tool"] = toolName
        meta["outcome"] = isSuccess ? "success" : "failure"
        
        if let error = errorType {
            // SANITIZATION: Strip PII from error messages before recording
            meta["error_signature"] = TelemetrySanitizer.sanitize(error)
        }
        
        let at = Date()
        Task {
            await TraceRecorder.shared.emitToolResult(span: context, name: toolName, success: isSuccess, output: errorType ?? "success", durationMs: durationMs, at: at)
        }
        logMetric(key: "tool_execution", value: isSuccess ? "1" : "0", context: context, extraMeta: meta)
    }
    
    /// Records an attempt to use a non-existent tool.
    func recordHallucination(toolName: String, context: TraceContext) {
        var meta = context.metadata
        meta["hallucinated_tool"] = toolName
        
        let at = Date()
        Task { await TraceRecorder.shared.emitError(span: context, error: "Hallucinated tool: \(toolName)", isRecoverable: true, at: at) }
        logMetric(key: "agent_hallucination", value: "1", context: context, extraMeta: meta)
    }

    // MARK: - Helper

    /// DEBUG-only console echo of a metric. Compiled out of release builds, so the hot
    /// path doesn't pay string-formatting + stdout cost per tool execution (§12.9). The
    /// structured metric itself still goes to TraceRecorder via the `emit*` calls above.
    private func logMetric(key: String, value: String, context: TraceContext, extraMeta: [String: String] = [:]) {
        #if DEBUG
        let profile = context.profileInfo
        var attributes: [String] = [
            "traceID: \(context.traceID)",
            "profile: \(profile.name)",
            "type: \(profile.type.rawValue)"
        ]
        let combinedMeta = context.metadata.merging(extraMeta) { (_, new) in new }
        for (k, v) in combinedMeta {
            attributes.append("\(k): \(v)")
        }
        print("📊 METRIC: [\(key)]: \(value) (\(attributes.joined(separator: ", ")))")
        #endif
    }
}
