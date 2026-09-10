// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SnippetIdentityTests.swift
//  DevgenticTests
//
//  Pins the contract that makes "click a code block, open THAT code block" work.
//
//  `openMessageInCodeViewer` locates the clicked snippet with `firstIndex(of:)`, and
//  CodeSnippet's `==` compares CONTENT (never `id` — that's a fresh UUID per extraction,
//  so it could never match). The snippet therefore has to be built identically on both
//  sides: at the click site (ContentBlockView / AgentBubbleContentView) and inside
//  CodeSnippetExtractor.
//
//  They weren't. cmark terminates a code block's content with "\n"; the click sites passed
//  it through raw while the extractor trimmed. Every lookup returned nil, so every click
//  fell back to `initialIndex = 0` and opened the FIRST snippet. Both sides now go through
//  `CodeSnippet(codeBlock:content:)`.
//

import XCTest
@testable import devgentic

final class SnippetIdentityTests: XCTestCase {

    /// Rebuilds what ContentBlockView does for each parsed `.code` block.
    private func clickSiteSnippets(_ md: String) -> [CodeSnippet] {
        parseMarkdown(md).compactMap { block in
            guard case .code(let lang, let content, _) = block.type else { return nil }
            return CodeSnippet(codeBlock: lang, content: content)
        }
    }

    private func viewerSnippets(_ md: String) -> [CodeSnippet] {
        CodeSnippetExtractor.extract(from: md).map { CodeSnippet(language: $0.language, code: $0.code) }
    }

    private let twoBlocks = """
    First:

    ```swift
    let a = 1
    ```

    Then:

    ```python
    b = 2
    ```
    """

    /// The decisive one: clicking block N must locate block N, not fall back to 0.
    func testClickedSnippetIsFoundAtItsOwnIndex() {
        let clicked = clickSiteSnippets(twoBlocks)
        let viewer = viewerSnippets(twoBlocks)
        XCTAssertEqual(clicked.count, 2, "Sanity: both fences should reach the click site")

        for (expected, snippet) in clicked.enumerated() {
            XCTAssertEqual(viewer.firstIndex(of: snippet), expected,
                           "Clicking snippet \(expected) resolved to \(viewer.firstIndex(of: snippet).map(String.init) ?? "nil") — the viewer would open the wrong code")
        }
    }

    /// A bare fence reaches the click site as "" and the extractor as nil; both must mean
    /// "no language" or the lookup misses.
    func testBareFenceSnippetsMatchAcrossSites() {
        let md = "```\nplain\n```"
        guard let clicked = clickSiteSnippets(md).first else { return XCTFail("No block parsed") }
        XCTAssertNil(clicked.language, "\"\" must normalise to nil, as the extractor does")
        XCTAssertEqual(viewerSnippets(md).firstIndex(of: clicked), 0)
    }

    /// The viewer stamps `sourceMessageID`/`sourceFileID` onto a snippet AFTER resolving its
    /// `--- Start of file ---` name against the user's attached files. A click site holds only
    /// the rendered block, so it cannot know either. If the lookup compares them, every
    /// SUCCESSFULLY LINKED snippet misses and falls back to snippet 0 — the same failure the
    /// trailing newline caused, just triggered by attaching a file instead.
    func testLinkedSnippetStillMatchesTheClickSite() {
        let clicked = CodeSnippet(codeBlock: "swift", content: "print(1)\n")   // ContentBlockView
        var linked = CodeSnippet(codeBlock: "swift", content: "print(1)\n")    // openMessageInCodeViewer
        linked.sourceMessageID = UUID()
        linked.sourceFileID = UUID()

        // The defect itself: `==` compares the source IDs, so the old `firstIndex(of:)`
        // could never have matched a linked snippet. This is why the lookup can't use it.
        XCTAssertNotEqual(linked, clicked,
                          "If == ever stops comparing source IDs, denotesSameBlock is redundant")
        XCTAssertTrue(linked.denotesSameBlock(as: clicked),
                      "A linked snippet must still be recognised as the block that was clicked")
        XCTAssertEqual([CodeSnippet(codeBlock: "python", content: "x\n"), linked]
            .firstIndex(where: { $0.denotesSameBlock(as: clicked) }), 1,
                       "Clicking the linked block resolved to the wrong snippet")
    }

    // MARK: - Line counting

    /// cmark's trailing "\n" used to inflate every count by one, so the renderer's
    /// "is this a card?" test and the viewer's `largeSnippets` filter disagreed at exactly
    /// the boundary: a 50-line block rendered a card the filter then excluded, and clicking
    /// it opened a DIFFERENT snippet with no way to reach the one you clicked.
    func testLineCountIgnoresTheTrailingNewline() {
        let body = (1...50).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(CodeSnippet.lineCount(codeBlockContent: body + "\n"), 50)
        XCTAssertEqual(CodeSnippet.lineCount(codeBlockContent: body), 50)
    }

    /// The threshold is `> 50`, and both askers must agree on which side of it a block sits.
    func testCardThresholdAgreesWithViewerFilter() {
        for lines in [50, 51] {
            let body = (1...lines).map { "line \($0)" }.joined(separator: "\n") + "\n"
            let renderer = CodeSnippet.isLarge(codeBlockContent: body)      // ContentBlockView
            let viewer = CodeSnippet(codeBlock: "swift", content: body).isLarge  // largeSnippets
            XCTAssertEqual(renderer, viewer, "\(lines) lines: renderer says \(renderer), viewer says \(viewer)")
            XCTAssertEqual(renderer, lines > ChatUIConstants.codeBlockLineLimit, "\(lines) lines misclassified")
        }
    }
}
