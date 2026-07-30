//
//  SourceLookupFallbackTests.swift
//  DevgenticTests
//
//  Covers the store-backed fallbacks for the Code Viewer's three source lookups. The
//  loaded message window is paginated (~20 newest); when a snippet's source message has
//  scrolled out of it, diff/apply/linking previously dead-ended silently. Now they fall
//  back to persistence — these tests drive the fallbacks with an empty window and a
//  canned store.
//

import XCTest
@testable import devgentic

/// Store stub with canned fallback answers; everything else is a no-op.
@MainActor
private final class FallbackChatStore: ChatPersistenceProtocol {
    var messagesById: [UUID: ChatMessage] = [:]
    var attachmentMessages: [ChatMessage] = []

    func fetchMessage(withId id: UUID) async -> ChatMessage? { messagesById[id] }
    func fetchUserMessagesWithAttachedTextFiles(for conversationId: UUID) async -> [ChatMessage] { attachmentMessages }

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
final class SourceLookupFallbackTests: XCTestCase {

    private var store: FallbackChatStore!
    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()
    private var tempFiles: [URL] = []

    override func setUp() async throws {
        store = FallbackChatStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        )
    }

    override func tearDown() async throws {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll()
        viewModel = nil
        store = nil
    }

    // MARK: - Fixtures

    /// A user message carrying an attached file, registered ONLY in the store (never in
    /// the loaded window) — the scrolled-out-of-page scenario.
    private func storeOnlySource(named name: String, content: String, onDisk: String? = nil) throws -> (message: ChatMessage, file: AttachedTextFile) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallback_\(UUID().uuidString)_\(name)")
        if let onDisk {
            try onDisk.write(to: url, atomically: true, encoding: .utf8)
            tempFiles.append(url)
        }
        let file = AttachedTextFile(name: name, url: url, fileExtension: (name as NSString).pathExtension,
                                    content: content, size: Int64(content.count))
        let message = ChatMessage(conversationId: conversationID, sender: .user,
                                  content: .plainText("attached"), attachedTextFiles: [file])
        store.messagesById[message.id] = message
        store.attachmentMessages = [message]
        return (message, file)
    }

    private func openLinkedTab(sourceMessageID: UUID, sourceFileID: UUID, code: String) -> CodeSnippet {
        let snippet = CodeSnippet(language: "swift", code: code,
                                  sourceMessageID: sourceMessageID, sourceFileID: sourceFileID)
        viewModel.codeViewerTabs = [CodeViewerTab(snippet: snippet)]
        viewModel.activeCodeViewerTabID = viewModel.codeViewerTabs[0].id
        viewModel.isCodeViewerVisible = true
        return snippet
    }

    // MARK: - Diff toggle fallback

    // The two diff-toggle fallback tests are gone with the panel's diff surface. The
    // store-fallback path they exercised is still covered by the apply/link tests below,
    // which use the same `resolveSourceFile` seam.

    func test_apply_fallsBackToStore_andWrites() async throws {
        let (message, file) = try storeOnlySource(named: "beta.swift", content: "OLD\n", onDisk: "OLD\n")
        let snippet = openLinkedTab(sourceMessageID: message.id, sourceFileID: file.id, code: "NEW")
        viewModel.currentChatMessages = []

        await viewModel.performApplyChanges(for: snippet)

        XCTAssertNil(viewModel.codeApplyError, "Apply must succeed via the store fallback")
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "NEW\n")
    }

    func test_apply_errors_whenGoneEverywhere() async {
        let snippet = openLinkedTab(sourceMessageID: UUID(), sourceFileID: UUID(), code: "NEW")
        viewModel.currentChatMessages = []

        await viewModel.performApplyChanges(for: snippet)

        XCTAssertNotNil(viewModel.codeApplyError, "A truly missing source must still surface the error")
    }

    // MARK: - Deferred linking (open-time window miss → store re-link)

    func test_deferredLinking_stampsTabInPlace() async throws {
        let sixtyLines = (1...60).map { "print(\($0))" }.joined(separator: "\n")
        let (sourceMessage, file) = try storeOnlySource(named: "alpha.swift", content: sixtyLines)

        // The agent message references alpha.swift, but the ATTACHING message is only in
        // the store — window linking misses at open time.
        let markdown = "--- Start of file: alpha.swift ---\n\n```swift\n\(sixtyLines)\n```"
        let agentMessage = ChatMessage(conversationId: conversationID, sender: .agent,
                                       content: .markdownText(markdown))
        viewModel.currentChatMessages = [agentMessage]

        viewModel.openMessageInCodeViewer(message: agentMessage)
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertNil(viewModel.codeViewerTabs[0].snippet.sourceFileID, "Window linking misses first")
        let snippetIDBeforeLink = viewModel.codeViewerTabs[0].snippet.id
        let tabID = viewModel.codeViewerTabs[0].id

        await viewModel.resolvePendingSourceLinks([(tabID: tabID, fileName: "alpha.swift")],
                                                  conversationID: conversationID)

        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.sourceFileID, file.id, "Store re-link stamps the tab")
        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.sourceMessageID, sourceMessage.id)
        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.id, snippetIDBeforeLink,
                       "Stamping is IN PLACE — a new snippet id would rebuild the editor under the user")
    }

    /// After a deferred link lands, re-opening the same card (whose fresh window-linking
    /// still misses) must focus the linked tab, not stack an unlinked duplicate.
    func test_reopenAfterDeferredLink_dedupsToLinkedTab() async throws {
        let sixtyLines = (1...60).map { "print(\($0))" }.joined(separator: "\n")
        _ = try storeOnlySource(named: "alpha.swift", content: sixtyLines)

        let markdown = "--- Start of file: alpha.swift ---\n\n```swift\n\(sixtyLines)\n```"
        let agentMessage = ChatMessage(conversationId: conversationID, sender: .agent,
                                       content: .markdownText(markdown))
        viewModel.currentChatMessages = [agentMessage]

        viewModel.openMessageInCodeViewer(message: agentMessage)
        let tabID = viewModel.codeViewerTabs[0].id
        await viewModel.resolvePendingSourceLinks([(tabID: tabID, fileName: "alpha.swift")],
                                                  conversationID: conversationID)
        XCTAssertNotNil(viewModel.codeViewerTabs[0].snippet.sourceFileID, "sanity: linked")

        viewModel.openMessageInCodeViewer(message: agentMessage)

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1,
                       "Nil-tolerant dedup must match the now-linked tab, not duplicate it")
        XCTAssertNotNil(viewModel.codeViewerTabs[0].snippet.sourceFileID, "The link survives the re-open")
    }
}
