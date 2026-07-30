//
//  ActionEffectTests.swift
//  DevgenticTests
//
//  Cover for the episodic `effect` field — the record of what a mutating tool actually
//  changed.
//
//  Before this existed, `MemoryAction` carried the tool name, 200-char-truncated params and
//  a status; output only ever reached `errorReason` on the FAILURE path. So a successful
//  write left the agent knowing it had called `write_file` and nothing about the result.
//  Asked to undo one, the model said "I do not have access to a version control system…
//  restoring the file perfectly is impossible" — while the pre-write snapshot sat in the
//  app the whole time (field-observed 2026-07-25).
//

import XCTest
@testable import devgentic

final class ActionEffectTests: XCTestCase {

    // MARK: - Fixtures

    private func writeExecution(
        path: String = "/Users/me/Project/Main.java",
        content: String,
        preWrite: String?,
        isSuccess: Bool = true
    ) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(),
            name: "write_file",
            params: #"{"path":"\#(path)","content":"placeholder"}"#,
            output: "Successfully wrote",
            isSuccess: isSuccess,
            isExecuting: false
        )
        // Params carry the exact bytes for write tools; build them properly so the
        // resolver sees real content rather than the placeholder above.
        let params = try! JSONSerialization.data(
            withJSONObject: ["path": path, "content": content]
        )
        data.params = String(data: params, encoding: .utf8)!
        data.preWriteContent = preWrite
        return data
    }

    // MARK: - The gap this closes

    /// The core case: a write with a baseline yields the change, not the file.
    func testWriteWithBaselineRecordsTheChange() throws {
        let before = "line one\nline two\nline three\n"
        let after = "line one\nline two CHANGED\nline three\nline four\n"

        let effect = try XCTUnwrap(
            ActionEffect.from(toolExecution: writeExecution(content: after, preWrite: before))
        )

        XCTAssertEqual(effect.fileName, "Main.java")
        XCTAssertEqual(effect.path, "/Users/me/Project/Main.java")
        XCTAssertGreaterThan(effect.linesAdded, 0)
        XCTAssertGreaterThan(effect.linesRemoved, 0)

        let diff = try XCTUnwrap(effect.diff)
        XCTAssertTrue(diff.contains("+line two CHANGED"), "The added line must be recorded")
        XCTAssertTrue(diff.contains("-line two"), "The removed line must be recorded")
        XCTAssertFalse(diff.contains("+line one"), "Unchanged lines are context, not changes")
        XCTAssertLessThan(diff.count, after.count + before.count,
                          "The effect is the change, never both whole files")
    }

    /// Context is what makes a change revertible — `- foo()` alone doesn't say where.
    func testDiffCarriesSurroundingContext() throws {
        let before = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "line 10", with: "line 10 EDITED")

        let effect = try XCTUnwrap(
            ActionEffect.from(toolExecution: writeExecution(content: after, preWrite: before))
        )
        let diff = try XCTUnwrap(effect.diff)

        XCTAssertTrue(diff.contains(" line 9"), "Context above the change locates it")
        XCTAssertTrue(diff.contains(" line 11"), "Context below the change locates it")
        XCTAssertFalse(diff.contains("line 2\n"), "…but not the whole file")
    }

    /// A byte-identical rewrite is not a change — recording one would tell the agent it
    /// edited something it didn't.
    func testIdenticalRewriteProducesNoEffect() {
        let text = "unchanged\ncontent\n"
        XCTAssertNil(ActionEffect.from(toolExecution: writeExecution(content: text, preWrite: text)))
    }

    /// No baseline: the write still happened and the agent must know it, even though the
    /// change itself can't be described.
    func testWriteWithoutBaselineStillRecordsTheFile() throws {
        let effect = try XCTUnwrap(
            ActionEffect.from(toolExecution: writeExecution(content: "a\nb\nc\n", preWrite: nil))
        )
        XCTAssertEqual(effect.fileName, "Main.java")
        XCTAssertNil(effect.diff, "Nothing to diff against")
        XCTAssertEqual(effect.linesRemoved, 0)
        XCTAssertGreaterThan(effect.linesAdded, 0)
    }

    /// A failed write changed nothing.
    func testFailedWriteProducesNoEffect() {
        let data = writeExecution(content: "new\n", preWrite: "old\n", isSuccess: false)
        XCTAssertNil(ActionEffect.from(toolExecution: data))
    }

    /// Reads change nothing, so they carry no effect.
    func testReadProducesNoEffect() {
        var data = ToolExecutionData(
            id: UUID(),
            name: "read_file",
            params: #"{"path":"/Users/me/Project/Main.java"}"#,
            output: "file contents here",
            isSuccess: true,
            isExecuting: false
        )
        data.preWriteContent = nil
        XCTAssertNil(ActionEffect.from(toolExecution: data))
    }

    // MARK: - "No baseline" must not read as "removed nothing" (2026-07-27 audit)
    //
    // `snapshotContents` returns nil when the file is over `preWriteSnapshotByteLimit`
    // (512 KB) OR isn't readable as UTF-8, so `linesRemoved: 0` is a PLACEHOLDER. Rendered as
    // "+N −0" it made a destructive overwrite of an 800 KB file look like a fresh create, and
    // the episodic XML told the model the same thing.

    /// `diff == nil` is the signal both the row and the formatter key on. Pin it, because
    /// nothing else distinguishes "replaced nothing" from "couldn't see what I replaced".
    func testNoBaselineIsDistinguishableFromRemovedNothing() throws {
        let noBaseline = try XCTUnwrap(
            ActionEffect.from(toolExecution: writeExecution(content: "a\nb\nc\n", preWrite: nil))
        )
        XCTAssertNil(noBaseline.diff, "the marker for an unmeasured write")
        XCTAssertEqual(noBaseline.linesRemoved, 0, "…which is exactly why 0 cannot be trusted here")

        let measured = try XCTUnwrap(
            ActionEffect.from(toolExecution: writeExecution(content: "a\nb\nc\n", preWrite: "a\nx\nc\n"))
        )
        XCTAssertNotNil(measured.diff, "a real pre-image produces a real diff")
    }

    /// The model reads this XML on every subsequent prompt. Without `baseline="none"` it sees
    /// `removed="0"` and will claim it can undo a write whose prior content was never captured.
    func testEpisodicXMLFlagsAnUnmeasuredWrite() throws {
        let unmeasured = ActionEffect(path: "/Users/me/Big.java", linesAdded: 9000,
                                      linesRemoved: 0, diff: nil, isTruncated: false)
        let measured = ActionEffect(path: "/Users/me/Small.java", linesAdded: 2,
                                    linesRemoved: 1, diff: "+ new\n- old", isTruncated: false)

        let unmeasuredXML = EpisodicHistoryFormatter.renderEffect(unmeasured)
        let measuredXML = EpisodicHistoryFormatter.renderEffect(measured)

        XCTAssertTrue(unmeasuredXML.contains("baseline=\"none\""),
                      "an unmeasured write must say so:\n\(unmeasuredXML)")
        XCTAssertFalse(measuredXML.contains("baseline=\"none\""),
                       "a measured one must not be hedged:\n\(measuredXML)")
        XCTAssertTrue(measuredXML.contains("removed=\"1\""))
    }

    // MARK: - Path-normalization corruption (field-observed 2026-07-27)

    /// `normalizePathArguments` sniffed the VALUE for a leading "/", so a Java file whose
    /// first line is a `//` comment was run through `standardizingPath`: every `//`
    /// collapsed to `/` and the content was cut at PATH_MAX (1024). The corrupted string
    /// fed the HITL banner, the live tab, and this effect's diff.
    func testFileContentIsNotTreatedAsAPath() {
        let content = """
        // Program 3: Demonstrates Abstraction
        abstract class Shape {
            // Abstract method: Must be implemented by any concrete subclass.
            public abstract double calculateArea();
        }
        """
        let normalized = normalizePathArguments([
            "path": .string("/Users/me/Desktop/Shape.java"),
            "content": .string(content)
        ])

        guard case .string(let outContent)? = normalized["content"] else {
            return XCTFail("content missing")
        }
        XCTAssertEqual(outContent, content, "File content must pass through untouched")
        XCTAssertTrue(outContent.contains("// Program 3"), "Line comments keep BOTH slashes")
        XCTAssertTrue(outContent.contains("// Abstract method"))

        guard case .string(let outPath)? = normalized["path"] else {
            return XCTFail("path missing")
        }
        XCTAssertEqual(outPath, "/Users/me/Desktop/Shape.java", "Real paths still normalize")
    }

    /// Content longer than PATH_MAX must survive intact — the 1024-byte cut is what made
    /// four different files all arrive at ~1014-1021 chars.
    func testLongContentIsNotTruncatedAtPathMax() {
        let content = "// header\n" + (1...400).map { "    int field\($0) = \($0); // note" }.joined(separator: "\n")
        XCTAssertGreaterThan(content.count, 1024, "sanity: past PATH_MAX")

        let normalized = normalizePathArguments(["content": .string(content)])
        guard case .string(let out)? = normalized["content"] else { return XCTFail("missing") }
        XCTAssertEqual(out.count, content.count, "No PATH_MAX truncation on content")
    }

    /// Path keys still normalize — the fix must not disable the deduplication it exists for.
    func testPathKeysStillNormalize() {
        let normalized = normalizePathArguments([
            "path": .string("/Users/me/Projects//sub/../Main.java/")
        ])
        guard case .string(let out)? = normalized["path"] else { return XCTFail("missing") }
        XCTAssertEqual(out, "/Users/me/Projects/Main.java",
                       "Doubled slashes, .. segments and trailing slash still collapse")
    }

    // MARK: - Budget

    /// Episodic memory rides in every subsequent prompt, so the diff MUST be capped — and
    /// the model must be told when the cap bit, or it reads a partial change as the whole.
    func testLargeDiffIsCappedAndFlagged() throws {
        let before = (1...4000).map { "original line \($0)" }.joined(separator: "\n")
        let after = (1...4000).map { "rewritten line \($0)" }.joined(separator: "\n")

        let effect = try XCTUnwrap(
            ActionEffect.from(toolExecution: writeExecution(content: after, preWrite: before))
        )
        let diff = try XCTUnwrap(effect.diff)

        XCTAssertTrue(effect.isTruncated, "The cap bit and must be flagged")
        XCTAssertLessThanOrEqual(
            diff.count,
            ActionEffect.diffCharacterLimit + 32,
            "Capped at the budget (plus the truncation marker)"
        )
        XCTAssertTrue(diff.contains("truncated"), "The marker itself must be present")
    }

    /// A normal edit is nowhere near the cap — the budget must not bite ordinary work.
    func testOrdinaryEditIsNotTruncated() throws {
        let before = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "line 5", with: "line 5 EDITED")

        let effect = try XCTUnwrap(
            ActionEffect.from(toolExecution: writeExecution(content: after, preWrite: before))
        )
        XCTAssertFalse(effect.isTruncated)
    }

    // MARK: - Shape

    /// The summary is what compact renderers show; it must name the file and the counts.
    func testSummaryIsCompactAndNamesTheFile() throws {
        let effect = try XCTUnwrap(
            ActionEffect.from(toolExecution: writeExecution(content: "a\nb\n", preWrite: "a\n"))
        )
        XCTAssertTrue(effect.summary.hasPrefix("Main.java"))
        XCTAssertTrue(effect.summary.contains("+"))
    }

    /// Persisted, unlike the raw snapshots it derives from (design §12 D1) — so a resumed
    /// conversation keeps the ability to describe what it changed.
    func testEffectRoundTripsThroughCodable() throws {
        let original = ActionEffect(
            path: "/Users/me/Project/Main.java",
            linesAdded: 14,
            linesRemoved: 5,
            diff: "+added\n-removed",
            isTruncated: false
        )
        let decoded = try JSONDecoder().decode(
            ActionEffect.self, from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    /// The effect is derived ONCE at tool-completion and persisted with the row — the
    /// episodic formatter must only ever COPY it. Deriving it per prompt-build re-ran an
    /// O(n²) LCS for every historical write on every request (~6s for a 4000-line diff).
    func testToolExecutionDataPersistsItsEffect() throws {
        var data = writeExecution(content: "a\nb\nc\n", preWrite: "a\n")
        data.effect = ActionEffect.from(toolExecution: data)
        XCTAssertNotNil(data.effect, "Precondition: this write has an effect")

        let decoded = try JSONDecoder().decode(
            ToolExecutionData.self, from: try JSONEncoder().encode(data)
        )
        XCTAssertEqual(decoded.effect, data.effect, "The effect must survive persistence…")
        XCTAssertNil(decoded.preWriteContent, "…while the raw snapshot stays session-scoped")
    }

    /// A `MemoryAction` written before this field existed must still decode.
    func testMemoryActionWithoutEffectStillDecodes() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","toolName":"write_file","intent":"write_file",
         "status":"success","params":{},"logs":[],"artifacts":[]}
        """
        let decoded = try JSONDecoder().decode(MemoryAction.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.effect)
        XCTAssertEqual(decoded.toolName, "write_file")
    }
}
