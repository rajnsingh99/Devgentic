// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  CodeViewerReopenResetTests.swift
//  DevgenticTests
//
//  Register CF-8 — `openTab`'s two refresh branches replaced the snippet but left the
//  save/draft baseline (`editedCode` / `lastSavedBuffer` / `lastSavedDisk`) in place. A SAVED
//  tab is exactly the clean-but-`editedCode`-set state, so re-opening a file the agent had
//  since rewritten showed the user's OLD buffer and then refused ⌘S as on-disk drift against
//  the old bytes. These pin the three-field reset `handleAgentWriteBegan` already did, now
//  on both `openTab` refresh paths.
//

import XCTest
@testable import devgentic

@MainActor
private final class InertChatStore: ChatPersistenceProtocol {
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
final class CodeViewerReopenResetTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let path = "/tmp/code_viewer_reopen_reset_nonexistent/Main.java"

    override func setUp() async throws {
        let store = InertChatStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        )
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    /// Puts a tab into the state `saveTabToItsPath` leaves behind on success: buffer kept,
    /// restore point and drift baseline set, `isDirty == false`. No disk involved — the
    /// three assignments ARE the post-save state.
    private func simulateSave(tabID: UUID, buffer: String) {
        guard let index = viewModel.codeViewerTabs.firstIndex(where: { $0.id == tabID }) else {
            return XCTFail("tab \(tabID) not found")
        }
        viewModel.codeViewerTabs[index].editedCode = buffer
        viewModel.codeViewerTabs[index].lastSavedBuffer = buffer
        viewModel.codeViewerTabs[index].lastSavedDisk = buffer + "\n"
        XCTAssertFalse(viewModel.codeViewerTabs[index].isDirty, "sanity: a saved tab is clean")
    }

    // MARK: - filePath branch

    /// ⚠️ THE CF-8 PIN. Save from the viewer, the agent rewrites the file with a non-live tool,
    /// the user reopens it from the timeline row: the tab must show the NEW content and the
    /// drift baseline must not be the OLD bytes.
    func testReopenByPathAfterSaveAdoptsTheNewContent() {
        let tabID = viewModel.openTab(for: CodeSnippet(language: "java", code: "class A {}"),
                                      fileName: "Main.java", filePath: path)
        simulateSave(tabID: tabID, buffer: "class A {}")

        let reopened = viewModel.openTab(for: CodeSnippet(language: "java", code: "class B {}"),
                                         fileName: "Main.java", filePath: path)

        XCTAssertEqual(reopened, tabID, "same path → same tab, no duplicate")
        let tab = viewModel.codeViewerTabs[0]
        XCTAssertEqual(tab.effectiveCode, "class B {}",
                       "the editor must show the content the tab was reopened with, not the stale saved buffer")
        XCTAssertFalse(tab.isDirty)
        XCTAssertNil(tab.editedCode)
        XCTAssertNil(tab.lastSavedBuffer)
        XCTAssertNil(tab.lastSavedDisk,
                     "the drift baseline must not be the OLD bytes — the next ⌘S would be refused as drift")
    }

    /// Since `updateCodeViewerDraft` stores every keystroke, an edit that returns to the
    /// restore point is the same clean-but-`editedCode`-set state — no save needed.
    func testReopenByPathAfterEditThenRevertAdoptsTheNewContent() {
        let tabID = viewModel.openTab(for: CodeSnippet(language: "java", code: "class A {}"),
                                      fileName: "Main.java", filePath: path)
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "class A { int x; }")
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "class A {}")
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty, "sanity: reverted → clean")
        XCTAssertNotNil(viewModel.codeViewerTabs[0].editedCode, "sanity: the buffer is still stored")

        viewModel.openTab(for: CodeSnippet(language: "java", code: "class B {}"),
                          fileName: "Main.java", filePath: path)

        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "class B {}")
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty)
    }

    /// The guard the reset sits behind: a genuinely dirty tab is still never refreshed.
    func testReopenByPathKeepsAnUnsavedDraft() {
        let tabID = viewModel.openTab(for: CodeSnippet(language: "java", code: "class A {}"),
                                      fileName: "Main.java", filePath: path)
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "class A { int draft; }")

        viewModel.openTab(for: CodeSnippet(language: "java", code: "class B {}"),
                          fileName: "Main.java", filePath: path)

        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "class A { int draft; }")
        XCTAssertTrue(viewModel.codeViewerTabs[0].isDirty)
    }

    // MARK: - origin (chat block) branch

    /// The same state on the origin-keyed path: a block reopened after its message finished
    /// streaming must adopt the grown block, not keep the saved buffer of the fragment.
    func testReopenByOriginAfterSaveAdoptsTheGrownBlock() {
        let messageID = UUID()
        let tabID = viewModel.openTab(for: CodeSnippet(language: "swift", code: "let a = 1"),
                                      originMessageID: messageID, originBlockIndex: 0)
        simulateSave(tabID: tabID, buffer: "let a = 1")

        let reopened = viewModel.openTab(for: CodeSnippet(language: "swift", code: "let a = 1\nlet b = 2"),
                                         originMessageID: messageID, originBlockIndex: 0)

        XCTAssertEqual(reopened, tabID, "same origin → same tab, no duplicate")
        let tab = viewModel.codeViewerTabs[0]
        XCTAssertEqual(tab.effectiveCode, "let a = 1\nlet b = 2")
        XCTAssertFalse(tab.isDirty)
        XCTAssertNil(tab.editedCode)
        XCTAssertNil(tab.lastSavedBuffer)
        XCTAssertNil(tab.lastSavedDisk)
    }

    /// Origin branch, dirty tab: the draft wins, exactly as before.
    func testReopenByOriginKeepsAnUnsavedDraft() {
        let messageID = UUID()
        let tabID = viewModel.openTab(for: CodeSnippet(language: "swift", code: "let a = 1"),
                                      originMessageID: messageID, originBlockIndex: 0)
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let a = 1 // mine")

        viewModel.openTab(for: CodeSnippet(language: "swift", code: "let a = 1\nlet b = 2"),
                          originMessageID: messageID, originBlockIndex: 0)

        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "let a = 1 // mine")
        XCTAssertTrue(viewModel.codeViewerTabs[0].isDirty)
    }
}
