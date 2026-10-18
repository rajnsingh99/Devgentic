// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InlineImageSplitTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class InlineImageSplitTests: XCTestCase {

    private enum Shape: Equatable {
        case paragraph(String)
        case image(url: String, alt: String?)
        case other
    }

    private func shapes(_ blocks: [ContentBlock]) -> [Shape] {
        blocks.map { block in
            switch block.type {
            case .paragraph(let text): return .paragraph(text)
            case .image(let url, let alt): return .image(url: url, alt: alt)
            default: return .other
            }
        }
    }

    /// THE pin — the shape the register's reviewer called out: prose, ONE newline, image.
    func testProseThenImageOnTheNextLineRendersBoth() {
        let blocks = parseMarkdown("Here is the chart:\n![chart](/tmp/dg/hist.png)")

        XCTAssertEqual(shapes(blocks), [
            .paragraph("Here is the chart:"),
            .image(url: "/tmp/dg/hist.png", alt: "chart")
        ])
    }

    /// The finder's original shape: prose, image and more prose on one line.
    func testImageInsideASentenceSplitsIntoThreeBlocksInOrder() {
        let blocks = parseMarkdown("Here is the distribution: ![histogram](/tmp/dg/hist.png) as requested.")

        XCTAssertEqual(shapes(blocks), [
            .paragraph("Here is the distribution:"),
            .image(url: "/tmp/dg/hist.png", alt: "histogram"),
            .paragraph("as requested.")
        ])
    }

    /// Two images on one line lost BOTH. No empty paragraph is emitted for the space between.
    func testTwoImagesOnOneLineBothRender() {
        let blocks = parseMarkdown("![a](/tmp/a.png) ![b](/tmp/b.png)")

        XCTAssertEqual(shapes(blocks), [
            .image(url: "/tmp/a.png", alt: "a"),
            .image(url: "/tmp/b.png", alt: "b")
        ])
    }

    /// Two images on consecutive lines are one paragraph joined by a soft break — which must
    /// not become a blank paragraph between them.
    func testImagesOnConsecutiveLinesEmitNoBlankParagraph() {
        let blocks = parseMarkdown("![a](/tmp/a.png)\n![b](/tmp/b.png)")

        XCTAssertEqual(shapes(blocks), [
            .image(url: "/tmp/a.png", alt: "a"),
            .image(url: "/tmp/b.png", alt: "b")
        ])
    }

    /// The single-child shape the old branch accepted still works, unchanged.
    func testStandaloneImageIsUnchanged() {
        XCTAssertEqual(shapes(parseMarkdown("![solo](https://e.com/y.png)")),
                       [.image(url: "https://e.com/y.png", alt: "solo")])
    }

    /// Inline markup in the text runs survives — the runs go through `format()`, not `plainText`.
    func testTextRunsKeepTheirMarkup() {
        let blocks = parseMarkdown("See **bold** and `code` ![i](/tmp/i.png)")

        XCTAssertEqual(shapes(blocks), [
            .paragraph("See **bold** and `code`"),
            .image(url: "/tmp/i.png", alt: "i")
        ])
    }

    /// Top-level block ids stay `block-N` in emission order — the streaming parser's settled-
    /// region stitching depends on that.
    func testSplitBlocksKeepSequentialTopLevelIDs() {
        let blocks = parseMarkdown("Intro\n\nHere: ![i](/tmp/i.png) done")

        XCTAssertEqual(blocks.map(\.id), ["block-0", "block-1", "block-2", "block-3"])
    }

    /// The paragraph branch is shared with list items, so an image inside one splits too.
    func testImageInsideAListItemSplits() {
        let blocks = parseMarkdown("- Result: ![plot](/tmp/p.png)")

        guard case .listItem(_, let children, _) = blocks.first?.type else {
            return XCTFail("expected a list item, got \(blocks.map(\.type))")
        }
        XCTAssertEqual(shapes(children), [
            .paragraph("Result:"),
            .image(url: "/tmp/p.png", alt: "plot")
        ])
    }

    /// A paragraph with no image never enters the split path — its text is byte-identical to
    /// the old branch's output.
    func testParagraphWithoutImagesIsUntouched() {
        XCTAssertEqual(shapes(parseMarkdown("Just **prose**, no picture.")),
                       [.paragraph("Just **prose**, no picture.")])
    }

    // MARK: - Cold-read findings on the first cut

    /// THE cold-read P2: a run is formatted as ONE paragraph, so the soft break between two
    /// lines of prose survives as `\n` (which the renderer turns into a space). The first cut
    /// formatted node by node, and a lone `SoftBreak.format()` is "" — "png.Here" fused.
    func testMultiLineProseBeforeAnImageKeepsItsLineBreaks() {
        let blocks = parseMarkdown("The results are in.\nTwo peaks are visible.\n![chart](/tmp/dg/hist.png)")

        XCTAssertEqual(shapes(blocks), [
            .paragraph("The results are in.\nTwo peaks are visible."),
            .image(url: "/tmp/dg/hist.png", alt: "chart")
        ])
    }

    /// Same for a caption AFTER the image, and for a hard break (two trailing spaces), which
    /// must keep its `"  \n"` form — the one break `AttributedString(markdown:)` honours.
    func testCaptionAfterAnImageKeepsSoftAndHardBreaks() {
        let soft = parseMarkdown("![c](/tmp/c.png)\nThe chart shows X.\nNote that Y.")
        XCTAssertEqual(shapes(soft), [
            .image(url: "/tmp/c.png", alt: "c"),
            .paragraph("The chart shows X.\nNote that Y.")
        ])

        let hard = parseMarkdown("first line  \nsecond line ![i](/tmp/i.png)")
        XCTAssertEqual(shapes(hard), [
            .paragraph("first line  \nsecond line"),
            .image(url: "/tmp/i.png", alt: "i")
        ])
    }

    /// A run that follows an image was inline in the source; trimmed and parsed alone it would
    /// become a list item or heading whose marker the renderer eats. The marker is escaped, and
    /// the renderer's own parser confirms the escape reads back as the literal characters.
    func testLeadingBlockSyntaxAfterAnImageIsEscapedNotEaten() throws {
        let cases: [(source: String, expected: String, rendered: String)] = [
            ("![a](/tmp/a.png) - caption", "\\- caption", "- caption"),
            ("![a](/tmp/a.png) 1. Open Settings", "1\\. Open Settings", "1. Open Settings"),
            ("![a](/tmp/a.png) # note", "\\# note", "# note"),
            ("![a](/tmp/a.png) > quoted", "\\> quoted", "> quoted"),
        ]
        for c in cases {
            let blocks = parseMarkdown(c.source)
            guard case .paragraph(let text)? = blocks.last?.type else {
                return XCTFail("no trailing paragraph for \(c.source): \(blocks.map(\.type))")
            }
            XCTAssertEqual(text, c.expected, c.source)
            let rendered = try AttributedString(markdown: text)
            XCTAssertEqual(String(rendered.characters), c.rendered, "the escape must read back as the author's characters")
        }
        // Prose that merely STARTS with one of those characters, not as a marker, is untouched.
        XCTAssertEqual(shapes(parseMarkdown("![a](/tmp/a.png) *emphasis* here")).last, .paragraph("*emphasis* here"))
        XCTAssertEqual(shapes(parseMarkdown("![a](/tmp/a.png) #hashtag")).last, .paragraph("#hashtag"))
    }

    /// A file-marker paragraph that also carries an image: the marker is CONSUMED (claim
    /// applied to the next fence, sentinel never rendered) and the image still renders.
    func testMarkerParagraphWithAnImageKeepsTheClaimAndHidesTheSentinel() {
        let blocks = parseMarkdown("--- Start of file: README.md ---\n![logo](/tmp/logo.png)\n\n```\nint x;\n```")

        XCTAssertFalse(blocks.contains { block in
            if case .paragraph(let t) = block.type { return t.contains("Start of file") }
            return false
        }, "the sentinel must not render as prose: \(blocks.map(\.type))")
        XCTAssertTrue(shapes(blocks).contains(.image(url: "/tmp/logo.png", alt: "logo")))
        let fence = blocks.compactMap { block -> String?? in
            if case .code(_, _, let name) = block.type { return .some(name) }
            return nil
        }.first
        XCTAssertEqual(fence, .some("README.md"), "the marker's filename claim must still reach the fence")
    }

    /// `[![alt](src)](href)` and `*![alt](src)*` — a wrapper whose only content is an image —
    /// render the image instead of collapsing to alt text (the link target is logged, not kept).
    func testImageWrappedInALinkOrEmphasisStillRenders() {
        XCTAssertEqual(shapes(parseMarkdown("Click to enlarge: [![chart](/tmp/dg/hist.png)](https://ci.example)")), [
            .paragraph("Click to enlarge:"),
            .image(url: "/tmp/dg/hist.png", alt: "chart")
        ])
        XCTAssertEqual(shapes(parseMarkdown("*![Figure 1](/tmp/fig1.png)*")),
                       [.image(url: "/tmp/fig1.png", alt: "Figure 1")])
        // A wrapper with anything else in it is prose and stays prose.
        XCTAssertEqual(shapes(parseMarkdown("[see ![i](/tmp/i.png) here](https://x)")),
                       [.paragraph("[see ![i](/tmp/i.png) here](https://x)")])
    }
}

/// The RAG chunker used to skip `.image` — harmless while an inline image's `![alt](path)`
/// still sat inside its paragraph's text, and a silent loss once the parser split it out.
final class InlineImageIndexingTests: XCTestCase {

    func testInlineImagePathAndAltTextStayInTheIndex() {
        let chunks = SemanticChunker().chunk(blocks: parseMarkdown("Here is the distribution: ![histogram](/tmp/dg/hist.png)"))

        XCTAssertTrue(chunks.contains { $0.contains("/tmp/dg/hist.png") && $0.contains("histogram") },
                      "asking 'where did you save the histogram?' must still retrieve this: \(chunks)")
        XCTAssertTrue(chunks.contains { $0.contains("Here is the distribution:") })
    }

    func testAnImageWithNeitherAltNorURLAddsNoChunk() {
        let chunks = SemanticChunker().chunk(blocks: [ContentBlock(id: "block-0", type: .image(url: "", altText: nil))])
        XCTAssertTrue(chunks.isEmpty)
    }
}
