// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  TraceContext.swift
//  Devgentic
//
//  Created by Raj Singh on 16/07/25.
//

import Foundation

/// A lightweight, serializable descriptor for the backend profile used in a trace.
struct ProfileInfo {
    let id: UUID
    let name: String
    let type: ProfileType
    let provider: ApiProvider? // Optional, as a workflow itself doesn't have a single provider

    /// Memberwise initializer for lightweight contexts (e.g., inline sub-agents).
    init(id: UUID, name: String, type: ProfileType, provider: ApiProvider?) {
        self.id = id
        self.name = name
        self.type = type
        self.provider = provider
    }

    /// Initializes the descriptor by extracting essential data from the main BackendProfileModel.
    /// This avoids carrying the entire heavy model throughout the trace.
    init(from profile: BackendProfileModel) {
        self.id = profile.id
        self.name = profile.displayName
        self.type = profile.profileType
        
        // Extract the provider only if the profile is a bot or an agent,
        // as workflows don't have a single, direct provider.
        switch profile.details {
        case .bot(let config):
            self.provider = config.llmConfig.apiProvider
        case .agent(let config):
            self.provider = config.llmConfig.apiProvider
        case .workflow:
            self.provider = nil
        case .imageGen(let config):
            self.provider = config.llmConfig.apiProvider
        case .code(let config):
            self.provider = config.llmConfig.apiProvider
        }
    }
}


/// A structure to carry tracing information through a request's lifecycle.
struct TraceContext: Sendable {
    /// A unique identifier for the entire end-to-end request.
    let traceID: String
    
    /// A unique identifier for a specific operation (span) within the trace.
    private(set) var spanID: String
    
    /// The unique identifier of the parent operation, if this is a child span.
    /// Used to reconstruct the hierarchical "Call Stack of Thoughts" (Waterfall view).
    private(set) var parentSpanID: String?
    
    /// The timestamp when the initial request was created.
    let requestStartTime: Date

    /// Lightweight information about the profile handling this request.
    let profileInfo: ProfileInfo
    
    /// The ID of the ChatMessage this trace is associated with.
    /// Set by ActiveStreamManager when the trace is created, enabling Report UI lookups.
    var messageID: UUID?
    
    /// Mutable metadata for attaching specific details to this span (e.g. "tool_name", "error_code").
    var metadata: [String: String] = [:]

    /// Initializes a new root trace context from a backend profile.
    init(profile: BackendProfileModel, messageID: UUID? = nil) {
        self.traceID = UUID().uuidString
        self.spanID = UUID().uuidString
        self.parentSpanID = nil // Root spans have no parent
        self.requestStartTime = Date()
        self.profileInfo = ProfileInfo(from: profile)
        self.messageID = messageID
    }

    /// Initializes a trace context for an inline sub-agent (no full BackendProfileModel).
    init(subAgentName: String, provider: ApiProvider) {
        self.traceID = UUID().uuidString
        self.spanID = UUID().uuidString
        self.parentSpanID = nil
        self.requestStartTime = Date()
        self.profileInfo = ProfileInfo(id: UUID(), name: subAgentName, type: .agent, provider: provider)
        self.messageID = nil
    }

    /// Creates a new context for a child operation (a new span).
    /// The new span shares the same traceID but gets a new, unique spanID,
    /// and links to the current spanID as its parent.
    /// - Returns: A new `TraceContext` for a child span.
    func newSpan() -> TraceContext {
        var newContext = self
        newContext.parentSpanID = self.spanID // Link to current span as parent
        newContext.spanID = UUID().uuidString // Generate new unique ID
        newContext.metadata = [:] // Clear metadata for the fresh span
        return newContext
    }
    
    /// Adds key-value metadata to the current span context.
    mutating func addMetadata(_ key: String, value: String) {
        self.metadata[key] = value
    }
}

// MARK: - Agent Trace Logging

/// A structured record of a single step in the agent's execution trajectory.
/// Captures the raw "Thought -> Action -> Observation" chain for debugging and transparency.
struct AgentTraceLog: Identifiable, Codable, Sendable {
    let id: UUID
    
    // --- Distributed Tracing Fields ---
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    // ----------------------------------
    
    let stepNumber: Int
    let timestamp: Date
    let state: AgentState
    
    /// The content of the trace.
    let content: String
    
    /// Optional metadata for advanced debugging (e.g., execution time, tool name).
    let metadata: [String: String]?
    
    init(
        id: UUID = UUID(),
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        stepNumber: Int,
        state: AgentState,
        content: String,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.stepNumber = stepNumber
        self.timestamp = Date()
        self.state = state
        self.content = content
        self.metadata = metadata
    }
}

// MARK: - Agent Metrics

struct AgentSessionMetrics {
    let sessionID: UUID
    var totalSteps: Int = 0
    var totalIterations: Int = 0
    /// Sum of the authoritative per-run iteration counts reported by COMPLETED
    /// inner executor runs. Planning/Reflexion sessions run several ReAct loops;
    /// each report replaces the event-derived drift for its own run while
    /// preserving the counts of the runs before it (a plain overwrite displayed
    /// only the last subtask's count).
    var confirmedIterations: Int = 0
    var toolCalls: Int = 0
    var parseErrors: Int = 0
    var didFinishSuccessfully: Bool = false
    var didHitMaxIterations: Bool = false
    var hallucinatedTools: Int = 0

    /// ExecutionOutcome.rawValue reported by the executor on its terminal
    /// finalizing event. When present it decides the summary's Outcome label
    /// honestly; when absent (non-reporting executors) the legacy
    /// finalizing-implies-success heuristic applies.
    var reportedOutcome: String? = nil
    
    // Track tools for summary
    var executedTools: [(name: String, success: Bool)] = []
    
    // Tools available to the agent (for checking hallucinations)
    let validToolNames: Set<String>
    
    // Time tracking
    let startTime: Date = Date()
    var endTime: Date?
    
    var duration: TimeInterval {
        guard let end = endTime else { return 0 }
        return end.timeIntervalSince(startTime)
    }
}

