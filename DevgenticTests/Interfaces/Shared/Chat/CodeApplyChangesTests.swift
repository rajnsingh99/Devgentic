//
//  CodeApplyChangesTests.swift
//  DevgenticTests
//
//  Covers audit finding #5 (CodeViewer apply-changes cluster), 2026-07-18:
//   • #3 — showCodeInViewer / openMessageInCodeViewer must reset stale diff state
//          (else the panel diffs the OLD baseline against the NEW snippet with a live Apply).
//   • #2 — a failed apply must surface via `codeApplyError`, not vanish into the log.
//   • #4 — apply preserves the file's trailing newline, and refuses to overwrite a file
//          that changed on disk since it was attached (silent-revert data loss).
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
final class CodeApplyChangesTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()
    private var tempFiles: [URL] = []

    override func setUp() async throws {
        let store = NoopChatStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        )
    }

    override func tearDown() async throws {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll()
        viewModel = nil
    }

    // MARK: - #3: a freshly opened block is never in diff mode (now per-tab)
    //
    // The old "stale global diff leaks onto new content" bug is structurally impossible now
    // that diff state lives per tab: a newly opened tab starts in final-code mode, and one
    // tab's diff can't bleed onto another.

    // MARK: - #4: edge-whitespace preservation (pure helper)

    func test_contentToApply_reAddsTrailingNewlineWhenBaselineHadOne() {
        // Snippet code is extraction-trimmed; the file ended in a newline → re-add it.
        let out = ChatHistoryViewModel.contentToApply(snippetCode: "a\nb", preservingEdgeWhitespaceOf: "a\nb\n")
        XCTAssertEqual(out, "a\nb\n")
    }

    func test_contentToApply_leavesContentWhenBaselineHadNoTrailingNewline() {
        let out = ChatHistoryViewModel.contentToApply(snippetCode: "a\nb", preservingEdgeWhitespaceOf: "a\nb")
        XCTAssertEqual(out, "a\nb")
    }

    func test_contentToApply_doesNotDoubleTheNewline() {
        let out = ChatHistoryViewModel.contentToApply(snippetCode: "a\n", preservingEdgeWhitespaceOf: "a\n")
        XCTAssertEqual(out, "a\n")
    }

    // MARK: - Leading edge (2026-07-27 audit)
    //
    // `normalizedCode` trims BOTH edges on open but only the trailing side was restored, so a
    // single ⌘S — even with no edits, since `saveTabToItsPath` has no unchanged-buffer guard —
    // permanently deleted a file's leading blank line. The drift guard compares both sides
    // trimmed, so it could never catch this.

    func test_contentToApply_reAddsLeadingBlankLine() {
        let out = ChatHistoryViewModel.contentToApply(
            snippetCode: "// header\nlet a = 1",
            preservingEdgeWhitespaceOf: "\n// header\nlet a = 1\n"
        )
        XCTAssertEqual(out, "\n// header\nlet a = 1\n", "both edges come back")
    }

    func test_contentToApply_reAddsLeadingIndentation() {
        let out = ChatHistoryViewModel.contentToApply(
            snippetCode: "let a = 1",
            preservingEdgeWhitespaceOf: "    let a = 1"
        )
        XCTAssertEqual(out, "    let a = 1")
    }

    func test_contentToApply_doesNotDoubleTheLeadingWhitespace() {
        let out = ChatHistoryViewModel.contentToApply(
            snippetCode: "\n// header",
            preservingEdgeWhitespaceOf: "\n// header"
        )
        XCTAssertEqual(out, "\n// header", "already present → left alone")
    }

    /// An already-trimmed baseline has nothing to restore. This is the degradation path when
    /// `onDiskContent` is nil, and it must be a no-op rather than damage.
    func test_contentToApply_trimmedBaselineIsANoOp() {
        let out = ChatHistoryViewModel.contentToApply(
            snippetCode: "let a = 1",
            preservingEdgeWhitespaceOf: "let a = 1"
        )
        XCTAssertEqual(out, "let a = 1")
    }

    /// An all-whitespace baseline has no non-whitespace prefix boundary; prepending it would
    /// splice the entire file in front of itself.
    func test_contentToApply_allWhitespaceBaselineDoesNotSpliceItself() {
        let out = ChatHistoryViewModel.contentToApply(
            snippetCode: "new content",
            preservingEdgeWhitespaceOf: "\n\n   \n"
        )
        XCTAssertEqual(out, "new content\n", "only the trailing newline applies")
    }

    func test_contentToApply_emptyBaselineIsANoOp() {
        XCTAssertEqual(
            ChatHistoryViewModel.contentToApply(snippetCode: "x", preservingEdgeWhitespaceOf: ""),
            "x"
        )
    }

    // MARK: - Apply integration (real temp file)

    /// Writes a temp file and returns (url, message, snippet) wired so `performApplyChanges`
    /// resolves the source. `attachedContent` is the baseline the diff was captured against.
    private func makeLinkedSnippet(onDisk: String, attachedContent: String, newCode: String)
        throws -> (url: URL, snippet: CodeSnippet) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apply_\(UUID().uuidString).swift")
        try onDisk.write(to: url, atomically: true, encoding: .utf8)
        tempFiles.append(url)

        let file = AttachedTextFile(name: url.lastPathComponent, url: url, fileExtension: "swift",
                                    content: attachedContent, size: Int64(attachedContent.count))
        let msg = ChatMessage(conversationId: conversationID, sender: .user,
                              content: .plainText("file"), attachedTextFiles: [file])
        viewModel.currentChatMessages = [msg]

        let snippet = CodeSnippet(language: "swift", code: newCode,
                                  sourceMessageID: msg.id, sourceFileID: file.id)
        return (url, snippet)
    }

    func test_apply_writesContent_andPreservesTrailingNewline() async throws {
        let (url, snippet) = try makeLinkedSnippet(onDisk: "OLD\n", attachedContent: "OLD\n", newCode: "NEW")

        await viewModel.performApplyChanges(for: snippet)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "NEW\n", "Apply writes the new content AND keeps the file's trailing newline")
        XCTAssertNil(viewModel.codeApplyError, "A successful apply leaves no error")
    }

    func test_apply_refusesOnDiskDrift_leavesFileUntouched_andReportsError() async throws {
        // Baseline (attach-time) was "OLD\n", but the file changed on disk since.
        let (url, snippet) = try makeLinkedSnippet(onDisk: "OLD\n", attachedContent: "OLD\n", newCode: "NEW")
        try "EXTERNAL EDIT".write(to: url, atomically: true, encoding: .utf8)

        await viewModel.performApplyChanges(for: snippet)

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(onDisk, "EXTERNAL EDIT", "Drift guard must NOT overwrite externally-edited content")
        XCTAssertNotNil(viewModel.codeApplyError, "Drift must be reported to the user")
        XCTAssertTrue(viewModel.codeApplyError?.contains("changed on disk") ?? false,
                      "The error should explain the drift")
    }

    func test_apply_setsError_whenSourceFileCannotBeFound() async {
        // A snippet whose source ids don't resolve to any current message/file.
        let snippet = CodeSnippet(language: "swift", code: "X", sourceMessageID: UUID(), sourceFileID: UUID())
        viewModel.currentChatMessages = []

        await viewModel.performApplyChanges(for: snippet)

        XCTAssertNotNil(viewModel.codeApplyError, "A missing source file must surface, not vanish into the log")
    }

    // MARK: - Editable tabs: the save engine is draft-aware

    /// Opens a tab for `snippet` the way the viewer does, returning its id.
    private func openTab(for snippet: CodeSnippet) -> UUID {
        viewModel.codeViewerTabs = [CodeViewerTab(snippet: snippet)]
        viewModel.activeCodeViewerTabID = viewModel.codeViewerTabs[0].id
        viewModel.isCodeViewerVisible = true
        return viewModel.codeViewerTabs[0].id
    }

    func test_save_writesDraft_notThePristineSnippet() async throws {
        let (url, snippet) = try makeLinkedSnippet(onDisk: "OLD\n", attachedContent: "OLD\n", newCode: "PROPOSAL")
        let tabID = openTab(for: snippet)
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "USER EDITED DRAFT")

        await viewModel.performApplyChanges(for: snippet)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "USER EDITED DRAFT\n", "The BUFFER (draft) is what saves — not snippet.code")
        XCTAssertNil(viewModel.codeApplyError)
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty, "A successful save cleans the tab")
        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.code, "PROPOSAL",
                       "Saving must not mutate the snippet (its id keys the editor rebuild)")
    }

    /// The drift-guard baseline must ADVANCE with our own writes. Comparing against
    /// attach-time content forever refused every save after the first as "drift" —
    /// this test pins the sequential-save fix (and the pre-existing double-apply bug).
    func test_save_twice_succeeds_baselineAdvances() async throws {
        let (url, snippet) = try makeLinkedSnippet(onDisk: "OLD\n", attachedContent: "OLD\n", newCode: "V1")
        let tabID = openTab(for: snippet)

        await viewModel.performApplyChanges(for: snippet)          // save 1: writes V1
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "V1\n")

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "V2")
        await viewModel.performApplyChanges(for: snippet)          // save 2: must NOT be "drift"

        XCTAssertNil(viewModel.codeApplyError, "The second save must not trip the drift guard on our own write")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "V2\n")
    }

    // MARK: - Per-hunk apply / revert

    // Per-hunk apply/revert removed with the panel's diff surface — a change is shown in
    // the tool row that produced it, and the panel's only write path is now Save
    // (`Docs/codeviewer-rescope-design.md` §4). The save-engine tests above still cover
    // drift, trailing-newline handling and baseline advance, which all survive.

    func test_save_noops_whenBufferUnchangedSinceLastSave() async throws {
        let (url, snippet) = try makeLinkedSnippet(onDisk: "OLD\n", attachedContent: "OLD\n", newCode: "V1")
        _ = openTab(for: snippet)

        await viewModel.performApplyChanges(for: snippet)          // save 1

        // An external edit that a real second WRITE would clobber (or drift-refuse).
        try "EXTERNAL".write(to: url, atomically: true, encoding: .utf8)
        await viewModel.performApplyChanges(for: snippet)          // clean → must not touch disk

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "EXTERNAL",
                       "A no-op save must not write (or error) — nothing changed since our last save")
        XCTAssertNil(viewModel.codeApplyError)
    }
}
