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
        case .agent(let llmConfig, _):
            self.provider = llmConfig.apiProvider
        case .workflow:
            self.provider = nil
        }
    }
}


/// A structure to carry tracing information through a request's lifecycle.
struct TraceContext {
    /// A unique identifier for the entire end-to-end request.
    let traceID: String
    
    /// A unique identifier for a specific operation (span) within the trace.
    private(set) var spanID: String
    
    /// The timestamp when the initial request was created.
    let requestStartTime: Date

    /// Lightweight information about the profile handling this request.
    let profileInfo: ProfileInfo

    /// Initializes a new root trace context from a backend profile.
    init(profile: BackendProfileModel) {
        self.traceID = UUID().uuidString
        self.spanID = UUID().uuidString
        self.requestStartTime = Date()
        self.profileInfo = ProfileInfo(from: profile)
    }

    /// Creates a new context for a child operation (a new span).
    /// The new span shares the same traceID but gets a new, unique spanID.
    /// - Returns: A new `TraceContext` for a child span.
    func newSpan() -> TraceContext {
        var newContext = self
        newContext.spanID = UUID().uuidString
        return newContext
    }
}

