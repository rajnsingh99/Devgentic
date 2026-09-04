//
//  ViewmodelObservationScopeTests.swift
//  DevgenticTests
//
//  [CF-14] WHICH bodies a Code Viewer keystroke wakes up.
//
//  `updateCodeViewerDraft` write-throughs every character into
//  `codeViewerTabs[i].editedCode`. Under `@Observable` that mutation notifies every reader
//  of the ARRAY — and `isCodeViewerPanelPresented` / `isCodeViewerMinimized` used to derive
//  their answer from `codeViewerTabs.isEmpty`, so `MainApplicationView.body` (the root
//  window: aura layers, sidebar, mode picker, the whole chat area) re-ran on every keypress
//  to re-learn something that only changes when a tab opens or closes.
//
//  These pin both halves of the fix: the flags no longer wake on a draft write, and the
//  mirror they read instead cannot drift from the array it mirrors.
//

import XCTest
@testable import devgentic

/// Nothing is fetched here — the Code Viewer is conversation-independent state.
@MainActor
private final class SilentChatStore: ChatPersistenceProtocol {
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument] { [] }
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class ViewmodelObservationScopeTests: XCTestCase {

    private var store: SilentChatStore!
    private var viewModel: ChatHistoryViewModel!

    override func setUp() async throws {
        store = SilentChatStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store,
                                                     fileProcessorService: FileProcessorService())
        )
    }

    override func tearDown() async throws {
        viewModel = nil
        store = nil
    }

    // MARK: - CF-14: a keystroke must not wake the root window

    /// THE regression pin. Typing changes the draft, not whether the panel is on screen —
    /// so an observer of `isCodeViewerPanelPresented` must not be notified. Before the fix
    /// the property read `codeViewerTabs`, so this fired on every character.
    func testTypingADraftDoesNotInvalidateThePanelPresentationFlag() {
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        let tabID = viewModel.codeViewerTabs[0].id
        XCTAssertTrue(viewModel.isCodeViewerPanelPresented, "sanity: the panel is up before we type")

        let unexpected = XCTestExpectation(description: "presentation flag invalidated by a keystroke")
        unexpected.isInverted = true
        withObservationTracking {
            _ = viewModel.isCodeViewerPanelPresented
        } onChange: {
            Task { @MainActor in unexpected.fulfill() }
        }

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let a = 2")

        wait(for: [unexpected], timeout: 0.5)
        XCTAssertEqual(viewModel.codeViewerTabs[0].editedCode, "let a = 2",
                       "the draft is still stored — the write-through is untouched, only its audience shrank")
    }

    /// The other side of the same coin: the flags must still be LIVE. A mirror that never
    /// updates (or that stops being observed) would leave the panel on screen after its last
    /// tab closed. This changes the tab set and nothing else — no `isCodeViewerVisible`
    /// write — so only the mirror can carry the notification.
    func testOpeningTheFirstTabStillInvalidatesTheMinimizedFlag() {
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        let tab = viewModel.codeViewerTabs[0]
        viewModel.closeAllCodeViewerTabs()
        XCTAssertFalse(viewModel.isCodeViewerMinimized, "sanity: no tabs, no pill")

        let invalidated = XCTestExpectation(description: "minimized flag invalidated when a tab appears")
        withObservationTracking {
            _ = viewModel.isCodeViewerMinimized
        } onChange: {
            Task { @MainActor in invalidated.fulfill() }
        }

        viewModel.codeViewerTabs = [tab]

        wait(for: [invalidated], timeout: 2.0)
        XCTAssertTrue(viewModel.isCodeViewerMinimized, "tabs with the panel hidden = the floating pill")
    }

    /// The mirror is maintained by `codeViewerTabs`' own `didSet`, so it must follow a
    /// wholesale write that goes through none of the tab-management methods. A mirror kept
    /// in sync at call sites instead would drift here and strand the panel on screen with
    /// zero tabs.
    func testTabPresenceMirrorFollowsADirectArrayWrite() {
        XCTAssertFalse(viewModel.hasCodeViewerTabs, "sanity: nothing open yet")

        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        XCTAssertTrue(viewModel.hasCodeViewerTabs)
        XCTAssertTrue(viewModel.isCodeViewerPanelPresented)

        viewModel.codeViewerTabs.removeAll()

        XCTAssertFalse(viewModel.hasCodeViewerTabs,
                       "the mirror must follow the array even when no close path ran")
        XCTAssertFalse(viewModel.isCodeViewerPanelPresented,
                       "a presented panel with zero tabs is the drift this mirror must not introduce")
    }

    /// An element write that changes nothing is not published at all: the editor re-emits
    /// its buffer whenever its document is rebuilt, and each re-emission used to invalidate
    /// every reader of the tabs for an identical string.
    func testRedeliveringUnchangedDraftContentPublishesNothing() {
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        let tabID = viewModel.codeViewerTabs[0].id
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let a = 2")

        let unexpected = XCTestExpectation(description: "tab array published for an unchanged draft")
        unexpected.isInverted = true
        withObservationTracking {
            _ = viewModel.codeViewerTabs
        } onChange: {
            Task { @MainActor in unexpected.fulfill() }
        }

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let a = 2")

        wait(for: [unexpected], timeout: 0.5)
        XCTAssertEqual(viewModel.codeViewerTabs[0].editedCode, "let a = 2", "the buffer still holds the draft")
    }
}
