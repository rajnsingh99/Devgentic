// ExplorerViewModel.swift
import SwiftUI
import Combine
import os

@MainActor
final class ExplorerViewModel: ObservableObject {
    @Published var rootItems: [FileSystemItem] = []
    @Published var selectedRootURL: URL? = nil {
        willSet {
            if let currentURL = self.selectedRootURL {
                if currentURL != newValue {
                    currentURL.stopAccessingSecurityScopedResource()
                    logger.info("Stopped accessing security-scoped resource (willSet) for: \(currentURL.path)")
                    expandedItemIDs = []
                }
            }
        }
        didSet {
            if let newURL = selectedRootURL {
                if newURL.startAccessingSecurityScopedResource() {
                    logger.info("Successfully started accessing security-scoped resource (didSet) for: \(newURL.path)")
                    if self.errorMessage?.contains("Could not gain permission") == true {
                        self.errorMessage = nil
                    }
                    loadDirectoryContents(for: newURL)
                } else {
                    logger.error("Failed to start accessing security-scoped resource (didSet) for: \(newURL.path). Files might not be accessible.")
                    self.errorMessage = "Could not gain permission to access this folder. Please try selecting it again. If the issue persists, check app permissions in System Settings (Privacy & Security -> Files and Folders)."
                    self.rootItems = []
                    self.isLoading = false
                    self.expandedItemIDs = []
                }
            } else {
                self.rootItems = []
                self.errorMessage = nil
                self.isLoading = false
                self.expandedItemIDs = []
                logger.info("selectedRootURL is now nil. Cleared items and errors.")
            }
        }
    }
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil // For explorer-related errors
    
    @Published var itemBeingRenamedID: URL? = nil
    @Published var currentEditName: String = ""
    @Published var renameErrorMessage: String? = nil

    @Published var expandedItemIDs: Set<URL> = []

    // Properties for sheet-based file viewer are REMOVED:
    // @Published var presentingFileViewer: Bool = false
    // @Published var viewingFileContent: String? = nil
    // @Published var viewingFileName: String? = nil
    // @Published var fileViewingError: String? = nil

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.explorer", category: "ExplorerViewModel")

    deinit {
        logger.info("ExplorerViewModel deinitialized. Resource cleanup for selectedRootURL is managed by its property observers.")
    }

    func expansionBinding(for item: FileSystemItem) -> Binding<Bool> {
        Binding(
            get: { self.expandedItemIDs.contains(item.id) },
            set: { isExpanding in
                if isExpanding {
                    self.expandedItemIDs.insert(item.id)
                    if item.isDirectory && item.children?.isEmpty == true {
                        self.logger.info("DisclosureGroup expanding '\(item.name)', triggering lazy load.")
                        self.toggleFolderExpansion(for: item)
                    }
                } else {
                    self.expandedItemIDs.remove(item.id)
                }
            }
        )
    }

    func selectRootDirectory() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose Root Folder"

        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                logger.info("Root directory selected: \(url.path)")
                selectedRootURL = url
            }
        }
    }

    func loadDirectoryContents(for rootURL: URL) {
        // ... (loadDirectoryContents logic remains the same) ...
        if let currentError = self.errorMessage, currentError.contains("Could not gain permission"), selectedRootURL == rootURL {
            logger.warning("Skipping loadDirectoryContents for \(rootURL.path) due to existing permission error: \(currentError)")
            self.isLoading = false
            return
        }

        isLoading = true
        if !(self.errorMessage?.contains("Could not gain permission") == true && selectedRootURL == rootURL) {
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

                var rootListItem = FileSystemItem(
                    id: rootURL,
                    name: rootName,
                    url: rootURL,
                    isDirectory: true,
                    children: []
                )

                do {
                    let childrenItems = try await fetchItems(at: rootURL)
                    rootListItem.children = childrenItems
                    
                    await MainActor.run {
                        self.rootItems = [rootListItem]
                        self.isLoading = false
                        if self.selectedRootURL == rootURL {
                           self.errorMessage = nil
                        }
                        if expandRootAfterLoad {
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
        // ... (toggleFolderExpansion logic remains the same) ...
        guard item.isDirectory else { return }
        
        if let currentError = self.errorMessage, currentError.contains("Could not gain permission"),
           (selectedRootURL == item.url || item.url.path.hasPrefix(selectedRootURL?.path ?? "___INVALID_PATH___")) {
            logger.warning("Skipping folder expansion/load for \(item.name) due to existing permission error related to its hierarchy.")
            return
        }

        if item.children?.isEmpty == true {
            logger.info("Data load triggered for folder: \(item.url.path) (children are empty)")
            Task {
                do {
                    let children = try await fetchItems(at: item.url)
                    await MainActor.run {
                        self.updateChildren(for: item.id, with: children)
                        if self.errorMessage?.contains("Failed to load contents of '\(item.name)'") == true {
                            self.errorMessage = nil
                        }
                    }
                } catch {
                    await MainActor.run {
                        if !(self.errorMessage?.contains("Could not gain permission") == true) {
                             self.errorMessage = "Failed to load contents of '\(item.name)': \(error.localizedDescription)"
                        }
                        self.logger.error("Error lazy loading children for folder \(item.url.path): \(error.localizedDescription)")
                    }
                }
            }
        } else {
            logger.debug("Folder '\(item.name)' children not empty or item is not a directory. UI expansion handled by DisclosureGroup binding.")
        }
    }
    
    private func updateChildren(for parentId: URL, with children: [FileSystemItem]) {
        // ... (updateChildren logic remains the same) ...
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
        // ... (fetchItems logic remains the same) ...
        var items: [FileSystemItem] = []
        let fileManager = FileManager.default
        
        guard url.startAccessingSecurityScopedResource() else {
            logger.warning("fetchItems: Could not start accessing security-scoped resource for \(url.path).")
            throw NSError(domain: "ExplorerViewModel.fetchItems", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Permission denied to access \(url.lastPathComponent)."])
        }
        defer {
            url.stopAccessingSecurityScopedResource()
        }

        let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.nameKey, .isDirectoryKey, .isHiddenKey], options: [])

        for itemURL in contents {
            let resourceValues = try itemURL.resourceValues(forKeys: [.nameKey, .isDirectoryKey, .isHiddenKey])
            
            if resourceValues.isHidden == true {
                continue
            }

            let name = resourceValues.name ?? itemURL.lastPathComponent
            let isDirectory = resourceValues.isDirectory ?? false
            
            items.append(FileSystemItem(id: itemURL, name: name, url: itemURL, isDirectory: isDirectory, children: isDirectory ? [] : nil))
        }
        
        return items.sorted {
            if $0.isDirectory && !$1.isDirectory { return true }
            if !$0.isDirectory && $1.isDirectory { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    
    // MARK: - File Operations (Reveal, Copy, Rename, etc.)

    // The openFile method is now simplified. The actual window opening will be
    // triggered from the View using the @Environment(\.openWindow) action.
    // This method can be removed if not used for other pre-processing.
    func openFile(_ item: FileSystemItem) {
        guard !item.isDirectory else {
            logger.info("Attempted to 'openFile' on a directory '\(item.name)'. This action is for files to be opened in a new window.")
            return
        }
        // The actual opening (e.g., openWindow(value: item.url)) will be handled in the View.
        logger.info("ViewModel's openFile called for: \(item.name). View should handle window opening.")
    }

    func revealInFinder(_ item: FileSystemItem) {
        // ... (revealInFinder logic remains the same) ...
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
        // ... (copyPath logic remains the same) ...
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.url.path, forType: .string)
        logger.info("Copied path to clipboard: \(item.url.path)")
    }

    func startRename(_ item: FileSystemItem) {
        // ... (startRename logic remains the same) ...
        logger.info("Starting rename for: \(item.name) (ID: \(item.id.path))")
        itemBeingRenamedID = item.id
        currentEditName = item.name
        renameErrorMessage = nil
    }

    func commitRename() {
        // ... (commitRename logic remains the same) ...
        guard let itemIDToRename = itemBeingRenamedID,
              let itemToRename = findItem(by: itemIDToRename, in: rootItems) else {
            logger.error("CommitRename called but itemToRename or its ID is nil.")
            cancelRename()
            return
        }

        let newName = currentEditName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            renameErrorMessage = "Name cannot be empty."
            logger.warning("New name is empty. Rename not committed.")
            return
        }

        guard newName != itemToRename.name else {
            logger.info("New name is the same as the old name. Cancelling rename.")
            cancelRename()
            return
        }

        if newName.contains(":") || newName.contains("/") {
            renameErrorMessage = "Name cannot contain ':' or '/'."
            logger.warning("Invalid characters in new name: \(newName)")
            return
        }
        
        let fileManager = FileManager.default
        let oldURL = itemToRename.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)

        if fileManager.fileExists(atPath: newURL.path) {
            renameErrorMessage = "An item named \"\(newName)\" already exists."
            logger.warning("Rename failed: item with new name already exists at \(newURL.path)")
            return
        }

        logger.info("Attempting to rename '\(itemToRename.name)' to '\(newName)' (URL: \(oldURL.path) -> \(newURL.path))")

        guard oldURL.deletingLastPathComponent().startAccessingSecurityScopedResource() else {
            logger.error("CommitRename: Could not gain access to parent directory of \(oldURL.path)")
            self.renameErrorMessage = "Permission denied to modify items in this folder."
            return
        }
        defer { oldURL.deletingLastPathComponent().stopAccessingSecurityScopedResource() }

        Task {
            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
                logger.info("Successfully renamed item.")
                
                await MainActor.run {
                    self.cancelRename()
                    if let rootToLoad = self.selectedRootURL {
                         self.loadDirectoryContents(for: rootToLoad)
                    }
                }
            } catch {
                logger.error("Failed to rename item: \(error.localizedDescription)")
                await MainActor.run {
                    self.renameErrorMessage = "Failed to rename: \(error.localizedDescription)"
                }
            }
        }
    }

    func cancelRename() {
        // ... (cancelRename logic remains the same) ...
        logger.info("Cancelling rename.")
        itemBeingRenamedID = nil
        currentEditName = ""
        renameErrorMessage = nil
    }

    func deleteItem(_ item: FileSystemItem) {
        // ... (deleteItem logic remains the same) ...
        logger.info("Delete action triggered for: \(item.name). Confirmation and deletion logic needed.")
    }
    
    func createNewFile(in parent: FileSystemItem?) {
        // ... (createNewFile logic remains the same) ...
        let targetDirectory = parent?.url ?? selectedRootURL
        logger.info("Create New File action triggered in directory: \(targetDirectory?.path ?? "root"). UI and logic needed.")
    }
    
    func createNewFolder(in parent: FileSystemItem?) {
        // ... (createNewFolder logic remains the same) ...
        let targetDirectory = parent?.url ?? selectedRootURL
        logger.info("Create New Folder action triggered in directory: \(targetDirectory?.path ?? "root"). UI and logic needed.")
    }
    
    private func findItem(by id: URL, in items: [FileSystemItem]) -> FileSystemItem? {
        // ... (findItem logic remains the same) ...
        for item in items {
            if item.id == id {
                return item
            }
            if let children = item.children, let foundInChildren = findItem(by: id, in: children) {
                return foundInChildren
            }
        }
        return nil
    }
}
