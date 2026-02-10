//
//  ContextMemoryManager.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ContextMemoryManager")

/// Manages the persistence of high-level context (Markdown files).
/// Handles "Tier 1: Global Profile" and "Tier 2: Session Context".
class ContextMemoryManager {
    
    static let shared = ContextMemoryManager()
    
    private let fileManager = FileManager.default
    
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
        initializeDirectoryStructure()
    }
    
    /// Ensures the directory structure and default Global Profile exist.
    private func initializeDirectoryStructure() {
        do {
            // 1. Create Root Directory
            if !fileManager.fileExists(atPath: rootURL.path) {
                try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
                logger.info("Created root memory directory at: \(self.rootURL.path)")
            }
            
            // 2. Create Sessions Directory
            if !fileManager.fileExists(atPath: sessionsURL.path) {
                try fileManager.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
                logger.info("Created sessions directory.")
            }
            
            // 3. Create Default Global Profile if missing
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
        - **Shell:** /bin/zsh
        - **User:** \(userName)
        - **Created:** \(Date().formatted(date: .numeric, time: .shortened))

        ## Critical Rules (Global)
        - NEVER delete files from /System, /Library, or /usr.
        - Always ask for confirmation before modifying files in critical directories.
        - If a tool fails, check the "Audit Logs" before retrying blindly.
        
        ## Preferences
        - (Add user preferences here, e.g., 'Prefer Python over Bash')
        """
        
        do {
            try defaultContent.write(to: globalProfileURL, atomically: true, encoding: .utf8)
            logger.info("Created default Global_Profile.md")
        } catch {
            logger.error("Failed to write default global profile: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Public API
    
    /// Retrieves the combined context (Global + Session) for the Agent.
    /// This is injected into the System Prompt.
    func getContext(for conversationID: UUID) -> String {
        var combinedContext = ""
        
        // 1. Read Global Profile
        do {
            let globalContent = try String(contentsOf: globalProfileURL, encoding: .utf8)
            combinedContext += "## 🌍 GLOBAL CONTEXT (User Profile)\n\(globalContent)\n\n"
        } catch {
            logger.error("Error reading Global Profile: \(error.localizedDescription)")
            combinedContext += "## 🌍 GLOBAL CONTEXT\n(Profile unavailable)\n\n"
        }
        
        // 2. Read Session Context
        let sessionFile = sessionsURL.appendingPathComponent("\(conversationID.uuidString).md")
        
        if fileManager.fileExists(atPath: sessionFile.path) {
            do {
                let sessionContent = try String(contentsOf: sessionFile, encoding: .utf8)
                combinedContext += "## 🧠 ACTIVE SESSION CONTEXT (Project Brief)\n\(sessionContent)"
            } catch {
                logger.error("Error reading Session Context: \(error.localizedDescription)")
                combinedContext += "## 🧠 ACTIVE SESSION CONTEXT\n(Error loading context)"
            }
        } else {
            // EAGER INITIALIZATION: Write the file immediately.
            let newSessionTemplate = """
            # Session: \(conversationID.uuidString)
            **Started:** \(Date().formatted())
            
            ## 🎯 Current Goal
            (Agent: Briefly describe the user's intent here)
            """
            
            do {
                try newSessionTemplate.write(to: sessionFile, atomically: true, encoding: .utf8)
                logger.info("Initialized new session file for ID: \(conversationID.uuidString)")
                combinedContext += "## 🧠 ACTIVE SESSION CONTEXT (New Project)\n\(newSessionTemplate)"
            } catch {
                logger.error("Failed to initialize session file: \(error.localizedDescription)")
                combinedContext += "## 🧠 ACTIVE SESSION CONTEXT\n(Context system error)"
            }
        }
        
        return combinedContext
    }
    
    /// Appends to the session-specific markdown file.
    /// The Agent uses this to maintain its "Whiteboard".
    func updateSession(conversationID: UUID, content: String) {
        let sessionFile = sessionsURL.appendingPathComponent("\(conversationID.uuidString).md")
        
        // Prepare content with a timestamp/separator to ensure clean appending
        let entry = "\n\n### Update: \(Date().formatted(date: .numeric, time: .shortened))\n\(content)"
        
        do {
            if !fileManager.fileExists(atPath: sessionFile.path) {
                // Create if missing (fallback)
                try entry.write(to: sessionFile, atomically: true, encoding: .utf8)
            } else {
                // Append using FileHandle
                let fileHandle = try FileHandle(forWritingTo: sessionFile)
                fileHandle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            }
            logger.info("Appended to session context for ID: \(conversationID.uuidString)")
        } catch {
            logger.error("Failed to update session context: \(error.localizedDescription)")
        }
    }
    
    /// Helper to list all active sessions (Optional: for UI to show history)
    func listRecentSessions() -> [URL] {
        do {
            let files = try fileManager.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            return files.sorted {
                let date0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let date1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return date0 > date1
            }
        } catch {
            return []
        }
    }
}
