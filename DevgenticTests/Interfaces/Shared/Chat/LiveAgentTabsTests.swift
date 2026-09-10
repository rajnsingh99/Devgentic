// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  LiveAgentTabsTests.swift
//  DevgenticTests
//
//  Covers live agent tabs under the BADGE-ONLY policy: a starting file write opens or
//  updates a background tab, the panel is never auto-opened, the active tab is never
//  stolen (unless the follow toggle is on inside an open panel), and a tab holding user
//  drafts is never touched. Plus the pure payload factories the stream layer posts.
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
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class LiveAgentTabsTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()
    private let followKey = "codeViewerFollowAgent"

    override func setUp() async throws {
        let store = NoopChatStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        )
        // Anchor the loaded conversation so payload conversation-guards pass.
        viewModel.currentChatMessages = [
            ChatMessage(conversationId: conversationID, sender: .user, content: .plainText("hi"))
        ]
        UserDefaults.standard.removeObject(forKey: followKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: followKey)
        viewModel = nil
    }

    private func began(_ fileName: String = "Solver.java", content: String = "class A {}") -> AgentLiveWriteEvent.Began {
        AgentLiveWriteEvent.Began(conversationID: conversationID,
                                  path: "/tmp/live_agent_tabs_nonexistent/\(fileName)",
                                  fileName: fileName,
                                  proposedContent: content)
    }

    private func completed(_ fileName: String = "Solver.java", success: Bool, pre: String? = nil) -> AgentLiveWriteEvent.Completed {
        AgentLiveWriteEvent.Completed(conversationID: conversationID,
                                      path: "/tmp/live_agent_tabs_nonexistent/\(fileName)",
                                      fileName: fileName,
                                      isSuccess: success,
                                      preWriteContent: pre)
    }

    // MARK: - Badge-only guarantees

    func testBeganOpensBackgroundTab_withoutShowingPanel() {
        viewModel.handleAgentWriteBegan(began())

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(viewModel.codeViewerTabs[0].liveState, .active)
        XCTAssertEqual(viewModel.codeViewerTabs[0].title, "Solver.java")
        XCTAssertFalse(viewModel.isCodeViewerVisible, "Badge-only: the panel must NEVER auto-open")
        XCTAssertTrue(viewModel.hasLiveAgentTabs)
        XCTAssertTrue(viewModel.isCodeViewerMinimized, "Tabs exist + panel hidden = the pill (pulsing) state")
    }

    func testBeganDoesNotStealActiveTab() {
        viewModel.showCodeInViewer(language: "swift", code: "let user = 1")
        let userTabID = viewModel.activeCodeViewerTabID

        viewModel.handleAgentWriteBegan(began())

        XCTAssertEqual(viewModel.codeViewerTabs.count, 2)
        XCTAssertEqual(viewModel.activeCodeViewerTabID, userTabID,
                       "The live tab arrives in the BACKGROUND — selection is never stolen")
    }

    func testFollowToggleSwitchesOnlyInsideOpenPanel() {
        UserDefaults.standard.set(true, forKey: followKey)

        // Panel open: follow switches to the live tab.
        viewModel.showCodeInViewer(language: "swift", code: "let user = 1")
        viewModel.handleAgentWriteBegan(began())
        XCTAssertEqual(viewModel.activeCodeViewerTab?.fileName, "Solver.java", "Follow-on switches inside an open panel")

        // Panel minimized: follow must NOT reopen it.
        viewModel.minimizeCodeViewer()
        viewModel.handleAgentWriteBegan(began("Other.java"))
        XCTAssertFalse(viewModel.isCodeViewerVisible, "Follow never overrides badge-only visibility")
    }

    func testDirtyTabIsNeverTouchedByLiveWrite() {
        viewModel.handleAgentWriteBegan(began(content: "v1"))
        viewModel.handleAgentWriteCompleted(completed(success: true))
        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "USER DRAFT")

        viewModel.handleAgentWriteBegan(began(content: "v2 — agent"))

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "USER DRAFT",
                       "A live write must never clobber unsaved user edits")
        XCTAssertNil(viewModel.codeViewerTabs[0].liveState, "The skipped write leaves no live state")
    }

    func testSecondWriteToSameFileReusesTab() {
        viewModel.handleAgentWriteBegan(began(content: "v1"))
        viewModel.handleAgentWriteCompleted(completed(success: true))
        viewModel.handleAgentWriteBegan(began(content: "v2"))

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "Same file → same tab")
        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.code, "v2")
        XCTAssertEqual(viewModel.codeViewerTabs[0].liveState, .active)
    }

    func testOtherConversationIsIgnored() {
        let foreign = AgentLiveWriteEvent.Began(conversationID: UUID(), path: "/tmp/x.java",
                                                fileName: "x.java", proposedContent: "class X {}")
        viewModel.handleAgentWriteBegan(foreign)
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)
    }

    // MARK: - Completion settles or rejects

    /// Settling clears the live pulse. The tab does NOT adopt a diff baseline any more —
    /// the change is shown in the tool row that produced it.
    func testSuccessSettlesTab() {
        viewModel.handleAgentWriteBegan(began(content: "new content"))
        viewModel.handleAgentWriteCompleted(completed(success: true, pre: "old content"))

        XCTAssertNil(viewModel.codeViewerTabs[0].liveState, "Settled")
        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.code, "new content")
        XCTAssertFalse(viewModel.hasLiveAgentTabs)
    }

    func testFailureMarksTabRejected() {
        viewModel.handleAgentWriteBegan(began())
        viewModel.handleAgentWriteCompleted(completed(success: false))

        XCTAssertEqual(viewModel.codeViewerTabs[0].liveState, .rejected,
                       "A denied/failed write shows a proposal that never reached disk")
    }

    // MARK: - Payload factories (what the stream layer posts)

    func testBeganFactoryParsesWriteFile() {
        let payload = AgentLiveWriteEvent.began(
            toolName: "write_file",
            params: #"{"path":"/Users/alice/Desktop/A.java","content":"class A {}","append":false}"#,
            conversationID: conversationID
        )
        XCTAssertEqual(payload?.fileName, "A.java")
        XCTAssertEqual(payload?.proposedContent, "class A {}")
    }

    func testBeganFactorySkipsAppendAndNonFileTools() {
        XCTAssertNil(AgentLiveWriteEvent.began(
            toolName: "write_file",
            params: #"{"path":"/tmp/a.txt","content":"frag","append":true}"#,
            conversationID: conversationID
        ), "Append writes stay on the completion-chip path")
        XCTAssertNil(AgentLiveWriteEvent.began(
            toolName: "execute_shell",
            params: #"{"command":"ls"}"#,
            conversationID: conversationID
        ))
    }

    func testCompletedFactoryCarriesOutcomeAndSnapshot() {
        let payload = AgentLiveWriteEvent.completed(
            toolName: "overwrite_file",
            params: #"{"file_path":"/tmp/B.swift","content":"x"}"#,
            isSuccess: true,
            preWriteContent: "old",
            conversationID: conversationID
        )
        XCTAssertEqual(payload?.fileName, "B.swift")
        XCTAssertEqual(payload?.isSuccess, true)
        XCTAssertEqual(payload?.preWriteContent, "old")
    }
}
