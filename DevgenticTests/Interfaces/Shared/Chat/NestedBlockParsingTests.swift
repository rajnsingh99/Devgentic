// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NestedBlockParsingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftUI
@testable import devgentic

final class NestedBlockParsingTests: XCTestCase {

    // MARK: - Helpers

    private func items(_ blocks: [ContentBlock]) -> [(prefix: String, text: String, checkbox: ContentBlock.Checkbox?)] {
        blocks.compactMap { block in
            guard case .listItem(let prefix, let children, let checkbox) = block.type else { return nil }
            return (prefix, children.map(\.plainText).joined(separator: " "), checkbox)
        }
    }

    /// Short kind name for asserting the ORDER of a block sequence.
    private func kind(_ block: ContentBlock) -> String {
        switch block.type {
        case .paragraph:      return "paragraph"
        case .code:           return "code"
        case .heading:        return "heading"
        case .listItem:       return "listItem"
        case .blockquote:     return "blockquote"
        case .horizontalRule: return "hr"
        case .table:          return "table"
        case .image:          return "image"
        }
    }

    /// Direct children of a list item.
    private func children(of block: ContentBlock?) -> [ContentBlock] {
        guard let block, case .listItem(_, let kids, _) = block.type else { return [] }
        return kids
    }

    /// Mirrors ContentBlockView.createStyledString's parse step.
    private func onScreen(_ text: String) -> String {
        guard let attr = try? AttributedString(markdown: text) else { return text }
        return String(attr.characters)
    }

    // MARK: - The regression

    /// The exact corruption from the audit, on realistic LLM output.
    func testNestedListNoLongerRunsTogether() {
        let md = """
        1. **Install dependencies**
           - Run `npm install`
           - Verify with `npm -v`
        2. **Configure the app**
        """
        let top = parseMarkdown(md)
        XCTAssertEqual(items(top).map(\.prefix), ["1.", "2."], "Two top-level steps")

        // The nested bullets are CHILDREN of step 1, each its own block.
        let step1Kids = children(of: top.first)
        let nested = items(step1Kids)
        XCTAssertEqual(nested.count, 2, "Nested bullets must be separate child blocks")
        XCTAssertEqual(nested.map(\.text), ["Run `npm install`", "Verify with `npm -v`"])

        // The decisive assertion: the item's OWN paragraph must not have absorbed the
        // nested markdown (which is what produced "Install dependenciesRun npm install…").
        guard case .paragraph(let lead) = step1Kids.first?.type else {
            return XCTFail("Step 1 should lead with its own paragraph")
        }
        XCTAssertFalse(lead.contains("npm install"), "Parent text must not absorb nested content")
        XCTAssertFalse(onScreen(lead).contains("dependenciesRun"), "Must not render run-together")
    }

    /// Nesting depth is represented by actual block nesting (no `indentation` param —
    /// the renderer's marker+VStack indents children for free).
    func testNestingDepthIsRepresentedByBlockNesting() {
        let top = parseMarkdown("- top\n  - middle\n    - deep")
        XCTAssertEqual(items(top).count, 1, "One root item")

        let middle = items(children(of: top.first))
        XCTAssertEqual(middle.count, 1)
        XCTAssertTrue(middle[0].text.hasPrefix("middle"))

        let deep = items(children(of: children(of: top.first).first { if case .listItem = $0.type { return true }; return false }))
        XCTAssertEqual(deep.count, 1)
        XCTAssertEqual(deep[0].text, "deep")
    }

    /// REGRESSION (user-caught on-device): a fence written AFTER an item's sub-bullets
    /// rendered ABOVE them, because the parser partitioned children into
    /// own-content-then-nested-lists. Children must keep DOCUMENT ORDER.
    func testContentAfterNestedListKeepsDocumentOrder() {
        let md = """
        1. **Create and Navigate to the Project Directory**
            *   Use your terminal to create a folder.
            *   Change into this new folder:

            ```bash
            mkdir my-node-app
            cd my-node-app
            ```
        """
        let kids = children(of: parseMarkdown(md).first)
        XCTAssertEqual(kids.map(kind), ["paragraph", "listItem", "listItem", "code"],
                       "The code fence must stay AFTER the sub-bullets, as written")
    }

    /// A fenced code block inside a list item used to be flattened into the item's
    /// text (literal backticks, no code styling). It must now be a real code block.
    func testCodeFenceInsideListItemStaysACodeBlock() {
        let md = """
        - Run the installer:

          ```bash
          npm install
          ```
        """
        let codeBlocks = children(of: parseMarkdown(md).first)
            .filter { if case .code = $0.type { return true }; return false }
        XCTAssertEqual(codeBlocks.count, 1, "The fence must survive as a code block child")
        if case .code(let lang, let content, _) = codeBlocks[0].type {
            XCTAssertEqual(lang, "bash")
            XCTAssertTrue(content.contains("npm install"))
        }
    }

    /// Multi-paragraph list items kept their paragraphs jammed together.
    func testMultiParagraphListItemKeepsSeparateParagraphs() {
        let paragraphs = children(of: parseMarkdown("- para one\n\n  para two").first)
            .filter { if case .paragraph = $0.type { return true }; return false }
        XCTAssertEqual(paragraphs.count, 2, "Both paragraphs must survive as separate blocks")
    }

    // MARK: - Previously-dropped semantics

    /// Blockquotes fell to the `else` fallback and rendered as ordinary prose.
    func testBlockquoteIsItsOwnBlock() {
        let blocks = parseMarkdown("> Note: needs Node 18+.\n\nAfter.")
        guard case .blockquote(let children) = blocks.first?.type else {
            return XCTFail("Expected a blockquote block, got \(String(describing: blocks.first?.type))")
        }
        XCTAssertTrue(children.map(\.plainText).joined().contains("Node 18+"))
        // The following paragraph must not be swallowed into the quote.
        XCTAssertEqual(blocks.count, 2)
    }

    /// `- [x]` and `- [ ]` both rendered as a plain bullet — the state was discarded.
    func testTaskListCheckboxStateSurvives() {
        let parsed = items(parseMarkdown("- [ ] todo item\n- [x] done item"))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].checkbox, .unchecked)
        XCTAssertEqual(parsed[1].checkbox, .checked)
        XCTAssertEqual(parsed[0].text, "todo item")
        XCTAssertEqual(parsed[1].text, "done item")
    }

    /// Ordered lists must keep their real numbering (and honour `start`).
    func testOrderedListNumbering() {
        XCTAssertEqual(items(parseMarkdown("1. a\n2. b\n3. c")).map(\.prefix), ["1.", "2.", "3."])
        XCTAssertEqual(items(parseMarkdown("5. a\n6. b")).map(\.prefix), ["5.", "6."])
    }

    // MARK: - Unaffected behaviour (characterization)

    /// The non-container block types must be untouched by the refactor.
    func testSimpleBlockTypesUnchanged() {
        let blocks = parseMarkdown("# Title\n\nBody text.\n\n---\n\n```swift\nlet x = 1\n```")
        guard blocks.count == 4 else { return XCTFail("Expected 4 blocks, got \(blocks.count)") }

        if case .heading(let level, let text) = blocks[0].type {
            XCTAssertEqual(level, 1); XCTAssertEqual(text, "Title")
        } else { XCTFail("Expected heading") }

        if case .paragraph(let t) = blocks[1].type { XCTAssertEqual(t, "Body text.") } else { XCTFail("Expected paragraph") }

        if case .horizontalRule = blocks[2].type {} else { XCTFail("Expected horizontalRule") }

        if case .code(let lang, let content, _) = blocks[3].type {
            XCTAssertEqual(lang, "swift"); XCTAssertTrue(content.contains("let x = 1"))
        } else { XCTFail("Expected code") }
    }

    /// Top-level ids must stay "block-N" — the streaming parser stitches settled
    /// regions using positional identity, and its tests assert those exact ids.
    func testTopLevelBlockIDsRemainPositional() {
        let blocks = parseMarkdown("# T\n\n- one\n  - nested\n\nEnd.")
        XCTAssertEqual(blocks.map(\.id), ["block-0", "block-1", "block-2"])
    }

    /// The file-marker → filename badge must still work through the new builder.
    func testFileMarkerStillAttachesFilename() {
        let blocks = parseMarkdown("--- Start of file: main.swift ---\n\n```swift\nprint(1)\n```")
        guard let code = blocks.first(where: { if case .code = $0.type { return true }; return false }),
              case .code(_, _, let fileName) = code.type else {
            return XCTFail("Expected a code block")
        }
        XCTAssertEqual(fileName, "main.swift")
    }

    /// RAG chunking must still see list content (it feeds embeddings).
    func testChunkerStillSeesNestedListContent() {
        let chunks = SemanticChunker().chunk(blocks: parseMarkdown("- top\n  - nested one"))
        let joined = chunks.joined(separator: " ")
        XCTAssertTrue(joined.contains("top"), "Parent item must reach the embedding pipeline")
        XCTAssertTrue(joined.contains("nested one"), "Nested item must reach the embedding pipeline")
    }
}
