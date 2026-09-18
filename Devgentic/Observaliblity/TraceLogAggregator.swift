// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TraceLogAggregator.swift
//  Devgentic
//
//  Created by Raj Singh on 07/02/26.
//

import Foundation
import os

/// A singleton service that collects detailed execution traces in memory.
/// Allows users to export debug logs ("Bug Reports") when things go wrong.
/// Acts as a "Black Box Recorder" for the Agent's cognitive process.
actor TraceLogAggregator {
    static let shared = TraceLogAggregator()
    
    // In-memory buffer: TraceID -> Ordered List of Logs
    private var traceBuffer: [String: [AgentTraceLog]] = [:]
    
    private let logger = Logger(subsystem: DGLogger.subsystem, category: "TraceAggregator")
    
    private init() {}
    
    // MARK: - Collection
    
    /// Appends a new log entry to the active trace.
    func append(_ log: AgentTraceLog) {
        if traceBuffer[log.traceID] == nil {
            traceBuffer[log.traceID] = []
        }
        traceBuffer[log.traceID]?.append(log)
    }
    
    /// Optional: Call this to clear logs when a session ends to free memory.
    /// In a real app, you might want a ring buffer or auto-cleanup policy.
    func clear() {
        let count = traceBuffer.count
        traceBuffer.removeAll()
        logger.info("Cleared \(count) traces from memory.")
    }
    
    // MARK: - Export
    
    /// Exports the specified trace to a JSON file for debugging.
    /// - Parameter traceID: The specific trace to export.
    /// - Returns: The URL of the generated JSON file in the temporary directory.
    func exportTrace(traceID: String) throws -> URL {
        guard let logs = traceBuffer[traceID] else {
             throw NSError(domain: "TraceAggregator", code: 404, userInfo: [NSLocalizedDescriptionKey: "Trace ID \(traceID) not found in memory."])
        }
        
        // 1. Sort by timestamp to ensure the timeline is correct
        let sortedLogs = logs.sorted { $0.timestamp < $1.timestamp }
        
        // 2. Prepare JSON Encoder
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(sortedLogs)
        
        // 3. Write to Temporary File
        let filename = "bug_report_\(traceID).json"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(filename)
        
        try data.write(to: fileURL)
        
        logger.notice("Exported trace \(traceID) to \(fileURL.path)")
        return fileURL
    }
    
    /// Helper to get the most recent trace ID (useful if the UI just wants "Export Last Run").
    func getMostRecentTraceID() -> String? {
        // Since dictionary order is undefined, we look for the log with the latest timestamp.
        let allLogs = traceBuffer.values.flatMap { $0 }
        return allLogs.sorted(by: { $0.timestamp > $1.timestamp }).first?.traceID
    }
}
