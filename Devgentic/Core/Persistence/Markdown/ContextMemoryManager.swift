//
//  ContextMemoryManager.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//  Updated: Phase 2 - Twin-Store Architecture (JSON State + History Log)
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ContextMemoryManager")

/// Manages the persistence of high-level context using the "Twin-Store" pattern.
/// Store 1: Active State (JSON) - The "RAM" (Injected into Prompt)
/// Store 2: Archived History (Markdown) - The "Disk" (Searchable, not fully injected)
class ContextMemoryManager {
    
    static let shared = ContextMemoryManager()
    
    private let fileManager = FileManager.default
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder
    
    // MARK: - Paths
    
    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    private var rootURL: URL {
        documentsURL.appendingPathComponent("Devgentic_Memory")
    }
    
    private var sessionsURL: URL {
        rootURL.appendingPathComponent("Sessions")
    }
    
    private var globalProfileURL: URL {
        rootURL.appendingPathComponent("Global_Profile.md")
    }
    
    // MARK: - Initialization
    
    private init() {
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        self.jsonDecoder = JSONDecoder()
        
        initializeDirectoryStructure()
    }
    
    private func initializeDirectoryStructure() {
        do {
            if !fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
                logger.info("Created root memory directory at: \(self.rootURL.path)")
            }
            if !fileManager.fileExists(atPath: sessionsURL.path) {
                try fileManager.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
            }
            if !fileManager.fileExists(atPath: globalProfileURL.path) {
                createDefaultGlobalProfile()
            }
        } catch {
            logger.error("Failed to initialize memory directories: \(error.localizedDescription)")
        }
    }
    
    private func createDefaultGlobalProfile() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let userName = NSUserName()
        let defaultContent = """
        # User Profile
        - **OS:** macOS \(osVersion)
        - **User:** \(userName)
        ## Critical Rules
        - NEVER delete system files.
        - Always check 'Audit Logs' before retrying tools.
        """
        try? defaultContent.write(to: globalProfileURL, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Path Helpers (Twin-Store)
    
    private func stateURL(for id: UUID) -> URL {
        return sessionsURL.appendingPathComponent("\(id.uuidString)_State.json")
    }
    
    private func historyURL(for id: UUID) -> URL {
        return sessionsURL.appendingPathComponent("\(id.uuidString)_History.md")
    }
    
    private func legacyURL(for id: UUID) -> URL {
        return sessionsURL.appendingPathComponent("\(id.uuidString).md")
    }
    
    // MARK: - Core API: Get Context
    
    /// Retrieves the Hybrid Context:
    /// 1. Global Profile (Static)
    /// 2. Mutable Active State (JSON - Full Fidelity)
    /// 3. Recent History (Tail - Low Token Cost)
    func getContext(for conversationID: UUID) -> String {
        migrateLegacyFileIfNeeded(for: conversationID)
        
        var combinedContext = ""
        
        // 1. Global Profile
        if let global = try? String(contentsOf: globalProfileURL, encoding: .utf8) {
            combinedContext += "## 🌍 GLOBAL CONTEXT\n\(global)\n\n"
        }
        
        // 2. Mutable Active State (RAM)
        let activeState = getActiveState(for: conversationID)
        if let jsonData = try? jsonEncoder.encode(activeState),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            combinedContext += """
            ## 🧠 ACTIVE MEMORY (RAM)
            Below is your current internal state. You must update this state as you progress.
            ```json
            \(jsonString)
            ```
            
            """
        }
        
        // 3. Recent History (Tail)
        let recentHistory = getRecentHistory(for: conversationID, lines: 15)
        combinedContext += """
        ## 📜 RECENT ACTIVITY (Last 15 Lines)
        \(recentHistory)
        
        (Note: Older history is archived. Use 'vector_search' or 'read_action_log' to access it.)
        """
        
        return combinedContext
    }
    
    // MARK: - State Management (RAM)
    
    /// Loads the JSON State object or returns a default empty state.
    func getActiveState(for conversationID: UUID) -> MutableActiveState {
        let url = stateURL(for: conversationID)
        
        if let data = try? Data(contentsOf: url),
           let state = try? jsonDecoder.decode(MutableActiveState.self, from: data) {
            return state
        }
        
        // Default State (New Session)
        return MutableActiveState(
            sessionID: conversationID.uuidString,
            primaryGoal: "Waiting for user instruction...",
            subTasks: [],
            negativeConstraints: [],
            workingMemory: [:]
        )
    }
    
    /// Persists the JSON State object (Atomic Write).
    func updateActiveState(conversationID: UUID, state: MutableActiveState) {
        let url = stateURL(for: conversationID)
        do {
            let data = try jsonEncoder.encode(state)
            try data.write(to: url)
            logger.debug("Updated Active State for \(conversationID.uuidString)")
        } catch {
            logger.error("Failed to save Active State: \(error.localizedDescription)")
        }
    }
    
    // MARK: - History Management (Disk)
    
    /// Appends a log entry to the History Markdown file.
    func appendToHistory(conversationID: UUID, content: String) {
        migrateLegacyFileIfNeeded(for: conversationID)
        
        let url = historyURL(for: conversationID)
        let entry = "\n\n### Update: \(Date().formatted(date: .numeric, time: .shortened))\n\(content)"
        
        do {
            if !fileManager.fileExists(atPath: url.path) {
                // Initialize Header
                let header = "# Session History: \(conversationID.uuidString)\n**Created:** \(Date().formatted())\n"
                try (header + entry).write(to: url, atomically: true, encoding: .utf8)
            } else {
                let fileHandle = try FileHandle(forWritingTo: url)
                fileHandle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) {
                    fileHandle.write(data)
                }
                try fileHandle.close()
            }
            logger.debug("Appended to History for \(conversationID.uuidString)")
        } catch {
            logger.error("Failed to append to History: \(error.localizedDescription)")
        }
    }
    
    /// Reads the last N lines of the history file to save tokens.
    func getRecentHistory(for conversationID: UUID, lines limit: Int) -> String {
        let url = historyURL(for: conversationID)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "(No history yet)"
        }
        
        let allLines = content.components(separatedBy: .newlines)
        if allLines.count <= limit {
            return content
        }
        
        let tail = allLines.suffix(limit).joined(separator: "\n")
        return "... (Previous history archived) ...\n\(tail)"
    }
    
    /// Reads the FULL history (for RAG/Tools).
    func getFullHistory(for conversationID: UUID) -> String {
        let url = historyURL(for: conversationID)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    
    // MARK: - Migration & Legacy Support
    
    /// Automatically migrates old monolithic .md files to the new _History.md format.
    private func migrateLegacyFileIfNeeded(for id: UUID) {
        let oldURL = legacyURL(for: id)
        let newURL = historyURL(for: id)
        
        // If old exists AND new doesn't, rename it.
        if fileManager.fileExists(atPath: oldURL.path) && !fileManager.fileExists(atPath: newURL.path) {
            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
                logger.info("Migrated legacy session \(id) to Twin-Store format.")
            } catch {
                logger.error("Migration failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// (Deprecated) Backwards compatibility for old tool calls. Redirects to History.
    func updateSession(conversationID: UUID, content: String) {
        appendToHistory(conversationID: conversationID, content: content)
    }
    
    func listRecentSessions() -> [URL] {
        // Updated to filter for _History.md files specifically to avoid duplicates
        do {
            let files = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            return files
                .filter { $0.lastPathComponent.hasSuffix("_History.md") }
                .sorted {
                    let date0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    let date1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    return date0 > date1
                }
        } catch {
            return []
        }
    }
}
