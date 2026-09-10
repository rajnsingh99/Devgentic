// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  FileNameInferenceTests.swift
//  DevgenticTests
//
//  Covers CodeFileNameInference — heuristic filename detection for code blocks with no
//  `--- Start of file ---` marker — and its wiring through the parser into ContentBlock,
//  the extractor, and Code Viewer tab titles.
//
//  The motivating shape is real LLM output (2026-07-24 screenshot): a heading, prose, an
//  inline-code filename (`DijkstraSolver.java`), then the fence. Only the injected marker
//  used to populate `fileName`, so those blocks rendered "Java Snippet" and tabs "Java".
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
final class FileNameInferenceTests: XCTestCase {

    // MARK: - Helpers

    private func lines(_ label: String, _ count: Int) -> String {
        (1...count).map { "print(\"\(label) \($0)\")" }.joined(separator: "\n")
    }

    /// First `.code` block in the parse, or nil.
    private func firstCodeBlock(in markdown: String) -> (language: String, content: String, fileName: String?)? {
        for block in parseMarkdown(markdown) {
            if case .code(let lang, let content, let name) = block.type {
                return (lang, content, name)
            }
        }
        return nil
    }

    // MARK: - Token validation

    func testFilenameTokenAcceptsAndCleans() {
        XCTAssertEqual(CodeFileNameInference.filenameToken("DijkstraSolver.java"), "DijkstraSolver.java")
        XCTAssertEqual(CodeFileNameInference.filenameToken("`Main.swift`:"), "Main.swift")
        XCTAssertEqual(CodeFileNameInference.filenameToken("**config.yaml**"), "config.yaml")
        // A single token as `fromTrailingProse` hands it over — "(see Foo.java)." splits
        // to a last word of "Foo.java)." — wrapping/trailing punctuation is stripped.
        XCTAssertEqual(CodeFileNameInference.filenameToken("src/Main.java)."), "src/Main.java")
        XCTAssertEqual(CodeFileNameInference.filenameToken("(src/Main.java)"), "src/Main.java")
        XCTAssertEqual(CodeFileNameInference.filenameToken("README.md"), "README.md")
    }

    func testFilenameTokenRejectsNonFilenames() {
        XCTAssertNil(CodeFileNameInference.filenameToken("follows..."), "Ellipsis prose is not a file")
        XCTAssertNil(CodeFileNameInference.filenameToken("v2.0:"), "Digit-led extension = version, not file")
        XCTAssertNil(CodeFileNameInference.filenameToken("https://example.io/a.js"), "URLs never claim")
        XCTAssertNil(CodeFileNameInference.filenameToken("Makefile"), "No extension → cannot infer")
        XCTAssertNil(CodeFileNameInference.filenameToken("etc."), "Trailing-dot word has no extension")
    }

    // MARK: - Signal: preceding prose / heading

    /// The screenshot shape: heading + prose + inline-code filename paragraph + fence.
    func testProseInlineCodeFilenameNamesFollowingFence() {
        let markdown = """
        ### Conway's Game of Life Simulation

        This program simulates Conway's Game of Life, a classic cellular automaton.

        `GameOfLifeSimulator.java`

        ```java
        \(lines("LIFE", 5))
        ```
        """
        XCTAssertEqual(firstCodeBlock(in: markdown)?.fileName, "GameOfLifeSimulator.java")
    }

    func testProseEndingWithFilenameColonClaims() {
        let markdown = """
        Here is the updated `Main.swift`:

        ```swift
        let x = 1
        ```
        """
        XCTAssertEqual(firstCodeBlock(in: markdown)?.fileName, "Main.swift")
    }

    func testHeadingFilenameClaims() {
        let markdown = """
        ### DijkstraSolver.java

        ```java
        int x = 1;
        ```
        """
        XCTAssertEqual(firstCodeBlock(in: markdown)?.fileName, "DijkstraSolver.java")
    }

    /// A mid-sentence mention must not claim — the paragraph ends on a different word.
    func testMidSentenceMentionDoesNotClaim() {
        let markdown = """
        I updated Foo.java and then reran the whole suite.

        ```java
        int x = 1;
        ```
        """
        XCTAssertNil(firstCodeBlock(in: markdown)?.fileName)
    }

    /// The prose claim is consumed by the FIRST fence; a second fence stays unnamed.
    func testProseClaimIsConsumedByFirstFenceOnly() {
        let markdown = """
        `alpha.py`

        ```python
        a = 1
        ```

        ```python
        b = 2
        ```
        """
        var names: [String?] = []
        for block in parseMarkdown(markdown) {
            if case .code(_, _, let name) = block.type { names.append(name) }
        }
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names[0], "alpha.py")
        XCTAssertNil(names[1], "The claim must not leak onto the second fence")
    }

    // MARK: - Signal: fence info string

    func testInfoStringSecondTokenClaims() {
        let markdown = """
        ```java DijkstraSolver.java
        int x = 1;
        ```
        """
        let block = firstCodeBlock(in: markdown)
        XCTAssertEqual(block?.fileName, "DijkstraSolver.java")
        XCTAssertEqual(block?.language, "java", "Language must be the FIRST token only — not the whole info string")
    }

    func testInfoStringColonFormClaims() {
        let markdown = """
        ```js:app.js
        const x = 1;
        ```
        """
        let block = firstCodeBlock(in: markdown)
        XCTAssertEqual(block?.fileName, "app.js")
        XCTAssertEqual(block?.language, "js")
    }

    func testInfoStringTitleKeyClaims() {
        let markdown = """
        ```python title=script.py
        x = 1
        ```
        """
        XCTAssertEqual(firstCodeBlock(in: markdown)?.fileName, "script.py")
    }

    /// The info string IS the filename (no language token) — models do this too.
    func testInfoStringBareFilenameClaims() {
        let markdown = """
        ```GameOfLifeSimulator.java
        int x = 1;
        ```
        """
        XCTAssertEqual(firstCodeBlock(in: markdown)?.fileName, "GameOfLifeSimulator.java")
    }

    /// Plain single-token info strings must be untouched — `c++` is a language, not a file.
    func testPlainLanguageInfoStringDoesNotClaim() {
        let markdown = """
        ```c++
        int x = 1;
        ```
        """
        let block = firstCodeBlock(in: markdown)
        XCTAssertNil(block?.fileName)
        XCTAssertEqual(block?.language, "c++")
    }

    // MARK: - Signal: leading comment

    func testLeadingCommentFilenameClaims() {
        XCTAssertEqual(firstCodeBlock(in: "```java\n// DijkstraSolver.java\nint x = 1;\n```")?.fileName,
                       "DijkstraSolver.java")
        XCTAssertEqual(firstCodeBlock(in: "```python\n# script.py\nx = 1\n```")?.fileName,
                       "script.py")
        XCTAssertEqual(firstCodeBlock(in: "```c\n/* main.c */\nint x;\n```")?.fileName,
                       "main.c")
        XCTAssertEqual(firstCodeBlock(in: "```swift\n// File: Sources/App.swift\nlet x = 1\n```")?.fileName,
                       "Sources/App.swift")
    }

    func testLeadingCommentSentenceDoesNotClaim() {
        XCTAssertNil(firstCodeBlock(in: "```java\n// This solves Dijkstra via Foo.java\nint x = 1;\n```")?.fileName,
                     "A comment SENTENCE mentioning a file must not claim")
    }

    func testShebangDoesNotClaim() {
        XCTAssertNil(firstCodeBlock(in: "```bash\n#!/usr/bin/env python\nx = 1\n```")?.fileName)
    }

    func testUncommentedCodeDoesNotClaim() {
        XCTAssertNil(firstCodeBlock(in: "```java\nimport java.util.Arrays;\nint x = 1;\n```")?.fileName,
                     "Plain code (the screenshot's actual body) must not claim from its first line")
    }

    // MARK: - Priority

    /// The explicit marker outranks every heuristic — it's what source-file linking
    /// resolves by name, so a weaker signal must never rename a linked block.
    func testMarkerOutranksInfoStringAndComment() {
        let markdown = """
        --- Start of file: alpha.swift ---

        ```swift beta.swift
        // gamma.swift
        let x = 1
        ```
        """
        XCTAssertEqual(firstCodeBlock(in: markdown)?.fileName, "alpha.swift")
    }

    func testInfoStringOutranksLeadingComment() {
        let markdown = """
        ```swift beta.swift
        // gamma.swift
        let x = 1
        ```
        """
        XCTAssertEqual(firstCodeBlock(in: markdown)?.fileName, "beta.swift")
    }

    // MARK: - Streaming parity

    /// The prose claim must survive a settled-region boundary: the claim paragraph settles
    /// in one flush, the fence arrives in a later one. `pendingFileName` threads across
    /// regions exactly like the marker does.
    func testProseClaimCrossesStreamingRegions() {
        let parser = StreamingMarkdownParser()
        let chunk1 = "`GameOfLifeSimulator.java`\n\n"
        _ = parser.parse(chunk1)

        let full = chunk1 + "```java\nint x = 1;\n```"
        let blocks = parser.parse(full)

        var found: String? = nil
        for block in blocks {
            if case .code(_, _, let name) = block.type { found = name }
        }
        XCTAssertEqual(found, "GameOfLifeSimulator.java")
    }

    // MARK: - End to end: extractor + viewer tab title

    func testInferredNameFlowsToExtractorAndTabTitle() {
        let store = NoopChatStore()
        let viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        )

        // Screenshot-shaped message with a LARGE block so it becomes a card + tab.
        let markdown = """
        `DijkstraSolver.java`

        ```java
        \(lines("DIJKSTRA", 60))
        ```
        """
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(markdown))
        viewModel.currentChatMessages = [message]

        viewModel.openMessageInCodeViewer(message: message)

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(viewModel.codeViewerTabs.first?.fileName, "DijkstraSolver.java")
        XCTAssertEqual(viewModel.codeViewerTabs.first?.title, "DijkstraSolver.java",
                       "The tab must be titled by the inferred filename, not 'Java'")
        XCTAssertNil(viewModel.codeViewerTabs.first?.snippet.sourceFileID,
                     "An inferred name with no matching attachment must NOT fabricate a source link")
    }
}
