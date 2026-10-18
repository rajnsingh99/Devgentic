// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenInCodeViewerTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

/// `openMessageInCodeViewer` never touches persistence — it reads the message plus
/// `currentChatMessages` and opens Code Viewer tabs. A no-op stub keeps this file
/// self-contained; ChatHistoryViewModelTests' richer mock is private to that file.
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
final class OpenInCodeViewerTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()

    override func setUp() async throws {
        let store = NoopChatStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            )
        )
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    // MARK: - Fixtures

    private func lines(_ label: String, _ count: Int) -> String {
        (1...count).map { "print(\"\(label) \($0)\")" }.joined(separator: "\n")
    }

    /// python BETA (60 lines) first, then the alpha.swift marker + swift ALPHA (60 lines).
    /// The linked block is deliberately SECOND — that's the shape that exposes bug 2.
    private func betaThenLinkedAlpha() -> String {
        """
        ```python
        \(lines("BETA", 60))
        ```

        --- Start of file: alpha.swift ---

        ```swift
        \(lines("ALPHA", 60))
        ```
        """
    }

    private func agentMessage(_ markdown: String) -> ChatMessage {
        ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText(markdown))
    }

    /// A user message carrying alpha.swift, so `findMessageWithSourceFile` can resolve it.
    private func userMessageAttaching(_ name: String, content: String) -> ChatMessage {
        ChatMessage(
            conversationId: conversationID,
            sender: .user,
            content: .plainText("Here is the file"),
            attachedTextFiles: [AttachedTextFile(
                name: name,
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                fileExtension: "swift",
                content: content,
                size: Int64(content.count)
            )]
        )
    }

    /// Rebuilds the snippet exactly as ContentBlockView does when its card is tapped:
    /// straight from the parsed block, knowing nothing about source files.
    private func clickSiteSnippet(_ markdown: String, language: String) -> CodeSnippet {
        for block in parseMarkdown(markdown) {
            if case .code(let lang, let content, _) = block.type, lang == language {
                return CodeSnippet(codeBlock: lang, content: content)
            }
        }
        XCTFail("No \(language) block parsed")
        return CodeSnippet(language: nil, code: "")
    }

    // MARK: - The click

    /// Clicking the SECOND card must open the SECOND snippet — while it is also linked to
    /// an attached file, which is what made bug 2 invisible in every other test.
    func testClickingTheLinkedSecondCardOpensThatSnippet() {
        let markdown = betaThenLinkedAlpha()
        let message = agentMessage(markdown)
        viewModel.currentChatMessages = [
            userMessageAttaching("alpha.swift", content: lines("ALPHA", 60)),
            message
        ]

        viewModel.openMessageInCodeViewer(
            message: message,
            selectedSnippet: clickSiteSnippet(markdown, language: "swift")
        )

        XCTAssertEqual(viewModel.codeViewerTabs.count, 2, "Both 60-line blocks are large — one tab each")
        let activeIndex = viewModel.codeViewerTabs.firstIndex { $0.id == viewModel.activeCodeViewerTabID }
        XCTAssertEqual(activeIndex, 1,
                       "Clicked the swift card (tab index 1) — focusing 0 means it showed BETA instead")
        guard let opened = viewModel.activeCodeViewerTab?.snippet else { return XCTFail("Viewer never opened") }
        XCTAssertEqual(opened.language, "swift")
        XCTAssertTrue(opened.code.hasPrefix("print(\"ALPHA 1\")"), "Opened the wrong code")
    }

    /// The linking itself: the marker survives a blank line before the fence, and resolves
    /// to the attached file. `sourceFileID` is what gates the viewer's "Show Changes" button.
    func testMarkerWithBlankLineLinksToTheAttachedFile() {
        let markdown = betaThenLinkedAlpha()
        let message = agentMessage(markdown)
        let userMessage = userMessageAttaching("alpha.swift", content: lines("ALPHA", 60))
        viewModel.currentChatMessages = [userMessage, message]

        viewModel.openMessageInCodeViewer(message: message)

        let swift = viewModel.codeViewerTabs.first { $0.snippet.language == "swift" }?.snippet
        XCTAssertEqual(swift?.sourceMessageID, userMessage.id)
        XCTAssertEqual(swift?.sourceFileID, userMessage.attachedTextFiles?.first?.id,
                       "Without a sourceFileID the viewer shows no Show Changes button")
    }

    /// An em dash is not a typo — the composer used to rewrite `---`, and cmark's smart
    /// punctuation rewrites it during parsing regardless. The marker must still resolve.
    func testEmDashMarkerStillLinks() {
        let markdown = """
        — Start of file: alpha.swift —

        ```swift
        \(lines("ALPHA", 60))
        ```
        """
        let message = agentMessage(markdown)
        let userMessage = userMessageAttaching("alpha.swift", content: lines("ALPHA", 60))
        viewModel.currentChatMessages = [userMessage, message]

        viewModel.openMessageInCodeViewer(message: message)

        XCTAssertEqual(viewModel.codeViewerTabs.first?.snippet.sourceFileID,
                       userMessage.attachedTextFiles?.first?.id)
    }

    // MARK: - The 50-line boundary

    /// A 50-line block is NOT large (the threshold is `> 50`), so it must not reach the
    /// viewer's list while a larger block exists. It used to be counted as 51 by the
    /// renderer — which drew a card for it — and as 50 here, which excluded it: clicking
    /// that card opened a different snippet, and the clicked one was unreachable.
    func testFiftyLineBlockIsExcludedWhenALargerBlockExists() {
        let markdown = """
        ```swift
        \(lines("GAMMA", 50))
        ```

        ```python
        \(lines("BETA", 60))
        ```
        """
        let message = agentMessage(markdown)
        viewModel.currentChatMessages = [message]

        viewModel.openMessageInCodeViewer(message: message)

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(viewModel.codeViewerTabs.first?.snippet.language, "python",
                       "Only the 60-line block is large; GAMMA (50) renders inline instead")
    }

    /// With no large blocks, every snippet is offered — this is the path the bubble's
    /// "Open in Editor" button uses, and the only way a small block reaches the viewer.
    func testSmallBlocksAreAllOfferedWhenNoneAreLarge() {
        let markdown = """
        ```c++
        int x = 1;
        ```

        ```objective-c
        NSLog(@"hi");
        ```
        """
        let message = agentMessage(markdown)
        viewModel.currentChatMessages = [message]

        viewModel.openMessageInCodeViewer(message: message)

        XCTAssertEqual(viewModel.codeViewerTabs.map { $0.snippet.language }, ["c++", "objective-c"])
        XCTAssertEqual(viewModel.codeViewerTabs.first?.snippet.code, "int x = 1;",
                       "The c++ info string must not leak into the body the viewer shows")
    }
}
