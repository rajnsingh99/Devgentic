// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    // MARK: - [CR52/CR59] create_file is a full-content writer

    /// ⚠️ WHY EIGHT GREEN LIVE-TAB SUITES NEVER NOTICED. Every view-model test in this file builds
    /// `AgentLiveWriteEvent.Began`/`.Completed` structs directly through the helpers above, which
    /// bypasses `liveWriteToolNames` entirely — so the whole live-tab cluster could stay green
    /// while the set that ADMITS a tool was one name short. These four tests go through the
    /// FACTORIES with a real tool name and a real params string, which is the only path that
    /// touches the set. Same shape as the standing "test the wiring, not just the policy" rule.
    ///
    /// `create_file` is `.libraryExceptCode` — the same visibility class as `write_file`, which
    /// was already covered — so this is the AGENT/WORKFLOW profiles' ordinary creation tool.
    /// Mutation that must kill this: remove `"create_file"` from `liveWriteToolNames`.
    func testBeganFactoryPlantsATabForCreateFile() throws {
        let payload = try XCTUnwrap(AgentLiveWriteEvent.began(
            toolName: "create_file",
            params: #"{"file_path":"/Users/alice/Proj/Notes.swift","content":"struct Notes {}"}"#,
            conversationID: conversationID
        ), "create_file carries the whole file in `content`, exactly like write_file — it must get a live tab")
        XCTAssertEqual(payload.fileName, "Notes.swift")
        XCTAssertEqual(payload.proposedContent, "struct Notes {}")
        XCTAssertEqual(payload.path, FilePathResolver.resolve("/Users/alice/Proj/Notes.swift"),
                       "the tab's identity must be the path the executor resolved, not the raw argument")
    }

    /// ⚠️ THE TWO FACTORIES ARE GATED SEPARATELY against the same constant. A fix inlined into
    /// `began` alone widens the OPEN path and leaves the SETTLE path narrow — the tab is planted
    /// and can never be settled, so it holds `.active` for the session: permanent "agent is
    /// writing" banner, pulsing pill, and ⌘S refused as on-disk drift. That is the CF-9 shape.
    ///
    /// The fixture is the REFUSAL case on purpose: `create_file` fails when the file already
    /// exists and `overwrite` is not set, so for this tool a failed completion is the everyday
    /// outcome rather than an exception, and `preWriteContent` is what makes the rejected tab's
    /// drift baseline the real bytes rather than nil.
    /// Mutation that must kill this: narrow `completed`'s guard, or inline the names into `began` only.
    func testCompletedFactorySettlesACreateFileThatWasRefused() throws {
        let payload = try XCTUnwrap(AgentLiveWriteEvent.completed(
            toolName: "create_file",
            params: #"{"file_path":"/Users/alice/Proj/Notes.swift","content":"struct Notes {}"}"#,
            isSuccess: false,
            preWriteContent: "the file that was already there\n",
            conversationID: conversationID
        ))
        XCTAssertEqual(payload.fileName, "Notes.swift")
        XCTAssertEqual(payload.isSuccess, false)
        XCTAssertEqual(payload.preWriteContent, "the file that was already there\n",
                       "without the pre-write bytes the rejected tab has no drift baseline and ⌘S is refused forever")
    }

    /// ⚠️ THE NARROWNESS CONTROL. Widening the set is the fix; widening the FACTORY would not be.
    /// `create_file` has no append mode, but the shared guards must still refuse the cases they
    /// always refused — otherwise this test's siblings above pass for the wrong reason.
    /// Mutation that must kill this: replace either guard with `true`, or drop the `content` check.
    func testCreateFileStillObeysTheFactoryGuards() {
        XCTAssertNil(AgentLiveWriteEvent.began(
            toolName: "create_file",
            params: #"{"file_path":"/tmp/Empty.swift","content":""}"#,
            conversationID: conversationID
        ), "a create with no content has nothing to show")
        XCTAssertNil(AgentLiveWriteEvent.began(
            toolName: "create_file",
            params: #"{"content":"struct A {}"}"#,
            conversationID: conversationID
        ), "no path argument means no tab identity")
        XCTAssertNil(AgentLiveWriteEvent.began(
            toolName: "create_file",
            params: #"{"file_path":"/tmp/Big.swift","content":"\#(String(repeating: "x", count: 512_001))"}"#,
            conversationID: conversationID
        ), "over the live-tab byte cap")
    }

    /// The set must not have been widened by simply admitting everything.
    /// Mutation that must kill this: replace the `liveWriteToolNames.contains` guard with `true`.
    func testNonWriterToolsStillGetNoLiveTab() {
        for tool in ["execute_shell", "read_file", "edit_code_single", "delete_file"] {
            XCTAssertNil(AgentLiveWriteEvent.began(
                toolName: tool,
                params: #"{"file_path":"/tmp/a.txt","content":"x"}"#,
                conversationID: conversationID
            ), "\(tool) is not a full-content writer and must stay on the completion-chip path")
        }
    }
}
