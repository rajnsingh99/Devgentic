//
//  ToolExecutionMediator.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logToolExecution = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ToolExecution")

/// A concrete implementation of `ToolDispatching`.
/// Encapsulates the serialization of tool parameters, metric recording,
/// hallucination catching, Human-In-The-Loop (HITL) suspension, and Pre-flight Permissions.
struct ToolExecutionMediator: ToolDispatching {
    
    // MARK: - Preparation & HITL
    
    func prepareDispatch(
        toolName: String,
        arguments: [String: AnyCodable],
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
        arguments: [String: AnyCodable],
        availableTools: [AgentTool],
        parentContext: TraceContext
    ) async -> ToolExecutionResult {
        
        var toolSpan = parentContext.newSpan()
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
            let requiredPermissions = getRequiredPermissions(for: sanitizedName)
            if !requiredPermissions.isEmpty {
                let hasPermissions = await PermissionManager.shared.ensurePermissions(for: requiredPermissions)
                
                if !hasPermissions {
                    logToolExecution.warning("⚠️ Pre-flight Permission Check Failed for '\(sanitizedName)'.")
                    let msg = "System Error: Missing required macOS permissions. Please ask the user to grant access in System Settings -> Privacy & Security."
                    let failResult = ToolExecutionResult.systemError(reason: msg)
                    
                    // Fire-and-forget metrics recording for permission failure
                    let duration = Date().timeIntervalSince(startTime)
                    Task { @MainActor in
                        MetricsManager.shared.recordToolReliability(toolName: sanitizedName, isSuccess: false, errorType: "Missing Permissions", context: toolSpan)
                        MetricsManager.shared.record(duration: duration, for: "tool_latency", context: toolSpan)
                    }
                    return failResult
                }
            }
            // -----------------------------------
            
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                let paramData = try encoder.encode(arguments)
                
                if let payloadStr = String(data: paramData, encoding: .utf8) {
                    logToolExecution.debug("▶️ Dispatching Tool '\(toolName)' with payload:\n\(payloadStr)")
                }

                let output = try await tool.run(paramData)
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let isSemanticFailure = trimmedOutput.isEmpty || trimmedOutput.lowercased().hasPrefix("error") || trimmedOutput.count < 3 || trimmedOutput.lowercased() == "null" || trimmedOutput.lowercased() == "nil"

                if isSemanticFailure {
                    result = .semanticFailure(toolName: toolName, output: output)
                    errorDescriptionForMetrics = trimmedOutput.isEmpty ? "Empty tool response" : output
                } else {
                    result = .success(output: output)
                }

            } catch {
                logToolExecution.error("❌ Tool '\(toolName)' threw system error:\n\(error.localizedDescription)")
                result = .systemError(reason: error.localizedDescription)
                errorDescriptionForMetrics = error.localizedDescription
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
            MetricsManager.shared.recordToolReliability(toolName: sanitizedName, isSuccess: result.isSuccess, errorType: errorDescriptionForMetrics, context: toolSpan)
            MetricsManager.shared.record(duration: duration, for: "tool_latency", context: toolSpan)
        }

        return result
    }
    
    // MARK: - Private Helpers
    
    private func getRequiredPermissions(for toolName: String) -> [SystemPermission] {
        switch toolName {
        case "fs_smart_search", "fs_read_metadata", "fs_watch_folder", "fs_organize_batch":
            return [.desktop, .documents, .downloads]
        case "run_applescript":
            return [.accessibility]
        default:
            return []
        }
    }
    
    private func serializeParams(_ params: [String: AnyCodable]) -> String {
        if let data = try? JSONEncoder().encode(params), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
