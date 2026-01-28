//
//  AdvancedFileSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 27/01/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - FS Smart Search (Spotlight)

struct SmartSearchTool: OpenFoundationModels.Tool {
    let name = "fs_smart_search"
    let description = "Instantly finds files using macOS Spotlight metadata. Much faster than crawling directories."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let search_term: String
        let search_scope: String? // Optional path to limit search
        
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            guard let term = props["search_term"] else { throw GeneratedContentError.missingProperty("search_term") }
            self.search_term = try String(term)
            
            if let scope = props["search_scope"] {
                self.search_scope = try String(scope)
            } else {
                self.search_scope = nil
            }
        }
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "search_term", description: "The filename or content to search for.", schema: DynamicGenerationSchema(type: String.self)),
                DynamicGenerationSchema.Property(name: "search_scope", description: "Optional folder path to limit the search.", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        let scopes = arguments.search_scope != nil ? [arguments.search_scope!] : nil
        
        do {
            // Fix: NSMetadataQuery and SpotlightSearcher are bound to the MainActor.
            // MainActor.run requires a synchronous closure, so we use Task { @MainActor ... }.value
            // to execute the async search method on the main thread and await the result.
            let paths = try await Task { @MainActor in
                let searcher = SpotlightSearcher()
                return try await searcher.search(queryStr: arguments.search_term, scope: scopes)
            }.value
            
            if paths.isEmpty { return "No results found matching '\(arguments.search_term)'." }
            // Limit results to avoid context overflow
            let limitedPaths = paths.prefix(20)
            return "Found \(paths.count) items (showing top 20):\n" + limitedPaths.joined(separator: "\n")
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - FS Read Metadata

struct ReadMetadataTool: OpenFoundationModels.Tool {
    let name = "fs_read_metadata"
    let description = "Gets detailed macOS info: Tags, Origin URL (where downloaded), and Last Opened Date."
    
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
                DynamicGenerationSchema.Property(name: "path", description: "File path to analyze.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        let url = URL(fileURLWithPath: arguments.path)
        
        do {
            // Fix: Use correct URLResourceKeys. `.contentCreationDateKey` does not exist; use `.creationDateKey`.
            let resourceKeys: Set<URLResourceKey> = [.tagNamesKey, .contentModificationDateKey, .creationDateKey, .typeIdentifierKey]
            let values = try url.resourceValues(forKeys: resourceKeys)
            
            var info = "Metadata for: \(url.lastPathComponent)\n"
            info += "Type: \(values.typeIdentifier ?? "Unknown")\n"
            // Fix: Use correct property `.creationDate`
            info += "Created: \(values.creationDate?.description ?? "N/A")\n"
            info += "Modified: \(values.contentModificationDate?.description ?? "N/A")\n"
            
            if let tags = values.tagNames, !tags.isEmpty {
                info += "Tags: \(tags.joined(separator: ", "))\n"
            } else {
                info += "Tags: None\n"
            }
            
            // 2. Extended Attributes (Origin URL)
            if let origin = ExtendedAttributeHelper.getWhereFroms(at: url) {
                info += "Origin URL: \(origin.first ?? "Unknown")\n"
            }
            
            return info
        } catch {
            return "Error reading metadata: \(error.localizedDescription)"
        }
    }
}

// MARK: - FS Organize Batch

struct OrganizeBatchTool: OpenFoundationModels.Tool {
    let name = "fs_organize_batch"
    let description = "Moves or renames a file. Handles conflicts automatically by appending numbers (e.g., 'File 1.txt')."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let source_path: String
        let destination_folder: String
        
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            guard let src = props["source_path"], let dst = props["destination_folder"] else {
                throw GeneratedContentError.missingProperty("source/destination")
            }
            self.source_path = try String(src)
            self.destination_folder = try String(dst)
        }
    }
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "source_path", description: "File to move.", schema: DynamicGenerationSchema(type: String.self)),
                DynamicGenerationSchema.Property(name: "destination_folder", description: "Target folder.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        let fm = FileManager.default
        let srcURL = URL(fileURLWithPath: arguments.source_path)
        let dstFolderURL = URL(fileURLWithPath: arguments.destination_folder)
        
        // Ensure destination folder exists
        if !fm.fileExists(atPath: dstFolderURL.path) {
            try fm.createDirectory(at: dstFolderURL, withIntermediateDirectories: true)
        }
        
        var finalDstURL = dstFolderURL.appendingPathComponent(srcURL.lastPathComponent)
        
        // Conflict Resolution: Append counter if file exists
        var counter = 1
        while fm.fileExists(atPath: finalDstURL.path) {
            let name = srcURL.deletingPathExtension().lastPathComponent
            let ext = srcURL.pathExtension
            let newName = "\(name) \(counter)" + (ext.isEmpty ? "" : ".\(ext)")
            finalDstURL = dstFolderURL.appendingPathComponent(newName)
            counter += 1
        }
        
        do {
            try fm.moveItem(at: srcURL, to: finalDstURL)
            return "Moved to: \(finalDstURL.path)"
        } catch {
            return "Move failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - FS Watch Folder

/// A simple singleton service to keep track of watchers so they don't get deallocated.
class WatcherService {
    static let shared = WatcherService()
    private var activeMonitors: [UUID: DispatchSourceFileSystemObject] = [:]
    
    func startWatching(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor != -1 else { return "Failed to open descriptor for path." }
        
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend], queue: DispatchQueue.global())
        
        let id = UUID()
        
        source.setEventHandler {
            // In a real agent system, this is where you would push a message to the chat stream.
            // For now, we just log it. You might want to implement a NotificationCenter post here.
            print("FS EVENT: Change detected in \(path)")
            NotificationCenter.default.post(name: Notification.Name("DevgenticFSEvent"), object: nil, userInfo: ["path": path])
        }
        
        source.setCancelHandler {
            close(descriptor)
        }
        
        source.resume()
        activeMonitors[id] = source
        return "Started watching \(path). Monitor ID: \(id.uuidString). Changes will be logged to system events."
    }
}

struct WatchFolderTool: OpenFoundationModels.Tool {
    let name = "fs_watch_folder"
    let description = "Starts a background monitor on a specific path. Returns changes."
    
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
                DynamicGenerationSchema.Property(name: "path", description: "Folder to watch.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        return WatcherService.shared.startWatching(path: arguments.path)
    }
}
