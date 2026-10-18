// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TimelineCodeViewerTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
private final class NoopChatStore: ChatPersistenceProtocol {
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
final class TimelineCodeViewerTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!

    override func setUp() async throws {
        let store = NoopChatStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        )
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    // MARK: - Opening from a timeline row

    /// A timeline open is now a plain content open — the CHANGE is shown in the tool row
    /// that produced it, so the tab carries no diff state at all
    /// (`Docs/codeviewer-rescope-design.md` §4).
    func testTimelineOpenIsPlainContent() {
        viewModel.openTimelineFileInCodeViewer(
            fileName: "DijkstraSolver.java",
            content: "class New {}"
        )

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        let tab = viewModel.codeViewerTabs[0]
        XCTAssertEqual(tab.title, "DijkstraSolver.java")
        XCTAssertEqual(tab.snippet.language, "java", "Language inferred from the extension")
        XCTAssertEqual(tab.snippet.code, "class New {}")
        XCTAssertNil(tab.snippet.sourceFileID, "Timeline tabs carry NO attachment link")
        XCTAssertTrue(viewModel.isCodeViewerPanelPresented)
    }

    /// The "Previous version" affordance opens the PRE-write content as its own ordinary
    /// tab — a pure viewer use, and the recovery path for a clobbered file.
    func testPreviousVersionOpensAsItsOwnPlainTab() {
        viewModel.openTimelineFileInCodeViewer(fileName: "a.swift", content: "let b = 2")
        viewModel.openTimelineFileInCodeViewer(fileName: "a.swift", content: "let a = 1")

        XCTAssertEqual(viewModel.codeViewerTabs.count, 2,
                       "Different content is a different tab, so both versions stay open")
        XCTAssertEqual(viewModel.codeViewerTabs[1].snippet.code, "let a = 1")
        XCTAssertNil(viewModel.codeViewerTabs[1].filePath,
                     "A historical version must NOT be linked to the live file")
    }

    func testReopeningSameWriteFocusesExistingTab() {
        viewModel.openTimelineFileInCodeViewer(fileName: "a.swift", content: "let a = 1")
        viewModel.openTimelineFileInCodeViewer(fileName: "a.swift", content: "let a = 1")

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "Identical content dedups to the existing tab")
    }

    func testEmptyContentIsSkipped() {
        viewModel.openTimelineFileInCodeViewer(fileName: "a.txt", content: "   \n  ")
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)
    }

    // MARK: - Edit tools (find/replace params, post-state via read-back)

    private func editRow(name: String, pre: String?, post: String?) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(), name: name,
            params: #"{"file_path":"/Users/alice/Desktop/Solver.java","old_string":"a","new_string":"b"}"#,
            output: "ok", isSuccess: true, isExecuting: false
        )
        data.preWriteContent = pre
        data.postWriteContent = post
        return data
    }

    func testEditRowOpensReadBackPostStateWithDiff() {
        let action = TimelineFileViewerAction.resolve(data: editRow(
            name: "edit_code_single",
            pre: "let a = 1\n",
            post: "let b = 1\n"
        ))
        XCTAssertEqual(action?.inlineContent, "let b = 1\n", "Edit rows open the READ-BACK post-state, not the params")
        XCTAssertEqual(action?.preWriteContent, "let a = 1\n")
        XCTAssertEqual(action?.fileName, "Solver.java")
        XCTAssertEqual(action?.isWrite, true)
    }

    func testEditBatchRowResolvesLikeSingle() {
        let action = TimelineFileViewerAction.resolve(data: editRow(
            name: "edit_code_batch",
            pre: "old",
            post: "new"
        ))
        XCTAssertEqual(action?.inlineContent, "new")
        XCTAssertEqual(action?.preWriteContent, "old")
    }

    /// Without the read-back the edit's result can't be represented — no affordance.
    func testEditRowWithoutReadBackGetsNoAffordance() {
        XCTAssertNil(TimelineFileViewerAction.resolve(data: editRow(
            name: "edit_code_single",
            pre: "old",
            post: nil
        )))
    }

    // MARK: - read_file reads from DISK, not the (capped) output field

    /// `ToolExecutionData.output` is capped at `maxPersistedOutputLength`, so using it as
    /// the viewer's content would open large files truncated — with the truncation marker
    /// embedded in the code, plus read_file's decorative header. The row must resolve to a
    /// disk read instead.
    func testReadFileResolvesToDiskNotOutput() {
        var data = ToolExecutionData(
            id: UUID(), name: "read_file",
            params: #"{"path":"/Users/alice/Desktop/Huge.java"}"#,
            output: "📄 Contents of file '/Users/alice/Desktop/Huge.java'\nclass Huge {}",
            isSuccess: true, isExecuting: false
        )
        data.preWriteContent = nil

        let action = TimelineFileViewerAction.resolve(data: data)
        XCTAssertEqual(action?.source, .fromDisk, "read_file must read the file, not reuse capped output")
        XCTAssertNil(action?.inlineContent, "No inline content — the click performs the read")
        XCTAssertEqual(action?.filePath, "/Users/alice/Desktop/Huge.java")
        XCTAssertEqual(action?.isWrite, false)
    }

    /// Writes keep inline content: their params are not size-capped, so they stay faithful.
    func testWritesKeepInlineContent() {
        let data = ToolExecutionData(
            id: UUID(), name: "write_file",
            params: #"{"path":"/tmp/A.swift","content":"let x = 1"}"#,
            output: "ok", isSuccess: true, isExecuting: false
        )
        let action = TimelineFileViewerAction.resolve(data: data)
        XCTAssertEqual(action?.inlineContent, "let x = 1")
        XCTAssertEqual(action?.filePath, "/tmp/A.swift")
    }

    // MARK: - Path identity (basename collisions)

    /// `src/Main.java` and `test/Main.java` are different files and must get different
    /// tabs — matching on the basename merged them into one.
    func testSameBasenameDifferentDirectoriesGetSeparateTabs() {
        viewModel.openTimelineFileInCodeViewer(fileName: "Main.java", filePath: "/proj/src/Main.java",
                                               content: "class A {}")
        viewModel.openTimelineFileInCodeViewer(fileName: "Main.java", filePath: "/proj/test/Main.java",
                                               content: "class B {}")

        XCTAssertEqual(viewModel.codeViewerTabs.count, 2, "Different paths are different files")
        XCTAssertEqual(viewModel.codeViewerTabs.map(\.filePath), ["/proj/src/Main.java", "/proj/test/Main.java"])
    }

    /// The same path reuses its tab and refreshes the content.
    func testSamePathReusesTabAndRefreshes() {
        viewModel.openTimelineFileInCodeViewer(fileName: "Main.java", filePath: "/proj/src/Main.java",
                                               content: "v1")
        viewModel.openTimelineFileInCodeViewer(fileName: "Main.java", filePath: "/proj/src/Main.java",
                                               content: "v2")

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.code, "v2", "Reopen refreshes a clean tab")
    }

    /// …but never over unsaved user edits.
    func testSamePathDoesNotClobberADraft() {
        viewModel.openTimelineFileInCodeViewer(fileName: "Main.java", filePath: "/proj/src/Main.java",
                                               content: "v1")
        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "MY EDIT")

        viewModel.openTimelineFileInCodeViewer(fileName: "Main.java", filePath: "/proj/src/Main.java",
                                               content: "v2")

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "MY EDIT",
                       "A reopen must not discard unsaved edits")
    }

    // MARK: - ToolExecutionData Codable compatibility

    func testLegacyToolExecutionDataDecodesWithoutSnapshot() throws {
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","name":"write_file","params":"{}","isExecuting":false}
        """
        let decoded = try JSONDecoder().decode(ToolExecutionData.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.preWriteContent, "Pre-snapshot rows decode with nil — no diff affordance")
    }

    /// Snapshots are SESSION-SCOPED: held in memory (so the viewer's diff works during the
    /// run that produced the write) but omitted from encoding, so they never enter the
    /// message's timeline blob. See Docs/large-tool-payload-storage.md; the encode/decode
    /// contract itself is pinned in TimelinePayloadBoundsTests.
    func testSnapshotsAreInMemoryOnlyAndNotPersisted() throws {
        var data = ToolExecutionData(id: UUID(), name: "write_file", params: "{}", output: "ok",
                                     isSuccess: true, isExecuting: false)
        data.preWriteContent = "old content\n"
        data.postWriteContent = "new content\n"

        XCTAssertEqual(data.preWriteContent, "old content\n", "In-memory capture drives the in-session diff")

        let decoded = try JSONDecoder().decode(ToolExecutionData.self,
                                               from: JSONEncoder().encode(data))
        XCTAssertNil(decoded.preWriteContent, "Snapshots must not be persisted into the timeline blob")
        XCTAssertNil(decoded.postWriteContent)
    }

    // MARK: - Helpers

    func testLanguageHintMapping() {
        XCTAssertEqual(CodeSnippet.languageHint(forFileName: "Solver.java"), "java")
        XCTAssertEqual(CodeSnippet.languageHint(forFileName: "app.py"), "python")
        XCTAssertEqual(CodeSnippet.languageHint(forFileName: "index.ts"), "typescript")
        XCTAssertEqual(CodeSnippet.languageHint(forFileName: "run.sh"), "bash")
        XCTAssertNil(CodeSnippet.languageHint(forFileName: "Makefile"), "No extension → no hint")
    }

    func testChangeCounts() {
        let counts = DiffUtility.changeCounts(original: "a\nb\nc", modified: "a\nB\nc\nd")
        XCTAssertEqual(counts.added, 2)     // B and d
        XCTAssertEqual(counts.deleted, 1)   // b
    }
}
