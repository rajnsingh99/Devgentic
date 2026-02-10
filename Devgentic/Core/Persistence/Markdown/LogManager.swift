//
//  LogManager.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LogManager")

// MARK: - Data Models

/// Represents a detailed record of a system action.
/// Stored as an individual JSON file in the Logs directory.
struct ActionManifest: Codable {
    /// Unique ID for this action (e.g., "ACT-8821")
    let id: String
    /// The name of the tool that performed the action (e.g., "fs_organize_batch")
    let tool: String
    /// When the action occurred
    let timestamp: Date
    /// A human-readable summary (e.g., "Moved 42 files to Archive")
    let summary: String
    /// Technical details of the operation.
    /// Using flexible key-value pairs to support different tools (move, delete, write).
    /// Example: [["original": "/path/a", "new": "/path/b", "status": "moved"], ...]
    let operations: [[String: String]]
}

// MARK: - Manager

/// Manages the "Evidence Locker" (Tier 3 Memory).
/// Handles JSON Logs and the Master CSV Index.
class LogManager {
    
    static let shared = LogManager()
    
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    // MARK: - Paths
    
    private var logsRootURL: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("Devgentic_Memory/Logs")
    }
    
    private var masterIndexURL: URL {
        logsRootURL.appendingPathComponent("master_index.csv")
    }
    
    // MARK: - Initialization
    
    private init() {
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        
        initializeLogDirectory()
    }
    
    private func initializeLogDirectory() {
        do {
            if !fileManager.fileExists(atPath: logsRootURL.path) {
                try fileManager.createDirectory(at: logsRootURL, withIntermediateDirectories: true)
                logger.info("Created Logs directory at: \(self.logsRootURL.path)")
            }
            
            // Initialize Master CSV header if missing
            if !fileManager.fileExists(atPath: masterIndexURL.path) {
                let header = "ID,Timestamp,Tool,Summary\n"
                try header.write(to: masterIndexURL, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.error("Failed to initialize Log directory: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Core Logging Logic
    
    /// Logs a destructive action to the permanent record.
    /// - Parameters:
    ///   - toolName: The tool used (e.g., "delete_file").
    ///   - summary: A short description for the index.
    ///   - operations: The detailed list of what happened.
    /// - Returns: The Action ID (e.g., "ACT-1234") to be returned to the Agent.
    @discardableResult
    func logAction(toolName: String, summary: String, operations: [[String: String]]) -> String {
        let actionID = generateActionID()
        let timestamp = Date()
        
        let manifest = ActionManifest(
            id: actionID,
            tool: toolName,
            timestamp: timestamp,
            summary: summary,
            operations: operations
        )
        
        // 1. Determine Folder (YYYY-MM)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM"
        let folderName = dateFormatter.string(from: timestamp)
        let folderURL = logsRootURL.appendingPathComponent(folderName)
        
        do {
            // Create month folder if needed
            if !fileManager.fileExists(atPath: folderURL.path) {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
            }
            
            // 2. Write JSON File
            let fileURL = folderURL.appendingPathComponent("action_\(actionID).json")
            let data = try encoder.encode(manifest)
            try data.write(to: fileURL)
            
            // 3. Update Master Index (CSV)
            try appendToMasterIndex(manifest: manifest)
            
            logger.info("Logged action \(actionID) to \(fileURL.lastPathComponent)")
            return actionID
            
        } catch {
            logger.error("Failed to log action: \(error.localizedDescription)")
            return "ERROR-LOG-FAILED"
        }
    }
    
    // MARK: - Retrieval Logic
    
    /// Retrieves the full details of a specific action by ID.
    func getLogDetails(actionID: String) -> ActionManifest? {
        // Since we split logs by month folders, we might need to search slightly,
        // but typically the agent might know the date or we scan the CSV first.
        // For simplicity: We scan the month folders.
        
        guard let monthFolders = try? fileManager.contentsOfDirectory(at: logsRootURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return nil
        }
        
        for folder in monthFolders {
            // Check inside each YYYY-MM folder
            let potentialFile = folder.appendingPathComponent("action_\(actionID).json")
            if fileManager.fileExists(atPath: potentialFile.path) {
                do {
                    let data = try Data(contentsOf: potentialFile)
                    return try decoder.decode(ActionManifest.self, from: data)
                } catch {
                    logger.error("Failed to decode log \(actionID): \(error.localizedDescription)")
                    return nil
                }
            }
        }
        
        return nil
    }
    
    /// Simple search within the Master CSV Index.
    /// Returns a raw string suitable for LLM consumption.
    func searchLogs(keyword: String) -> String {
        do {
            let csvContent = try String(contentsOf: masterIndexURL, encoding: .utf8)
            let lines = csvContent.components(separatedBy: .newlines)
            
            // Filter lines containing the keyword (case insensitive)
            let matches = lines.filter { $0.localizedCaseInsensitiveContains(keyword) }
            
            if matches.isEmpty {
                return "No logs found containing keyword: '\(keyword)'"
            }
            
            // Return header + matches
            let header = lines.first ?? "ID,Timestamp,Tool,Summary"
            return ([header] + matches).joined(separator: "\n")
            
        } catch {
            return "Error reading master index: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Private Helpers
    
    private func generateActionID() -> String {
        // Generate a short, readable ID (e.g., 4 hex chars)
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let shortHash = String(uuid.prefix(6))
        return "ACT-\(shortHash)"
    }
    
    private func appendToMasterIndex(manifest: ActionManifest) throws {
        // CSV Format: ID,Timestamp,Tool,"Summary"
        let dateStr = ISO8601DateFormatter().string(from: manifest.timestamp)
        let safeSummary = manifest.summary.replacingOccurrences(of: "\"", with: "'") // Escape quotes
        let csvRow = "\(manifest.id),\(dateStr),\(manifest.tool),\"\(safeSummary)\"\n"
        
        if let data = csvRow.data(using: .utf8) {
            if let fileHandle = FileHandle(forWritingAtPath: masterIndexURL.path) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            } else {
                // If file handle fails (rare), try simple append via string write (less efficient but fallback)
                // In production, FileHandle is preferred.
                // Re-creating file scenario handled in init.
            }
        }
    }
}
