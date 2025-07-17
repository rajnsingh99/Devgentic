//
//  MetricsManager.swift
//  Devgentic
//
//  Created by Raj Singh on 16/07/25.
//

import Foundation

/// A singleton class to handle the recording of performance metrics.
@MainActor
class MetricsManager {
    static let shared = MetricsManager()
    
    private init() {}

    /// Records the duration of a specific operation.
    /// In a production app, this could send data to a service like Prometheus or Datadog.
    /// For now, it prints structured logs to the console.
    /// - Parameters:
    ///   - duration: The time interval of the operation.
    ///   - key: The name of the metric (e.g., "rag_duration", "time_to_first_token").
    ///   - context: The trace context to associate the metric with.
    ///   - backend: The backend type involved in the operation, if applicable.
    ///   - provider: The remote provider involved, if applicable.
    func record(duration: TimeInterval, for key: String, context: TraceContext, backend: BackendType? = nil, provider: RemoteProvider? = nil) {
        var attributes: [String] = []
        if let backend = backend { attributes.append("backend: \(backend.rawValue)") }
        if let provider = provider { attributes.append("provider: \(provider.rawValue)") }
        
        let attributesString = attributes.isEmpty ? "" : ", " + attributes.joined(separator: ", ")
        
        print("📊 METRIC [\(key)]: \(String(format: "%.4f", duration))s (traceID: \(context.traceID)\(attributesString))")
    }
}

