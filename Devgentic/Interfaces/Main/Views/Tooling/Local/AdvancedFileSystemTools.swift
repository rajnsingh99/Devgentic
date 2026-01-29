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
    // OPTIMIZATION: Anchored to `mdfind` to trigger the model's knowledge of indexed search vs. traversal.
    let description = "Deep system search using macOS Spotlight (NSMetadataQuery). Functionally similar to the `mdfind` CLI command. Instantly finds files by matching Filenames OR Text Content. Use this as the PRIMARY tool for locating lost files or digging up documents by topic."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let search_term: String
        let search_scope: String?
        
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
                DynamicGenerationSchema.Property(name: "search_term", description: "The keyword or phrase to search for (substring match on name or content).", schema: DynamicGenerationSchema(type: String.self)),
                DynamicGenerationSchema.Property(name: "search_scope", description: "Optional folder path to restrict the search.", schema: DynamicGenerationSchema(type: String.self), isOptional: true)
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        let scopes = arguments.search_scope != nil ? [arguments.search_scope!] : nil
        
        do {
            let paths = try await Task { @MainActor in
                let searcher = SpotlightSearcher()
                return try await searcher.search(queryStr: arguments.search_term, scope: scopes)
            }.value
            
            if paths.isEmpty { return "No results found matching '\(arguments.search_term)'." }
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
    // OPTIMIZATION: Anchored to `mdls` and `stat` for detailed attributes.
    let description = "Retrieves detailed file metadata. Combines the capabilities of `mdls` (Spotlight attributes) and `stat` (system info). Returns File Size, Content Type (UTI), Creation/Mod Dates, Tags, and Origin URL (`kMDItemWhereFroms`)."
    
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
                DynamicGenerationSchema.Property(name: "path", description: "The absolute path of the file.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        let url = URL(fileURLWithPath: arguments.path)
        
        do {
            // CRITICAL FIX: Added .fileSizeKey
            let resourceKeys: Set<URLResourceKey> = [.tagNamesKey, .contentModificationDateKey, .creationDateKey, .typeIdentifierKey, .fileSizeKey]
            let values = try url.resourceValues(forKeys: resourceKeys)
            
            var info = "Metadata for: \(url.lastPathComponent)\n"
            
            // CRITICAL FIX: Formatted file size output
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
            
            return info
        } catch {
            return "Error reading metadata: \(error.localizedDescription)"
        }
    }
}

// MARK: - FS Organize Batch

struct OrganizeBatchTool: OpenFoundationModels.Tool {
    let name = "fs_organize_batch"
    // OPTIMIZATION: Anchored to a "Safe Move" concept similar to `mv -n`.
    let description = "Smart file mover. Acts like the `mv` command but with built-in safety: if the destination file exists, it automatically resolves conflicts by renaming the source (e.g., 'File 2.txt') instead of overwriting."
    
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
                DynamicGenerationSchema.Property(name: "source_path", description: "The full path of the file to move.", schema: DynamicGenerationSchema(type: String.self)),
                DynamicGenerationSchema.Property(name: "destination_folder", description: "The target folder path.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        let fm = FileManager.default
        let srcURL = URL(fileURLWithPath: arguments.source_path)
        let dstFolderURL = URL(fileURLWithPath: arguments.destination_folder)
        
        if !fm.fileExists(atPath: dstFolderURL.path) {
            try fm.createDirectory(at: dstFolderURL, withIntermediateDirectories: true)
        }
        
        var finalDstURL = dstFolderURL.appendingPathComponent(srcURL.lastPathComponent)
        
        // Conflict Resolution
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
            print("FS EVENT: Change detected in \(path)")
            NotificationCenter.default.post(name: Notification.Name("DevgenticFSEvent"), object: nil, userInfo: ["path": path])
        }
        
        source.setCancelHandler {
            close(descriptor)
        }
        
        source.resume()
        activeMonitors[id] = source
        return "Started watching \(path). Monitor ID: \(id.uuidString). Changes will be logged via Notifications."
    }
}

struct WatchFolderTool: OpenFoundationModels.Tool {
    let name = "fs_watch_folder"
    // OPTIMIZATION: Anchored to `fswatch` for real-time monitoring.
    let description = "Starts a background monitor on a folder, behaving like `fswatch` or `inotify`. Tracks file system events (Create, Delete, Rename) in real-time."
    
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
        return WatcherService.shared.startWatching(path: arguments.path)
    }
}
