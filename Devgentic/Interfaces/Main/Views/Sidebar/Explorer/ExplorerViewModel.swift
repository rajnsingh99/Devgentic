// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExplorerViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os
import UniformTypeIdentifiers

@Observable @MainActor
final class ExplorerViewModel {
    private(set) var treeVersion: Int = 0
    @ObservationIgnored var onNodeReloadRequired: ((URL) -> Void)?
    @ObservationIgnored var onOpenFileRequested: ((FileSystemItem) -> Void)?

    var rootItems: [FileSystemItem] = [] {
        didSet {
            recomputeFilteredRootItems()
            treeVersion &+= 1
        }
    }
    var selectedRootURL: URL? = nil {
        willSet {
            if let currentURL = self.selectedRootURL {
                if currentURL != newValue || newValue == nil {
                    currentURL.stopAccessingSecurityScopedResource()
                    logger.info("Stopped accessing security-scoped resource (willSet for selectedRootURL) for: \(currentURL.path)")
                }
            }
        }
        didSet {
            if oldValue != selectedRootURL {
                rootItems = []
                expandedItemIDs = []
                errorMessage = nil
                // ⚠️ The `@` index belongs to the folder — drop it with the folder. It used to be
                // only REPLACED when a new folder finished indexing, so a root going to none (Chat
                // with no folder, Code Home) kept offering the previous folder's files: Code's
                // `java` project showed up in Chat's `@` picker. Also stop a pending file-change
                // refresh for the old folder, which would append its files back.
                allSuggestableFiles = []
                fileSystemDebounceTask?.cancel()

                // Publish as an MCP root. Roots are not a Code-mode feature — the folder open
                // here is "the folder this app is working in" for chat and workflow too, and
                // is the only workspace boundary those interfaces can offer a server.
                //
                // Published even when it fails to open below: an MCP server's access rests on
                // ordinary file permissions, not on this app's security-scoped grant, so the
                // boundary is still the right thing to state.
                let published = selectedRootURL
                Task { await MCPRootsProvider.setExplorerRoot(published) }
            }

            if let newURL = selectedRootURL {
                let hasSecurityScope = newURL.startAccessingSecurityScopedResource()
                if hasSecurityScope {
                    logger.info("Successfully started accessing security-scoped resource (didSet for selectedRootURL) for: \(newURL.path)")
                    // ⚠️ Only CHAT's folder is the remembered one. Code shows its project here
                    // too, and saving that overwrote Chat's folder — switching back to Chat then
                    // showed the Code project.
                    if scope == .chat { saveBookmark(for: newURL) }
                } else {
                    logger.info("Selected URL is not security-scoped or does not require scoped access: \(newURL.path)")
                }

                if FileManager.default.isReadableFile(atPath: newURL.path) {
                    // Trigger deep search and start monitoring.
                    Task {
                        await indexAllFiles(from: newURL)
                    }
                    startMonitoring(path: newURL.path)

                    loadDirectoryContents(for: newURL)
                } else {
                    logger.error("Folder at path is not readable: \(newURL.path). Files might not be accessible.")
                    self.errorMessage = "Could not gain permission to access this folder. Please try selecting it again. If the issue persists, check app permissions in System Settings (Privacy & Security -> Files and Folders)."
                    self.rootItems = []
                    self.isLoading = false
                    self.expandedItemIDs = []
                    if scope == .chat {
                        chatRootURL = nil
                        clearLastOpenedFolderBookmark()
                    }
                }
            } else {
                // Stop monitoring when the folder is closed.
                stopMonitoring()
                self.rootItems = []
                self.errorMessage = nil
                self.isLoading = false
                self.expandedItemIDs = []
                // Code Home shows NO folder; that must not forget Chat's.
                if scope == .chat { clearLastOpenedFolderBookmark() }
                logger.info("selectedRootURL is now nil (\(self.scope == .chat ? "chat — bookmark cleared" : "code — chat's folder kept")).")
            }
        }
    }
    
    var searchText: String = "" {
        didSet {
            recomputeFilteredRootItems()
            treeVersion &+= 1
        }
    }
    private(set) var filteredRootItems: [FileSystemItem] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil

    var itemBeingRenamedID: URL? = nil
    var currentEditName: String = ""
    var renameErrorMessage: String? = nil

    var expandedItemIDs: Set<URL> = []
    var loadingIDs: Set<URL> = []
    @ObservationIgnored private var preSearchExpandedItemIDs: Set<URL>? = nil

    // The in-memory cache for all files in the directory.
    var allSuggestableFiles: [FileSystemItem] = []

    // A flag to provide UI feedback during the initial scan.
    var isIndexing: Bool = false

    // A property to hold our real-time file system monitor.
    @ObservationIgnored private var fileSystemMonitor: FileSystemMonitor?
    @ObservationIgnored private var fileSystemDebounceTask: Task<Void, Never>?

    @ObservationIgnored private let logger = DGLogger(category: "ExplorerViewModel")
    @ObservationIgnored private static let lastOpenedFolderBookmarkKey = "explorerLastOpenedFolderBookmark"

    // MARK: - Whose folder is showing
    //
    // The Explorer is shared by Chat and Code, but each owns a different folder:
    //  • Chat — the folder the user opened here; remembered across launches (the bookmark).
    //  • Code — the Code session's project (`CodeSessionManager.projectPath`), or none on Home.
    // Both used to write ONE root, so Code's project leaked into Chat and Chat's folder into a
    // Code session. `MainApplicationViewModel.syncExplorerToInterfaceMode` picks the owner.

    enum Scope: Equatable { case chat, code }

    /// Which mode's folder `selectedRootURL` currently shows.
    private(set) var scope: Scope = .chat

    /// Chat's folder, kept while Code borrows the Explorer.
    @ObservationIgnored private(set) var chatRootURL: URL?

    /// Set by the app to `chooseCodeFolder`, which binds the folder to the Code session. In Code
    /// scope the Explorer's folder buttons hand their pick to this instead of showing an
    /// Explorer-only folder, which would leave Code running in a different project.
    @ObservationIgnored var chooseCodeProject: ((URL) -> Void)?

    /// Show Chat's own folder (or none — the "Open Folder" state).
    func showChatFolder() {
        scope = .chat
        if selectedRootURL?.standardizedFileURL != chatRootURL?.standardizedFileURL {
            selectedRootURL = chatRootURL
        }
        logger.info("[EXPLORER] Showing Chat's folder: \(self.chatRootURL.map { "'\($0.lastPathComponent)'" } ?? "none — Open Folder").")
    }

    /// Chat's folder is now `url` — remembered (bookmark) and shown.
    func openChatFolder(_ url: URL) {
        scope = .chat
        chatRootURL = url
        selectedRootURL = url
    }

    /// Show the Code session's project, or nil for Code Home ("Select Project folder").
    func showCodeProject(_ url: URL?) {
        scope = .code
        if selectedRootURL?.standardizedFileURL != url?.standardizedFileURL {
            selectedRootURL = url
        } else if let url {
            // Same folder: didSet won't fire, so refresh explicitly (the tree may be stale).
            loadDirectoryContents(for: url)
        }
        logger.info("[EXPLORER] Showing the Code project: \(url.map { "'\($0.lastPathComponent)'" } ?? "none — Select Project folder").")
    }

    /// Where Chat's folder bookmark lives. Injectable so tests use a throwaway suite: with
    /// `.standard` they read — and could clear — the developer's real Chat folder, and any
    /// assertion about "Chat has no folder" depended on the machine running it.
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        logger.info("ExplorerViewModel initializing.")
        loadLastOpenedFolder()
    }

    /// Recomputes filteredRootItems from rootItems and searchText.
    /// Called via didSet on both rootItems and searchText.
    private func recomputeFilteredRootItems() {
        let items = rootItems
        guard !searchText.isEmpty else {
            filteredRootItems = items
            if let preSearch = preSearchExpandedItemIDs {
                expandedItemIDs = preSearch
                preSearchExpandedItemIDs = nil
            }
            return
        }

        if preSearchExpandedItemIDs == nil {
            preSearchExpandedItemIDs = expandedItemIDs
        }

        let query = searchText.lowercased()
        var matchingAncestors: Set<URL> = []

        func filterItems(_ items: [FileSystemItem]) -> [FileSystemItem] {
            var result: [FileSystemItem] = []
            for item in items {
                if item.name.lowercased().contains(query) {
                    result.append(item)
                    if item.isDirectory {
                        matchingAncestors.insert(item.id)
                    }
                } else if let children = item.children {
                    let filteredChildren = filterItems(children)
                    if !filteredChildren.isEmpty {
                        var copy = item
                        copy.children = filteredChildren
                        result.append(copy)
                        matchingAncestors.insert(item.id)
                    }
                }
            }
            return result
        }

        filteredRootItems = filterItems(items)
        expandedItemIDs.formUnion(matchingAncestors)
    }

    deinit {
        logger.info("ExplorerViewModel deinitialized. Resource cleanup for selectedRootURL is managed by its property observers.")
        // The call to stopMonitoring() is removed. The FileSystemMonitor's own deinit will handle the cleanup automatically
        // when the ExplorerViewModel is deallocated, which is the correct and safe pattern.
    }

    /// Task-based debounce for file system events. Cancels previous pending task on each new event.
    private func handleFileSystemEvent(_ url: URL) {
        fileSystemDebounceTask?.cancel()
        fileSystemDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.logger.info("Debounced file system event triggered for \(url.path). Refreshing contents.")

            if url == self.selectedRootURL || url.resolvingSymlinksInPath().path == self.selectedRootURL?.resolvingSymlinksInPath().path {
                await self.indexAllFiles(from: url)
                self.loadDirectoryContents(for: url)
            } else {
                await self.refreshSubfolder(at: url)
            }
        }
    }
        
    // MARK: - File Operations (New & Existing)
    
    // --- STEP 2.5: New Context Menu Actions ---
    func copyRelativePath(_ item: FileSystemItem) {
        guard let rootPath = selectedRootURL?.path else { return }
        var itemPath = item.url.path
        
        if itemPath.hasPrefix(rootPath) {
            // Remove the root path prefix to get the relative path
            itemPath.removeFirst(rootPath.count)
            // Remove leading slash if it exists
            if itemPath.hasPrefix("/") {
                itemPath.removeFirst()
            }
        }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(itemPath, forType: .string)
        logger.info("Copied relative path to clipboard: \(itemPath)")
    }
        
    func openInTerminal(_ item: FileSystemItem) {
        let path: String
        if item.isDirectory {
            path = item.url.path
        } else {
            path = item.url.deletingLastPathComponent().path
        }
        
        // TWO interpreters nest here, and the path has to survive both.
        //
        // `do script` hands its string to a SHELL, and that string is itself an AppleScript
        // literal. Previously the path went in raw inside escaped double quotes: a folder named
        // `a"; rm -rf ~; #` closed the AppleScript literal AND the shell quoting. The path comes
        // from disk, so a crafted filename in any downloaded archive or cloned repo was enough —
        // no model involvement needed.
        //
        // Inner layer: POSIX single-quote the path, which makes every character literal to the
        // shell (`'` itself is closed, escaped and reopened). Outer layer: escape the resulting
        // string for the AppleScript literal.
        let shellQuotedPath = "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let escapedCommand = AppleScriptEscaping.escapeStringLiteral("cd \(shellQuotedPath)")
        let scriptSource = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """
        
        if let script = NSAppleScript(source: scriptSource) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let err = error {
                logger.error("AppleScript error opening terminal: \(err)")
            } else {
                logger.info("Opened terminal at path: \(path)")
            }
        }
    }

    // MARK: - Persistence Logic
    private func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope)
            defaults.set(bookmarkData, forKey: Self.lastOpenedFolderBookmarkKey)
            logger.info("Saved security-scoped bookmark for URL: \(url.path)")
        } catch {
            logger.error("Failed to save bookmark for URL \(url.path): \(error.localizedDescription)")
            clearLastOpenedFolderBookmark()
        }
    }

    private func loadLastOpenedFolder() {
        guard let bookmarkData = defaults.data(forKey: Self.lastOpenedFolderBookmarkKey) else {
            logger.info("No saved folder bookmark found.")
            return
        }
        do {
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                logger.warning("Resolved bookmark is stale for URL: \(resolvedURL.path). Will attempt to re-access and re-save via selectedRootURL.didSet.")
            }
            logger.info("Successfully resolved bookmark to URL: \(resolvedURL.path)")
            self.chatRootURL = resolvedURL
            self.selectedRootURL = resolvedURL
        } catch {
            logger.error("Failed to resolve bookmark data or access persisted URL: \(error.localizedDescription)")
            clearLastOpenedFolderBookmark()
        }
    }

    private func clearLastOpenedFolderBookmark() {
        defaults.removeObject(forKey: Self.lastOpenedFolderBookmarkKey)
        logger.info("Cleared last opened folder bookmark from UserDefaults.")
    }

    // MARK: - Expansion State Management
    func expansionBinding(for item: FileSystemItem) -> Binding<Bool> {
        Binding(
            get: { self.expandedItemIDs.contains(item.id) },
            set: { isExpanding in
                if isExpanding {
                    self.expandedItemIDs.insert(item.id)
                    if item.isDirectory && item.children == nil {
                        self.logger.info("DisclosureGroup expanding '\(item.name)', triggering lazy load.")
                        self.toggleFolderExpansion(for: item)
                    }
                } else {
                    self.expandedItemIDs.remove(item.id)
                }
            }
        )
    }

    // MARK: - Directory Operations
    func selectRootDirectory() {
        // In Code the folder IS the session's project — pick it through the Code flow.
        if scope == .code, let chooseCodeProject {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "Select Project Folder")
            panel.message = String(localized: "Choose a folder for your Code session.")
            if panel.runModal() == .OK, let url = panel.url {
                logger.info("[EXPLORER] Code project chosen from the Explorer: \(url.path)")
                chooseCodeProject(url)
            }
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose Root Folder"
        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                logger.info("Root directory selected via panel: \(url.path)")
                openChatFolder(url)
            }
        }
    }

    func loadDirectoryContents(for rootURL: URL) {
        if let currentError = self.errorMessage,
           currentError.contains("Could not gain permission"),
           self.selectedRootURL == rootURL {
            logger.warning("Skipping loadDirectoryContents for \(rootURL.path) due to existing permission error: \(currentError)")
            self.isLoading = false
            return
        }
        isLoading = true
        if !(self.errorMessage?.contains("Could not gain permission") == true && self.selectedRootURL == rootURL) {
            errorMessage = nil
        }
        var expandRootAfterLoad = true
        Task(priority: .userInitiated) {
            var rootName = rootURL.lastPathComponent
            var isRootActuallyDirectory = false
            do {
                let resourceValues = try rootURL.resourceValues(forKeys: [.nameKey, .isDirectoryKey])
                rootName = resourceValues.name ?? rootURL.lastPathComponent
                isRootActuallyDirectory = resourceValues.isDirectory ?? false
                guard isRootActuallyDirectory else {
                    expandRootAfterLoad = false
                    await MainActor.run {
                        self.errorMessage = "'\(rootName)' is not a folder."
                        self.isLoading = false
                        self.rootItems = []
                        self.logger.error("Selected item \(rootURL.path) ('\(rootName)') is not a directory.")
                    }
                    return
                }
                var rootListItem = FileSystemItem(id: rootURL, name: rootName, url: rootURL, isDirectory: true, children: [])
                do {
                    let childrenItems = try await fetchItems(at: rootURL)
                    rootListItem.children = childrenItems
                    await MainActor.run {
                        self.rootItems = [rootListItem]
                        self.isLoading = false
                        if self.selectedRootURL == rootURL && self.errorMessage?.contains("Could not load contents of '\(rootListItem.name)'") == true {
                           self.errorMessage = nil
                        }
                        if expandRootAfterLoad && !self.expandedItemIDs.contains(rootURL) {
                            self.expandedItemIDs.insert(rootURL)
                        }
                        self.logger.info("Successfully loaded root '\(rootListItem.name)' with \(childrenItems.count) children for \(rootURL.path)")
                    }
                } catch {
                    expandRootAfterLoad = false
                    await MainActor.run {
                        self.rootItems = [rootListItem]
                        if !(self.errorMessage?.contains("Could not gain permission") == true && self.selectedRootURL == rootURL) {
                            self.errorMessage = "Could not load contents of '\(rootListItem.name)': \(error.localizedDescription)"
                        }
                        self.isLoading = false
                        self.logger.error("Error loading children for directory \(rootURL.path) ('\(rootListItem.name)'): \(error.localizedDescription)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Could not read attributes of '\(rootName)': \(error.localizedDescription)"
                    self.isLoading = false
                    self.rootItems = []
                    self.logger.error("Error getting resource values for root \(rootURL.path): \(error.localizedDescription)")
                }
            }
        }
    }

    func toggleFolderExpansion(for item: FileSystemItem) {
        guard item.isDirectory else { return }
        
        guard !loadingIDs.contains(item.id) else {
            logger.info("Load for folder '\(item.name)' is already in progress. Ignoring duplicate request.")
            return
        }

        if let currentError = self.errorMessage, currentError.contains("Could not gain permission"),
           (selectedRootURL == item.url || item.url.path.hasPrefix(selectedRootURL?.path ?? "___INVALID_PATH___")) {
            logger.warning("Skipping folder expansion/load for \(item.name) due to existing permission error related to its hierarchy.")
            return
        }
        
        if item.children == nil {
            logger.info("Data load triggered for folder: \(item.url.path) (children have not been loaded yet)")
            loadingIDs.insert(item.id)
            
            Task {
                do {
                    let children = try await fetchItems(at: item.url)
                    await MainActor.run {
                        self.updateChildren(for: item.id, with: children)
                        if self.errorMessage?.contains("Failed to load contents of '\(item.name)'") == true {
                            self.errorMessage = nil
                        }
                        self.loadingIDs.remove(item.id)
                    }
                } catch {
                    await MainActor.run {
                        if !(self.errorMessage?.contains("Could not gain permission") == true) {
                             self.errorMessage = "Failed to load contents of '\(item.name)': \(error.localizedDescription)"
                        }
                        self.updateChildren(for: item.id, with: [])
                        self.logger.error("Error lazy loading children for folder \(item.url.path): \(error.localizedDescription)")
                        self.loadingIDs.remove(item.id)
                    }
                }
            }
        } else {
            logger.debug("Folder '\(item.name)' children already loaded. UI expansion handled by DisclosureGroup binding.")
        }
    }

    func collapseAll() {
        expandedItemIDs.removeAll()
        treeVersion &+= 1
        if let root = selectedRootURL {
            onNodeReloadRequired?(root)
        }
    }

    func refresh() {
        if let root = selectedRootURL {
            loadDirectoryContents(for: root)
        }
    }
        
    private func updateChildren(for parentId: URL, with children: [FileSystemItem]) {
        let parentStandardized = parentId.resolvingSymlinksInPath().path
        func findAndUpdate(items: inout [FileSystemItem]) -> Bool {
            for i in 0..<items.count {
                let itemStandardized = items[i].id.resolvingSymlinksInPath().path
                if items[i].id == parentId || items[i].id.path == parentId.path || itemStandardized == parentStandardized {
                    items[i].children = children
                    return true
                }
                if items[i].isDirectory, items[i].children != nil {
                    var childItems = items[i].children!
                    if findAndUpdate(items: &childItems) {
                        items[i].children = childItems
                        return true
                    }
                }
            }
            return false
        }
        if findAndUpdate(items: &rootItems) {
            // @Observable tracks rootItems mutation automatically
            recomputeFilteredRootItems()
            treeVersion &+= 1
            onNodeReloadRequired?(parentId)
        }
    }

    private func fetchItems(at url: URL) async throws -> [FileSystemItem] {
        var items: [FileSystemItem] = []
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.nameKey, .isDirectoryKey, .isHiddenKey]

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(resourceKeys), options: [])
        
        for itemURL in contents {
            let resourceValues = try itemURL.resourceValues(forKeys: resourceKeys)
            if resourceValues.isHidden == true { continue }
            let name = resourceValues.name ?? itemURL.lastPathComponent
            let isDirectory = resourceValues.isDirectory ?? false
            items.append(FileSystemItem(id: itemURL, name: name, url: itemURL, isDirectory: isDirectory, children: nil))
        }
        return items.sorted {
            if $0.isDirectory && !$1.isDirectory { return true }
            if !$0.isDirectory && $1.isDirectory { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    
    // MARK: - File Operations
    func openFile(_ item: FileSystemItem) {
        logger.info("openFile called for: \(item.name) at \(item.url.path)")
        
        guard !item.isDirectory else {
            logger.info("openFile: Item is a directory, skipping open.")
            return
        }
        
        if let onOpenFileRequested {
            onOpenFileRequested(item)
            return
        }
        
        openWithSystemApp(item)
    }

    func openWithSystemApp(_ item: FileSystemItem) {
        guard !item.isDirectory else {
            logger.info("openWithSystemApp: Item is a directory, skipping.")
            return
        }

        // Ensure we have access if it's security-scoped
        let url = item.url
        let accessStarted = url.startAccessingSecurityScopedResource()
        if accessStarted {
            logger.debug("Started accessing security-scoped resource for opening: \(url.path)")
        }
        
        defer {
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
                logger.debug("Stopped accessing security-scoped resource for opening: \(url.path)")
            }
        }
        
        if NSWorkspace.shared.open(url) {
            logger.info("Successfully opened file with system default app: \(item.name)")
        } else {
            logger.error("Failed to open file with system default app: \(item.name) at \(url.path)")
            self.errorMessage = "Could not open '\(item.name)' with the system default application."
        }
    }
    func revealInFinder(_ item: FileSystemItem) {
        let hasScope = item.url.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                item.url.stopAccessingSecurityScopedResource()
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
        logger.info("Revealing item in Finder: \(item.url.path)")
    }
    func copyPath(_ item: FileSystemItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.url.path, forType: .string)
        logger.info("Copied path to clipboard: \(item.url.path)")
    }
    func startRename(_ item: FileSystemItem) {
        logger.info("Starting rename for: \(item.name) (ID: \(item.id.path))")
        itemBeingRenamedID = item.id
        currentEditName = item.name
        renameErrorMessage = nil
    }
    func commitRename() {
        guard let itemIDToRename = itemBeingRenamedID,
              let itemToRename = findItem(by: itemIDToRename, in: rootItems) else {
            logger.error("CommitRename called but itemToRename or its ID is nil.")
            cancelRename(); return
        }
        let newName = currentEditName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            renameErrorMessage = "Name cannot be empty."; logger.warning("New name is empty."); return
        }
        guard newName != itemToRename.name else {
            logger.info("New name is the same as the old name. Cancelling rename."); cancelRename(); return
        }
        if newName.contains(":") || newName.contains("/") {
            renameErrorMessage = "Name cannot contain ':' or '/'."; logger.warning("Invalid characters in new name: \(newName)"); return
        }
        let fileManager = FileManager.default
        let oldURL = itemToRename.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
        if fileManager.fileExists(atPath: newURL.path) {
            renameErrorMessage = "An item named \"\(newName)\" already exists."; logger.warning("Rename failed: item with new name already exists at \(newURL.path)"); return
        }
        logger.info("Attempting to rename '\(itemToRename.name)' to '\(newName)' (URL: \(oldURL.path) -> \(newURL.path))")
        let parentURL = oldURL.deletingLastPathComponent()
        let hasScope = parentURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                parentURL.stopAccessingSecurityScopedResource()
            }
        }
        Task {
            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
                logger.info("Successfully renamed item: \(oldURL.lastPathComponent) -> \(newName)")
                await MainActor.run {
                    self.cancelRename()
                    self.replaceItemInTree(oldURL: oldURL, newURL: newURL, newName: newName)
                }
            } catch {
                logger.error("Failed to rename item: \(error.localizedDescription)")
                await MainActor.run { self.renameErrorMessage = "Failed to rename: \(error.localizedDescription)" }
            }
        }
    }
    func cancelRename() {
        logger.info("Cancelling rename.")
        itemBeingRenamedID = nil
        currentEditName = ""
        renameErrorMessage = nil
    }

    private func replaceItemInTree(oldURL: URL, newURL: URL, newName: String) {
        let oldStandardized = oldURL.resolvingSymlinksInPath().path
        func updateInItems(_ items: inout [FileSystemItem]) -> Bool {
            for i in 0..<items.count {
                let itemPath = items[i].id.resolvingSymlinksInPath().path
                if items[i].id == oldURL || items[i].id.path == oldURL.path || itemPath == oldStandardized {
                    items[i] = FileSystemItem(
                        id: newURL,
                        name: newName,
                        url: newURL,
                        isDirectory: items[i].isDirectory,
                        children: items[i].children
                    )
                    return true
                }
                if items[i].isDirectory, items[i].children != nil {
                    var childItems = items[i].children!
                    if updateInItems(&childItems) {
                        items[i].children = childItems
                        return true
                    }
                }
            }
            return false
        }
        if updateInItems(&rootItems) {
            recomputeFilteredRootItems()
            treeVersion &+= 1
            onNodeReloadRequired?(oldURL.deletingLastPathComponent())
        }
    }

    func deleteItem(_ item: FileSystemItem) {
        logger.info("Deleting item: \(item.name) at \(item.url.path)")
        let url = item.url
        let parentURL = url.deletingLastPathComponent()
        
        let hasScope = parentURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                parentURL.stopAccessingSecurityScopedResource()
            }
        }

        Task {
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                logger.info("Successfully moved item to Trash: \(item.name)")
                await MainActor.run {
                    self.removeItemFromTree(item.id)
                }
            } catch {
                logger.error("Failed to move item to Trash \(item.name): \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = "Failed to delete '\(item.name)': \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeItemFromTree(_ itemID: URL) {
        let targetPath = itemID.resolvingSymlinksInPath().path
        let parentURL = itemID.deletingLastPathComponent()

        func removeFromItems(_ items: inout [FileSystemItem]) -> Bool {
            if let index = items.firstIndex(where: {
                $0.id == itemID || $0.id.path == itemID.path || $0.id.resolvingSymlinksInPath().path == targetPath
            }) {
                items.remove(at: index)
                return true
            }
            for i in 0..<items.count {
                if items[i].isDirectory, items[i].children != nil {
                    var childItems = items[i].children!
                    if removeFromItems(&childItems) {
                        items[i].children = childItems
                        return true
                    }
                }
            }
            return false
        }

        if removeFromItems(&rootItems) {
            expandedItemIDs.remove(itemID)
            allSuggestableFiles.removeAll { $0.id == itemID || $0.url.path.hasPrefix(itemID.path) }
            recomputeFilteredRootItems()
            treeVersion &+= 1
            onNodeReloadRequired?(parentURL)
        }
    }

    func createNewFile(in parent: FileSystemItem?) {
        guard let targetFolderURL = (parent?.isDirectory == true ? parent?.url : selectedRootURL) else { return }

        let fileManager = FileManager.default
        var newFileName = "untitled.txt"
        var counter = 2
        var newFileURL = targetFolderURL.appendingPathComponent(newFileName)
        while fileManager.fileExists(atPath: newFileURL.path) {
            newFileName = "untitled \(counter).txt"
            newFileURL = targetFolderURL.appendingPathComponent(newFileName)
            counter += 1
        }

        let hasScope = targetFolderURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                targetFolderURL.stopAccessingSecurityScopedResource()
            }
        }

        Task {
            do {
                try "".write(to: newFileURL, atomically: true, encoding: .utf8)
                logger.info("Created new file at: \(newFileURL.path)")
                let newItem = FileSystemItem(id: newFileURL, name: newFileName, url: newFileURL, isDirectory: false)
                await MainActor.run {
                    self.addItemToTree(newItem, inParentURL: targetFolderURL)
                    self.startRename(newItem)
                }
            } catch {
                logger.error("Failed to create file: \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = "Failed to create file: \(error.localizedDescription)"
                }
            }
        }
    }

    func createNewFolder(in parent: FileSystemItem?) {
        guard let targetFolderURL = (parent?.isDirectory == true ? parent?.url : selectedRootURL) else { return }

        let fileManager = FileManager.default
        var newFolderName = "untitled folder"
        var counter = 2
        var newFolderURL = targetFolderURL.appendingPathComponent(newFolderName)
        while fileManager.fileExists(atPath: newFolderURL.path) {
            newFolderName = "untitled folder \(counter)"
            newFolderURL = targetFolderURL.appendingPathComponent(newFolderName)
            counter += 1
        }

        let hasScope = targetFolderURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope {
                targetFolderURL.stopAccessingSecurityScopedResource()
            }
        }

        Task {
            do {
                try fileManager.createDirectory(at: newFolderURL, withIntermediateDirectories: true)
                logger.info("Created new folder at: \(newFolderURL.path)")
                let newItem = FileSystemItem(id: newFolderURL, name: newFolderName, url: newFolderURL, isDirectory: true, children: [])
                await MainActor.run {
                    self.addItemToTree(newItem, inParentURL: targetFolderURL)
                    self.startRename(newItem)
                }
            } catch {
                logger.error("Failed to create folder: \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = "Failed to create folder: \(error.localizedDescription)"
                }
            }
        }
    }

    private func addItemToTree(_ item: FileSystemItem, inParentURL: URL) {
        let parentPath = inParentURL.resolvingSymlinksInPath().path
        
        func addUnderParent(items: inout [FileSystemItem]) -> Bool {
            for i in 0..<items.count {
                let itemPath = items[i].id.resolvingSymlinksInPath().path
                if items[i].id == inParentURL || items[i].id.path == inParentURL.path || itemPath == parentPath {
                    if items[i].children != nil {
                        items[i].children?.append(item)
                        items[i].children?.sort {
                            if $0.isDirectory && !$1.isDirectory { return true }
                            if !$0.isDirectory && $1.isDirectory { return false }
                            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }
                    } else {
                        items[i].children = [item]
                    }
                    return true
                }
                if items[i].isDirectory, items[i].children != nil {
                    var childItems = items[i].children!
                    if addUnderParent(items: &childItems) {
                        items[i].children = childItems
                        return true
                    }
                }
            }
            return false
        }

        if addUnderParent(items: &rootItems) {
            expandedItemIDs.insert(inParentURL)
            if !item.isDirectory {
                allSuggestableFiles.append(item)
            }
            recomputeFilteredRootItems()
            treeVersion &+= 1
            onNodeReloadRequired?(inParentURL)
        }
    }
    func findItem(by id: URL, in items: [FileSystemItem]) -> FileSystemItem? {
        let targetStandardized = id.resolvingSymlinksInPath().path
        for item in items {
            let itemStandardized = item.id.resolvingSymlinksInPath().path
            if item.id == id || item.id.path == id.path || itemStandardized == targetStandardized { return item }
            if let children = item.children, let foundInChildren = findItem(by: id, in: children) { return foundInChildren }
        }
        return nil
    }

    func findItem(by id: URL) -> FileSystemItem? {
        if let item = findItem(by: id, in: filteredRootItems) {
            return item
        }
        return findItem(by: id, in: rootItems)
    }

    // MARK: - File Suggestion Logic
    public func suggestableFiles(query: String) -> [FileSystemItem] {
        logger.debug("Searching cache for query: '\(query)'")
        if query.isEmpty {
            // Return a sorted, limited list if the query is empty.
            return Array(allSuggestableFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(50))
        } else {
            let lowercasedQuery = query.lowercased()
            // Perform a fast, in-memory filter.
            return allSuggestableFiles.filter { $0.name.lowercased().contains(lowercasedQuery) }
                                      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    
    // MARK: - File System Monitoring
    private func startMonitoring(path: String) {
        stopMonitoring()
        
        let excludedPaths = [
            "\(path)/.git",
            "\(path)/node_modules",
            "\(path)/.build",
            "\(path)/DerivedData",
            "\(path)/.DS_Store"
        ]
        
        // The callback is dispatched on main by FileSystemMonitor.handleEvents.
        fileSystemMonitor = FileSystemMonitor { [weak self] urls in
            if let firstURL = urls.first {
                Task { @MainActor [weak self] in
                    self?.handleFileSystemEvent(firstURL)
                }
            }
        }
        fileSystemMonitor?.start(path: path, excludedPaths: excludedPaths)
        logger.info("Started file system monitoring for path: \(path) with \(excludedPaths.count) exclusions.")
    }

    private func stopMonitoring() {
        fileSystemMonitor?.stop()
        fileSystemMonitor = nil
        logger.info("Stopped file system monitoring.")
    }
    
    // MARK: - Deep Search (Indexing)
    /// Internal (not private) so the stale-result guard can be tested deterministically.
    func indexAllFiles(from url: URL) async {
        await MainActor.run { self.isIndexing = true }
        
        let indexLogger = self.logger
        let allFiles = await Task.detached(priority: .userInitiated) { () -> [FileSystemItem] in
            var collectedFiles: [FileSystemItem] = []
            let resourceKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .isHiddenKey]

            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { url, error -> Bool in
                    indexLogger.error("Enumeration error at \(url.path): \(error.localizedDescription)")
                    return true
                }
            ) else {
                return []
            }

            // Reworked loop to correctly identify and skip excluded directories.
            for case let fileURL as URL in enumerator {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }
                
                // If the item is a directory and its name is in the exclusion list, skip its descendants.
                if resourceValues.isDirectory == true {
                    if SuggestableFileFilter.excludedDirectoryNames.contains(resourceValues.name ?? "") {
                        enumerator.skipDescendants()
                    }
                    // Always continue for all directories, as we only want to index files.
                    continue
                }

                // The .skipsHiddenFiles option handles this, but a check remains for safety.
                if resourceValues.isHidden == true { continue }

                // Build artifacts, archives, media — see SuggestableFileFilter.
                guard SuggestableFileFilter.admits(fileURL: fileURL) else { continue }

                let name = resourceValues.name ?? fileURL.lastPathComponent
                collectedFiles.append(FileSystemItem(id: fileURL, name: name, url: fileURL, isDirectory: false))
            }
            return collectedFiles
        }.value

        await MainActor.run {
            self.isIndexing = false
            // The root may have changed while this scan ran (a mode switch mid-index). A late
            // result for the OLD folder must not overwrite the new folder's (empty) index.
            guard self.selectedRootURL?.standardizedFileURL == url.standardizedFileURL else {
                self.logger.info("[EXPLORER] Index for '\(url.lastPathComponent)' finished after the root changed to \(self.selectedRootURL.map { "'\($0.lastPathComponent)'" } ?? "none") — discarded. CONSEQUENCE: the @ picker offers only the folder now open.")
                return
            }
            self.allSuggestableFiles = allFiles
            self.logger.info("Indexing complete. Found \(allFiles.count) suggestable files.")
        }
    }
    
    // MARK: - Incremental Refresh
    private func refreshSubfolder(at url: URL) async {
        logger.info("Starting incremental refresh for subfolder: \(url.path)")
        
        var folderURL = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                folderURL = url.deletingLastPathComponent()
            }
        } else {
            folderURL = url.deletingLastPathComponent()
        }

        // Scan only the specific subfolder — unless it lies inside build output. The
        // enumerator starts AT this folder, so it never sees the excluded ancestor and
        // would re-admit e.g. a freshly compiled `out/…/January2026.class`.
        let subfolderFiles: [FileSystemItem]
        if let root = selectedRootURL, SuggestableFileFilter.isInsideExcludedDirectory(folderURL, root: root) {
            subfolderFiles = []
            logger.debug("Incremental refresh: '\(folderURL.lastPathComponent)' is inside an excluded build/dependency folder — no files added to the @ suggestion index (the Explorer tree still refreshes).")
        } else {
            subfolderFiles = await fetchAllFiles(under: folderURL)
        }
        let freshChildren = try? await fetchItems(at: folderURL)
        
        await MainActor.run {
            // Same race as `indexAllFiles`: only a folder still under the open root may write.
            guard let root = self.selectedRootURL,
                  folderURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) else {
                self.logger.info("[EXPLORER] Refresh of '\(folderURL.lastPathComponent)' finished outside the open folder — discarded.")
                return
            }
            // Remove old entries for this subfolder path
            let subfolderPath = folderURL.path
            self.allSuggestableFiles.removeAll { item in
                item.url.path.hasPrefix(subfolderPath)
            }
            
            // Add new entries
            self.allSuggestableFiles.append(contentsOf: subfolderFiles)
            
            // Update visual tree if this folder is loaded in rootItems
            if let freshChildren = freshChildren,
               let existingItem = self.findItem(by: folderURL),
               existingItem.children != nil {
                self.updateChildren(for: folderURL, with: freshChildren)
            }

            self.logger.info("Incremental refresh complete for \(folderURL.lastPathComponent). Updated cache with \(subfolderFiles.count) files.")
        }
    }
    
    // MARK: - Document Preview

    /// Extract a preview of document content (first 2000 chars) for rich file types.
    func previewContent(for item: FileSystemItem) async -> String? {
        let registry = DocumentExtractionRegistry.shared
        guard registry.canExtract(from: item.url) else { return nil }

        do {
            let result = try await registry.extract(from: item.url, maxSize: 2_000)
            return result.text
        } catch {
            return nil
        }
    }

    private func fetchAllFiles(under url: URL) async -> [FileSystemItem] {
        await Task.detached(priority: .userInitiated) { () -> [FileSystemItem] in
            var collectedFiles: [FileSystemItem] = []
            let resourceKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .isHiddenKey]

            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                return []
            }

            for case let fileURL as URL in enumerator {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { continue }
                if resourceValues.isDirectory == true {
                    if SuggestableFileFilter.excludedDirectoryNames.contains(resourceValues.name ?? "") {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                
                // Build artifacts, archives, media — see SuggestableFileFilter.
                guard SuggestableFileFilter.admits(fileURL: fileURL) else { continue }

                let name = resourceValues.name ?? fileURL.lastPathComponent
                collectedFiles.append(FileSystemItem(id: fileURL, name: name, url: fileURL, isDirectory: false))
            }
            return collectedFiles
        }.value
    }
}
