//
//  ExplorerViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import Combine
import os

@MainActor
final class ExplorerViewModel: ObservableObject {
    @Published var rootItems: [FileSystemItem] = []
    @Published var selectedRootURL: URL? = nil {
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
            }

            if let newURL = selectedRootURL {
                if newURL.startAccessingSecurityScopedResource() {
                    logger.info("Successfully started accessing security-scoped resource (didSet for selectedRootURL) for: \(newURL.path)")
                    saveBookmark(for: newURL)
                    
                    // **NEW**: Trigger the deep search and start monitoring.
                    Task {
                        await indexAllFiles(from: newURL)
                    }
                    startMonitoring(path: newURL.path)

                    loadDirectoryContents(for: newURL) // This can remain for the visual explorer view
                } else {
                    logger.error("Failed to start accessing security-scoped resource (didSet for selectedRootURL) for: \(newURL.path). Files might not be accessible.")
                    self.errorMessage = "Could not gain permission to access this folder. Please try selecting it again. If the issue persists, check app permissions in System Settings (Privacy & Security -> Files and Folders)."
                    self.rootItems = []
                    self.isLoading = false
                    self.expandedItemIDs = []
                    clearLastOpenedFolderBookmark()
                }
            } else {
                // **NEW**: Stop monitoring when the folder is closed.
                stopMonitoring()
                self.rootItems = []
                self.errorMessage = nil
                self.isLoading = false
                self.expandedItemIDs = []
                clearLastOpenedFolderBookmark()
                logger.info("selectedRootURL is now nil. Cleared items, errors, and bookmark.")
            }
        }
    }
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    
    @Published var itemBeingRenamedID: URL? = nil
    @Published var currentEditName: String = ""
    @Published var renameErrorMessage: String? = nil

    @Published var expandedItemIDs: Set<URL> = []
    @Published private var loadingIDs: Set<URL> = []

    // The in-memory cache for all files in the directory.
    @Published var allSuggestableFiles: [FileSystemItem] = []

    // A flag to provide UI feedback during the initial scan.
    @Published var isIndexing: Bool = false

    // A property to hold our real-time file system monitor.
    private var fileSystemMonitor: FileSystemMonitor?
    private var fileSystemEventSubject = PassthroughSubject<URL, Never>()
    private var cancellables = Set<AnyCancellable>()


    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.explorer", category: "ExplorerViewModel")
    private static let lastOpenedFolderBookmarkKey = "explorerLastOpenedFolderBookmark"

    init() {
        logger.info("ExplorerViewModel initializing.")
        loadLastOpenedFolder()
    }

    deinit {
        logger.info("ExplorerViewModel deinitialized. Resource cleanup for selectedRootURL is managed by its property observers.")
        // The call to stopMonitoring() is removed. The FileSystemMonitor's own deinit will handle the cleanup automatically
        // when the ExplorerViewModel is deallocated, which is the correct and safe pattern.
    }
    
    private func setupDebouncer() {
        fileSystemEventSubject
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self = self else { return }
                self.logger.info("Debounced file system event triggered for \(url.path). Refreshing contents.")
                // Re-run the indexing and reload the visual tree
                Task {
                    await self.indexAllFiles(from: url)
                }
                self.loadDirectoryContents(for: url)
            }
            .store(in: &cancellables)
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
        
        let scriptSource = """
        tell application "Terminal"
            activate
            do script "cd \\"\(path)\\""
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
            UserDefaults.standard.set(bookmarkData, forKey: Self.lastOpenedFolderBookmarkKey)
            logger.info("Saved security-scoped bookmark for URL: \(url.path)")
        } catch {
            logger.error("Failed to save bookmark for URL \(url.path): \(error.localizedDescription)")
            clearLastOpenedFolderBookmark()
        }
    }

    private func loadLastOpenedFolder() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.lastOpenedFolderBookmarkKey) else {
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
            self.selectedRootURL = resolvedURL
        } catch {
            logger.error("Failed to resolve bookmark data or access persisted URL: \(error.localizedDescription)")
            clearLastOpenedFolderBookmark()
        }
    }

    private func clearLastOpenedFolderBookmark() {
        UserDefaults.standard.removeObject(forKey: Self.lastOpenedFolderBookmarkKey)
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
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose Root Folder"
        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                logger.info("Root directory selected via panel: \(url.path)")
                selectedRootURL = url
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
        
    private func updateChildren(for parentId: URL, with children: [FileSystemItem]) {
        func findAndUpdate(items: inout [FileSystemItem]) -> Bool {
            for i in 0..<items.count {
                if items[i].id == parentId {
                    items[i].children = children
                    return true
                }
                if items[i].isDirectory, items[i].children != nil {
                    if findAndUpdate(items: &items[i].children!) {
                        return true
                    }
                }
            }
            return false
        }
        if findAndUpdate(items: &rootItems) {
            objectWillChange.send()
        }
    }

    private func fetchItems(at url: URL) async throws -> [FileSystemItem] {
        var items: [FileSystemItem] = []
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.nameKey, .isDirectoryKey, .isHiddenKey]

        guard url.startAccessingSecurityScopedResource() else {
            logger.warning("fetchItems: Could not start accessing security-scoped resource for \(url.path).")
            throw NSError(domain: "ExplorerViewModel.fetchItems", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Permission denied to access \(url.lastPathComponent)."])
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
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
    func openFile(_ item: FileSystemItem) { logger.info("ViewModel's openFile called for: \(item.name).") }
    func revealInFinder(_ item: FileSystemItem) {
        guard item.url.startAccessingSecurityScopedResource() else {
            logger.error("Could not gain access to reveal in Finder: \(item.url.path)")
            self.errorMessage = "Could not reveal '\(item.name)': Permission denied."
            return
        }
        defer { item.url.stopAccessingSecurityScopedResource() }
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
        guard oldURL.deletingLastPathComponent().startAccessingSecurityScopedResource() else {
            logger.error("CommitRename: Could not gain access to parent directory of \(oldURL.path)")
            self.renameErrorMessage = "Permission denied to modify items in this folder."; return
        }
        defer { oldURL.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
        Task {
            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
                logger.info("Successfully renamed item.")
                await MainActor.run {
                    self.cancelRename()
                    if let rootToLoad = self.selectedRootURL { self.loadDirectoryContents(for: rootToLoad) }
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
    func deleteItem(_ item: FileSystemItem) { logger.info("Delete action triggered for: \(item.name).") }
    func createNewFile(in parent: FileSystemItem?) { logger.info("Create New File action triggered in directory: \(parent?.url.path ?? self.selectedRootURL?.path ?? "root").") }
    func createNewFolder(in parent: FileSystemItem?) { logger.info("Create New Folder action triggered in directory: \(parent?.url.path ?? self.selectedRootURL?.path ?? "root").") }
    private func findItem(by id: URL, in items: [FileSystemItem]) -> FileSystemItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children, let foundInChildren = findItem(by: id, in: children) { return foundInChildren }
        }
        return nil
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
        stopMonitoring() // Ensure any existing monitor is stopped.
        fileSystemMonitor = FileSystemMonitor { [weak self] url in
            self?.logger.info("File system change detected at \(url.path). Re-indexing...")
            // For simplicity and robustness, we will re-run the full deep search.
            Task {
                await self?.indexAllFiles(from: url)
            }
        }
        fileSystemMonitor?.start(path: path)
        logger.info("Started file system monitoring for path: \(path)")
    }

    // This method is now a standard private method isolated to the MainActor.
    // It's no longer `nonisolated`.
    private func stopMonitoring() {
        fileSystemMonitor?.stop()
        fileSystemMonitor = nil
        logger.info("Stopped file system monitoring.")
    }
    
    // MARK: - Deep Search (Indexing)
    private func indexAllFiles(from url: URL) async {
        await MainActor.run { self.isIndexing = true }
        
        let allFiles = await Task.detached(priority: .userInitiated) { () -> [FileSystemItem] in
            var collectedFiles: [FileSystemItem] = []
            let resourceKeys: [URLResourceKey] = [.nameKey, .isDirectoryKey, .isHiddenKey]
            let excludedDirectoryNames: Set<String> = [".git", ".build", "node_modules", "Pods", ".DS_Store"]

            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { url, error -> Bool in
                    self.logger.error("Enumeration error at \(url.path): \(error.localizedDescription)")
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
                    if excludedDirectoryNames.contains(resourceValues.name ?? "") {
                        enumerator.skipDescendants()
                    }
                    // Always continue for all directories, as we only want to index files.
                    continue
                }

                // The .skipsHiddenFiles option handles this, but a check remains for safety.
                if resourceValues.isHidden == true { continue }

                let name = resourceValues.name ?? fileURL.lastPathComponent
                collectedFiles.append(FileSystemItem(id: fileURL, name: name, url: fileURL, isDirectory: false))
            }
            return collectedFiles
        }.value

        await MainActor.run {
            self.allSuggestableFiles = allFiles
            self.isIndexing = false
            self.logger.info("Indexing complete. Found \(allFiles.count) suggestable files.")
        }
    }
}
