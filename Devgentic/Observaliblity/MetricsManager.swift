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
    /// - Parameters:
    ///   - duration: The time interval to record.
    ///   - key: A descriptive key for the metric (e.g., "time_to_first_token").
    ///   - context: The TraceContext containing profile and trace identifiers.
    func record(duration: TimeInterval, for key: String, context: TraceContext) {
        let profile = context.profileInfo
        var attributes: [String] = []
        
        // Add specific, useful attributes from the profile context.
        attributes.append("profileName: \(profile.name)")
        attributes.append("profileType: \(profile.type.rawValue)")
        if let provider = profile.provider {
            attributes.append("provider: \(provider.rawValue)")
        }
        
        let attributesString = attributes.isEmpty ? "" : ", " + attributes.joined(separator: ", ")
        
        // Log the metric with the enriched context.
        print("📊 METRIC [\(key)]: \(String(format: "%.4f", duration))s (traceID: \(context.traceID)\(attributesString))")
    }
}
