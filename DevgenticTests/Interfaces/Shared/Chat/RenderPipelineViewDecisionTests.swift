// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RenderPipelineViewDecisionTests.swift
//  DevgenticTests
//
//  The decisions behind three ContentBlockView/CodeBlockView defects
//  (Chat_Production_Readiness_Fresh), each extracted out of the view's `body` so it can be
//  driven directly:
//
//   • CF-5 — the inline "Viewer" button opened tabs with no origin identity, so dedup fell
//     through to exact-code equality and a block opened mid-stream, then again once it had
//     grown, left a duplicate tab holding the truncated fragment.
//
//   • CF-6 — a file-reference tap whose file was gone did nothing visible; the failure was
//     a log line only, under a comment claiming parity with the timeline row's explicit
//     failure surface.
//
//   • CF-7 — a markdown image naming a local path always rendered "Failed to load image":
//     `URL(string:)` yields a SCHEME-LESS URL and AsyncImage loads through URLSession.
//

import XCTest
@testable import devgentic

// MARK: - CF-7

final class LocalMarkdownImagePathTests: XCTestCase {

    /// The mechanism the row describes, pinned: these are the shapes URLSession cannot load.
    func testPathReferencesParseToASchemelessURL() {
        XCTAssertNil(URL(string: "/Users/x/chart.png")?.scheme)
        XCTAssertNil(URL(string: "./out/chart.png")?.scheme)
        XCTAssertNil(URL(string: "~/chart.png")?.scheme)
    }

    func testAbsolutePathIsClaimedAsAFile() {
        XCTAssertEqual(ContentBlockView.localImagePath(forSource: "/Users/x/chart.png"),
                       "/Users/x/chart.png")
    }

    func testTildeIsExpanded() {
        XCTAssertEqual(ContentBlockView.localImagePath(forSource: "~/chart.png"),
                       NSHomeDirectory() + "/chart.png")
    }

    func testDotRelativePathIsClaimed() {
        XCTAssertEqual(ContentBlockView.localImagePath(forSource: "./out/chart.png"), "./out/chart.png")
        XCTAssertEqual(ContentBlockView.localImagePath(forSource: "../out/chart.png"), "../out/chart.png")
    }

    /// A path containing a space must still be claimed, and must be claimed VERBATIM.
    ///
    /// ⚠️ The premise here is not what it looks like. On this Foundation, `URL(string:)` does NOT
    /// fail on the space — it percent-encodes it, returning `/Users/a%20b/chart.png`. So the
    /// dangerous outcome is not "no URL" but a URL whose path no longer names the file on disk.
    /// The claim must therefore come from the SOURCE STRING, never from a round trip through
    /// `URL(string:)`, or every path with a space would be read from the wrong location.
    func testPathWithASpaceIsStillClaimed() {
        XCTAssertEqual(URL(string: "/Users/a b/chart.png")?.absoluteString, "/Users/a%20b/chart.png",
                       "Fixture premise: the space is percent-encoded, not rejected")
        XCTAssertEqual(ContentBlockView.localImagePath(forSource: "/Users/a b/chart.png"),
                       "/Users/a b/chart.png",
                       "The path must survive verbatim — a percent-encoded one points at no file")
    }

    func testFileURLIsReadAsAPathRatherThanThroughURLSession() {
        XCTAssertEqual(ContentBlockView.localImagePath(forSource: "file:///tmp/a.png"), "/tmp/a.png")
    }

    /// Genuine URLs stay on the AsyncImage path, unchanged.
    func testRemoteAndDataReferencesAreNotClaimed() {
        XCTAssertNil(ContentBlockView.localImagePath(forSource: "https://example.com/a.png"))
        XCTAssertNil(ContentBlockView.localImagePath(forSource: "http://example.com/a.png"))
        XCTAssertNil(ContentBlockView.localImagePath(forSource: "data:image/png;base64,AAAA"))
    }

    /// A bare relative reference has no base to resolve against inside a chat transcript,
    /// so it is deliberately left where it was rather than guessed at.
    func testBareRelativeReferenceIsLeftOnTheRemotePath() {
        XCTAssertNil(ContentBlockView.localImagePath(forSource: "images/a.png"))
    }

    /// `./out/chart.png` IS claimed as a path — nothing else could ever have loaded it — but
    /// nothing resolves it either: `expandingTildeInPath` is a no-op and `FileManager` falls
    /// back to the PROCESS working directory ("/" for a Finder-launched app), never the
    /// agent's workspace. The chip therefore may NOT say the file is gone: that is a
    /// confident, specific and untrue statement about a file that is on disk, and the chip
    /// shows only the last path component, so the reader cannot see where we looked.
    func testARelativeReferenceIsNotReportedAsAMissingFile() {
        for relative in ["./out/chart.png", "../out/chart.png"] {
            let reason = ContentBlockView.localImageFailureText(path: relative, fileExists: false)
            XCTAssertTrue(reason.contains("relative"), "Got: \(reason)")
            XCTAssertFalse(reason.contains("no longer here"),
                           "A file we never looked for in the right folder is not a missing file: \(reason)")
        }
    }

    /// An ABSOLUTE path we did look for and did not find is genuinely gone, and still says so.
    func testAnAbsolutePathThatIsGoneStillSaysSo() {
        let reason = ContentBlockView.localImageFailureText(path: "/tmp/out/chart.png", fileExists: false)
        XCTAssertTrue(reason.contains("no longer here"), "Got: \(reason)")
    }

    /// Present but undecodable is its own outcome, for either path shape.
    func testAFileThatExistsButIsNotAnImageSaysThat() {
        for path in ["/tmp/out/chart.png", "./out/chart.png"] {
            let reason = ContentBlockView.localImageFailureText(path: path, fileExists: true)
            XCTAssertTrue(reason.contains("isn't an image"), "Got: \(reason)")
        }
    }

    func testEmptySourceIsNotClaimed() {
        XCTAssertNil(ContentBlockView.localImagePath(forSource: ""))
        XCTAssertNil(ContentBlockView.localImagePath(forSource: "   "))
    }

    /// End to end: the parser really does hand the view a bare path for an agent-written chart.
    func testParserEmitsABarePathForALocalImage() throws {
        var found: String?
        for block in parseMarkdown("![chart](/tmp/devgentic/chart.png)") {
            if case .image(let url, _) = block.type { found = url }
        }
        let source = try XCTUnwrap(found)
        XCTAssertEqual(source, "/tmp/devgentic/chart.png")
        XCTAssertEqual(ContentBlockView.localImagePath(forSource: source), "/tmp/devgentic/chart.png")
    }
}

// MARK: - CF-6

final class FileReferenceOpenFailureTests: XCTestCase {

    /// The field case, driven through a REAL read error rather than a constructed one.
    func testAMissingFileProducesAMovedOrDeletedReason() {
        let path = NSTemporaryDirectory() + "devgentic-absent-\(UUID().uuidString).swift"
        do {
            _ = try String(contentsOfFile: path, encoding: .utf8)
            XCTFail("Fixture must not exist")
        } catch {
            let reason = ContentBlockView.openFailureText(for: error, path: path)
            XCTAssertTrue(reason.contains((path as NSString).lastPathComponent),
                          "The reason must name the file: \(reason)")
            XCTAssertTrue(reason.contains("moved or deleted"), "Got: \(reason)")
        }
    }

    /// Mapped from `CocoaError` CODES, not from the message text, so the distinction
    /// survives localization.
    func testEachCocoaCodeMapsToItsOwnReason() {
        let path = "/somewhere/Report.swift"
        XCTAssertTrue(ContentBlockView.openFailureText(for: CocoaError(.fileReadNoSuchFile), path: path)
            .contains("moved or deleted"))
        XCTAssertTrue(ContentBlockView.openFailureText(for: CocoaError(.fileReadNoPermission), path: path)
            .contains("permission"))
        XCTAssertTrue(ContentBlockView.openFailureText(for: CocoaError(.fileReadInapplicableStringEncoding), path: path)
            .contains("UTF-8"))
    }

    /// An error the mapping does not recognise still says which file and why.
    func testUnrecognisedErrorsStillNameTheFile() {
        struct Odd: LocalizedError { var errorDescription: String? { "disk went away" } }
        let reason = ContentBlockView.openFailureText(for: Odd(), path: "/a/b/Notes.md")
        XCTAssertTrue(reason.contains("Notes.md"), "Got: \(reason)")
        XCTAssertTrue(reason.contains("disk went away"), "Got: \(reason)")
    }

    /// Every reason must be something a reader can act on — never empty, never bare.
    func testNoReasonIsEmpty() {
        for error in [CocoaError(.fileReadNoSuchFile), CocoaError(.fileReadNoPermission),
                      CocoaError(.fileReadInapplicableStringEncoding), CocoaError(.fileReadUnknown)] {
            XCTAssertFalse(ContentBlockView.openFailureText(for: error, path: "/a/B.txt").isEmpty)
        }
    }
}

// MARK: - CF-5

@MainActor
private final class OriginNoopStore: ChatPersistenceProtocol {
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
final class InlineCodeBlockOriginTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()

    override func setUp() async throws {
        let store = OriginNoopStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )
    }

    override func tearDown() async throws { viewModel = nil }

    // MARK: Fixtures

    private func lines(_ label: String, _ count: Int) -> String {
        (1...count).map { "print(\"\(label) \($0)\")" }.joined(separator: "\n")
    }

    /// One LARGE block (rendered as a card) followed by a SMALL one (rendered inline, with
    /// the "Viewer" button). `secondBlockLines` stays under the 50-line card threshold.
    private func markdown(secondBlockLines: Int) -> String {
        """
        ```python
        \(lines("BIG", 60))
        ```

        ```python
        \(lines("SMALL", secondBlockLines))
        ```
        """
    }

    private func message(_ text: String, id: UUID) -> ChatMessage {
        ChatMessage(id: id, conversationId: conversationID, sender: .agent, content: .markdownText(text))
    }

    /// The raw content the renderer hands `CodeBlockView` for the nth code block.
    private func blockContent(_ index: Int, in markdown: String) -> String {
        var contents: [String] = []
        for block in parseMarkdown(markdown) {
            if case .code(_, let content, _) = block.type { contents.append(content) }
        }
        return contents[index]
    }

    // MARK: Numbering

    func testOrdinalCountsEveryCodeBlockInDocumentOrder() {
        let text = markdown(secondBlockLines: 10)
        XCTAssertEqual(ContentBlockView.codeBlockOrdinal(forContent: blockContent(0, in: text),
                                                         in: .markdownText(text)), 0)
        XCTAssertEqual(ContentBlockView.codeBlockOrdinal(forContent: blockContent(1, in: text),
                                                         in: .markdownText(text)), 1)
    }

    func testASingleCodeBlockMessageIsOrdinalZero() {
        XCTAssertEqual(ContentBlockView.codeBlockOrdinal(forContent: "let x = 1",
                                                         in: .codeBlock(language: "swift", code: "let x = 1\n")),
                       0)
    }

    func testContentThatIsNotInTheMessageHasNoOrdinal() {
        let text = markdown(secondBlockLines: 10)
        XCTAssertNil(ContentBlockView.codeBlockOrdinal(forContent: "print(\"nowhere\")",
                                                        in: .markdownText(text)))
        XCTAssertNil(ContentBlockView.codeBlockOrdinal(forContent: "   ", in: .markdownText(text)))
    }

    // MARK: Which text the ordinal is resolved against

    /// ⚠️ The ordinal must be read from what the bubble is SHOWING, not from `message.content`.
    ///
    /// After a Retry the two diverge: `beginRegenerationVariant` selects a new variant and the
    /// streaming path writes only `variants[selected]`, while `content` keeps the ORIGINAL
    /// answer. `ChatBubbleView` renders `displayedContent`, so the blocks on screen belong to
    /// the new variant — and looked up in `content` they are not found at all. The ordinal
    /// comes back nil, `CodeBlockView` drops the origin, and dedup falls back to exact-code
    /// equality: the duplicate-tab defect CF-5 was filed for, surviving the fix.
    func testOrdinalFollowsTheVariantOnScreenAfterARegeneration() {
        let original = markdown(secondBlockLines: 10)
        let regenerated = """
        ```python
        \(lines("REDONE-BIG", 60))
        ```

        ```python
        \(lines("REDONE-SMALL", 12))
        ```
        """
        let msg = message(original, id: UUID())
        XCTAssertTrue(msg.beginRegenerationVariant(backendEntityId: nil))
        // Exactly what ActiveStreamManager's regeneration branch writes: the selected
        // variant only. `content` is deliberately left holding the first answer.
        msg.agentResponse?.variants[1].content = .markdownText(regenerated)

        let onScreen = blockContent(1, in: regenerated)
        XCTAssertNotEqual(onScreen, blockContent(1, in: original),
                          "Fixture premise: the two variants must not be interchangeable")
        XCTAssertNil(ContentBlockView.codeBlockOrdinal(forContent: onScreen, in: .markdownText(original)),
                     "Fixture premise: `content` still holds the original answer, which has no such block")
        XCTAssertEqual(ContentBlockView.codeBlockOrdinal(forContent: onScreen, in: msg), 1,
                       "Resolved against the rendered variant, the block is found at its own ordinal")
    }

    /// The control: a message that was never regenerated keeps `content` and `variants[0]` in
    /// lockstep, so nothing about the ordinary path changes.
    func testOrdinalIsUnchangedForAMessageThatWasNeverRegenerated() {
        let text = markdown(secondBlockLines: 10)
        let msg = message(text, id: UUID())
        XCTAssertEqual(ContentBlockView.codeBlockOrdinal(forContent: blockContent(0, in: text), in: msg), 0)
        XCTAssertEqual(ContentBlockView.codeBlockOrdinal(forContent: blockContent(1, in: text), in: msg), 1)
    }

    /// The ordinal is positional, so it does NOT move when the block it names keeps growing —
    /// which is the only reason it can identify a streaming block at all.
    func testOrdinalIsStableWhileTheBlockGrows() {
        let early = markdown(secondBlockLines: 10)
        let late = markdown(secondBlockLines: 40)
        XCTAssertEqual(ContentBlockView.codeBlockOrdinal(forContent: blockContent(1, in: early),
                                                         in: .markdownText(early)), 1)
        XCTAssertEqual(ContentBlockView.codeBlockOrdinal(forContent: blockContent(1, in: late),
                                                         in: .markdownText(late)), 1)
    }

    // MARK: Parity with the card path

    /// The two open routes MUST number blocks identically: a block can cross the 50-line
    /// card threshold mid-stream, so the same block gets opened from the inline button
    /// before and from the card after. Disagreeing ordinals = two tabs for one block.
    func testOrdinalMatchesWhatTheCardPathStamps() {
        let text = markdown(secondBlockLines: 10)
        let msg = message(text, id: UUID())

        viewModel.openMessageInCodeViewer(message: msg)

        let tab = viewModel.codeViewerTabs.first
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "Only the large block becomes a card tab")
        XCTAssertEqual(tab?.originBlockIndex,
                       ContentBlockView.codeBlockOrdinal(forContent: blockContent(0, in: text),
                                                          in: .markdownText(text)),
                       "The inline button and the card must agree on this block's ordinal")
    }

    // MARK: The defect

    /// What the inline button does now: open with the resolved origin, twice, across growth.
    func testReopeningAGrownInlineBlockRefreshesItsTab() {
        let messageID = UUID()
        let early = markdown(secondBlockLines: 10)
        let late = markdown(secondBlockLines: 40)

        let earlyContent = blockContent(1, in: early)
        let firstID = viewModel.openTab(
            for: CodeSnippet(codeBlock: "python", content: earlyContent),
            fileName: nil,
            originMessageID: messageID,
            originBlockIndex: ContentBlockView.codeBlockOrdinal(forContent: earlyContent,
                                                                in: .markdownText(early))
        )

        let lateContent = blockContent(1, in: late)
        let secondID = viewModel.openTab(
            for: CodeSnippet(codeBlock: "python", content: lateContent),
            fileName: nil,
            originMessageID: messageID,
            originBlockIndex: ContentBlockView.codeBlockOrdinal(forContent: lateContent,
                                                                in: .markdownText(late))
        )

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "Re-opening must refresh, not append")
        XCTAssertEqual(firstID, secondID, "Same tab")
        XCTAssertEqual(viewModel.codeViewerTabs.first?.snippet.code,
                       CodeSnippet.normalizedCode(lateContent),
                       "The tab must hold the grown block, not the truncated fragment")
    }

    /// The counterfactual — what the button did BEFORE it carried an origin. Content
    /// equality cannot match a block that grew, so a second tab appeared holding the
    /// mid-stream fragment. This is the behaviour the fix removes.
    func testOpeningWithoutAnOriginStillDuplicatesTheGrownBlock() {
        let early = blockContent(1, in: markdown(secondBlockLines: 10))
        let late = blockContent(1, in: markdown(secondBlockLines: 40))

        viewModel.openTab(for: CodeSnippet(codeBlock: "python", content: early), fileName: nil)
        viewModel.openTab(for: CodeSnippet(codeBlock: "python", content: late), fileName: nil)

        XCTAssertEqual(viewModel.codeViewerTabs.count, 2,
                       "Without an origin, dedup is exact-code equality — the defect CF-5 describes")
    }
}
