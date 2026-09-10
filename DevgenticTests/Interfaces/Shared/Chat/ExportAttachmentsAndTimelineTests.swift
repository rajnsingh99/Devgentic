// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ExportAttachmentsAndTimelineTests.swift
//  DevgenticTests
//
//  [CF-19] `ConversationExporter.toMarkdown` read `attachedTextFiles` and the content enum and
//  nothing else. A turn that was "here's a screenshot, what's wrong?" exported as the prompt
//  alone, with nothing recording that an image was part of the question; an agent turn that was
//  all tool calls with no final prose exported as a heading over an empty section. Both under a
//  comment in the same function stating that an export which quietly omits something
//  misrepresents the conversation.
//
//  These pin the two writers and the bounds on them. `toMarkdown` itself is `async` and pulls in
//  the document-extraction registry, so the per-turn helpers are what the tests drive directly —
//  they are `nonisolated static` for exactly that reason.
//

import XCTest
@testable import devgentic

final class ExportAttachmentsAndTimelineTests: XCTestCase {

    // MARK: - Fixtures

    private func image(named name: String, bytes: Int) -> AttachedImageFile {
        AttachedImageFile(name: name,
                          url: URL(fileURLWithPath: "/tmp/\(name)"),
                          fileExtension: "png",
                          binaryData: Data(repeating: 0, count: bytes),
                          size: Int64(bytes))
    }

    private func toolRow(name: String, params: String = "{}", output: String? = "ok",
                         isSuccess: Bool? = true, isExecuting: Bool = false,
                         durationMs: Int? = nil,
                         failure: ToolFailureCategory? = nil) -> TimelineEvent {
        var data = ToolExecutionData(id: UUID(), name: name, params: params,
                                     output: output, isSuccess: isSuccess, isExecuting: isExecuting)
        data.durationMs = durationMs
        data.failureCategory = failure
        return .toolExecution(data)
    }

    // MARK: - Attached images

    /// The headline omission: an image turn exported with no trace the image existed.
    func testAttachedImageProducesALineNamingTheFile() {
        let line = ConversationExporter.attachedImageLine(for: image(named: "screenshot.png", bytes: 2048))

        XCTAssertTrue(line.contains("screenshot.png"), "The reader must be able to tell WHICH image: \(line)")
        XCTAssertTrue(line.contains("2 KB"), "Size tells the reader the bytes were deliberately not embedded: \(line)")
        XCTAssertTrue(line.hasPrefix(">"), "Rendered as a quote block beside the existing 'Attached:' lines: \(line)")
    }

    /// A row whose bytes were not loaded still has its recorded `size`; falling back to it keeps
    /// the line honest instead of printing "0 KB" for a real image.
    func testImageSizeFallsBackToTheRecordedSizeWhenBytesAreAbsent() {
        let noBytes = AttachedImageFile(name: "photo.jpg",
                                        url: URL(fileURLWithPath: "/tmp/photo.jpg"),
                                        fileExtension: "jpg",
                                        binaryData: Data(),
                                        size: 4096)

        XCTAssertEqual(ConversationExporter.imageByteCount(noBytes), 4096)
    }

    // MARK: - Execution log

    /// Only the `- ` list items are tool rows; the rest of the returned array is the
    /// `<details>` wrapper.
    private func toolLines(_ lines: [String]?) -> [String] {
        (lines ?? []).filter { $0.hasPrefix("- ") }
    }

    /// The second omission: an all-tool-calls turn exported as an empty section.
    func testTimelineProducesOneLinePerToolRow() {
        var omissions = ConversationExporter.TimelineOmissions()
        let lines = ConversationExporter.executionLogLines(
            for: [toolRow(name: "fs_read"), toolRow(name: "write_file")],
            omissions: &omissions
        )

        XCTAssertEqual(toolLines(lines).count, 2)
        XCTAssertTrue(lines?.contains(where: { $0.contains("fs_read") }) == true)
        XCTAssertTrue(lines?.contains(where: { $0.contains("write_file") }) == true)
        XCTAssertEqual(lines?.first, "<details>", "The block is collapsible so a long log does not bury the answer.")
        XCTAssertEqual(lines?.last, "</details>")
    }

    /// Outcome must be legible in the export, or a failed run reads as a successful one.
    func testOutcomeGlyphDistinguishesSuccessFailureAndStop() {
        let ok = toolRow(name: "a", isSuccess: true)
        let failed = toolRow(name: "b", isSuccess: false)
        let stopped = toolRow(name: "c", output: nil, isSuccess: false, failure: .cancelled)
        let running = toolRow(name: "d", output: nil, isSuccess: nil, isExecuting: true)

        guard case .toolExecution(let okData) = ok,
              case .toolExecution(let failedData) = failed,
              case .toolExecution(let stoppedData) = stopped,
              case .toolExecution(let runningData) = running else {
            return XCTFail("Expected tool rows")
        }

        XCTAssertEqual(ConversationExporter.outcomeGlyph(for: okData), "✅")
        XCTAssertEqual(ConversationExporter.outcomeGlyph(for: failedData), "❌")
        XCTAssertEqual(ConversationExporter.outcomeGlyph(for: stoppedData), "⏹",
                       "A user Stop is not a failure — the same rule the timeline header follows.")
        XCTAssertEqual(ConversationExporter.outcomeGlyph(for: runningData), "⏳")
    }

    /// ⚠️ The exported line must still name the CAUSE of a stopped row. Since CF-51 a user Stop
    /// settles the row with `isSuccess` nil (a stop is not a tool failure) while keeping
    /// `.cancelled` in `failureCategory`; the suffix was gated on `isSuccess == false`, so it
    /// silently vanished from every export. The glyph was unaffected, so nothing looked wrong.
    func testAStoppedRowStillExportsItsCancelledCause() {
        var stopped = ToolExecutionData(
            id: UUID(), name: "fs_read", params: "{}",
            output: "Cancelled before the tool finished.", isSuccess: nil, isExecuting: false
        )
        stopped.failureCategory = .cancelled

        let line = ConversationExporter.toolRowLine(for: stopped)

        XCTAssertTrue(line.contains(ToolFailureCategory.cancelled.displayName),
                      "The stop's cause must survive into the export: '\(line)'")
        XCTAssertTrue(line.hasPrefix("- ⏹"), "and it is still a stop, not a failure: '\(line)'")
    }

    /// A reasoning-only timeline earns no block: an empty `<details>` is worse than none.
    func testReasoningOnlyTimelineProducesNoBlock() {
        var omissions = ConversationExporter.TimelineOmissions()
        let lines = ConversationExporter.executionLogLines(
            for: [.reasoning(id: UUID(), text: "thinking about it")],
            omissions: &omissions
        )

        XCTAssertNil(lines, "No tool row earns a line, so the caller must write no block at all.")
        XCTAssertEqual(omissions.reasoningRows, 1, "The skipped row is still counted, not silently dropped.")
    }

    /// The cap keeps a runaway 500-event timeline from turning an export into a log dump, and
    /// what it folds away is counted rather than silently lost.
    func testToolRowsAreCappedAndTheRemainderIsCounted() {
        var omissions = ConversationExporter.TimelineOmissions()
        let many = (0..<(ConversationExporter.maxExportedToolRows + 7)).map { toolRow(name: "tool_\($0)") }

        let lines = ConversationExporter.executionLogLines(for: many, omissions: &omissions)
        let rows = toolLines(lines)

        // 50 tool rows + the one "… and N more" line that accounts for the rest. The VALUE is
        // stated here rather than read back from `maxExportedToolRows`: a test whose expectation
        // derives from the constant it is pinning cannot notice the constant changing.
        XCTAssertEqual(rows.count, 51)
        XCTAssertEqual(omissions.foldedToolRows, 7)
        XCTAssertTrue(rows.last?.contains("and 7 more") == true,
                      "What was folded away must be stated, not silently dropped: \(rows.last ?? "nil")")
    }

    /// A multi-line argument must not break the list item it is written into.
    func testInlineArgumentFlattensNewlinesAndBoundsLength() {
        let flattened = ConversationExporter.inlineArgument("first\nsecond")
        XCTAssertFalse(flattened.contains("\n"))

        let long = ConversationExporter.inlineArgument(String(repeating: "x", count: 200))
        XCTAssertTrue(long.count <= 82, "Bounded to one line's worth plus the code span: \(long.count)")
        XCTAssertTrue(long.contains("…"))
    }

    /// A backtick inside the argument would close the inline-code span and corrupt the rest of
    /// the line — the same class as the fence-escaping rule the exporter already follows.
    func testArgumentContainingABacktickIsNotWrappedInCode() {
        let line = ConversationExporter.inlineArgument("ls `pwd`")
        XCTAssertFalse(line.hasPrefix("`"), "A backtick-bearing argument is written plain: \(line)")
    }
}
