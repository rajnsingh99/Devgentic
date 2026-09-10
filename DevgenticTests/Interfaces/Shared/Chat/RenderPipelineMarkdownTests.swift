// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RenderPipelineMarkdownTests.swift
//  DevgenticTests
//
//  Parser-level cover for two render-pipeline defects (Chat_Production_Readiness_Fresh):
//
//   • CF-3 — `fromTrailingProse` claimed a filename from the last WORD of any short
//     paragraph or heading, so "…runs on Node.js:", "…built with ASP.NET:" and "…, e.g.:"
//     all became the code block's file badge, card title, viewer tab name and Save-As
//     default filename. A claim now needs the author's own markup — plus two corrections
//     the first pass at that gate got wrong: a LABEL inside the marked-up run
//     ("**File: src/Main.java**") must not defeat the claim, and markup alone must not
//     rescue a dotted identifier (`java.util.List`, **ASP.NET**) that is not a file.
//
//   • CF-4 — `<br>` produced no line break anywhere. In prose it was rewritten to "\n",
//     a CommonMark SOFT break that `AttributedString(markdown:)` renders as a SPACE;
//     `<br/>`, `<br />` and `<BR>` were not rewritten at all and reached the reader as
//     literal tag text; and table cells never passed through the rewrite, including
//     tables the app itself serialises through `TableMarkdown.escapeCell`.
//

import XCTest
@testable import devgentic

// MARK: - CF-3

final class FilenameClaimSignalTests: XCTestCase {

    /// The filename the first code block in `markdown` claims, or nil.
    private func claimedFileName(in markdown: String) -> String? {
        for block in parseMarkdown(markdown) {
            if case .code(_, _, let name) = block.type { return name }
        }
        return nil
    }

    private func fence(_ body: String = "let x = 1") -> String {
        """

        ```swift
        \(body)
        ```
        """
    }

    // MARK: The defect

    /// The register's first example. "Node.js" IS `stem.ext` shaped — only the absence of
    /// markup separates it from a real filename.
    func testProseEndingInAProductNameDoesNotClaim() {
        XCTAssertNil(claimedFileName(in: "This program runs on Node.js:\(fence())"),
                     "A sentence ending in Node.js must not title the block 'Node.js'")
    }

    func testProseEndingInADottedFrameworkDoesNotClaim() {
        XCTAssertNil(claimedFileName(in: "The service is built with ASP.NET:\(fence())"))
    }

    func testProseEndingInAnAbbreviationDoesNotClaim() {
        XCTAssertNil(claimedFileName(in: "Set any of the usual options, e.g.:\(fence())"),
                     "'e.g.:' used to clean down to the filename 'e.g'")
    }

    /// A heading that merely ENDS in a filename-shaped word is prose too.
    func testHeadingEndingInAProductNameDoesNotClaim() {
        XCTAssertNil(claimedFileName(in: "## Setting up Node.js\(fence())"))
    }

    // MARK: The signals that must survive

    func testInlineCodeAboveAFenceStillClaims() {
        XCTAssertEqual(claimedFileName(in: "`GameOfLifeSimulator.java`\(fence())"),
                       "GameOfLifeSimulator.java")
    }

    func testInlineCodeWithATrailingColonStillClaims() {
        XCTAssertEqual(claimedFileName(in: "Here is the updated `Main.swift`:\(fence())"), "Main.swift")
    }

    func testBoldFilenameClaims() {
        XCTAssertEqual(claimedFileName(in: "Updated **config.yaml**:\(fence())"), "config.yaml",
                       "A bold run is the other deliberate naming signal models emit")
    }

    /// A heading that IS the filename is its own signal — there is no surrounding sentence
    /// for the token to be a stray word of.
    func testHeadingThatIsWhollyAFilenameStillClaims() {
        XCTAssertEqual(claimedFileName(in: "### DijkstraSolver.java\(fence())"), "DijkstraSolver.java")
    }

    /// The markup has to be at the END: a marked-up mention mid-sentence is still a mention.
    func testMarkedUpMentionMidSentenceDoesNotClaim() {
        XCTAssertNil(claimedFileName(in: "I changed `Foo.java` and then reran the suite.\(fence())"))
    }

    // MARK: A LABEL inside the markup must not defeat the claim

    /// ⚠️ Regression guard. The markup gate handed the WHOLE `Strong` run to `filenameToken`,
    /// whose anchored `stem.ext` match cannot survive the spaces in a label — so these two
    /// shapes, which carry exactly the deliberate-naming markup the gate asks for, stopped
    /// naming their block and fell back to "Java Snippet" / a viewer tab titled "Java".
    /// Both claimed correctly before the CF-3 change.
    func testALabelledFilenameInsideABoldRunClaims() {
        XCTAssertEqual(claimedFileName(in: "**File: src/Main.java**\(fence())"), "src/Main.java")
        XCTAssertEqual(claimedFileName(in: "**Updated: config.yaml**\(fence())"), "config.yaml")
    }

    func testALabelledFilenameInsideACodeSpanClaims() {
        XCTAssertEqual(claimedFileName(in: "`File: app.py`\(fence())"), "app.py")
    }

    /// The label rule takes only a SINGLE token after the last colon, so a bolded SENTENCE
    /// cannot smuggle its last word through on the strength of a colon earlier in the run.
    func testABoldedSentenceDoesNotClaimOnItsColon() {
        XCTAssertNil(claimedFileName(in: "**Note: this program runs on Node.js**\(fence())"))
    }

    /// A heading carries no markup signal of its own, so the whole-heading escape hatch
    /// deliberately does NOT take the label fallback.
    func testAnUnmarkedLabelledHeadingDoesNotClaim() {
        XCTAssertNil(claimedFileName(in: "## Note: Node.js\(fence())"))
    }

    // MARK: Dotted identifiers are not filenames

    /// A backticked fully-qualified type is the single most common trailing token in code
    /// chat, and the backticks are ordinary code formatting — not a file claim. It used to
    /// become the badge, the viewer tab title and the Save-As default filename.
    ///
    /// The separable signal is case: a file extension is lowercase by convention, the last
    /// segment of an FQN is not. `os.path` and `Node.js` are NOT separable this way and still
    /// claim when marked up — see `plausibleFilenameToken`.
    /// The fixture premise the depth rule rests on: these ARE `stem.ext` shaped, so only their
    /// structure — three dots deep, Pascal-cased last segment — tells them from a filename.
    func testFullyQualifiedTypesAreStemExtShapedToBeginWith() {
        XCTAssertEqual(CodeFileNameInference.filenameToken("java.util.List"), "java.util.List")
    }

    /// ⚠️ `ASP.NET` is two segments, so the FQN rule deliberately does NOT reject it — see
    /// `plausibleFilenameToken`. The earlier rule that did (any uppercase extension initial)
    /// also rejected `script.R`, `README.MD`, `query.SQL` and `Makefile.PL`, and losing a real
    /// file's name costs exactly what a wrong one does. The UNMARKED prose form the row was
    /// actually filed about — "built with ASP.NET:" — is still refused, by the markup gate.
    func testUnmarkedDottedFrameworkNameDoesNotClaim() {
        XCTAssertNil(claimedFileName(in: "The service is built with ASP.NET:\(fence())"),
                     "The row's own example, in the shape it was filed: unmarked prose")
    }

    /// The FQN shape that IS separable: dotted three or more deep, ending in a Pascal-cased
    /// segment. That is a type name, never a filename.
    func testABacktickedFullyQualifiedTypeIsRejectedByDepth() {
        XCTAssertNil(claimedFileName(in: "A small example using `java.util.List`:\(fence())"))
        XCTAssertNil(claimedFileName(in: "Bind it to `com.example.Main`:\(fence())"))
        XCTAssertNil(claimedFileName(in: "Injected as `org.slf4j.Logger`:\(fence())"))
    }

    /// ⚠️ Regression guard for the rule above. These are all REAL extensions with an uppercase
    /// initial; a rule keyed on that alone silently un-named every one of them.
    func testRealFilenamesWithUppercaseExtensionsStillClaim() {
        for name in ["script.R", "README.MD", "query.SQL", "Makefile.PL", "analysis.Rmd"] {
            XCTAssertEqual(claimedFileName(in: "Here is `\(name)`:\(fence())"), name,
                           "\(name) is a real filename and must keep its badge")
        }
    }

    /// The control: a real filename with a lowercase extension is untouched by that rule.
    func testLowercaseExtensionsStillClaimFromProseAndHeadings() {
        XCTAssertEqual(claimedFileName(in: "Here is `webpack.config.js`:\(fence())"), "webpack.config.js",
                       "A dotted STEM is ordinary for real files")
        XCTAssertEqual(claimedFileName(in: "### Program.cs\(fence())"), "Program.cs")
    }

    // MARK: Token cleaning

    /// The trailing-dot rule: a `.` directly after a letter or digit belongs to an
    /// abbreviation and is NOT stripped, so no extension can be manufactured from it.
    func testAbbreviationTokensAreRejected() {
        XCTAssertNil(CodeFileNameInference.filenameToken("e.g.:"))
        XCTAssertNil(CodeFileNameInference.filenameToken("etc."))
        XCTAssertNil(CodeFileNameInference.filenameToken("Main.swift."),
                     "A filename never ends in a bare dot")
    }

    /// …while a dot after a bracket or backtick is ordinary prose punctuation and still goes.
    func testWrappedTokensStillClean() {
        XCTAssertEqual(CodeFileNameInference.filenameToken("src/Main.java)."), "src/Main.java")
        XCTAssertEqual(CodeFileNameInference.filenameToken("`Main.swift`:"), "Main.swift")
        XCTAssertEqual(CodeFileNameInference.filenameToken("`Main.swift`."), "Main.swift")
        XCTAssertEqual(CodeFileNameInference.filenameToken("**config.yaml**"), "config.yaml")
        XCTAssertEqual(CodeFileNameInference.filenameToken("README.md"), "README.md")
    }

    /// The info string and leading-comment ladders share `filenameToken` and must be
    /// untouched by the trailing-dot rule.
    func testInfoStringAndCommentLaddersAreUnaffected() {
        XCTAssertEqual(claimedFileName(in: "```java DijkstraSolver.java\nint x = 1;\n```"),
                       "DijkstraSolver.java")
        XCTAssertEqual(claimedFileName(in: "```java\n// DijkstraSolver.java\nint x = 1;\n```"),
                       "DijkstraSolver.java")
        XCTAssertEqual(claimedFileName(in: "```js:app.js\nconst x = 1;\n```"), "app.js")
    }
}

// MARK: - CF-4

final class HTMLLineBreakRewriteTests: XCTestCase {

    /// What a string carries after `AttributedString(markdown:)` — the exact transform the
    /// chat renderer applies before handing the text to `Text`.
    private func rendered(_ markdown: String) throws -> String {
        let attributed = try XCTUnwrap(try? AttributedString(markdown: markdown))
        return String(attributed.characters)
    }

    private func firstParagraph(in markdown: String) -> String? {
        for block in parseMarkdown(markdown) {
            if case .paragraph(let text) = block.type { return text }
        }
        return nil
    }

    /// The rewrite target is a HARD break — two spaces, then a newline. A bare "\n" is a
    /// soft break and renders as a space, which is the whole defect.
    func testEverySpellingBecomesTwoSpacesAndANewline() {
        XCTAssertEqual(rewritingHTMLLineBreaks("a<br>b<br/>c<br />d<BR>e<Br  />f"),
                       "a  \nb  \nc  \nd  \ne  \nf")
    }

    /// Foundation's own behaviour, pinned so the choice of "  \n" cannot silently rot.
    func testSoftBreakRendersAsASpaceButAHardBreakSurvives() throws {
        XCTAssertEqual(try rendered("a\nb"), "a b")
        XCTAssertEqual(try rendered("a  \nb"), "a\nb")
    }

    func testParagraphBreakSurvivesToTheRenderer() throws {
        let paragraph = try XCTUnwrap(firstParagraph(in: "line one<br>line two"))
        XCTAssertEqual(try rendered(paragraph), "line one\nline two",
                       "A <br> in prose must reach the reader as a line break, not a space")
    }

    func testSelfClosingAndUppercaseSpellingsNoLongerRenderLiterally() throws {
        for spelling in ["<br/>", "<br />", "<BR>"] {
            let paragraph = try XCTUnwrap(firstParagraph(in: "line one\(spelling)line two"))
            XCTAssertFalse(try rendered(paragraph).contains("<"),
                           "\(spelling) must not reach the reader as literal tag text")
            XCTAssertEqual(try rendered(paragraph), "line one\nline two")
        }
    }

    /// Table cells bypass `preprocessMarkdownText` entirely — `TableCellView` parses the
    /// cell string directly — so the rewrite has to happen where the cells are built.
    func testTableCellsCarryTheHardBreak() throws {
        let markdown = """
        | Step | Detail |
        | --- | --- |
        | one | first<br>second |
        """
        let table = parseMarkdown(markdown).first { if case .table = $0.type { return true }; return false }
        guard case .table(_, let rows, _)? = table?.type else {
            return XCTFail("Expected a table block")
        }
        XCTAssertEqual(rows.first?.last, "first  \nsecond")
        XCTAssertEqual(try rendered(try XCTUnwrap(rows.first?.last)), "first\nsecond")
    }

    /// The app's own serializer emits `<br>` for a multi-line cell, so a table Devgentic
    /// copies out has to survive being pasted back in.
    func testAppSerialisedMultiLineCellRoundTrips() throws {
        let markdown = TableMarkdown.serialize(headers: ["Note"], rows: [["one\ntwo"]], alignments: [])
        XCTAssertTrue(markdown.contains("one<br>two"), "escapeCell's contract")

        let table = parseMarkdown(markdown).first { if case .table = $0.type { return true }; return false }
        guard case .table(_, let rows, _)? = table?.type else {
            return XCTFail("Expected a table block")
        }
        XCTAssertEqual(try rendered(try XCTUnwrap(rows.first?.first)), "one\ntwo",
                       "The cell must come back with its line break, not with a literal <br>")
    }

    // MARK: - The rewrite must not eat CONTENT

    /// ⚠️ The rewrite is a blind regex over a string that is sometimes already-serialised
    /// markdown, so it once destroyed any `<br>` a user was DOCUMENTING rather than using:
    /// the backticks were consumed with the tag and "Use `<br/>`…" rendered as "Use     …".
    /// A code span is content; only prose carries markup to interpret.
    func testABreakTagInsideAnInlineCodeSpanSurvivesVerbatim() throws {
        XCTAssertEqual(rewritingHTMLLineBreaks("Use `<br/>` to force a line break."),
                       "Use `<br/>` to force a line break.")
        XCTAssertEqual(rewritingHTMLLineBreaks("The `<br>` tag"), "The `<br>` tag")
        XCTAssertEqual(try rendered(rewritingHTMLLineBreaks("The `<br>` tag")), "The <br> tag")
    }

    /// Same rule one level up: a fenced block is verbatim by definition.
    func testABreakTagInsideAFencedBlockSurvivesVerbatim() {
        let fence = "```\nplain <br> in fence\n```"
        XCTAssertEqual(rewritingHTMLLineBreaks(fence), fence)
    }

    /// The point of the rewrite still has to work, on both sides of a code span.
    func testProseBreaksStillRewriteAroundACodeSpan() throws {
        XCTAssertEqual(try rendered(rewritingHTMLLineBreaks("a `x` b<br>c")), "a x b\nc")
        XCTAssertEqual(try rendered(rewritingHTMLLineBreaks("one<BR />two")), "one\ntwo")
    }

    /// An unmatched backtick opens no span — CommonMark leaves it literal — so the tail is
    /// still prose and must not silently lose its breaks.
    func testAnUnmatchedBacktickDoesNotDisableTheRewriteForTheRest() {
        XCTAssertEqual(rewritingHTMLLineBreaks("unclosed `span <br> tail"),
                       "unclosed `span   \n tail")
    }
}
