// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  FileReferenceResolverTests.swift
//  DevgenticTests
//
//  Inline `code` spans that name an absolute path become tappable and open in the Code Viewer.
//
//  The load-bearing half of this feature is what it REFUSES. A model's prose is dense with
//  code spans that look file-ish — `Double.NaN`, `System.out.println`, `array.map` — and every
//  dead link costs more trust than the live ones earn. Two routes qualify, and neither is
//  shape alone: an ABSOLUTE PATH (rooted, no whitespace, not a directory), or a BARE FILENAME
//  that matches a file the conversation actually read or wrote. Both then require a readable
//  regular file to exist right now. Anything else stays plain text, silently.
//

import XCTest
@testable import devgentic

final class FileReferenceResolverTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filerefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func makeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - What qualifies

    func testAbsolutePathQualifies() {
        XCTAssertTrue(FileReferenceResolver.looksLikeAbsolutePath("/Users/alice/Desktop/AbstractionDemo.java"))
        XCTAssertTrue(FileReferenceResolver.looksLikeAbsolutePath("/tmp/a.txt"))
        XCTAssertTrue(FileReferenceResolver.looksLikeAbsolutePath("/usr/local/bin/tool"),
                      "an extension is not required — plenty of real files have none")
    }

    func testTildePathIsExpanded() throws {
        let path = try XCTUnwrap(FileReferenceResolver.candidatePath("~/Desktop/Notes.md"))
        XCTAssertTrue(path.hasPrefix(NSHomeDirectory()), "got \(path)")
        XCTAssertTrue(path.hasSuffix("/Desktop/Notes.md"))
    }

    // MARK: - What must NOT qualify

    /// The whole reason this is absolute-paths-only. Every one of these appeared as inline
    /// code in real replies.
    func testSymbolsAndDottedIdentifiersAreRejected() {
        for span in ["AbstractionDemo.java", "Double.NaN", "System.out.println",
                     "array.map", "greet()", "Shape", "main", "config.json", "package.json"] {
            XCTAssertFalse(FileReferenceResolver.looksLikeAbsolutePath(span),
                           "'\(span)' is not an absolute path and must stay plain text")
        }
    }

    /// Existing on disk is NOT enough for a bare name — without the conversation index there
    /// is nothing distinguishing `Present.java` from any other dotted identifier. The
    /// index-aware overload is what resolves these; see the bare-filename section below.
    func testBareFilenameAloneIsRejectedEvenWhenTheFileExists() throws {
        try makeFile("Present.java")
        XCTAssertNil(FileReferenceResolver.candidatePath("Present.java"))
    }

    /// Relative paths look rooted to a human but not to us; resolving them needs a cwd we
    /// don't have.
    func testRelativePathsAreRejected() {
        for span in ["./src/Main.java", "../Main.java", "src/Main.java"] {
            XCTAssertFalse(FileReferenceResolver.looksLikeAbsolutePath(span), span)
        }
    }

    /// Shell commands routinely start with a path. Linkifying the whole span would be wrong
    /// even if the leading token is real.
    func testCommandLinesAreRejected() {
        for span in ["/usr/bin/env python script.py",
                     "javac /Users/alice/Desktop/AbstractionDemo.java",
                     "cd /tmp && ls"] {
            XCTAssertFalse(FileReferenceResolver.looksLikeAbsolutePath(span), span)
        }
    }

    func testDirectoriesAndRootsAreRejected() {
        XCTAssertFalse(FileReferenceResolver.looksLikeAbsolutePath("/Users/alice/Desktop/"))
        XCTAssertFalse(FileReferenceResolver.looksLikeAbsolutePath("/"))
        XCTAssertFalse(FileReferenceResolver.looksLikeAbsolutePath("~/"))
    }

    func testEmptyAndOversizedSpansAreRejected() {
        XCTAssertFalse(FileReferenceResolver.looksLikeAbsolutePath(""))
        XCTAssertFalse(FileReferenceResolver.looksLikeAbsolutePath("   "))
        let huge = "/" + String(repeating: "a", count: FileReferenceResolver.maxPathLength + 1)
        XCTAssertFalse(FileReferenceResolver.looksLikeAbsolutePath(huge),
                       "a pasted blob in backticks must not be scanned as a path")
    }

    // MARK: - Existence verification

    func testOnlyExistingRegularFilesVerify() throws {
        let real = try makeFile("Real.java")
        let missing = tempDir.appendingPathComponent("Gone.java").path
        let directory = tempDir.path

        let verified = FileReferenceResolver.verifyExisting([real.path, missing, directory])

        XCTAssertEqual(verified, [real.path], "a missing file and a directory are both unopenable")
    }

    /// A file deleted between render and tap is the reason verification exists at all — the
    /// span quietly reverts to plain text rather than offering a link that fails.
    func testDeletedFileNoLongerVerifies() throws {
        let url = try makeFile("Transient.java")
        XCTAssertEqual(FileReferenceResolver.verifyExisting([url.path]), [url.path])

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(FileReferenceResolver.verifyExisting([url.path]).isEmpty)
    }

    // MARK: - Extraction from markdown

    /// Only text the author marked as CODE is eligible — a path mentioned in running prose
    /// is not a reference the user asked to be actionable.
    func testOnlyInlineCodeSpansAreCandidates() {
        let markdown = """
        I wrote the file to /Users/alice/Desktop/Prose.java just now, \
        and updated `/Users/alice/Desktop/Code.java` as requested. \
        The method `greet()` prints a message.
        """
        let candidates = FileReferenceResolver.candidates(inMarkdown: markdown)
        XCTAssertEqual(candidates, ["/Users/alice/Desktop/Code.java"],
                       "the prose path and the symbol are both excluded")
    }

    func testMultipleDistinctPathsAreAllCandidates() {
        let markdown = "Changed `/tmp/a.java` and `/tmp/b.java`, then re-read `/tmp/a.java`."
        XCTAssertEqual(FileReferenceResolver.candidates(inMarkdown: markdown),
                       ["/tmp/a.java", "/tmp/b.java"], "de-duplicated")
    }

    func testBlockWithNoCodeSpansYieldsNothing() {
        XCTAssertTrue(FileReferenceResolver.candidates(inMarkdown: "Plain prose, no code.").isEmpty)
    }

    // MARK: - Link URLs

    func testLinkURLRoundTrips() throws {
        let path = "/Users/alice/Desktop/AbstractionDemo.java"
        let url = try XCTUnwrap(FileReferenceResolver.linkURL(forVerifiedPath: path))
        XCTAssertEqual(FileReferenceResolver.path(fromLinkURL: url), path)
    }

    /// Spaces and non-ASCII are legal in macOS paths and must survive percent-encoding.
    func testLinkURLRoundTripsAwkwardPaths() throws {
        for path in ["/Users/alice/My Documents/Réservé.java",
                     "/tmp/a+b&c=d.java",
                     "/tmp/emoji-🎉.txt"] {
            let url = try XCTUnwrap(FileReferenceResolver.linkURL(forVerifiedPath: path), path)
            XCTAssertEqual(FileReferenceResolver.path(fromLinkURL: url), path, path)
        }
    }

    /// The handler must ignore links it doesn't own, or it would swallow ordinary markdown
    /// links and stop them opening in the browser.
    func testForeignURLsAreNotOurs() {
        for raw in ["https://example.com/a.java", "file:///tmp/a.java", "devgentic-file://other?path=/tmp/a"] {
            let url = URL(string: raw)!
            XCTAssertNil(FileReferenceResolver.path(fromLinkURL: url), raw)
        }
    }

    /// A private scheme, not `file:` — an unhandled `file:` link would be opened by the SYSTEM
    /// on any surface lacking our handler, launching whatever app owns that extension.
    func testSchemeIsPrivateRatherThanFile() {
        XCTAssertNotEqual(FileReferenceResolver.scheme, "file")
    }

    // MARK: - Bare filenames, resolved through the conversation's own files
    //
    // A bare name has no shape that distinguishes it from a symbol, so the filter is
    // MEMBERSHIP: it must name a file the agent actually read or wrote. `Double.NaN` was never
    // a tool argument and therefore can never resolve, no matter how file-ish it looks.

    private func toolRow(name: String, path: String, params: String? = nil,
                         effect: Bool = true) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(),
            name: name,
            params: params ?? #"{"path":"\#(path)"}"#,
            output: "ok",
            isSuccess: true,
            isExecuting: false
        )
        if effect {
            data.effect = ActionEffect(path: path, linesAdded: 3, linesRemoved: 1,
                                       diff: "+ new", isTruncated: false)
        }
        return data
    }

    private func message(_ rows: [ToolExecutionData]) -> ChatMessage {
        let m = ChatMessage(id: UUID(), conversationId: UUID(), sender: .agent,
                            content: .markdownText("done"))
        m.timelineEvents = rows.map { .toolExecution($0) }
        return m
    }

    @MainActor
    func testBareFilenameResolvesToAFileTheConversationWrote() {
        let index = FileReferenceResolver.fileIndex(from: [
            message([toolRow(name: "write_file", path: "/Users/alice/Desktop/AbstractionDemo.java")])
        ])
        XCTAssertEqual(FileReferenceResolver.candidatePath("AbstractionDemo.java", in: index),
                       "/Users/alice/Desktop/AbstractionDemo.java")
    }

    /// The whole safety argument. These look every bit as file-ish as a real name.
    @MainActor
    func testSymbolsStillDoNotResolveAgainstAPopulatedIndex() {
        let index = FileReferenceResolver.fileIndex(from: [
            message([toolRow(name: "write_file", path: "/Users/alice/Desktop/AbstractionDemo.java")])
        ])
        for span in ["Double.NaN", "System.out.println", "array.map", "greet()",
                     "Shape", "main", "AbstractionDemo", "config.json"] {
            XCTAssertNil(FileReferenceResolver.candidatePath(span, in: index),
                         "'\(span)' was never a tool argument and must stay plain text")
        }
    }

    /// AMBIGUITY IS DROPPED, NOT GUESSED — opening the wrong file is silent, and worse than
    /// not linking at all.
    @MainActor
    func testSameBasenameInTwoDirectoriesResolvesToNeither() {
        let index = FileReferenceResolver.fileIndex(from: [
            message([
                toolRow(name: "write_file", path: "/proj/src/Main.java"),
                toolRow(name: "write_file", path: "/proj/test/Main.java")
            ])
        ])
        XCTAssertNil(index["Main.java"], "genuinely unresolvable → excluded")
        XCTAssertNil(FileReferenceResolver.candidatePath("Main.java", in: index))
    }

    /// The same file written twice is not ambiguous.
    @MainActor
    func testRepeatedWritesToOneFileStayResolvable() {
        let index = FileReferenceResolver.fileIndex(from: [
            message([
                toolRow(name: "write_file", path: "/proj/Main.java"),
                toolRow(name: "write_file", path: "/proj/Main.java")
            ])
        ])
        XCTAssertEqual(index["Main.java"], "/proj/Main.java")
    }

    /// Writes contribute via the PERSISTED effect, so bare names still resolve after a reload
    /// when the session-scoped snapshots are gone.
    @MainActor
    func testIndexUsesThePersistedEffectPath() {
        let index = FileReferenceResolver.fileIndex(from: [
            message([toolRow(name: "write_file", path: "/proj/Persisted.java")])
        ])
        XCTAssertEqual(index["Persisted.java"], "/proj/Persisted.java")
    }

    /// A write's params carry the ENTIRE file. Decoding those to find a path would parse
    /// megabytes across a long conversation, so oversized params are skipped — safe precisely
    /// because such calls already contribute their effect path.
    @MainActor
    func testOversizedParamsAreNotScanned() {
        let huge = String(repeating: "x", count: FileReferenceResolver.maxParamsScanLength + 500)
        let row = toolRow(name: "read_file", path: "/proj/Huge.java",
                          params: #"{"path":"/proj/Huge.java","content":"\#(huge)"}"#,
                          effect: false)
        let index = FileReferenceResolver.fileIndex(from: [message([row])])
        XCTAssertNil(index["Huge.java"], "skipped rather than parsed")
    }

    /// Files from EARLIER messages must resolve — the reference is usually a turn or two after
    /// the write that produced it.
    @MainActor
    func testIndexSpansTheWholeConversation() {
        let index = FileReferenceResolver.fileIndex(from: [
            message([toolRow(name: "write_file", path: "/proj/Early.java")]),
            message([toolRow(name: "write_file", path: "/proj/Late.java")])
        ])
        XCTAssertEqual(index["Early.java"], "/proj/Early.java")
        XCTAssertEqual(index["Late.java"], "/proj/Late.java")
    }

    @MainActor
    func testEmptyConversationResolvesNothing() {
        XCTAssertTrue(FileReferenceResolver.fileIndex(from: []).isEmpty)
        XCTAssertNil(FileReferenceResolver.candidatePath("Anything.java", in: [:]))
    }

    /// An absolute path must not need the index — the two routes are independent.
    @MainActor
    func testAbsolutePathsResolveWithoutAnIndex() {
        XCTAssertEqual(FileReferenceResolver.candidatePath("/tmp/A.java", in: [:]), "/tmp/A.java")
    }

    // MARK: - Span extraction with an index

    @MainActor
    func testCandidateLinksMapsSpansToPaths() {
        let index = ["AbstractionDemo.java": "/Users/alice/Desktop/AbstractionDemo.java"]
        let markdown = "I updated `AbstractionDemo.java`, see `/tmp/other.java`, calling `greet()`."

        let links = FileReferenceResolver.candidateLinks(inMarkdown: markdown, index: index)

        XCTAssertEqual(links["AbstractionDemo.java"], "/Users/alice/Desktop/AbstractionDemo.java")
        XCTAssertEqual(links["/tmp/other.java"], "/tmp/other.java")
        XCTAssertNil(links["greet()"], "symbols are not references")
        XCTAssertEqual(links.count, 2)
    }

    /// A bare name in PROSE is not a reference the user asked to be actionable — only text
    /// marked as code is eligible.
    @MainActor
    func testBareFilenameInProseIsNotALink() {
        let index = ["Main.java": "/proj/Main.java"]
        let links = FileReferenceResolver.candidateLinks(
            inMarkdown: "I edited Main.java earlier today.", index: index)
        XCTAssertTrue(links.isEmpty)
    }
}
