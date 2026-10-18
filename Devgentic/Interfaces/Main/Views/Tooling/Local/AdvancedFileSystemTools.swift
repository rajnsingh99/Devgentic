// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AdvancedFileSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "AdvancedFileSystemTools")

// MARK: - Hybrid Search Service (Two-Phase Prefiltered)

/// A Spotlight-backed search wrapper that ranks filename matches ahead of content matches.
/// Content matches run only when filename matches are sparse, so low-relevance hits do not drown filename hits.
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
                if fileManager.isReadableFile(atPath: url.path) {
                    availableScopes.append(url)
                }
            }
        }
        return availableScopes
    }

    // MARK: - Two-Phase Search

    /// Performs a two-phase search: filename matches first, content matches as fallback.
    /// Returns a `SearchResult` with categorized matches for structured output.
    func search(term: String, scope: String?) async throws -> SearchResult {
        // 1. Scope Resolution & Permission Check
        var searchScopes: [Any] = []
        var permissionNote: String? = nil

        let cleanScope = (scope == "null" || scope == "") ? nil : scope

        if let specificScope = cleanScope {
            if FileManager.default.isReadableFile(atPath: specificScope) {
                searchScopes = [URL(fileURLWithPath: specificScope)]
            } else {
                return SearchResult(error: "Error: Permission denied or path does not exist for scope: \(specificScope). Please grant access.")
            }
        } else {
            let validUserScopes = checkPermissionsAndGetScopes()
            if !validUserScopes.isEmpty {
                searchScopes = validUserScopes
            } else {
                searchScopes = [NSMetadataQueryUserHomeScope]
                permissionNote = "[Note: Limited access to user directories. Results might be incomplete until permissions are granted.]"
            }
        }

        let nameQuery = buildNameOnlyQuery(from: term)
        let nameResults = await runQuery(rawQuery: nameQuery, scopes: searchScopes, limit: 10)

        // Content-only query (lower signal); runs only when filename matches are sparse.
        var contentResults: [String] = []
        if nameResults.count < 5 {
            let contentQuery = buildContentOnlyQuery(from: term)
            let rawContentResults = await runQuery(rawQuery: contentQuery, scopes: searchScopes, limit: 5)
            // Deduplicate: remove any paths already found in name results
            let nameSet = Set(nameResults)
            contentResults = rawContentResults.filter { !nameSet.contains($0) }
        }

        // Direct filesystem fallback for scoped searches that found nothing: Spotlight excludes volatile locations
        // such as /private/tmp, so an empty index result is not proof of absence.
        if let specificScope = cleanScope, nameResults.isEmpty, contentResults.isEmpty {
            let scopeURL = URL(fileURLWithPath: specificScope)
            let searchTerm = term
            let walkResults = await Task.detached(priority: .userInitiated) {
                Self.filesystemScan(term: searchTerm, scopeURL: scopeURL)
            }.value

            switch walkResults {
            case .some(let paths) where !paths.isEmpty:
                return SearchResult(
                    nameMatches: paths,
                    contentMatches: [],
                    permissionNote: permissionNote,
                    provenanceNote: "[Note: The Spotlight index has no entries for this location (unindexed or not yet indexed) — results come from a direct filename scan of the folder. Content matching wasn't performed.]"
                )
            case .some:
                return SearchResult(
                    nameMatches: [],
                    contentMatches: [],
                    permissionNote: permissionNote,
                    provenanceNote: "[Note: Verified with a direct filesystem scan — no filename matches on disk in this location either.]"
                )
            case .none:
                return SearchResult(
                    nameMatches: [],
                    contentMatches: [],
                    permissionNote: permissionNote,
                    provenanceNote: "[Note: The Spotlight index has no entries for this location and it couldn't be scanned directly — absence is NOT verified. Inspect the directory contents directly.]"
                )
            }
        }

        return SearchResult(
            nameMatches: nameResults,
            contentMatches: contentResults,
            permissionNote: permissionNote
        )
    }

    // MARK: - Filesystem Fallback Scan

    /// Index-free fallback that walks `scopeURL`, matching filenames against all whitespace-separated tokens.
    /// Skips hidden files and package contents; bounded by `maxScanned`, `maxResults` and `maxDepth`.
    /// Returns matched paths (empty = nothing found), or nil when the scope could not be enumerated.
    nonisolated static func filesystemScan(
        term: String,
        scopeURL: URL,
        maxResults: Int = 10,
        maxScanned: Int = 5_000,
        maxDepth: Int = 6
    ) -> [String]? {
        let tokens = term.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scopeURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: scopeURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return nil }

        var matches: [String] = []
        var scanned = 0
        for case let url as URL in enumerator {
            scanned += 1
            if scanned > maxScanned { break }
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent.lowercased()
            if tokens.allSatisfy({ name.contains($0) }) {
                matches.append(url.path)
                if matches.count >= maxResults { break }
            }
        }
        return matches
    }

    // MARK: - Reusable Query Executor

    /// Runs a single NSMetadataQuery with the given raw query string and returns paths up to `limit`.
    private func runQuery(rawQuery: String, scopes: [Any], limit: Int) async -> [String] {
        guard !rawQuery.isEmpty else { return [] }

        return await withCheckedContinuation { continuation in
            nonisolated(unsafe) let query = NSMetadataQuery()
            query.sortDescriptors = [
                NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false),
                NSSortDescriptor(key: NSMetadataItemDisplayNameKey, ascending: true)
            ]
            query.valueListAttributes = requiredAttributes

            guard let predicate = NSPredicate(fromMetadataQueryString: rawQuery) else {
                continuation.resume(returning: [])
                return
            }
            query.predicate = predicate
            query.searchScopes = scopes

            nonisolated(unsafe) var observer: NSObjectProtocol?
            nonisolated(unsafe) var hasResumed = false

            @Sendable func finish(_ results: [String]) {
                guard !hasResumed else { return }
                hasResumed = true
                if let obs = observer { NotificationCenter.default.removeObserver(obs) }
                query.stop()
                continuation.resume(returning: Array(results.prefix(limit)))
            }

            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { @Sendable _ in
                query.disableUpdates()
                let paths = (query.results as? [NSMetadataItem] ?? []).compactMap {
                    $0.value(forAttribute: NSMetadataItemPathKey) as? String
                }
                finish(paths)
            }

            query.start()

            // Timeout Safety: 4.0s max per query phase
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if query.isGathering {
                    query.disableUpdates()
                    let paths = (query.results as? [NSMetadataItem] ?? []).compactMap {
                        $0.value(forAttribute: NSMetadataItemPathKey) as? String
                    }
                    finish(paths)
                }
            }
        }
    }

    // MARK: - Query Builders

    /// Builds a query over filenames only (DisplayName + FSName): high signal, low noise.
    private func buildNameOnlyQuery(from input: String) -> String {
        let tokens = input.split(separator: " ")
        guard !tokens.isEmpty else { return "" }

        let subQueries = tokens.map { token -> String in
            let escaped = String(token).replacingOccurrences(of: "\"", with: "\\\"")
            return "((kMDItemDisplayName == \"*\(escaped)*\"cdw) || (kMDItemFSName == \"*\(escaped)*\"cdw))"
        }

        return applyExclusions(to: subQueries.joined(separator: " && "))
    }

    /// Builds a query over file content only (TextContent): broader reach, higher noise.
    private func buildContentOnlyQuery(from input: String) -> String {
        let tokens = input.split(separator: " ")
        guard !tokens.isEmpty else { return "" }

        let subQueries = tokens.map { token -> String in
            let escaped = String(token).replacingOccurrences(of: "\"", with: "\\\"")
            return "(kMDItemTextContent == \"\(escaped)\"cdw)"
        }

        return applyExclusions(to: subQueries.joined(separator: " && "))
    }

    /// Appends system path exclusions (Library, Trash) to a query string.
    private func applyExclusions(to query: String) -> String {
        guard filterSystemPaths else { return query }
        let exclusions = ["*/Library/*", "*/.Trash/*"]
        let exclusionQuery = exclusions.map { "kMDItemPath != \"\($0)\"" }.joined(separator: " && ")
        return "(\(query)) && (\(exclusionQuery))"
    }

    // MARK: - Search Result Model

    /// Structured result from a two-phase search, categorizing matches by relevance tier.
    struct SearchResult {
        let nameMatches: [String]
        let contentMatches: [String]
        let permissionNote: String?
        /// Where the answer came from when it did NOT come from the Spotlight index
        /// (filesystem-scan fallback, unverifiable scope). Rendered with the output —
        /// including for EMPTY results — so absence claims carry their evidence level.
        let provenanceNote: String?
        let error: String?

        /// Total number of results across all categories.
        var totalCount: Int { nameMatches.count + contentMatches.count }
        var isEmpty: Bool { nameMatches.isEmpty && contentMatches.isEmpty }
        var hasError: Bool { error != nil }

        init(nameMatches: [String] = [], contentMatches: [String] = [], permissionNote: String? = nil, provenanceNote: String? = nil, error: String? = nil) {
            self.nameMatches = nameMatches
            self.contentMatches = contentMatches
            self.permissionNote = permissionNote
            self.provenanceNote = provenanceNote
            self.error = error
        }

        init(error: String) {
            self.nameMatches = []
            self.contentMatches = []
            self.permissionNote = nil
            self.provenanceNote = nil
            self.error = error
        }
    }
}

// MARK: - FS Smart Search (Spotlight + Hybrid)

struct SmartSearchTool: DevgenticTool {
    let name = "spotlight_search"
    let category = "File System"
    let description = "Advanced macOS Spotlight Search. Finds files by matching Filename OR Text Content. Supports partial matches and scope limiting; scoped searches fall back to a direct filename scan when the Spotlight index has no coverage (e.g. /tmp)."
    
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
            let scopeKeys = ToolPathKeys.spotlightScope
            
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
        do {
            let result = try await HybridSearchService.shared.search(
                term: arguments.search_term,
                scope: arguments.search_scope
            )

            // Check for explicit error
            if let error = result.error {
                return "\(error)"
            }

            if result.isEmpty {
                var message = "No results found matching '\(arguments.search_term)'."
                // Absence claims carry their evidence level, so the model can tell an index-only miss from a disk-verified one.
                if let note = result.provenanceNote {
                    message += "\n\(note)"
                }
                return message
            }

            // Build structured output with relevance tiers
            var output = "Search Results for '\(arguments.search_term)' (\(result.totalCount) items):\n"

            if !result.nameMatches.isEmpty {
                output += "\n📁 Name Matches (\(result.nameMatches.count)):\n"
                output += result.nameMatches.map { path -> String in
                    let icon = path.contains(".") ? "📄" : "📁"
                    return "- \(icon) \(path)"
                }.joined(separator: "\n")
            }

            if !result.contentMatches.isEmpty {
                output += "\n\n📄 Content Matches (\(result.contentMatches.count)):\n"
                output += result.contentMatches.map { "- 📄 \($0)" }.joined(separator: "\n")
            }

            if let note = result.permissionNote {
                output += "\n\n\(note)"
            }

            if let note = result.provenanceNote {
                output += "\n\n\(note)"
            }

            return "\(output)"

        } catch {
            return "Error: search failed — \(error.localizedDescription)"
        }
    }
}

// MARK: - FS Read Metadata

struct ReadMetadataTool: DevgenticTool {
    let name = "read_file_metadata"
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
            let keys = ToolPathKeys.fileMetadata
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
        // Resolved through `FilePathResolver`; a raw `URL(fileURLWithPath:)` anchors relative paths at the process
        // working directory (`/` for a Finder-launched app), so the same string would address different files per tool.
        let resolvedPath = FilePathResolver.resolve(arguments.path)
        let url = URL(fileURLWithPath: resolvedPath)
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
            
            return info + ""
        } catch {
            return "Error reading metadata: \(error.localizedDescription)"
        }
    }
}

// MARK: - FS Organize Batch

struct OrganizeBatchTool: DevgenticTool {
    let name = "batch_move_files"
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
            let possibleKeys = ToolPathKeys.batchMoveSources
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
            let destKeys = ToolPathKeys.batchMoveDestination
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
            
            // `dryRun` accepts the same spelling variants as the other arguments, plus stringified booleans ("true").
            // A dropped `dry_run` would perform the real, irreversible move instead of a no-op.
            var dryRunValue: Bool? = nil
            let dryRunKeys = ["dryRun", "dry_run", "dryrun", "is_dry_run", "isDryRun", "simulate", "preview"]
            for key in dryRunKeys {
                guard let codingKey = DynamicKey(stringValue: key) else { continue }
                if let boolVal = try? container.decode(Bool.self, forKey: codingKey) {
                    dryRunValue = boolVal
                    break
                }
                if let strVal = try? container.decode(String.self, forKey: codingKey),
                   let boolVal = Bool(strVal.lowercased()) {
                    dryRunValue = boolVal
                    break
                }
            }
            self.dryRun = dryRunValue
        }
    }
    
    var parameterSchema: ToolParameters {
        let props: [String: ToolParameterProperty] = [
            "sourcePaths": ToolParameterProperty(type: "array", description: "Array of full file paths to move.", items: ["type": "string"]),
            "destinationFolder": ToolParameterProperty(type: "string", description: "The target folder path.", items: nil),
            "dryRun": ToolParameterProperty(type: "boolean", description: "If true, simulates the move.", items: nil)
        ]
        return ToolParameters(type: "object", properties: props, required: ["sourcePaths", "destinationFolder"])
    }
    
    private var fileManager: FileManager { .default }
    
    func call(arguments: Arguments) async throws -> String {
        let isDryRun = arguments.dryRun ?? false
        /// Where each file went, emitted in the `[FSBATCH]` log line; the returned string reports counts only.
        var operationsLog: [(from: String, to: String)] = []
        var movedCount = 0
        var errors: [String] = []

        // Resolved through `FilePathResolver`; a raw relative path would anchor at the process working directory (`/`).
        let destURL = URL(fileURLWithPath: FilePathResolver.resolve(arguments.destinationFolder))
        if !isDryRun {
            do {
                if !fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.createDirectory(at: destURL, withIntermediateDirectories: true)
                }
            } catch {
                return "Error: Could not create destination folder: \(error.localizedDescription)"
            }
        }
        
        for rawSourcePath in arguments.sourcePaths {
            let sourcePath = FilePathResolver.resolve(rawSourcePath)
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let fileName = sourceURL.lastPathComponent
            let destFileURL = destURL.appendingPathComponent(fileName)

            if !fileManager.fileExists(atPath: sourcePath) {
                errors.append("Skipped (Not Found): \(fileName)")
                continue
            }

            if isDryRun {
                movedCount += 1
                operationsLog.append((from: sourcePath, to: destFileURL.path))
                continue
            }

            do {
                if fileManager.fileExists(atPath: destFileURL.path) {
                    errors.append("Skipped (Exists): \(fileName)")
                } else {
                    try fileManager.moveItem(at: sourceURL, to: destFileURL)
                    movedCount += 1
                    operationsLog.append((from: sourcePath, to: destFileURL.path))
                }
            } catch {
                errors.append("Error moving \(fileName): \(error.localizedDescription)")
            }
        }

        var resultMessage = isDryRun ? "[DRY RUN] " : ""
        resultMessage += "Processed \(arguments.sourcePaths.count) files. Moved: \(movedCount). Errors: \(errors.count)."
        if !errors.isEmpty { resultMessage += "\nDetails: \(errors.joined(separator: ", "))" }

        // Logs the mode and a capped source-to-destination mapping: a batch move is irreversible and the string
        // returned to the model carries counts only. The cap keeps a large batch from producing one unreadable line.
        let mappingCap = 20
        let mapping = operationsLog.prefix(mappingCap)
            .map { "\($0.from) -> \($0.to)" }
            .joined(separator: "; ")
        let overflow = operationsLog.count > mappingCap
            ? " (+\(operationsLog.count - mappingCap) more not listed)"
            : ""

        logger.info("""
            [FSBATCH] \(isDryRun ? "SIMULATED" : "MOVED") \(movedCount) of \
            \(arguments.sourcePaths.count) file(s) into '\(destURL.path)'; \(errors.count) skipped \
            or failed\(errors.isEmpty ? "" : " — \(errors.joined(separator: "; "))"). \
            \(isDryRun ? "No file was touched." : "Sources no longer exist at their old paths.")\
            \(mapping.isEmpty ? "" : " Mapping: \(mapping)\(overflow)")
            """)

        return resultMessage
    }
}

// MARK: - FS Watch Folder

// Why: tool calls reach this singleton concurrently, so every `activeMonitors` access must hold the lock;
// a lost entry leaks the file descriptor and the monitor can never be stopped.
/// Tracks the folder monitors `watch_folder` has started.
/// A lock (not an actor) guards `activeMonitors` because the methods are synchronous.
final class WatcherService: @unchecked Sendable {
    static let shared = WatcherService()

    /// Guards `activeMonitors` on EVERY path. Never held across a call out to dispatch — see
    /// `stopWatching`, which cancels its source after releasing.
    private let lock = NSLock()
    private var activeMonitors: [UUID: (source: DispatchSourceFileSystemObject, path: String)] = [:]

    func startWatching(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor != -1 else { return "Error: could not open a file descriptor for that path — it may not exist or may not be readable." }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend], queue: DispatchQueue.global())
        let id = UUID()

        source.setEventHandler {
            print("FS EVENT: Change detected in \(path)")
            NotificationCenter.default.post(name: Notification.Name("DevgenticFSEvent"), object: nil, userInfo: ["path": path])
        }

        source.setCancelHandler { close(descriptor) }
        source.resume()

        // Only the map mutation is guarded. Opening the descriptor and arming the source touch
        // no shared state, and holding a lock across them would serialise unrelated work.
        lock.lock()
        activeMonitors[id] = (source: source, path: path)
        lock.unlock()

        return "Started watching \(path). Monitor ID: \(id.uuidString)."
    }

    func stopWatching(monitorID: String) -> String {
        guard let uuid = UUID(uuidString: monitorID) else {
            return "Error: No active monitor with ID '\(monitorID)'."
        }

        // Look up and remove ATOMICALLY. The previous read-then-remove let two concurrent stops
        // both find the entry, so both cancelled the same source and reported success.
        lock.lock()
        let entry = activeMonitors.removeValue(forKey: uuid)
        lock.unlock()

        guard let entry else {
            return "Error: No active monitor with ID '\(monitorID)'."
        }

        // Cancelled after releasing the lock: `cancel()` schedules the cancel handler, and
        // calling out to dispatch while holding a lock is how deadlocks are grown.
        entry.source.cancel()
        return "Stopped monitoring '\(entry.path)' (ID: \(monitorID))."
    }

    func listActive() -> [(id: String, path: String)] {
        lock.lock()
        defer { lock.unlock() }
        return activeMonitors.map { (id: $0.key.uuidString, path: $0.value.path) }
    }
}

struct WatchFolderTool: DevgenticTool {
    let name = "watch_folder"
    let category = "File System"
    let description = "Manages folder monitoring: start watching, stop watching, or list active monitors."

    struct Arguments: Decodable, Sendable {
        let action: String?
        let path: String?
        let monitor_id: String?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            self.action = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "action")!))

            var foundPath: String? = nil
            let keys = ToolPathKeys.watchFolder
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let str = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = str
                    break
                }
            }
            self.path = foundPath
            self.monitor_id = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "monitor_id")!))
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'start' (default), 'stop', 'list'"),
                ("path", "string", "Folder path to watch (required for start)"),
                ("monitor_id", "string", "Monitor ID to stop (required for stop)")
            ],
            required: []
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let action = arguments.action ?? "start"

        switch action {
        case "start":
            guard let path = arguments.path else {
                return "Error: 'path' required for start."
            }
            return WatcherService.shared.startWatching(path: path)

        case "stop":
            guard let monitorID = arguments.monitor_id else {
                return "Error: 'monitor_id' required for stop."
            }
            let result = WatcherService.shared.stopWatching(monitorID: monitorID)
            return "\(result)"

        case "list":
            let monitors = WatcherService.shared.listActive()
            if monitors.isEmpty {
                return "No active folder monitors."
            }
            let list = monitors.map { "- [\($0.id)] \($0.path)" }.joined(separator: "\n")
            return "Active Monitors (\(monitors.count)):\n\(list)"

        default:
            return "Error: Unknown action '\(action)'. Use start/stop/list."
        }
    }
}
