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

    // MARK: - #3: stale diff state is reset when new content opens

    func test_showCodeInViewer_resetsStaleDiffState() {
        viewModel.isShowingDiff = true
        viewModel.originalCodeForDiff = "old file contents"

        viewModel.showCodeInViewer(language: "swift", code: "let y = 2")

        XCTAssertFalse(viewModel.isShowingDiff, "Opening new code must clear the previous diff toggle")
        XCTAssertNil(viewModel.originalCodeForDiff, "Opening new code must clear the previous diff baseline")
    }

    func test_openMessageInCodeViewer_resetsStaleDiffState() {
        viewModel.isShowingDiff = true
        viewModel.originalCodeForDiff = "old file contents"

        let msg = ChatMessage(conversationId: conversationID, sender: .agent,
                              content: .markdownText("```swift\nlet z = 3\n```"))
        viewModel.currentChatMessages = [msg]
        viewModel.openMessageInCodeViewer(message: msg)

        XCTAssertNotNil(viewModel.codeViewerContent, "sanity: a snippet opened")
        XCTAssertFalse(viewModel.isShowingDiff, "Opening a message must clear the previous diff toggle")
        XCTAssertNil(viewModel.originalCodeForDiff, "Opening a message must clear the previous diff baseline")
    }

    // MARK: - #4: trailing-newline preservation (pure helper)

    func test_contentToApply_reAddsTrailingNewlineWhenBaselineHadOne() {
        // Snippet code is extraction-trimmed; the file ended in a newline → re-add it.
        let out = ChatHistoryViewModel.contentToApply(snippetCode: "a\nb", preservingTrailingNewlineOf: "a\nb\n")
        XCTAssertEqual(out, "a\nb\n")
    }

    func test_contentToApply_leavesContentWhenBaselineHadNoTrailingNewline() {
        let out = ChatHistoryViewModel.contentToApply(snippetCode: "a\nb", preservingTrailingNewlineOf: "a\nb")
        XCTAssertEqual(out, "a\nb")
    }

    func test_contentToApply_doesNotDoubleTheNewline() {
        let out = ChatHistoryViewModel.contentToApply(snippetCode: "a\n", preservingTrailingNewlineOf: "a\n")
        XCTAssertEqual(out, "a\n")
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
}
