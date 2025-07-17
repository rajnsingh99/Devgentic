//
//  TraceContext.swift
//  Devgentic
//
//  Created by Raj Singh on 16/07/25.
//

import Foundation

/// A structure to carry tracing information through a request's lifecycle.
struct TraceContext {
    /// A unique identifier for the entire end-to-end request.
    let traceID: String
    
    /// A unique identifier for a specific operation (span) within the trace.
    private(set) var spanID: String
    
    /// The timestamp when the initial request was created.
    let requestStartTime: Date

    /// Initializes a new root trace context.
    init() {
        self.traceID = UUID().uuidString
        self.spanID = UUID().uuidString
        self.requestStartTime = Date()
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
