//
//  DraftBufferIdentityTests.swift
//  DevgenticTests
//
//  Regression cover for AD1 (Chat_Production_Readiness.md Part D) — the CH1 fix re-opened a
//  data-loss defect a 2026-07-26 audit had already closed.
//
//  ROOT CAUSE: `editedCode == nil` meant two different things. `updateCodeViewerDraft` stored
//  `nil` whenever the buffer returned to the restore point (as a way to clear the dirty dot),
//  so `effectiveCode` (`editedCode ?? snippet.code`) reported the PRISTINE CHAT BLOCK for a tab
//  whose editor was showing the user's text — and the save path reads `effectiveCode` as the
//  bytes to write.
//

import XCTest
@testable import devgentic

@MainActor
private final class NoopStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class DraftBufferIdentityTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()
    private var tempFiles: [URL] = []

    override func setUp() async throws {
        let store = NoopStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store,
                                                     fileProcessorService: FileProcessorService()),
            ownsCodeViewer: true
        )
    }

    override func tearDown() async throws {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll()
        viewModel = nil
    }

    /// A snippet wired so `performApplyChanges` resolves its source file.
    private func linkedSnippet(onDisk: String, newCode: String) throws -> (url: URL, snippet: CodeSnippet) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ad1_\(UUID().uuidString).swift")
        try onDisk.write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(url)

        let file = AttachedTextFile(name: url.lastPathComponent, url: url, fileExtension: "swift",
                                    content: onDisk, size: Int64(onDisk.count))
        let msg = ChatMessage(conversationId: conversationID, sender: .user,
                              content: .plainText("file"), attachedTextFiles: [file])
        viewModel.currentChatMessages = [msg]
        return (url, CodeSnippet(language: "swift", code: newCode,
                                 sourceMessageID: msg.id, sourceFileID: file.id))
    }

    // MARK: - The invariant AD1 turned on

    /// States the invariant in its simplest form: `effectiveCode` is what the editor is showing.
    ///
    /// ⚠️ CONTROL, NOT A DISCRIMINATOR — verified: it passes against the pre-fix behaviour too.
    /// With nothing saved yet the restore point IS the chat block, so `nil` and the block are
    /// the same string and the defect is invisible here. The two tests below are the ones that
    /// actually fail without the fix; this one exists to document the contract.
    func testReturningToTheRestorePointKeepsTheEditorsTextNotThePristineBlock() throws {
        let (_, snippet) = try linkedSnippet(onDisk: "ON DISK\n", newCode: "BLOCK")
        let tabID = viewModel.openTab(for: snippet)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "USER TEXT")
        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "USER TEXT")

        // Type back to the restore point (here: the chat block, since nothing is saved yet).
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "BLOCK")

        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "BLOCK",
                       "effectiveCode must report the editor's text, not fall through to the block")
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty,
                       "the dirty dot must still clear — by COMPARISON, not by nil")
    }

    /// The same property one save later, which is the state AD1 actually needed: the restore
    /// point has moved to `lastSavedBuffer`, so returning to it is no longer the block.
    func testReturningToAPreviouslySavedBufferIsCleanButKeepsItsText() async throws {
        let (_, snippet) = try linkedSnippet(onDisk: "BLOCK", newCode: "BLOCK")
        let tabID = viewModel.openTab(for: snippet)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "V1")
        await viewModel.performApplyChanges(for: snippet)
        XCTAssertEqual(viewModel.codeViewerTabs[0].lastSavedBuffer, "V1", "precondition: V1 is saved")

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "V2")
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "V1")   // undo back to the save point

        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "V1",
                       "the editor shows V1 — effectiveCode must not report the pristine block")
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty)
    }

    // MARK: - End-to-end: the write AD1 would have produced

    /// The whole point: after editing, saving, and undoing back to the saved text, the next
    /// save must write THAT text — not the original chat block. Under the defect the tab's
    /// buffer had silently become the block, and this wrote it over the user's file while
    /// logging "✅ Saved".
    func testSaveAfterUndoWritesTheEditorsTextNotTheOriginalBlock() async throws {
        let (url, snippet) = try linkedSnippet(onDisk: "BLOCK", newCode: "BLOCK")
        let tabID = viewModel.openTab(for: snippet)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "V1")
        await viewModel.performApplyChanges(for: snippet)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "V1")

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "V2")
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "V1")
        await viewModel.performApplyChanges(for: snippet)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "V1",
                       "the file must still hold the user's work, never the pristine block")
    }

    /// Control: a genuine forward edit after a save still saves, and the tab is dirty until it
    /// does. Guards against 'fixing' AD1 by making everything permanently dirty.
    func testForwardEditAfterSaveIsDirtyAndSaves() async throws {
        let (url, snippet) = try linkedSnippet(onDisk: "BLOCK", newCode: "BLOCK")
        let tabID = viewModel.openTab(for: snippet)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "V1")
        await viewModel.performApplyChanges(for: snippet)
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty, "a completed save leaves the tab clean")

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "V2")
        XCTAssertTrue(viewModel.codeViewerTabs[0].isDirty, "a forward edit must mark the tab dirty")

        await viewModel.performApplyChanges(for: snippet)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "V2")
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty)
    }

    /// Control: an untouched tab still reports the block, so the fix did not make every tab
    /// look edited.
    func testUntouchedTabStillReportsTheBlockAndIsClean() throws {
        let (_, snippet) = try linkedSnippet(onDisk: "ON DISK", newCode: "BLOCK")
        _ = viewModel.openTab(for: snippet)

        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "BLOCK")
        XCTAssertNil(viewModel.codeViewerTabs[0].editedCode, "no write-through has happened yet")
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty)
    }
}
