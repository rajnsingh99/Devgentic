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

    /// Initializes the descriptor by extracting essential data from the main BackendProfileModel.
    /// This avoids carrying the entire heavy model throughout the trace.
    init(from profile: BackendProfileModel) {
        self.id = profile.id
        self.name = profile.displayName
        self.type = profile.profileType
        
        // Extract the provider only if the profile is a bot or an agent,
        // as workflows don't have a single, direct provider.
        switch profile.details {
        case .bot(let llmConfig):
            self.provider = llmConfig.apiProvider
        // FIXED: Added an extra wildcard `_` to account for 'architecture'
        case .agent(let llmConfig, _, _, _, _, _):
            self.provider = llmConfig.apiProvider
        case .workflow:
            self.provider = nil
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
    
    /// Mutable metadata for attaching specific details to this span (e.g. "tool_name", "error_code").
    var metadata: [String: String] = [:]

    /// Initializes a new root trace context from a backend profile.
    init(profile: BackendProfileModel) {
        self.traceID = UUID().uuidString
        self.spanID = UUID().uuidString
        self.parentSpanID = nil // Root spans have no parent
        self.requestStartTime = Date()
        self.profileInfo = ProfileInfo(from: profile)
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
