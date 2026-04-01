//
//  ReportExporter.swift
//  Devgentic
//
//  Created by Raj Singh on 28/03/26.
//

import Foundation

enum ReportExporter {

    struct ExportBundle: Codable {
        let version: String
        let exportedAt: Date
        let mode: String
        let trace: TraceRecord
        let summary: TraceSummary
        let userFeedback: UserFeedback?
    }

    static func export(
        trace: TraceRecord,
        summary: TraceSummary,
        isDeveloperMode: Bool,
        feedback: UserFeedback? = nil
    ) -> URL? {
        let bundle = ExportBundle(
            version: "1.0",
            exportedAt: Date(),
            mode: isDeveloperMode ? "developer" : "user",
            trace: trace,
            summary: summary,
            userFeedback: isDeveloperMode ? nil : feedback
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(bundle)
            let tempDir = FileManager.default.temporaryDirectory
            let prefix = isDeveloperMode ? "trace" : "feedback"
            let fileURL = tempDir.appendingPathComponent("\(prefix)_\(trace.traceID).json")
            try data.write(to: fileURL)
            return fileURL
        } catch {
            print("[ReportExporter] Failed to encode bundle: \(error)")
            return nil
        }
    }
}
