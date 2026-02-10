//
//  AdvancedFileSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 27/01/26.
//  Updated for Audit Consistency.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - FS Smart Search (Spotlight)

struct SmartSearchTool: OpenFoundationModels.Tool {
    let name = "fs_smart_search"
    // OPTIMIZATION: Anchored to `mdfind` to trigger the model's knowledge of indexed search vs. traversal.
    let description = "Deep system search using macOS Spotlight (NSMetadataQuery). Functionally similar to the `mdfind` CLI command. Instantly finds files by matching Filenames OR Text Content. Use this as the PRIMARY tool for locating lost files or digging up documents by topic."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let search_term: String
        let search_scope: String?
        
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // Robust alias checking for search term
            var term: String? = nil
            let termKeys = ["search_term", "query", "term", "keyword", "text"]
            
            for key in termKeys {
                if let val = props[key], let str = try? String(val) {
                    term = str
                    break
                }
            }
            
            guard let validTerm = term else { throw GeneratedContentError.missingProperty("search_term") }
            self.search_term = validTerm
            
            // Robust alias checking for scope
            var scope: String? = nil
            let scopeKeys = ["search_scope", "scope", "path", "folder", "directory"]
            
            for key in scopeKeys {
                if let val = props[key], let str = try? String(val) {
                    scope = str
                    break
                }
            }
            self.search_scope = scope
        }
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "search_term", description: "The keyword or phrase to search for.", schema: DynamicGenerationSchema(type: String.self)),
                DynamicGenerationSchema.Property(name: "search_scope", description: "Optional folder path to restrict the search.", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
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
        
        let scopes = arguments.search_scope != nil ? [arguments.search_scope!] : nil
        
        do {
            let paths = try await Task { @MainActor in
                let searcher = SpotlightSearcher()
                return try await searcher.search(queryStr: arguments.search_term, scope: scopes)
            }.value
            
            if paths.isEmpty {
                return "No results found matching '\(arguments.search_term)'. (Audit Ref: \(logID))"
            }
            let limitedPaths = paths.prefix(20)
            return "Found \(paths.count) items (showing top 20):\n" + limitedPaths.joined(separator: "\n") + "\n(Audit Ref: \(logID))"
        } catch {
            return "Search failed: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - FS Read Metadata

struct ReadMetadataTool: OpenFoundationModels.Tool {
    let name = "fs_read_metadata"
    let description = "Retrieves detailed file metadata. Combines the capabilities of `mdls` (Spotlight attributes) and `stat` (system info)."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            var foundPath: String? = nil
            let keys = ["path", "filePath", "file", "filename"]
            for key in keys { if let val = props[key], let str = try? String(val) { foundPath = str; break } }
            guard let val = foundPath else { throw GeneratedContentError.missingProperty("path") }
            self.path = val
        }
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "path", description: "The absolute path of the file.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
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

// MARK: - FS Organize Batch (Already Audited - Kept for Completeness)

struct OrganizeBatchTool: OpenFoundationModels.Tool {
    struct Arguments: Codable, OpenFoundationModelsCore.ConvertibleFromGeneratedContent {
        let sourcePaths: [String]
        let destinationFolder: String
        let dryRun: Bool?
        
        init(_ content: OpenFoundationModelsCore.GeneratedContent) throws {
            let properties = try content.properties()
            var foundPaths: [String]? = nil
            let possibleKeys = ["sourcePaths", "source_paths", "paths", "files", "sourcePath", "source_path", "path", "file", "src", "source", "from"]
            for key in possibleKeys {
                guard let val = properties[key] else { continue }
                if let array = try? [String](val) { foundPaths = array; break }
                if let single = try? String(val) { foundPaths = [single]; break }
            }
            guard let validPaths = foundPaths else { throw OpenFoundationModelsCore.GeneratedContentError.missingProperty("sourcePaths") }
            self.sourcePaths = validPaths
            
            var foundDest: String? = nil
            let destKeys = ["destinationFolder", "destination_folder", "destination", "folder", "target", "dst", "to", "targetPath", "target_path", "output"]
            for key in destKeys { if let val = properties[key], let dest = try? String(val) { foundDest = dest; break } }
            guard let validDest = foundDest else { throw OpenFoundationModelsCore.GeneratedContentError.missingProperty("destinationFolder") }
            self.destinationFolder = validDest
            
            if let val = properties["dryRun"], let dry = try? Bool(val) { self.dryRun = dry } else { self.dryRun = false }
        }
    }
    
    typealias Output = String
    let name = "fs_organize_batch"
    let description = "Moves a batch of files to a specific destination folder. AUTOMATICALLY LOGS the action to the Evidence Locker."
    private let fileManager = FileManager.default
    
    var parameters: OpenFoundationModelsCore.GenerationSchema {
        let arraySchema = OpenFoundationModelsCore.DynamicGenerationSchema(arrayOf: OpenFoundationModelsCore.DynamicGenerationSchema(type: String.self))
        let stringSchema = OpenFoundationModelsCore.DynamicGenerationSchema(type: String.self)
        let boolSchema = OpenFoundationModelsCore.DynamicGenerationSchema(type: Bool.self)
        
        let root = OpenFoundationModelsCore.DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                OpenFoundationModelsCore.DynamicGenerationSchema.Property(name: "sourcePaths", description: "Array of full file paths to move.", schema: arraySchema),
                OpenFoundationModelsCore.DynamicGenerationSchema.Property(name: "destinationFolder", description: "The target folder path.", schema: stringSchema),
                OpenFoundationModelsCore.DynamicGenerationSchema.Property(name: "dryRun", description: "If true, simulates the move.", schema: boolSchema, isOptional: true)
            ]
        )
        return try! OpenFoundationModelsCore.GenerationSchema(root: root, dependencies: [])
    }
    
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

struct WatchFolderTool: OpenFoundationModels.Tool {
    let name = "fs_watch_folder"
    let description = "Starts a background monitor on a folder, behaving like `fswatch`."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            guard let val = props["path"] else { throw GeneratedContentError.missingProperty("path") }
            self.path = try String(val)
        }
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "path", description: "The folder path to watch.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
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
