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

    func record(duration: TimeInterval, for key: String, context: TraceContext, backend: BackendType? = nil, provider: RemoteProvider? = nil) {
        var attributes: [String] = []
        if let backend = backend { attributes.append("backend: \(backend.rawValue)") }
        if let provider = provider { attributes.append("provider: \(provider.rawValue)") }
        
        let attributesString = attributes.isEmpty ? "" : ", " + attributes.joined(separator: ", ")
        
        print("📊 METRIC [\(key)]: \(String(format: "%.4f", duration))s (traceID: \(context.traceID)\(attributesString))")
    }
}

