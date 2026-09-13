// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AuthoredFileLinkTests.swift
//  DevgenticTests
//
//  CR18 — a model-authored markdown link could open ANY file on disk.
//
//  The file-reference feature verifies which inline CODE SPANS become links: a span is matched
//  against the conversation's own file index, `stat`ed, and only then is a `devgentic-file://`
//  URL minted for it. None of that constrains a link the AUTHOR wrote. A reply containing
//  `[click here](devgentic-file://open?path=/Users/you/.ssh/id_rsa)` parses to a run carrying
//  that URL verbatim, and the tap handler used to accept it because the SCHEME matched.
//

import XCTest
@testable import devgentic

final class AuthoredFileLinkTests: XCTestCase {

    // MARK: - The premise: an authored link really does reach the handler

    /// ⚠️ PROBED, not assumed. If Foundation ever stops preserving a custom scheme through the
    /// markdown parse, this whole attack surface closes and this test says so.
    func testFoundationPreservesOurSchemeInAnAuthoredLink() throws {
        let parsed = try AttributedString(
            markdown: "Click [here](devgentic-file://open?path=/etc/passwd) to continue.")

        let linked = try XCTUnwrap(parsed.runs.first { $0.link != nil },
                                   "an authored link must survive the parse for this to matter")
        XCTAssertEqual(linked.link?.scheme, FileReferenceResolver.scheme)
    }

    /// The URL parser answers "is this OUR SHAPE", and nothing more. It must keep returning the
    /// path for an authored link — the refusal belongs at the consumer, which knows what was
    /// verified. Pinning this stops a future fix from being put in the wrong place.
    func testTheURLParserIsNotAnAuthorisationCheck() throws {
        let authored = try XCTUnwrap(URL(string: "devgentic-file://open?path=/etc/passwd"))

        XCTAssertEqual(FileReferenceResolver.path(fromLinkURL: authored), "/etc/passwd",
                       "the parser reports the shape; it cannot know what was verified")
    }

    func testAForeignSchemeIsNotOurs() throws {
        for raw in ["https://example.com/x", "file:///etc/passwd", "devgentic-file://other?path=/x"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(FileReferenceResolver.path(fromLinkURL: url), raw)
        }
    }

    // MARK: - The gate

    /// THE pin: a path this block never verified is refused, however well-formed the URL is.
    func testAnAuthoredPathIsRefused() {
        let verified = ["/work/src/Main.java"]

        for authored in ["/etc/passwd", "/Users/someone/.ssh/id_rsa", "/work/src/Main.java.bak"] {
            XCTAssertFalse(ContentBlockView.isVerifiedForThisBlock(authored, verifiedPaths: verified),
                           "\(authored) was never verified for this block")
        }
    }

    /// …and the feature still works: a path the block DID verify opens.
    func testAVerifiedPathIsAllowed() {
        XCTAssertTrue(ContentBlockView.isVerifiedForThisBlock(
            "/work/src/Main.java", verifiedPaths: ["/work/src/Main.java", "/work/notes.md"]))
    }

    /// A block with nothing verified can open nothing — the state every block is in until its
    /// off-main verification lands.
    func testNothingVerifiedOpensNothing() {
        XCTAssertFalse(ContentBlockView.isVerifiedForThisBlock("/work/src/Main.java",
                                                               verifiedPaths: [String]()))
    }

    /// ⚠️ Exact match, not a prefix or a containment test: `/work/src` must not authorise
    /// `/work/src/../../etc/passwd`, and a verified path must not authorise its neighbours.
    func testTheMatchIsExactRatherThanAPrefix() {
        let verified = ["/work/src/Main.java"]

        for near in ["/work/src", "/work/src/Main.java/../../../etc/passwd",
                     "/work/src/Main.javaX", "work/src/Main.java"] {
            XCTAssertFalse(ContentBlockView.isVerifiedForThisBlock(near, verifiedPaths: verified), near)
        }
    }

    // MARK: - Round trip

    /// What the app itself mints must survive the round trip and pass its own gate — otherwise
    /// the fix would silently disable the feature it is protecting.
    func testAMintedLinkRoundTripsAndPassesTheGate() throws {
        for path in ["/work/src/Main.java",
                     "/work/My Documents/notes file.md",
                     "/work/ünïcode/Ω.swift",
                     "/work/a#b?c/d.txt"] {
            let url = try XCTUnwrap(FileReferenceResolver.linkURL(forVerifiedPath: path), path)
            let parsed = try XCTUnwrap(FileReferenceResolver.path(fromLinkURL: url), path)

            XCTAssertEqual(parsed, path, "round trip must be lossless for \(path)")
            XCTAssertTrue(ContentBlockView.isVerifiedForThisBlock(parsed, verifiedPaths: [path]), path)
        }
    }
}

// MARK: - CR16 / CR17: markdown that silently lost characters

/// Two findings from the same family — a transform that rewrites a payload by shape and joins or
/// drops text the author separated. Both were verified by probing the renderer, not by reading.
final class MarkdownCharacterLossTests: XCTestCase {

    /// What `ContentBlockView` will make of a block's text. The renderer's own call.
    private func rendered(_ markdown: String) -> String {
        (try? AttributedString(markdown: markdown)).map { String($0.characters) } ?? "<parse failed>"
    }

    private func headingText(in markdown: String) -> String? {
        for block in parseMarkdown(markdown) {
            if case .heading(_, let text) = block.type { return text }
        }
        return nil
    }

    private func paragraphText(in markdown: String) -> String? {
        for block in parseMarkdown(markdown) {
            if case .paragraph(let text) = block.type { return text }
        }
        return nil
    }

    // MARK: CR16 — consecutive <br> fused the words either side

    /// ⚠️ THE pin. Each `<br>` became `"  \n"` independently, so two in a row made `"  \n  \n"` —
    /// a PARAGRAPH break, which this renderer draws as NOTHING.
    func testConsecutiveBreaksDoNotFuseTheWordsEitherSide() throws {
        let text = try XCTUnwrap(paragraphText(in: "alpha<br><br>bravo"))

        XCTAssertEqual(rendered(text), "alpha\nbravo", "rendered as 'alphabravo' before the fix")
    }

    /// The commoner shape, which the finding did not mention: ONE tag at end of line already
    /// supplies the newline that makes the pair a paragraph.
    func testABreakAtEndOfLineDoesNotFuseWithTheNextLine() throws {
        let text = try XCTUnwrap(paragraphText(in: "line one<br>\nline two"))

        XCTAssertEqual(rendered(text), "line one\nline two", "rendered as 'line oneline two' before the fix")
    }

    /// Every spelling and separator a model actually emits.
    func testEverySpellingOfARunCollapsesToOneBreak() throws {
        for source in ["a<br><br>b", "a<br/><br/>b", "a<br> <br>b", "a<BR><Br />b",
                       "a<br>\n<br>b", "a<br><br><br>b"] {
            let text = try XCTUnwrap(paragraphText(in: source), source)
            XCTAssertEqual(rendered(text), "a\nb", source)
        }
    }

    /// ⚠️ REGRESSION GUARD. The first cut of this fix consumed trailing whitespace whether or not
    /// a newline followed, so `"a<br> b"` lost the author's space. A fix for content loss must not
    /// lose content — horizontal whitespace is only consumed as part of a newline.
    func testTheAuthorsOwnSpacingAfterABreakIsPreserved() throws {
        XCTAssertEqual(rewritingHTMLLineBreaks("a<br> b"), "a  \n b")
        XCTAssertEqual(rewritingHTMLLineBreaks("a<br>   b"), "a  \n   b")
        XCTAssertEqual(rewritingHTMLLineBreaks("unclosed `span <br> tail"), "unclosed `span   \n tail")
    }

    /// A lone break is unchanged, and so is text with no break at all.
    func testASingleBreakAndPlainTextAreUnchanged() throws {
        XCTAssertEqual(rendered(try XCTUnwrap(paragraphText(in: "a<br>b"))), "a\nb")
        XCTAssertEqual(rendered(try XCTUnwrap(paragraphText(in: "a<br>b<br>c"))), "a\nb\nc")
        XCTAssertEqual(rendered(try XCTUnwrap(paragraphText(in: "no breaks here"))), "no breaks here")
    }

    // MARK: CR17 — a heading starting with a block marker lost it

    /// ⚠️ THE pin. cmark has already eaten the `##`, so the heading's TEXT is re-parsed on its
    /// own — and text beginning with another block marker is read as that block, marker gone.
    /// Numbering a section is ordinary, so this silently dropped the number.
    func testANumberedHeadingKeepsItsNumber() throws {
        let text = try XCTUnwrap(headingText(in: "## 1. Setup"))

        XCTAssertEqual(rendered(text), "1. Setup", "rendered as 'Setup' before the fix")
    }

    func testEveryLeadingBlockMarkerSurvivesInAHeading() throws {
        let cases = [("## 1. Setup", "1. Setup"), ("## 2) Install", "2) Install"),
                     ("## - Prerequisites", "- Prerequisites"), ("## * Bullet", "* Bullet"),
                     ("## + Plus", "+ Plus"), ("## > Note", "> Note")]
        for (source, expected) in cases {
            let text = try XCTUnwrap(headingText(in: source), source)
            XCTAssertEqual(rendered(text), expected, source)
        }
    }

    /// ⚠️ Only a LEADING marker followed by whitespace is escaped. A version number and a hashtag
    /// are not markers and must not grow a backslash.
    func testTextThatMerelyLooksLikeAMarkerIsUntouched() throws {
        for (source, expected) in [("## 1.5 release", "1.5 release"), ("## #hashtag", "#hashtag"),
                                   ("## Setup", "Setup"), ("## -dash-case", "-dash-case")] {
            let text = try XCTUnwrap(headingText(in: source), source)
            XCTAssertEqual(text, expected, "no escape should have been added to \(source)")
            XCTAssertEqual(rendered(text), expected, source)
        }
    }

    /// Inline markup inside a heading still renders as markup — the escape must not disarm it.
    func testInlineMarkupInAHeadingStillRenders() throws {
        let text = try XCTUnwrap(headingText(in: "## **Bold** and `code`"))
        XCTAssertEqual(rendered(text), "Bold and code")
    }
}

// MARK: - CR19: the snapshot looked at a different file from the writer

/// `fileTargetPath` decides which file the pre/post-write snapshot reads. It used to expand `~`
/// and stop, leaving a RELATIVE path relative — and `FileManager` resolves those against the
/// process working directory, which for a GUI-launched app is `/`. The tools that actually write
/// the file resolve through `FilePathResolver`, which anchors a relative path to HOME. So for a
/// bare `notes.md` the snapshot read `/notes.md` and the write went to `<home>/notes.md`.
final class SnapshotPathResolutionTests: XCTestCase {

    private func args(_ pairs: [String: String]) -> [String: JSONValue] {
        pairs.mapValues { JSONValue.string($0) }
    }

    /// ⚠️ THE pin: the snapshot and the writer must name the SAME file. Asserted against
    /// `FilePathResolver` itself rather than against a hard-coded home path, so the two cannot
    /// drift apart again without this failing.
    func testARelativePathResolvesTheSameWayTheWriterResolvesIt() throws {
        for relative in ["notes.md", "project/index.html", "a/b/c.txt"] {
            let resolved = try XCTUnwrap(fileTargetPath(in: args(["path": relative])), relative)

            XCTAssertEqual(resolved, FilePathResolver.resolve(relative),
                           "the snapshot must look where the write tool writes")
            XCTAssertTrue(resolved.hasPrefix("/"), "and it must be absolute: \(resolved)")
            XCTAssertFalse(resolved.hasPrefix("//"), resolved)
        }
    }

    /// The failure this caused, stated as the property that prevents it: a relative path must
    /// NOT resolve to the volume root, which is where the old expansion left it.
    func testARelativePathNoLongerAnchorsToTheVolumeRoot() throws {
        let resolved = try XCTUnwrap(fileTargetPath(in: args(["path": "notes.md"])))

        XCTAssertNotEqual(resolved, "/notes.md",
                          "anchoring to the read-only volume root is what made the baseline empty")
        XCTAssertEqual(resolved, (NSHomeDirectory() as NSString).appendingPathComponent("notes.md"))
    }

    /// Absolute and tilde paths keep working exactly as before.
    func testAbsoluteAndTildePathsAreUnchanged() throws {
        XCTAssertEqual(fileTargetPath(in: args(["path": "/tmp/x.txt"])), "/tmp/x.txt")
        XCTAssertEqual(fileTargetPath(in: args(["path": "~/Desktop/x.txt"])),
                       (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/x.txt"))
    }

    /// Both argument spellings are honoured — native tools take `path`, split tools `file_path`.
    func testBothArgumentSpellingsResolve() throws {
        XCTAssertEqual(fileTargetPath(in: args(["file_path": "notes.md"])),
                       FilePathResolver.resolve("notes.md"))
        // `path` wins when a call somehow carries both, which is the pre-existing precedence.
        XCTAssertEqual(fileTargetPath(in: args(["path": "/a.txt", "file_path": "/b.txt"])), "/a.txt")
    }

    func testNoPathArgumentYieldsNil() {
        XCTAssertNil(fileTargetPath(in: args([:])))
        XCTAssertNil(fileTargetPath(in: args(["path": ""])))
        XCTAssertNil(fileTargetPath(in: args(["other": "x"])))
    }
}
