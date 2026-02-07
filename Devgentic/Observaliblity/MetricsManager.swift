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
    func record(duration: TimeInterval, for key: String, context: TraceContext) {
        let logString = self.formatLog(key: key, value: String(format: "%.4fs", duration), context: context)
        print("📊 METRIC: \(logString)")
    }
    
    /// Records the success or failure of the Planning Phase.
    func recordPlanOutcome(success: Bool, isAmbiguous: Bool, context: TraceContext) {
        var meta = context.metadata
        meta["ambiguous"] = String(isAmbiguous)
        meta["outcome"] = success ? "success" : "failure"
        
        let logString = self.formatLog(key: "plan_outcome", value: success ? "1" : "0", context: context, extraMeta: meta)
        print("📊 METRIC: \(logString)")
    }
    
    /// Records the reliability of a specific tool execution.
    /// - Parameters:
    ///   - errorType: The raw error description (will be sanitized).
    func recordToolReliability(toolName: String, isSuccess: Bool, errorType: String?, context: TraceContext) {
        var meta = context.metadata
        meta["tool"] = toolName
        meta["outcome"] = isSuccess ? "success" : "failure"
        
        if let error = errorType {
            // SANITIZATION: Strip PII from error messages before recording
            meta["error_signature"] = TelemetrySanitizer.sanitize(error)
        }
        
        let logString = self.formatLog(key: "tool_execution", value: isSuccess ? "1" : "0", context: context, extraMeta: meta)
        print("📊 METRIC: \(logString)")
    }
    
    /// Records an attempt to use a non-existent tool.
    func recordHallucination(toolName: String, context: TraceContext) {
        var meta = context.metadata
        meta["hallucinated_tool"] = toolName
        
        let logString = self.formatLog(key: "agent_hallucination", value: "1", context: context, extraMeta: meta)
        print("📊 METRIC: \(logString)")
    }
    
    // MARK: - Helper
    
    private func formatLog(key: String, value: String, context: TraceContext, extraMeta: [String: String] = [:]) -> String {
        let profile = context.profileInfo
        var attributes: [String] = []
        
        attributes.append("traceID: \(context.traceID)")
        attributes.append("profile: \(profile.name)")
        attributes.append("type: \(profile.type.rawValue)")
        
        // Merge context metadata with extra metadata
        let combinedMeta = context.metadata.merging(extraMeta) { (_, new) in new }
        
        for (k, v) in combinedMeta {
            attributes.append("\(k): \(v)")
        }
        
        return "[\(key)]: \(value) (\(attributes.joined(separator: ", ")))"
    }
}
