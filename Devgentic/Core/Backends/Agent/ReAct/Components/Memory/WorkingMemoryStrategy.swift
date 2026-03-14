//
//  WorkingMemoryStrategy.swift
//  Devgentic
//
//  Created by Raj Singh on 11/03/26.
//

import Foundation

/// Defines how volatile working memory is recorded and compiled for the LLM prompt.
protocol WorkingMemoryStrategy: Sendable {
    /// Records a tool execution result.
    mutating func recordObservation(stepId: Int, toolName: String, result: String)
    
    /// Records a system-level alert or error.
    mutating func recordSystemAlert(msg: String)
    
    /// Compiles the collected logs into a string for prompt injection.
    func compileForPrompt() -> String
    
    /// Resets the memory.
    mutating func clear()
}

// MARK: - Concrete Implementations

/// For Edge (Small) Models: Aggressive summarization and Markdown formatting.
struct SummarizedLinearMemory: WorkingMemoryStrategy {
    private var logs: [String] = []
    
    mutating func recordObservation(stepId: Int, toolName: String, result: String) {
        // Implement summarization logic: truncate if result is too long.
        let truncated = result.count > 300 ? String(result.prefix(300)) + "..." : result
        logs.append("- [Step \(stepId)] Called `\(toolName)`. Result: \(truncated)")
    }
    
    mutating func recordSystemAlert(msg: String) {
        logs.append("- [SYSTEM ALERT] \(msg)")
    }
    
    func compileForPrompt() -> String {
        guard !logs.isEmpty else { return "No actions taken yet." }
        return logs.joined(separator: "\n")
    }
    
    mutating func clear() {
        logs.removeAll()
    }
}

/// For Frontier (Large) Models: Raw, high-fidelity logs.
struct HighContextLinearMemory: WorkingMemoryStrategy {
    private var logs: [String] = []
    
    mutating func recordObservation(stepId: Int, toolName: String, result: String) {
        // High fidelity: retain full logs.
        logs.append("- [Step \(stepId)] \(toolName):\n\(result)")
    }
    
    mutating func recordSystemAlert(msg: String) {
        logs.append("- [SYSTEM ALERT] \(msg)")
    }
    
    func compileForPrompt() -> String {
        guard !logs.isEmpty else { return "No actions taken yet." }
        return logs.joined(separator: "\n\n")
    }
    
    mutating func clear() {
        logs.removeAll()
    }
}
