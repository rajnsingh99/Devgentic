// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  CodeSnippetExtractorTests.swift
//  DevgenticTests
//
//  Pins the 2026-07-16 extractor fix.
//
//  The old implementation hand-rolled a fence regex:
//      ```(?:(\w+)\n)?([\s\S]*?)```
//  `(\w+)` cannot match a non-word info string (`c++`, `objective-c`, `swift:Foo.swift`)
//  and the group is OPTIONAL — so instead of failing it silently skipped, and the info
//  string was swallowed into the CODE BODY. That corrupted what the viewer displayed
//  and what the user copied. It also required exactly `\n` after the language (so
//  "```swift " with a trailing space corrupted too), and couldn't see fences nested in
//  list items.
//
//  Snippets are now derived from the real CommonMark AST (`parseMarkdown`), which
//  already models language + our `--- Start of file ---` filename marker.
//

import XCTest
@testable import devgentic

final class CodeSnippetExtractorTests: XCTestCase {

    private func extract(_ md: String) -> [CodeSnippetExtractor.ExtractedInfo] {
        CodeSnippetExtractor.extract(from: md)
    }

    // MARK: - The corruption

    /// Info strings containing non-word characters must never leak into the code body.
    func testNonWordInfoStringsDoNotCorruptCode() {
        let cases = ["c++", "objective-c", "c#", "f#"]
        for info in cases {
            let snippets = extract("```\(info)\nint x = 1;\n```")
            XCTAssertEqual(snippets.count, 1, "\(info): expected one snippet")
            guard let s = snippets.first else { continue }
            XCTAssertEqual(s.code, "int x = 1;", "\(info): code body was corrupted with the info string")
            XCTAssertFalse(s.code.hasPrefix(info), "\(info): info string leaked into the code")
        }
    }

    /// A trailing space after the language used to defeat the `(\w+)\n` group and dump
    /// "swift " into the code.
    func testTrailingSpaceAfterLanguageDoesNotCorruptCode() {
        let snippets = extract("```swift \nlet x = 1\n```")
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.code, "let x = 1")
        XCTAssertFalse(snippets.first?.code.contains("swift") ?? true, "Language leaked into the code body")
    }

    /// Plain languages still resolve.
    func testPlainLanguageIsExtracted() {
        let snippets = extract("```swift\nlet x = 1\n```")
        XCTAssertEqual(snippets.first?.language, "swift")
        XCTAssertEqual(snippets.first?.code, "let x = 1")
    }

    /// A bare fence has no language — and must not invent one.
    func testBareFenceHasNoLanguage() {
        let snippets = extract("```\nplain text\n```")
        XCTAssertEqual(snippets.count, 1)
        XCTAssertNil(snippets.first?.language)
        XCTAssertEqual(snippets.first?.code, "plain text")
    }

    // MARK: - Coverage the regex never had

    /// LLMs constantly put fences inside numbered steps. The regex found them only by
    /// accident (and mangled the indentation); the AST models them properly.
    func testFenceNestedInListItemIsExtracted() {
        let md = """
        1. Install it:

           ```bash
           npm install
           ```
        """
        let snippets = extract(md)
        XCTAssertEqual(snippets.count, 1, "A fence inside a list item must be extractable")
        XCTAssertEqual(snippets.first?.language, "bash")
        XCTAssertEqual(snippets.first?.code, "npm install")
    }

    /// Multiple fences in one reply, in document order.
    func testMultipleFencesInOrder() {
        let md = """
        First:

        ```swift
        let a = 1
        ```

        Then:

        ```python
        b = 2
        ```
        """
        let snippets = extract(md)
        XCTAssertEqual(snippets.map(\.language), ["swift", "python"])
        XCTAssertEqual(snippets.map(\.code), ["let a = 1", "b = 2"])
    }

    /// The `--- Start of file: X ---` marker must still attach a filename (that's what
    /// links a snippet back to its uploaded source file for the diff/apply flow).
    func testFileMarkerAttachesFilename() {
        let md = "--- Start of file: main.swift ---\n\n```swift\nprint(1)\n```"
        let snippets = extract(md)
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.first?.potentialFileName, "main.swift")
    }

    /// Prose containing an inline triple-backtick span must not masquerade as a fence.
    func testEmptyAndProseOnlyInputYieldNothing() {
        XCTAssertTrue(extract("").isEmpty)
        XCTAssertTrue(extract("Just some prose with `inline code` in it.").isEmpty)
    }

    /// Whitespace-only fences carry no content and shouldn't reach the viewer.
    func testWhitespaceOnlyFenceIsSkipped() {
        XCTAssertTrue(extract("```swift\n   \n```").isEmpty)
    }
}
