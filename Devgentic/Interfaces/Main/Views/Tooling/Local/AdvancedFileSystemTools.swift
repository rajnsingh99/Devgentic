//
//  AdvancedFileSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 27/01/26.
//  Updated by Agent Engineer on 12/02/26.
//  UPGRADE:
//  1. Replaced Hybrid Engine with Production POC (Raw Query + Permission Scoping).
//  2. Removed Deep Scan fallback for simplification.
//  3. Added explicit permission checks to trigger TCC prompts for Documents/Downloads.
//  4. FIX: Handle "null" string from LLM to correctly trigger Global Search.
//  5. FIX: Added kMDItemFSName to query to ensure Folders are found.
//  PATCHED: Updated Output to clarify search context.
//  MIGRATION: Updated to native DevgenticTool protocol and removed OFM dependencies.
//

import Foundation

// MARK: - Hybrid Search Service (Based on POC)

/// A Production-Grade Search Engine wrapper for macOS.
/// Implements Raw Spotlight Query Language to solve tokenization edge cases.
@MainActor
class HybridSearchService {
    static let shared = HybridSearchService()
    
    // Pre-fetching attributes prevents disk I/O during result mapping
    private let requiredAttributes = [
        NSMetadataItemPathKey,
        NSMetadataItemDisplayNameKey,
        NSMetadataItemFSNameKey,
        kMDItemKind as String
    ]
    
    // Toggle this to true to explicitly hide system-heavy noise folders
    private let filterSystemPaths = true
    
    /// Checks permission for all primary root-level user directories.
    /// This acts as the "Manual Trigger" to prompt TCC if needed and gathers available scopes.
    private func checkPermissionsAndGetScopes() -> [URL] {
        let fileManager = FileManager.default
        let foldersToCheck: [FileManager.SearchPathDirectory] = [
            .documentDirectory,
            .desktopDirectory,
            .downloadsDirectory,
            .moviesDirectory,
            .musicDirectory,
            .picturesDirectory
        ]
        
        var availableScopes: [URL] = []
        
        for folder in foldersToCheck {
            if let url = fileManager.urls(for: folder, in: .userDomainMask).first {
                // Non-intrusive check: isReadableFile will return false if TCC block is active.
                // Attempting to read it often triggers the OS permission prompt if not yet determined.
                if fileManager.isReadableFile(atPath: url.path) {
                    availableScopes.append(url)
                }
            }
        }
        return availableScopes
    }
    
    /// Performs the search using the POC raw query logic.
    func search(term: String, scope: String?) async throws -> [String] {
        // 1. Scope Resolution & Permission Check
        var searchScopes: [Any] = []
        var permissionNote: String? = nil
        
        // Safety Check: If scope is the string "null" or empty, treat as Global
        let cleanScope = (scope == "null" || scope == "") ? nil : scope
        
        if let specificScope = cleanScope {
            // User requested specific scope
            if FileManager.default.isReadableFile(atPath: specificScope) {
                searchScopes = [URL(fileURLWithPath: specificScope)]
            } else {
                return ["Error: Permission denied or path does not exist for scope: \(specificScope). Please grant access."]
            }
        } else {
            // Global Search: Use validated user directories from POC logic
            let validUserScopes = checkPermissionsAndGetScopes()
            
            if !validUserScopes.isEmpty {
                searchScopes = validUserScopes
            } else {
                // Fallback to Home if we are still waiting for initial user interaction/permissions
                searchScopes = [NSMetadataQueryUserHomeScope]
                permissionNote = "[Note: Limited access to user directories. Results might be incomplete until permissions are granted.]"
            }
        }
        
        return await withCheckedContinuation { continuation in
            let query = NSMetadataQuery()
            
            // Logic from POC: Setup
            query.sortDescriptors = [
                NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false),
                NSSortDescriptor(key: NSMetadataItemDisplayNameKey, ascending: true)
            ]
            query.valueListAttributes = requiredAttributes
            
            // Logic from POC: Raw Query Construction
            let rawQueryString = buildRawQuery(from: term)
            
            if let predicate = NSPredicate(fromMetadataQueryString: rawQueryString) {
                query.predicate = predicate
            } else {
                continuation.resume(returning: ["Error: Failed to compile search query."])
                return
            }
            
            query.searchScopes = searchScopes
            
            // Notification Observer
            var observer: NSObjectProtocol?
            
            func finish(results: [String]) {
                if let obs = observer { NotificationCenter.default.removeObserver(obs) }
                query.stop()
                
                var finalOutput = results
                if let note = permissionNote {
                    finalOutput.append(note)
                }
                continuation.resume(returning: finalOutput)
            }
            
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { notification in
                query.disableUpdates()
                
                let foundItems = query.results as? [NSMetadataItem] ?? []
                var paths: [String] = []
                
                for item in foundItems {
                    if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                        paths.append(path)
                    }
                }
                
                // Return all results (Tool wrapper handles truncation if needed)
                finish(results: paths)
            }
            
            // Start Search
            query.start()
            
            // Timeout Safety: 4.0s max
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if query.isGathering {
                    // Force finish with whatever we have so far
                    query.disableUpdates()
                    let foundItems = query.results as? [NSMetadataItem] ?? []
                    let paths = foundItems.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
                    finish(results: paths)
                }
            }
        }
    }
    
    // Logic from POC: Raw Query Builder
    private func buildRawQuery(from input: String) -> String {
        let tokens = input.split(separator: " ")
        guard !tokens.isEmpty else { return "" }
        
        let subQueries = tokens.map { token -> String in
            let escaped = String(token).replacingOccurrences(of: "\"", with: "\\\"")
            // Search DisplayName, FSName (Filename), and Content with 'cdw' modifiers (Case, Diacritic, Word-based)
            // UPDATE: Added kMDItemFSName to ensure exact filename matches are found (e.g. Folders)
            return "((kMDItemDisplayName == \"*\(escaped)*\"cdw) || (kMDItemFSName == \"*\(escaped)*\"cdw) || (kMDItemTextContent == \"\(escaped)\"cdw))"
        }
        
        var finalQuery = subQueries.joined(separator: " && ")
        
        if filterSystemPaths {
            let exclusions = [
                "*/Library/*",
                "*/.Trash/*"
            ]
            let exclusionQuery = exclusions.map { "kMDItemPath != \"\($0)\"" }.joined(separator: " && ")
            finalQuery = "(\(finalQuery)) && (\(exclusionQuery))"
        }
        
        return finalQuery
    }
}

// MARK: - FS Smart Search (Spotlight + Hybrid)

struct SmartSearchTool: DevgenticTool {
    let name = "fs_smart_search"
    let category = "File System"
    let description = "Advanced macOS Spotlight Search. Finds files by matching Filename OR Text Content. Supports partial matches and scope limiting."
    
    struct Arguments: Decodable, Sendable {
        let search_term: String
        let search_scope: String?
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // Robust alias checking for search term
            var term: String? = nil
            let termKeys = ["search_term", "query", "term", "keyword", "text", "searchTerm"]
            
            for key in termKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let str = try? container.decode(String.self, forKey: codingKey) {
                    term = str
                    break
                }
            }
            
            guard let validTerm = term else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'search_term'"))
            }
            self.search_term = validTerm
            
            // Robust alias checking for scope
            var scope: String? = nil
            let scopeKeys = ["search_scope", "scope", "path", "folder", "directory", "searchScope"]
            
            for key in scopeKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let str = try? container.decode(String.self, forKey: codingKey) {
                    // FIX: Handle LLM passing the literal string "null" instead of actual null/nil
                    if str.caseInsensitiveCompare("null") == .orderedSame {
                        scope = nil
                    } else {
                        scope = str
                    }
                    break
                }
            }
            self.search_scope = scope
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("search_term", "string", "The keyword or phrase. Supports partial matches."),
                ("search_scope", "string", "Optional folder path. Leave NULL for global search.")
            ],
            required: ["search_term"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Executed Spotlight Search: '\(arguments.search_term)'",
            operations: [
                ["term": arguments.search_term, "scope": arguments.search_scope ?? "Global"]
            ]
        )
        // -------------------------------
        
        do {
            let paths = try await HybridSearchService.shared.search(
                term: arguments.search_term,
                scope: arguments.search_scope
            )
            
            // Check for explicit error messages
            if let first = paths.first, first.starts(with: "Error:") {
                return "\(first) (Audit Ref: \(logID))"
            }
            
            if paths.isEmpty {
                return "No results found matching '\(arguments.search_term)'. (Audit Ref: \(logID))"
            }
            
            // Check for permission warning
            let warning = paths.first(where: { $0.starts(with: "[Note:") })
            let filePaths = paths.filter { !$0.starts(with: "[Note:") }
            
            if filePaths.isEmpty {
                 return "No files found matching '\(arguments.search_term)'. \(warning ?? "") (Audit Ref: \(logID))"
            }
            
            let limitedPaths = filePaths.prefix(20)
            var output = "Found \(filePaths.count) items (showing top 20):\n" + limitedPaths.joined(separator: "\n")
            if let note = warning {
                output += "\n\n\(note)"
            }
            
            // FIX: Explicitly label the search action results
            return "🔍 Search Results for '\(arguments.search_term)':\n\(output)\n(Audit Ref: \(logID))"
            
        } catch {
            return "Search failed: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - FS Read Metadata

struct ReadMetadataTool: DevgenticTool {
    let name = "fs_read_metadata"
    let category = "File System"
    let description = "Retrieves detailed file metadata including creation date, type, size, and origin URL."
    
    struct Arguments: Decodable, Sendable {
        let path: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            var foundPath: String? = nil
            let keys = ["path", "filePath", "file", "filename"]
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let str = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = str
                    break
                }
            }
            guard let val = foundPath else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'path'"))
            }
            self.path = val
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "The absolute path of the file.")
            ],
            required: ["path"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Read metadata for: \(arguments.path)",
            operations: [
                ["path": arguments.path]
            ]
        )
        // -------------------------------

        let url = URL(fileURLWithPath: arguments.path)
        do {
            let resourceKeys: Set<URLResourceKey> = [.tagNamesKey, .contentModificationDateKey, .creationDateKey, .typeIdentifierKey, .fileSizeKey]
            let values = try url.resourceValues(forKeys: resourceKeys)
            
            var info = "Metadata for: \(url.lastPathComponent)\n"
            if let fileSize = values.fileSize {
                let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
                info += "Size: \(sizeStr) (\(fileSize) bytes)\n"
            } else {
                info += "Size: Unknown\n"
            }
            
            info += "Type: \(values.typeIdentifier ?? "Unknown")\n"
            info += "Created: \(values.creationDate?.description ?? "N/A")\n"
            info += "Modified: \(values.contentModificationDate?.description ?? "N/A")\n"
            
            if let tags = values.tagNames, !tags.isEmpty {
                info += "Tags: \(tags.joined(separator: ", "))\n"
            } else {
                info += "Tags: None\n"
            }
            
            if let origin = ExtendedAttributeHelper.getWhereFroms(at: url) {
                info += "Origin URL: \(origin.first ?? "Unknown")\n"
            }
            
            return info + "\n(Audit Ref: \(logID))"
        } catch {
            return "Error reading metadata: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - FS Organize Batch

struct OrganizeBatchTool: DevgenticTool {
    let name = "fs_organize_batch"
    let category = "File System"
    let description = "Moves multiple files to a specific destination folder in a single operation."

    
    struct Arguments: Decodable, Sendable {
        let sourcePaths: [String]
        let destinationFolder: String
        let dryRun: Bool?
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            var foundPaths: [String]? = nil
            let possibleKeys = ["sourcePaths", "source_paths", "paths", "files", "sourcePath", "source_path", "path", "file", "src", "source", "from"]
            for key in possibleKeys {
                if let codingKey = DynamicKey(stringValue: key) {
                    if let arrayVal = try? container.decode([String].self, forKey: codingKey) {
                        foundPaths = arrayVal
                        break
                    } else if let singleVal = try? container.decode(String.self, forKey: codingKey) {
                        foundPaths = [singleVal]
                        break
                    }
                }
            }
            guard let validPaths = foundPaths else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'sourcePaths'"))
            }
            self.sourcePaths = validPaths
            
            var foundDest: String? = nil
            let destKeys = ["destinationFolder", "destination_folder", "destination", "folder", "target", "dst", "to", "targetPath", "target_path", "output"]
            for key in destKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let dest = try? container.decode(String.self, forKey: codingKey) {
                    foundDest = dest
                    break
                }
            }
            guard let validDest = foundDest else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'destinationFolder'"))
            }
            self.destinationFolder = validDest
            
            if let codingKey = DynamicKey(stringValue: "dryRun") {
                self.dryRun = try? container.decodeIfPresent(Bool.self, forKey: codingKey)
            } else {
                self.dryRun = false
            }
        }
    }
    
    var parameterSchema: ToolParameters {
        let props: [String: ToolParameterProperty] = [
            "sourcePaths": ToolParameterProperty(type: "array", description: "Array of full file paths to move."),
            "destinationFolder": ToolParameterProperty(type: "string", description: "The target folder path."),
            "dryRun": ToolParameterProperty(type: "boolean", description: "If true, simulates the move.")
        ]
        return ToolParameters(type: "object", properties: props, required: ["sourcePaths", "destinationFolder"])
    }
    
    private let fileManager = FileManager.default
    
    func call(arguments: Arguments) async throws -> String {
        let isDryRun = arguments.dryRun ?? false
        var operationsLog: [[String: String]] = []
        var movedCount = 0
        var errors: [String] = []
        
        let destURL = URL(fileURLWithPath: arguments.destinationFolder)
        if !isDryRun {
            do {
                if !fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.createDirectory(at: destURL, withIntermediateDirectories: true)
                }
            } catch {
                return "Error: Could not create destination folder: \(error.localizedDescription)"
            }
        }
        
        for sourcePath in arguments.sourcePaths {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let fileName = sourceURL.lastPathComponent
            let destFileURL = destURL.appendingPathComponent(fileName)
            
            if !fileManager.fileExists(atPath: sourcePath) {
                errors.append("Skipped (Not Found): \(fileName)")
                continue
            }
            
            if isDryRun {
                movedCount += 1
                operationsLog.append(["original": sourcePath, "new": destFileURL.path, "status": "DRY_RUN"])
                continue
            }
            
            do {
                if fileManager.fileExists(atPath: destFileURL.path) {
                    errors.append("Skipped (Exists): \(fileName)")
                } else {
                    try fileManager.moveItem(at: sourceURL, to: destFileURL)
                    movedCount += 1
                    operationsLog.append(["original": sourcePath, "new": destFileURL.path, "status": "MOVED"])
                }
            } catch {
                errors.append("Error moving \(fileName): \(error.localizedDescription)")
            }
        }
        
        var resultMessage = isDryRun ? "[DRY RUN] " : ""
        resultMessage += "Processed \(arguments.sourcePaths.count) files. Moved: \(movedCount). Errors: \(errors.count)."
        if !errors.isEmpty { resultMessage += "\nDetails: \(errors.joined(separator: ", "))" }
        
        // --- LOGGING ---
        if !isDryRun && movedCount > 0 {
            let summary = "Moved \(movedCount) files to \(destURL.lastPathComponent)"
            let actionID = LogManager.shared.logAction(toolName: self.name, summary: summary, operations: operationsLog)
            resultMessage += "\n\n✅ Action Logged to Evidence Locker. Reference ID: \(actionID)"
        }
        return resultMessage
    }
}

// MARK: - FS Watch Folder

class WatcherService {
    static let shared = WatcherService()
    private var activeMonitors: [UUID: DispatchSourceFileSystemObject] = [:]
    
    func startWatching(path: String, auditRef: String) -> String {
        let url = URL(fileURLWithPath: path)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor != -1 else { return "Failed to open descriptor for path." }
        
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend], queue: DispatchQueue.global())
        let id = UUID()
        
        source.setEventHandler {
            print("FS EVENT: Change detected in \(path)")
            NotificationCenter.default.post(name: Notification.Name("DevgenticFSEvent"), object: nil, userInfo: ["path": path, "auditRef": auditRef])
        }
        
        source.setCancelHandler { close(descriptor) }
        source.resume()
        activeMonitors[id] = source
        return "Started watching \(path). Monitor ID: \(id.uuidString). (Audit Ref: \(auditRef))"
    }
}

struct WatchFolderTool: DevgenticTool {
    let name = "fs_watch_folder"
    let category = "File System"
    let description = "Starts a background monitor on a specific folder to notify of writes, deletes, or renames."
    
    struct Arguments: Decodable, Sendable {
        let path: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            var foundPath: String? = nil
            let keys = ["path", "folder", "directory", "dir"]
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let str = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = str
                    break
                }
            }
            guard let val = foundPath else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'path'"))
            }
            self.path = val
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "The folder path to watch.")
            ],
            required: ["path"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Started File System Monitor",
            operations: [
                ["path": arguments.path, "status": "active"]
            ]
        )
        // -------------------------------
        
        return WatcherService.shared.startWatching(path: arguments.path, auditRef: logID)
    }
}
