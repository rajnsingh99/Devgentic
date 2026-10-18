// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FenceFilenameLanguageTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class FenceFilenameLanguageTests: XCTestCase {

    private func firstCodeBlock(in markdown: String) -> (language: String, fileName: String?)? {
        for block in parseMarkdown(markdown) {
            if case .code(let language, _, let fileName) = block.type { return (language, fileName) }
        }
        return nil
    }

    /// THE pin: the filename is claimed AND the language is the extension's grammar.
    func testBareFilenameFenceDerivesTheLanguageFromTheExtension() {
        let block = firstCodeBlock(in: "```DijkstraSolver.java\nint x = 1;\n```")

        XCTAssertEqual(block?.fileName, "DijkstraSolver.java")
        XCTAssertEqual(block?.language, "java",
                       "the language badge must not print the filename a second time, and hljs must be handed a grammar it knows")
    }

    func testBareFilenameFenceMapsCommonExtensions() {
        XCTAssertEqual(firstCodeBlock(in: "```script.py\nx = 1\n```")?.language, "python")
        XCTAssertEqual(firstCodeBlock(in: "```app.ts\nconst x = 1\n```")?.language, "typescript")
        XCTAssertEqual(firstCodeBlock(in: "```src/Main.swift\nlet x = 1\n```")?.language, "swift")
        XCTAssertEqual(firstCodeBlock(in: "```src/Main.swift\nlet x = 1\n```")?.fileName, "src/Main.swift")
    }

    /// The unit the parser delegates to, pinned directly so the mapping and the claim are one
    /// decision: same input, both halves.
    func testInfoStringSplitReturnsBothHalves() {
        let split = CodeFileNameInference.languageAndFileName(fromInfoString: "Solver.rs")
        XCTAssertEqual(split.fileName, "Solver.rs")
        XCTAssertEqual(split.language, "rust")
    }

    /// The other two conventions are untouched — they already set the language correctly.
    func testColonAndSecondTokenFormsAreUnchanged() {
        let colon = firstCodeBlock(in: "```js:app.js\nconst x = 1;\n```")
        XCTAssertEqual(colon?.language, "js")
        XCTAssertEqual(colon?.fileName, "app.js")

        let second = firstCodeBlock(in: "```java DijkstraSolver.java\nint x = 1;\n```")
        XCTAssertEqual(second?.language, "java")
        XCTAssertEqual(second?.fileName, "DijkstraSolver.java")
    }

    /// An UNKNOWN extension yields the bare extension (`languageHint`'s best-effort contract) —
    /// never the whole filename again. Pinned generically: the language is never the filename.
    func testUnknownExtensionYieldsTheExtensionNeverTheFilename() {
        let block = firstCodeBlock(in: "```Solver.cbl\nIDENTIFICATION DIVISION.\n```")
        XCTAssertEqual(block?.fileName, "Solver.cbl")
        XCTAssertEqual(block?.language, "cbl")
        XCTAssertNotEqual(block?.language, block?.fileName)
    }

    /// A plain language token with no extension is not a filename — nothing changes for it.
    func testPlainLanguageTokenIsNotTouched() {
        let block = firstCodeBlock(in: "```c++\nint x = 1;\n```")
        XCTAssertNil(block?.fileName)
        XCTAssertEqual(block?.language, "c++")
    }
}
