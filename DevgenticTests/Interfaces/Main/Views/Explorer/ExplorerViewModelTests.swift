// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExplorerViewModelTests.swift
//  DevgenticTests
//

import XCTest
@testable import devgentic

@MainActor
private final class ExplorerMockChatStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class ExplorerViewModelTests: XCTestCase {

    private var tempDir: URL!
    private var viewModel: ExplorerViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerViewModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        viewModel = ExplorerViewModel()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        viewModel = nil
        try super.tearDownWithError()
    }

    func testNonSecurityScopedFolderLoadsContentsSuccessfully() async throws {
        // Create files in the test directory
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let subfolder = tempDir.appendingPathComponent("SubfolderA")
        try "hello".write(to: file1, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        viewModel.selectedRootURL = tempDir

        // Wait briefly for directory load task to complete
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.rootItems.count, 1)

        let rootItem = viewModel.rootItems[0]
        XCTAssertEqual(rootItem.url.path, tempDir.path)
        let children = try XCTUnwrap(rootItem.children)
        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(children.contains { $0.name == "SubfolderA" && $0.isDirectory })
        XCTAssertTrue(children.contains { $0.name == "file1.txt" && !$0.isDirectory })
    }

    func testSubfolderLazyLoadPopulatesChildrenWithoutEmptying() async throws {
        // Structure: tempDir -> SubfolderA -> SubfolderB -> nested.txt
        let subA = tempDir.appendingPathComponent("SubfolderA")
        let subB = subA.appendingPathComponent("SubfolderB")
        let nestedFile = subB.appendingPathComponent("nested.txt")

        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        try "nested content".write(to: nestedFile, atomically: true, encoding: .utf8)

        viewModel.selectedRootURL = tempDir
        try await Task.sleep(for: .milliseconds(200))

        let rootItem = try XCTUnwrap(viewModel.rootItems.first)
        let subAItem = try XCTUnwrap(rootItem.children?.first(where: { $0.name == "SubfolderA" }))

        // SubfolderA initially has children == nil
        XCTAssertNil(subAItem.children)

        // Expand SubfolderA
        var reloadedParentURL: URL? = nil
        viewModel.onNodeReloadRequired = { url in
            reloadedParentURL = url
        }

        viewModel.toggleFolderExpansion(for: subAItem)
        try await Task.sleep(for: .milliseconds(200))

        // Find SubfolderA in viewModel
        let updatedSubA = try XCTUnwrap(viewModel.findItem(by: subAItem.id))
        let subAChildren = try XCTUnwrap(updatedSubA.children)

        // It must NOT be empty
        XCTAssertFalse(subAChildren.isEmpty)
        XCTAssertEqual(subAChildren.count, 1)
        XCTAssertEqual(subAChildren.first?.name, "SubfolderB")
        XCTAssertEqual(reloadedParentURL?.path, subAItem.url.path)

        // Now expand SubfolderB
        let subBItem = try XCTUnwrap(subAChildren.first)
        viewModel.toggleFolderExpansion(for: subBItem)
        try await Task.sleep(for: .milliseconds(200))

        let updatedSubB = try XCTUnwrap(viewModel.findItem(by: subBItem.id))
        let subBChildren = try XCTUnwrap(updatedSubB.children)
        XCTAssertEqual(subBChildren.count, 1)
        XCTAssertEqual(subBChildren.first?.name, "nested.txt")
    }

    func testFindItemResolvesNestedItemsByPathOrID() async throws {
        let subA = tempDir.appendingPathComponent("SubfolderA")
        let fileA = subA.appendingPathComponent("test.swift")
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try "// swift".write(to: fileA, atomically: true, encoding: .utf8)

        viewModel.selectedRootURL = tempDir
        try await Task.sleep(for: .milliseconds(200))

        let rootItem = try XCTUnwrap(viewModel.rootItems.first)
        let subAItem = try XCTUnwrap(rootItem.children?.first(where: { $0.name == "SubfolderA" }))
        viewModel.toggleFolderExpansion(for: subAItem)
        try await Task.sleep(for: .milliseconds(200))

        let found = viewModel.findItem(by: fileA)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "test.swift")
    }

    func testTreeVersionIncrementsOnMutation() async throws {
        let initialVersion = viewModel.treeVersion

        let file = tempDir.appendingPathComponent("sample.txt")
        try "sample".write(to: file, atomically: true, encoding: .utf8)

        viewModel.selectedRootURL = tempDir
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertGreaterThan(viewModel.treeVersion, initialVersion)
    }

    func testSearchAutoExpandsAncestorsAndClearingRestoresState() async throws {
        // Structure: tempDir -> Folder1 -> nestedTarget.swift
        let folder1 = tempDir.appendingPathComponent("Folder1")
        let targetFile = folder1.appendingPathComponent("nestedTarget.swift")
        try FileManager.default.createDirectory(at: folder1, withIntermediateDirectories: true)
        try "// code".write(to: targetFile, atomically: true, encoding: .utf8)

        viewModel.selectedRootURL = tempDir
        try await Task.sleep(for: .milliseconds(200))

        let rootItem = try XCTUnwrap(viewModel.rootItems.first)
        let folder1Item = try XCTUnwrap(rootItem.children?.first(where: { $0.name == "Folder1" }))
        viewModel.toggleFolderExpansion(for: folder1Item)
        try await Task.sleep(for: .milliseconds(200))

        // Collapse folder1 so it is not in expandedItemIDs
        viewModel.expandedItemIDs.remove(folder1Item.id)
        XCTAssertFalse(viewModel.expandedItemIDs.contains(folder1Item.id))

        // Search for "nestedTarget"
        viewModel.searchText = "nestedTarget"
        XCTAssertFalse(viewModel.filteredRootItems.isEmpty)
        // Ancestor folder must now be in expandedItemIDs
        XCTAssertTrue(viewModel.expandedItemIDs.contains(folder1Item.id))

        // Clear search
        viewModel.searchText = ""
        // Pre-search state restored: folder1 is collapsed again
        XCTAssertFalse(viewModel.expandedItemIDs.contains(folder1Item.id))
    }

    func testCreateNewFileAndFolder() async throws {
        viewModel.selectedRootURL = tempDir
        try await Task.sleep(for: .milliseconds(200))

        let rootItem = try XCTUnwrap(viewModel.rootItems.first)

        // Create new file
        viewModel.createNewFile(in: rootItem)
        try await Task.sleep(for: .milliseconds(200))

        let createdFile = viewModel.findItem(by: tempDir.appendingPathComponent("untitled.txt"))
        XCTAssertNotNil(createdFile)
        XCTAssertEqual(createdFile?.name, "untitled.txt")
        XCTAssertEqual(viewModel.itemBeingRenamedID, createdFile?.id)

        // Create new folder
        viewModel.createNewFolder(in: rootItem)
        try await Task.sleep(for: .milliseconds(200))

        let createdFolder = viewModel.findItem(by: tempDir.appendingPathComponent("untitled folder"))
        XCTAssertNotNil(createdFolder)
        XCTAssertTrue(createdFolder?.isDirectory == true)
    }

    func testCommitRenameUpdatesInPlaceWithoutCollapsingTree() async throws {
        let file = tempDir.appendingPathComponent("original.txt")
        try "test".write(to: file, atomically: true, encoding: .utf8)

        viewModel.selectedRootURL = tempDir
        try await Task.sleep(for: .milliseconds(200))

        let originalItem = try XCTUnwrap(viewModel.findItem(by: file))
        viewModel.startRename(originalItem)
        viewModel.currentEditName = "renamed.txt"
        viewModel.commitRename()

        try await Task.sleep(for: .milliseconds(200))

        let renamedItem = viewModel.findItem(by: tempDir.appendingPathComponent("renamed.txt"))
        XCTAssertNotNil(renamedItem)
        XCTAssertEqual(renamedItem?.name, "renamed.txt")
        XCTAssertNil(viewModel.findItem(by: file))
    }

    func testDeleteItemMovesToTrashAndRemovesFromTree() async throws {
        let file = tempDir.appendingPathComponent("toDelete.txt")
        try "bye".write(to: file, atomically: true, encoding: .utf8)

        viewModel.selectedRootURL = tempDir
        try await Task.sleep(for: .milliseconds(200))

        let item = try XCTUnwrap(viewModel.findItem(by: file))
        viewModel.deleteItem(item)

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNil(viewModel.findItem(by: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCollapseAllClearsExpandedIDsAndIncrementsVersion() async throws {
        viewModel.selectedRootURL = tempDir
        try await Task.sleep(for: .milliseconds(200))

        let folder = tempDir.appendingPathComponent("FolderA")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        viewModel.expandedItemIDs.insert(folder)
        XCTAssertTrue(viewModel.expandedItemIDs.contains(folder))

        let vBefore = viewModel.treeVersion
        viewModel.collapseAll()

        XCTAssertTrue(viewModel.expandedItemIDs.isEmpty)
        XCTAssertGreaterThan(viewModel.treeVersion, vBefore)
    }

    func testRefreshReloadsDirectoryContents() async throws {
        viewModel.selectedRootURL = tempDir
        try await Task.sleep(for: .milliseconds(200))

        let newFile = tempDir.appendingPathComponent("lateAdded.txt")
        try "content".write(to: newFile, atomically: true, encoding: .utf8)

        viewModel.refresh()
        try await Task.sleep(for: .milliseconds(200))

        let item = viewModel.findItem(by: newFile)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.name, "lateAdded.txt")
    }

    func testNoiseAndDependencyDetection() {
        let nodeModules = FileSystemItem(
            id: URL(fileURLWithPath: "/path/node_modules"),
            name: "node_modules",
            url: URL(fileURLWithPath: "/path/node_modules"),
            isDirectory: true
        )
        XCTAssertTrue(nodeModules.isIgnoredOrDependency)
        XCTAssertEqual(nodeModules.iconName, "shippingbox.fill")

        let lockFile = FileSystemItem(
            id: URL(fileURLWithPath: "/path/package-lock.json"),
            name: "package-lock.json",
            url: URL(fileURLWithPath: "/path/package-lock.json"),
            isDirectory: false
        )
        XCTAssertTrue(lockFile.isIgnoredOrDependency)

        let srcFolder = FileSystemItem(
            id: URL(fileURLWithPath: "/path/src"),
            name: "src",
            url: URL(fileURLWithPath: "/path/src"),
            isDirectory: true
        )
        XCTAssertFalse(srcFolder.isIgnoredOrDependency)
        XCTAssertEqual(srcFolder.iconName, "folder.fill")
    }

    func testFileIconAndColorAttributes() {
        let tsFile = FileSystemItem(
            id: URL(fileURLWithPath: "/path/App.tsx"),
            name: "App.tsx",
            url: URL(fileURLWithPath: "/path/App.tsx"),
            isDirectory: false
        )
        XCTAssertEqual(tsFile.iconName, "chevron.left.forwardslash.chevron.right")

        let htmlFile = FileSystemItem(
            id: URL(fileURLWithPath: "/path/index.html"),
            name: "index.html",
            url: URL(fileURLWithPath: "/path/index.html"),
            isDirectory: false
        )
        XCTAssertEqual(htmlFile.iconName, "chevron.left.slash.chevron.right")

        let cssFile = FileSystemItem(
            id: URL(fileURLWithPath: "/path/style.css"),
            name: "style.css",
            url: URL(fileURLWithPath: "/path/style.css"),
            isDirectory: false
        )
        XCTAssertEqual(cssFile.iconName, "paintbrush.fill")

        let jsonFile = FileSystemItem(
            id: URL(fileURLWithPath: "/path/package.json"),
            name: "package.json",
            url: URL(fileURLWithPath: "/path/package.json"),
            isDirectory: false
        )
        XCTAssertEqual(jsonFile.iconName, "doc.text.below.ecg")
    }

    func testOpenFileDispatchesToOnOpenFileRequestedForFiles() {
        let fileURL = tempDir.appendingPathComponent("test.swift")
        let item = FileSystemItem(
            id: fileURL,
            name: "test.swift",
            url: fileURL,
            isDirectory: false
        )

        var requestedItem: FileSystemItem? = nil
        viewModel.onOpenFileRequested = { openedItem in
            requestedItem = openedItem
        }

        viewModel.openFile(item)
        XCTAssertEqual(requestedItem?.id, item.id)
        XCTAssertEqual(requestedItem?.name, "test.swift")
    }

    func testOpenFileIgnoresDirectories() {
        let dirURL = tempDir.appendingPathComponent("Sources")
        let item = FileSystemItem(
            id: dirURL,
            name: "Sources",
            url: dirURL,
            isDirectory: true
        )

        var requestedItem: FileSystemItem? = nil
        viewModel.onOpenFileRequested = { openedItem in
            requestedItem = openedItem
        }

        viewModel.openFile(item)
        XCTAssertNil(requestedItem)
    }

    func testFileOpenCoordinatorBinaryDetection() {
        XCTAssertTrue(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/image.png")))
        XCTAssertTrue(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/photo.jpg")))
        XCTAssertTrue(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/archive.zip")))
        XCTAssertTrue(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/doc.pdf")))
        XCTAssertTrue(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/binary.dylib")))

        XCTAssertFalse(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/App.swift")))
        XCTAssertFalse(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/index.ts")))
        XCTAssertFalse(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/data.json")))
        XCTAssertFalse(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/README.md")))
        XCTAssertFalse(FileOpenCoordinator.isLikelyBinary(url: URL(fileURLWithPath: "/path/script.py")))
    }

    func testFileOpenCoordinatorOpensFileInChatHistoryViewModel() throws {
        let fileURL = tempDir.appendingPathComponent("Sample.swift")
        let sourceCode = "struct Sample {\n    let value = 42\n}\n"
        try sourceCode.write(to: fileURL, atomically: true, encoding: .utf8)

        let item = FileSystemItem(
            id: fileURL,
            name: "Sample.swift",
            url: fileURL,
            isDirectory: false
        )

        let store = ExplorerMockChatStore()
        let chatVM = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )

        FileOpenCoordinator.open(item: item, in: chatVM, fallbackViewModel: viewModel)

        XCTAssertEqual(chatVM.codeViewerTabs.count, 1)
        let tab = try XCTUnwrap(chatVM.codeViewerTabs.first)
        XCTAssertEqual(tab.fileName, "Sample.swift")
        XCTAssertEqual(tab.filePath, fileURL.path)
        XCTAssertEqual(tab.snippet.code, sourceCode)
        XCTAssertEqual(tab.snippet.language, "swift")
        XCTAssertTrue(chatVM.isCodeViewerVisible)
        XCTAssertEqual(chatVM.activeCodeViewerTabID, tab.id)
    }

    func testCloseOtherCodeViewerTabsRetainsTargetAndUpdatesActiveTab() {
        let store = ExplorerMockChatStore()
        let chatVM = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )

        chatVM.openTab(for: CodeSnippet(language: "swift", code: "let a = 1"), fileName: "A.swift", filePath: "/path/A.swift")
        chatVM.openTab(for: CodeSnippet(language: "swift", code: "let b = 2"), fileName: "B.swift", filePath: "/path/B.swift")
        chatVM.openTab(for: CodeSnippet(language: "swift", code: "let c = 3"), fileName: "C.swift", filePath: "/path/C.swift")

        XCTAssertEqual(chatVM.codeViewerTabs.count, 3)
        let tabB = chatVM.codeViewerTabs[1]

        chatVM.closeOtherCodeViewerTabs(exceptID: tabB.id)

        XCTAssertEqual(chatVM.codeViewerTabs.count, 1)
        XCTAssertEqual(chatVM.codeViewerTabs.first?.id, tabB.id)
        XCTAssertEqual(chatVM.activeCodeViewerTabID, tabB.id)
    }

    func testCloseTabsToTheRightClosesSubsequentTabs() {
        let store = ExplorerMockChatStore()
        let chatVM = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )

        chatVM.openTab(for: CodeSnippet(language: "swift", code: "let a = 1"), fileName: "A.swift", filePath: "/path/A.swift")
        chatVM.openTab(for: CodeSnippet(language: "swift", code: "let b = 2"), fileName: "B.swift", filePath: "/path/B.swift")
        chatVM.openTab(for: CodeSnippet(language: "swift", code: "let c = 3"), fileName: "C.swift", filePath: "/path/C.swift")

        XCTAssertEqual(chatVM.codeViewerTabs.count, 3)
        let tabA = chatVM.codeViewerTabs[0]
        let tabC = chatVM.codeViewerTabs[2]
        chatVM.selectCodeViewerTab(id: tabC.id)
        XCTAssertEqual(chatVM.activeCodeViewerTabID, tabC.id)

        chatVM.closeTabsToTheRight(ofID: tabA.id)

        XCTAssertEqual(chatVM.codeViewerTabs.count, 1)
        XCTAssertEqual(chatVM.codeViewerTabs.first?.id, tabA.id)
        XCTAssertEqual(chatVM.activeCodeViewerTabID, tabA.id)
    }
}
