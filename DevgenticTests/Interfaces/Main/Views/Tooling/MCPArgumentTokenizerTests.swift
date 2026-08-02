//
//  MCPArgumentTokenizerTests.swift
//  DevgenticTests
//
//  P1 #16 — arguments used to be whitespace-split with no quoting, and the JSON pane
//  joined them back with a plain " ". Any argument containing a space was therefore
//  corrupted, and a paste→save round-trip silently rewrote a config the user never edited.
//
//  The round-trip property `tokenize(join(x)) == x` is the real contract here.
//

import XCTest
@testable import devgentic

final class MCPArgumentTokenizerTests: XCTestCase {

    // MARK: - Tokenize

    func testTokenize_PlainArguments_SplitsOnWhitespace() {
        XCTAssertEqual(
            MCPArgumentTokenizer.tokenize("-y @modelcontextprotocol/server-filesystem /tmp"),
            ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        )
    }

    func testTokenize_CollapsesRunsOfWhitespace() {
        XCTAssertEqual(MCPArgumentTokenizer.tokenize("  a   b\t\tc \n"), ["a", "b", "c"])
    }

    func testTokenize_EmptyInput_YieldsNoArguments() {
        XCTAssertEqual(MCPArgumentTokenizer.tokenize(""), [])
        XCTAssertEqual(MCPArgumentTokenizer.tokenize("    "), [])
    }

    /// The headline bug: a path with a space became two argv entries.
    func testTokenize_DoubleQuotedPathWithSpace_StaysOneArgument() {
        XCTAssertEqual(
            MCPArgumentTokenizer.tokenize("--root \"/Users/alice/My Documents/data\""),
            ["--root", "/Users/alice/My Documents/data"]
        )
    }

    func testTokenize_SingleQuotedPathWithSpace_StaysOneArgument() {
        XCTAssertEqual(
            MCPArgumentTokenizer.tokenize("--root '/Users/alice/My Documents/data'"),
            ["--root", "/Users/alice/My Documents/data"]
        )
    }

    func testTokenize_EscapedSpace_StaysOneArgument() {
        XCTAssertEqual(
            MCPArgumentTokenizer.tokenize("/Users/alice/My\\ Documents"),
            ["/Users/alice/My Documents"]
        )
    }

    func testTokenize_QuoteAdjacentToText_JoinsIntoOneArgument() {
        XCTAssertEqual(MCPArgumentTokenizer.tokenize("--path=\"a b\""), ["--path=a b"])
    }

    func testTokenize_SingleQuotesArePreservedLiterally() {
        // Inside single quotes a backslash is NOT an escape.
        XCTAssertEqual(MCPArgumentTokenizer.tokenize("'a\\b'"), ["a\\b"])
    }

    func testTokenize_QuotedEmptyString_IsARealArgument() {
        XCTAssertEqual(MCPArgumentTokenizer.tokenize("--flag \"\""), ["--flag", ""])
    }

    /// A user mid-edit must never lose typed characters.
    func testTokenize_UnterminatedQuote_KeepsContent() {
        XCTAssertEqual(MCPArgumentTokenizer.tokenize("--root \"/tmp/unfinished"), ["--root", "/tmp/unfinished"])
    }

    func testTokenize_TrailingBackslash_IsLiteral() {
        XCTAssertEqual(MCPArgumentTokenizer.tokenize("abc\\"), ["abc\\"])
    }

    /// Not a shell: no variable expansion, no globbing. `ShellProcess` execs argv with no
    /// shell, and expanding here would reintroduce the injection surface that removes.
    func testTokenize_DoesNotExpandVariablesOrGlobs() {
        XCTAssertEqual(MCPArgumentTokenizer.tokenize("$HOME *.txt `whoami`"), ["$HOME", "*.txt", "`whoami`"])
    }

    // MARK: - Join

    func testJoin_PlainArguments_NoQuoting() {
        XCTAssertEqual(MCPArgumentTokenizer.join(["-y", "server", "/tmp"]), "-y server /tmp")
    }

    func testJoin_ArgumentWithSpace_IsQuoted() {
        XCTAssertEqual(
            MCPArgumentTokenizer.join(["--root", "/Users/alice/My Documents"]),
            "--root \"/Users/alice/My Documents\""
        )
    }

    func testJoin_EmptyArgument_IsQuoted() {
        XCTAssertEqual(MCPArgumentTokenizer.join(["--flag", ""]), "--flag \"\"")
    }

    func testJoin_EmptyArray_YieldsEmptyString() {
        XCTAssertEqual(MCPArgumentTokenizer.join([]), "")
    }

    // MARK: - Round-trip (the actual contract)

    func testRoundTrip_PreservesEveryArgumentExactly() {
        let cases: [[String]] = [
            [],
            ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            ["--root", "/Users/alice/My Documents/data"],
            ["--flag", ""],
            ["a b", "c  d", " leading", "trailing "],
            ["quote\"inside"],
            ["single'quote"],
            ["back\\slash"],
            ["$HOME", "*.txt", "`whoami`", "a;b|c&d"],
            ["--json", "{\"key\": \"value with space\"}"],
        ]

        for original in cases {
            let round = MCPArgumentTokenizer.tokenize(MCPArgumentTokenizer.join(original))
            XCTAssertEqual(round, original, "Round-trip must be lossless for \(original)")
        }
    }

    /// The specific corruption path: paste JSON → form → save must not rewrite argv.
    func testRoundTrip_PastedConfigWithSpacedPath_SurvivesSaveCycle() {
        let fromPastedJSON = ["-y", "server-filesystem", "/Users/alice/My Documents"]

        // JSON pane renders args into the single-line field...
        let formField = MCPArgumentTokenizer.join(fromPastedJSON)
        // ...and saving tokenizes the field back into argv.
        let saved = MCPArgumentTokenizer.tokenize(formField)

        XCTAssertEqual(saved, fromPastedJSON)
        XCTAssertEqual(saved.count, 3, "The spaced path must not have been split into two argv entries")
    }
}
