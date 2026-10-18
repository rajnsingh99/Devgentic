// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SplitToolTimelineLabelTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SplitToolTimelineLabelTests: XCTestCase {

    /// Every tool `CodeToolPreset` supplies to a Code profile, with the params shape it really
    /// declares (see `CodingAssistantSplitTools.swift`).
    private static let splitTools: [(name: String, params: String, expected: String, verb: String)] = [
        ("create_new_file",
         #"{"file_path":"/Users/me/proj/Notes.swift","content":"import SwiftUI\nimport Foundation\nstruct A {}"}"#,
         "Notes.swift", "Created"),
        ("overwrite_file",
         #"{"file_path":"/Users/me/proj/Main.swift","content":"import Foundation\nprint(1)"}"#,
         "Main.swift", "Overwrote"),
        ("edit_code_single",
         #"{"file_path":"/Users/me/proj/Util.swift","old_string":"let a = 1","new_string":"let a = 2"}"#,
         "Util.swift", "Edited"),
        ("edit_code_batch",
         #"{"file_path":"/Users/me/proj/Batch.swift","edits":[{"old_string":"a","new_string":"b"}]}"#,
         "Batch.swift", "Edited"),
        ("code_search_text",
         #"{"pattern":"TODO","glob":"*.swift"}"#,
         "TODO", "Searched"),
        ("code_search_symbol",
         #"{"pattern":"ChatHistoryViewModel"}"#,
         "ChatHistoryViewModel", "Searched"),
        ("code_search_files",
         #"{"pattern":"import SwiftUI"}"#,
         "import SwiftUI", "Found"),
    ]

    // MARK: - tc-1: the label must name the FILE, never its contents

    /// ⚠️ THE REGRESSION GUARD. Mutation that must kill this: remove the split names from
    /// `primaryLabel`'s file / search cases.
    func testEverySplitToolLabelsItsTargetRatherThanItsPayload() {
        for tool in Self.splitTools {
            let label = ToolArgFormatter.primaryLabel(tool: tool.name, params: tool.params)
            XCTAssertEqual(label, tool.expected,
                           "\(tool.name) must label its target, not whichever param iterated first")
            XCTAssertFalse(label.contains("import SwiftUI\n"),
                           "\(tool.name) must never surface file content in a row label")
        }
    }

    /// The group heading is built from the verb/object tables. Without entries there,
    /// `objectLabel` returns "tool"/"tools" and a Code profile read "Create 3 tools" where a Chat
    /// profile read "Created 3 files". Mutation that must kill this: drop the split entries from
    /// `verbOverrides` / `objectOverrides`.
    func testSplitToolsHaveVerbAndObjectEntriesSoGroupTitlesReadCorrectly() {
        for tool in Self.splitTools {
            let object = ToolArgFormatter.objectLabel(tool: tool.name, plural: 3)
            XCTAssertFalse(object == "tools",
                           "\(tool.name) falls back to the generic object — its group title would read 'N tools'")
            // ⚠️ The EXACT verb, not merely non-empty. `verb(tool:)` falls back to capitalising the
            // first underscore-segment, which is non-empty for every name — so `!verb.isEmpty`
            // was true with the overrides deleted. The past-tense form is what distinguishes the
            // override ("Created") from the fallback ("Create").
            XCTAssertEqual(ToolArgFormatter.verb(tool: tool.name), tool.verb,
                           "\(tool.name) must use its override verb, not the name-derived fallback")
        }
    }

    // MARK: - tc-1: the fallback must be deterministic and payload-free

    /// An unknown tool (a third-party MCP tool, or one added to the catalogue without a row here)
    /// must still never put a file's contents in a chip. Mutation that must kill this: restore
    /// the `for (_, v) in dict` fallback.
    func testAnUnknownToolNeverSurfacesAPayloadParam() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "some_third_party_tool",
            params: #"{"content":"SECRET FILE BODY THAT MUST NOT APPEAR","file_path":"/tmp/x.txt"}"#
        )
        XCTAssertEqual(label, "x.txt", "an identifying key must win over a payload key")
        XCTAssertFalse(label.contains("SECRET"))
    }

    /// With ONLY payload keys present the label must be empty rather than a slice of the file.
    func testAnUnknownToolWithOnlyPayloadParamsLabelsNothing() {
        let label = ToolArgFormatter.primaryLabel(
            tool: "some_third_party_tool",
            params: #"{"content":"WHOLE FILE BODY","old_string":"a","new_string":"b"}"#
        )
        XCTAssertEqual(label, "",
                       "no identity available — a row with no label is correct; leaking content is not")
    }

    /// ⚠️ HONEST SCOPE. This pins the fallback's RULE — lowest key by sorted order — not
    /// "determinism" as such. A first version of this test asserted only that repeated parses
    /// agree, and it PASSED against a mutant with the old `for (_, v) in dict` fallback restored:
    /// Swift seeds its hash per PROCESS, so a bridged dictionary's order is stable within one
    /// test run and the nondeterminism the fix is about (the same stored row labelling differently
    /// between app LAUNCHES) is unobservable from inside a single process.
    ///
    /// Asserting the exact sorted-first value is what makes the mutant fail, and the twelve keys
    /// are deliberate: an arbitrary-order implementation has roughly a 1-in-12 chance of
    /// coincidentally agreeing. That is a strong probabilistic kill, not a proof — stated plainly
    /// rather than dressed up as one.
    func testTheFallbackPicksTheLowestKeyBySortedOrder() {
        let params = #"{"zulu":"z","mike":"m","alpha":"a","tango":"t","echo":"e","kilo":"k","romeo":"r","victor":"v","papa":"p","sierra":"s","juliet":"j","bravo":"b"}"#
        let label = ToolArgFormatter.primaryLabel(tool: "unknown_tool", params: params)
        XCTAssertEqual(label, "a",
                       "the fallback must take the alphabetically-first key ('alpha'), making the label a function of the params alone")
    }

    // MARK: - tc-2: the chat/workflow file tools get a chip and an effect

    private func writeRow(name: String, params: String,
                          pre: String? = nil, post: String? = nil) -> ToolExecutionData {
        ToolExecutionData(
            id: UUID(), name: name, params: params, output: "ok", isSuccess: true,
            isExecuting: false, preWriteContent: pre, postWriteContent: post
        )
    }

    /// ⚠️ `create_file` is `.libraryExceptCode` exactly like `write_file`, which was already
    /// eligible. Mutation that must kill this: remove `create_file` from `chipEligibleTools`.
    func testCreateFileResolvesAFileViewerAction() throws {
        let action = TimelineFileViewerAction.resolve(
            data: writeRow(name: "create_file",
                           params: #"{"file_path":"/Users/me/New.swift","content":"let a = 1"}"#,
                           pre: "")
        )
        let resolved = try XCTUnwrap(action,
            "a chat-profile file creation must produce a chip — without it there is no +N −M, no 'Previous version', and no persisted ActionEffect")
        XCTAssertEqual(resolved.fileName, "New.swift")
        XCTAssertTrue(resolved.isWrite)
    }

    /// `edit_code` carries find/replace only, so it needs the executor's post-write read-back —
    /// the same contract as its two splits. Mutation that must kill this: remove `edit_code` from
    /// `chipEligibleTools` or from the `edit_code_single`/`edit_code_batch` case.
    func testEditCodeResolvesUsingThePostWriteReadBack() throws {
        let action = TimelineFileViewerAction.resolve(
            data: writeRow(name: "edit_code",
                           params: #"{"file_path":"/Users/me/Edit.swift","old_string":"a","new_string":"b"}"#,
                           pre: "let a = 1", post: "let b = 1")
        )
        let resolved = try XCTUnwrap(action, "edit_code must resolve once it has a read-back")
        XCTAssertEqual(resolved.fileName, "Edit.swift")
    }

    /// The control that keeps the fix honest: with no read-back there is still NO chip, because
    /// the post-state cannot be represented. This is the pre-existing contract for the splits and
    /// `edit_code` must not get a weaker one.
    func testEditCodeWithoutAReadBackStillProducesNoChip() {
        let action = TimelineFileViewerAction.resolve(
            data: writeRow(name: "edit_code",
                           params: #"{"file_path":"/Users/me/Edit.swift","old_string":"a","new_string":"b"}"#,
                           pre: "let a = 1", post: nil)
        )
        XCTAssertNil(action,
                     "without the read-back the change cannot be shown — a lying chip is worse than none")
    }

    /// Control: a genuinely ineligible tool still resolves to nil, so the fix did not widen the
    /// set into accepting everything.
    func testANonFileToolStillResolvesToNil() {
        let action = TimelineFileViewerAction.resolve(
            data: writeRow(name: "execute_shell", params: #"{"command":"ls -la"}"#)
        )
        XCTAssertNil(action)
    }
}

// MARK: - tc-3: an interrupted run must not report a clean one

/// A force-quit mid-run stamps no `terminalOutcome` (neither `finalizeMessage` nor
/// `.executionFinished` is reached) and `markInterruptedByProcessDeath` deliberately writes nothing
/// to the abandoned row, so `failed` is 0 too. Both correct individually — together they made the
/// header render a green checkmark and "Executed 3 steps" directly above the `InterruptedRunChip`.
final class InterruptedRunSummaryTests: XCTestCase {

    private func toolRow(success: Bool?) -> TimelineEvent {
        .toolExecution(ToolExecutionData(
            id: UUID(), name: "read_file", params: #"{"file_path":"/tmp/a.swift"}"#,
            output: success == nil ? nil : "ok", isSuccess: success, isExecuting: false
        ))
    }

    /// ⚠️ THE REGRESSION GUARD. Mutation that must kill this: drop the
    /// `if outcome == nil, isInterrupted` branch from `summarize`.
    func testAnInterruptedRunWithNoOutcomeDoesNotReportSuccess() {
        let events = [toolRow(success: true), toolRow(success: nil)]
        let summary = AgentTimelineView.summarize(events: events, outcome: nil, isInterrupted: true)
        XCTAssertEqual(summary.status, .interrupted,
                       "a run that never finished must not render the success glyph")
        XCTAssertNotEqual(summary.status, .succeeded)
    }

    /// The outcome still LEADS. A run that DID end and reported how must keep that status —
    /// otherwise a resumed-then-cancelled run would read "Interrupted" instead of "Stopped".
    func testAStampedOutcomeWinsOverTheInterruptedFlag() {
        let events = [toolRow(success: true)]
        XCTAssertEqual(
            AgentTimelineView.summarize(events: events, outcome: .cancelled, isInterrupted: true).status,
            .cancelled, "an explicit outcome is what the run actually reported")
        XCTAssertEqual(
            AgentTimelineView.summarize(events: events, outcome: .completed, isInterrupted: true).status,
            .succeeded, "a completed run that was once parked is still a completed run")
    }

    /// The ordinary path is untouched: no flag, no outcome, no failures → success.
    func testACleanRunStillReportsSuccess() {
        let summary = AgentTimelineView.summarize(events: [toolRow(success: true)],
                                                  outcome: nil, isInterrupted: false)
        XCTAssertEqual(summary.status, .succeeded)
    }

    /// A failed tool still escalates to degraded when the run was not interrupted.
    func testAFailedToolStillReportsDegraded() {
        let summary = AgentTimelineView.summarize(events: [toolRow(success: false)],
                                                  outcome: nil, isInterrupted: false)
        XCTAssertEqual(summary.status, .degraded)
        XCTAssertEqual(summary.failedTools, 1)
    }

    /// [tc-7] `summarize` returns the tool count so ONE flatten answers every question the header
    /// asks. `summaryTitle` used to run a second, identical flatten purely to recount, and `body`
    /// read the whole summary six times per pass. Pinning the count here is what removes any
    /// reason for a future author to recount downstream.
    func testSummarizeReportsTheToolCountIncludingNestedCardRows() {
        // Same fixture shape the existing timeline suites use.
        var plan = PlanRunData(phase: .finished, steps: [
            PlanStepData(id: "step_1", title: "Do it", status: .completed)
        ])
        plan.steps[0].events = [toolRow(success: true), toolRow(success: false)]
        let nested = TimelineEvent.planExecution(plan)
        let summary = AgentTimelineView.summarize(events: [toolRow(success: true), nested])
        XCTAssertEqual(summary.toolCount, 3,
                       "the count must include rows nested inside capability cards — a Plan & Execute run has NO top-level tool rows")
        XCTAssertEqual(summary.failedTools, 1)
    }

    /// `.interrupted` must be visually distinct from `.degraded` — they occupy the same slot.
    func testInterruptedAndDegradedUseDifferentGlyphs() {
        XCTAssertNotEqual(AgentTimelineView.TimelineSummaryStatus.interrupted.glyph,
                          AgentTimelineView.TimelineSummaryStatus.degraded.glyph)
        XCTAssertNotEqual(AgentTimelineView.TimelineSummaryStatus.interrupted.glyph,
                          AgentTimelineView.TimelineSummaryStatus.succeeded.glyph)
    }
}

/// cv-4: creating a file must not report a deleted line.
final class DiffEmptySideTests: XCTestCase {

    /// ⚠️ THE REGRESSION GUARD. `preWriteSnapshot` returns `""` — not nil — for a file that does
    /// not exist yet, and `"".components(separatedBy: .newlines)` is `[""]`, one empty line. So a
    /// creation diffed against it reported a phantom deletion, and the chip read "+2 −1".
    /// Mutation that must kill this: drop the `isEmpty ? [] :` guards in `lineLevelDiff`.
    func testCreatingAFileReportsPureAdditions() {
        let counts = DiffUtility.changeCounts(original: "", modified: "line1\nline2")
        XCTAssertEqual(counts.added, 2)
        XCTAssertEqual(counts.deleted, 0, "a creation deletes nothing — there was no file")
    }

    /// The mirror: emptying a file is a pure deletion, not a deletion plus a phantom addition.
    func testEmptyingAFileReportsPureDeletions() {
        let counts = DiffUtility.changeCounts(original: "line1\nline2", modified: "")
        XCTAssertEqual(counts.added, 0)
        XCTAssertEqual(counts.deleted, 2)
    }

    /// Both empty must be a no-op, and must not trap — this file has a history of `1...0` traps.
    func testBothSidesEmptyProducesNoRows() {
        XCTAssertTrue(DiffUtility.generateDiff(original: "", modified: "").isEmpty)
        let counts = DiffUtility.changeCounts(original: "", modified: "")
        XCTAssertEqual(counts.added, 0)
        XCTAssertEqual(counts.deleted, 0)
    }

    /// ⚠️ THE COLD-READ GUARD for cv-4's own regression. The ROWS and the COUNTS are read by
    /// different consumers — `FileChangePreviewView`/`ActionEffectBuilder.changedLines` take rows,
    /// the chip takes counts — and they must describe the same thing. A newline-terminated create
    /// produced one row MORE than lines in the file, rendering `+13 −0` and a spurious green blank
    /// row for a 12-line file, and writing that phantom line into the persisted effect the model
    /// reads back. Mutation that must kill this: drop the trailing-newline trim from `lines(_:)`.
    func testRowCountMatchesTheCountsForANewlineTerminatedCreate() {
        let created = "line1\nline2\n"
        let rows = DiffUtility.generateDiff(original: "", modified: created)
        let counts = DiffUtility.changeCounts(original: "", modified: created)
        XCTAssertEqual(rows.count, 2, "two real lines, two rows — no phantom trailing row")
        XCTAssertEqual(counts.added, 2)
        XCTAssertEqual(rows.filter { $0.type == .added }.count, counts.added,
                       "the rows and the counts must agree — different consumers read each")
    }

    /// The same for a truncation to empty.
    func testRowCountMatchesTheCountsForATruncation() {
        let rows = DiffUtility.generateDiff(original: "line1\nline2\n", modified: "")
        let counts = DiffUtility.changeCounts(original: "line1\nline2\n", modified: "")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { $0.type == .deleted }.count, counts.deleted)
    }

    /// Control: an ordinary edit is unaffected by the empty-side handling.
    func testAnOrdinaryEditIsUnchanged() {
        let counts = DiffUtility.changeCounts(original: "a\nb\nc", modified: "a\nB\nc")
        XCTAssertEqual(counts.added, 1)
        XCTAssertEqual(counts.deleted, 1)
    }

    /// Control: the trailing-newline trim `changeCounts` already had still works.
    func testATrailingNewlineIsStillNotACount() {
        let counts = DiffUtility.changeCounts(original: "a\nb\n", modified: "a\nb")
        XCTAssertEqual(counts.added, 0)
        XCTAssertEqual(counts.deleted, 0)
    }
}

/// tc-4: a prompt the user declined is not a tool failure.
final class DeclinedAskUserSummaryTests: XCTestCase {

    private func tool(_ name: String, success: Bool?, cancelled: Bool = false) -> TimelineEvent {
        .toolExecution(ToolExecutionData(
            id: UUID(), name: name, params: "{}", output: "o", isSuccess: success,
            failureCategory: cancelled ? .cancelled : nil, isExecuting: false
        ))
    }

    /// ⚠️ THE REGRESSION GUARD. Mutation that must kill this: drop the `isDeclinedPrompt` test
    /// from `summarize`'s count loop.
    func testASkippedAskUserIsNotCountedAsAFailedTool() {
        let s = AgentTimelineView.summarize(
            events: [tool("write_file", success: true), tool("ask_user", success: false, cancelled: true)],
            outcome: .completed
        )
        XCTAssertEqual(s.failedTools, 0, "the user declined a prompt — nothing failed")
        XCTAssertEqual(s.status, .succeeded,
                       "the header must not go amber about an event the user themselves declined")
    }

    /// Narrowness, half one: an `ask_user` that failed for some OTHER reason is a real failure.
    func testAnAskUserThatFailedForAnotherReasonStillCounts() {
        let s = AgentTimelineView.summarize(
            events: [tool("ask_user", success: false, cancelled: false)], outcome: .completed
        )
        XCTAssertEqual(s.failedTools, 1)
        XCTAssertEqual(s.status, .degraded)
    }

    /// Narrowness, half two: a CANCELLED WRITE still counts — the write did not happen. This is
    /// also what keeps CF-46's existing test (whose helper builds a `write_file`) green.
    func testACancelledWriteStillCountsAsAFailure() {
        let s = AgentTimelineView.summarize(
            events: [tool("write_file", success: false, cancelled: true)], outcome: .completed
        )
        XCTAssertEqual(s.failedTools, 1)
        XCTAssertEqual(s.status, .degraded)
    }
}

/// P3 wave 1: format-after-bucket boundaries and export block structure.
final class ExportAndMagnitudeBoundaryTests: XCTestCase {

    // MARK: - mm-9: the bucket must be chosen from the ROUNDED value

    /// ⚠️ THE REGRESSION GUARD. Choosing the bucket from the raw count and only then applying
    /// `%.1f` let the format round past the threshold the bucket was picked by.
    /// Mutation that must kill this: restore `if count >= 1_000_000 … if count >= 1_000 …`.
    func testTheMillionsBoundaryDoesNotRenderAsFourDigitThousands() {
        XCTAssertEqual(TokenUsageBadge.abbreviated(999_950), "1.0M",
                       "999,950 rounds to 1000.0K, which must be promoted to 1.0M — not printed")
        XCTAssertEqual(TokenUsageBadge.abbreviated(999_999), "1.0M")
    }

    /// …and the promotion must scale from the MILLIONS divisor. Promoting the thousands string
    /// verbatim would print "1000.0M".
    func testThePromotedValueIsScaledFromMillionsNotPromotedVerbatim() {
        XCTAssertFalse(TokenUsageBadge.abbreviated(999_950).contains("1000"),
                       "the promoted value must be re-scaled, not the thousands string relabelled")
    }

    /// Controls: the ordinary buckets are untouched on both sides of each threshold.
    func testOrdinaryMagnitudesAreUnchanged() {
        XCTAssertEqual(TokenUsageBadge.abbreviated(999), "999")
        XCTAssertEqual(TokenUsageBadge.abbreviated(1_000), "1.0K")
        XCTAssertEqual(TokenUsageBadge.abbreviated(999_949), "999.9K")
        XCTAssertEqual(TokenUsageBadge.abbreviated(1_000_000), "1.0M")
        XCTAssertEqual(TokenUsageBadge.abbreviated(1_500_000), "1.5M")
    }

    // MARK: - mm-7: consecutive quoted lines are ONE paragraph

    /// Each attachment must be its own list item, or N attachments render run-together on one
    /// wrapped line. Asserted on the RENDERED output, not the emitted bytes — the bytes looked
    /// fine, which is exactly why this survived.
    func testMultipleAttachmentsRenderAsSeparateItems() throws {
        func img(_ name: String) -> AttachedImageFile {
            AttachedImageFile(name: name,
                              url: URL(fileURLWithPath: "/tmp/\(name)"),
                              fileExtension: "png",
                              binaryData: Data(repeating: 0, count: 2048),
                              size: 2048)
        }
        let a = ConversationExporter.attachedImageLine(for: img("one.png"))
        let b = ConversationExporter.attachedImageLine(for: img("two.png"))
        // ⚠️ Assert the LIST MARKER, which is the fix. The first version of this test rendered
        // through `.inlineOnlyPreservingWhitespace`, which does not interpret block syntax and
        // preserves the newline — so the two lines never fused and the test passed with the fix
        // reverted. It also used a needle containing a backtick, which inline-code parsing
        // removes, making the negative assertion unfalsifiable twice over.
        XCTAssertTrue(a.hasPrefix("> - "), "each attachment is its own list item inside the quote")
        XCTAssertTrue(b.hasPrefix("> - "))
        // And the rendered form, with the SAME options production uses.
        let rendered = String(try AttributedString(markdown: "\(a)\n\(b)").characters)
        XCTAssertTrue(rendered.contains("one.png"))
        XCTAssertTrue(rendered.contains("two.png"))
        XCTAssertFalse(rendered.contains("one.png (2 KB) Attached image"),
                       "the two attachments must not collapse onto one line: \(rendered)")
    }
}

/// sa-6: the speed badge must report the speed the user actually picked.
final class SpeechRateFormattingTests: XCTestCase {

    /// ⚠️ THE REGRESSION GUARD. `%.1f` rendered the two QUARTER presets as "0.8x" and "1.2x" —
    /// the menu offered one speed and the badge reported another, for a value chosen from a
    /// fixed list. Mutation that must kill this: restore `String(format: "%.1fx", rate)`.
    func testEverySpeedPresetRendersItsOwnValue() {
        let expected: [Float: String] = [
            0.5: "0.5x", 0.75: "0.75x", 1.0: "1x", 1.25: "1.25x", 1.5: "1.5x", 2.0: "2x",
        ]
        for rate in SpeechService.speedPresets {
            let want = try? XCTUnwrap(expected[rate])
            XCTAssertEqual(SpeechControlIsland.formatRate(rate), want,
                           "preset \(rate) must render as itself — the menu and the badge must agree")
        }
    }

    /// Integers keep their old rendering: no "1.0x".
    func testWholeNumbersHaveNoDecimalPoint() {
        XCTAssertEqual(SpeechControlIsland.formatRate(1.0), "1x")
        XCTAssertEqual(SpeechControlIsland.formatRate(2.0), "2x")
    }

    /// Every preset is covered by the map above — a new preset must not silently skip the test.
    func testTheExpectationTableCoversEveryPreset() {
        XCTAssertEqual(SpeechService.speedPresets.count, 6,
                       "a preset was added or removed — extend testEverySpeedPresetRendersItsOwnValue")
    }
}

/// tc-10: a settled row whose outcome was never reported must still say so.
final class SettledUnreportedRowTests: XCTestCase {

    /// The state `statusIcon`'s new third arm renders is reachable from exactly three writers,
    /// all in `DanglingToolRowCloser`. This pins that reachability — if a normal completion ever
    /// starts landing here, the glyph would be painted on rows that DID report, and this fails.
    func testOnlyTheClosersProduceASettledRowWithNoOutcome() {
        var events: [TimelineEvent] = [.toolExecution(ToolExecutionData(
            id: UUID(), name: "write_file", params: "{}", output: nil,
            isSuccess: nil, isExecuting: true
        ))]

        // A user Stop: settled, no isSuccess, category .cancelled.
        DanglingToolRowCloser.close(&events, outcome: .cancelled)
        guard case .toolExecution(let cancelled) = events[0] else { return XCTFail("shape") }
        XCTAssertFalse(cancelled.isExecuting)
        XCTAssertNil(cancelled.isSuccess, "a user Stop is not a tool failure")
        XCTAssertEqual(cancelled.failureCategory, .cancelled,
                       "…and the category is what selects the neutral `slash.circle` over `circle.dotted`")
    }

    /// Process death settles the row and writes NOTHING else — the state with no category at all.
    func testProcessDeathLeavesNoCategoryEither() {
        var events: [TimelineEvent] = [.toolExecution(ToolExecutionData(
            id: UUID(), name: "write_file", params: "{}", output: nil,
            isSuccess: nil, isExecuting: true
        ))]
        DanglingToolRowCloser.markInterruptedByProcessDeath(&events)
        guard case .toolExecution(let row) = events[0] else { return XCTFail("shape") }
        XCTAssertFalse(row.isExecuting)
        XCTAssertNil(row.isSuccess)
        XCTAssertNil(row.failureCategory, "nothing is written — resume finds the row by output == nil")
        XCTAssertNil(row.output, "…and the output must stay nil, or resume stops recognising it")
    }

    /// A FAILED close still reports a failure — the new arm must not swallow real failures.
    func testANonCancelledCloseStillReportsFailure() {
        var events: [TimelineEvent] = [.toolExecution(ToolExecutionData(
            id: UUID(), name: "write_file", params: "{}", output: nil,
            isSuccess: nil, isExecuting: true
        ))]
        DanglingToolRowCloser.close(&events, outcome: .failed)
        guard case .toolExecution(let row) = events[0] else { return XCTFail("shape") }
        XCTAssertEqual(row.isSuccess, false, "a failure close still reports false")
    }
}

/// mm-8: the bucket and the printed string must agree about which unit this is.
final class DurationBoundaryTests: XCTestCase {

    /// ⚠️ THE REGRESSION GUARD. `s < 60` was tested on the unrounded value while `%.1f` rounded,
    /// so the last 50 ms before a minute printed "60.0s" — a duration in seconds that reads as a
    /// minute. Mutation that must kill this: restore `if s < 60 { … }; clock(wholeSeconds: Int(s))`.
    func testTheMinuteBoundaryNeverPrintsSixtySeconds() {
        XCTAssertEqual(DurationFormat.milliseconds(59_950), "1m")
        XCTAssertEqual(DurationFormat.milliseconds(59_999), "1m")
        XCTAssertEqual(DurationFormat.seconds(59.95), "1m")
        XCTAssertEqual(DurationFormat.seconds(59.999), "1m")
    }

    /// ⚠️ The fix must NOT be "round the input". That would change 500 ms of behaviour to correct
    /// 50 ms — 59.6 s must still read as seconds.
    func testValuesWellBelowTheBoundaryAreUnchanged() {
        XCTAssertEqual(DurationFormat.milliseconds(59_949), "59.9s")
        XCTAssertEqual(DurationFormat.milliseconds(59_600), "59.6s")
        XCTAssertEqual(DurationFormat.seconds(59.94), "59.9s")
    }

    /// ⚠️⚠️ THE COLD-READ GUARD. The first mm-8 fix derived whole seconds from the ROUNDED tenths,
    /// which disagreed with `elapsed` for every duration in an `[n.95, n+1)` band — ~5% of all
    /// values, a far wider defect than the 50 ms it closed. This sweeps the bands directly.
    /// Mutation that must kill this: `clock(wholeSeconds: Int(tenths / 10))`.
    func testMillisecondsAgreesWithElapsedAcrossTheRoundingBands() {
        let start = Date(timeIntervalSince1970: 0)
        for hundredths in stride(from: 6_000, through: 20_000, by: 1) {
            let seconds = Double(hundredths) / 100.0
            let viaMs = DurationFormat.milliseconds(Int((seconds * 1000).rounded()))
            let viaElapsed = DurationFormat.elapsed(from: start, to: start.addingTimeInterval(seconds))
            XCTAssertEqual(viaMs, viaElapsed, "disagreement at \(seconds)s")
        }
    }

    /// ⚠️ Cross-helper agreement — the reason this helper was consolidated in the first place.
    /// `elapsed` truncates, so `milliseconds` must too above the boundary, or the same run reads
    /// one duration in an exported tool row and a different one in the live streaming footer.
    func testMillisecondsAndElapsedAgreeAboveTheBoundary() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(DurationFormat.milliseconds(90_700),
                       DurationFormat.elapsed(from: start, to: start.addingTimeInterval(90.7)),
                       "a 90.7s run must read the same in both renderings")
        XCTAssertEqual(DurationFormat.milliseconds(90_700), "1m 30s")
    }

    /// Controls on the other buckets.
    func testSubSecondAndHourBucketsAreUnchanged() {
        XCTAssertEqual(DurationFormat.milliseconds(820), "820ms")
        XCTAssertEqual(DurationFormat.milliseconds(999), "999ms")
        XCTAssertEqual(DurationFormat.milliseconds(1_000), "1.0s")
        XCTAssertEqual(DurationFormat.milliseconds(60_000), "1m")
        XCTAssertEqual(DurationFormat.seconds(0.5), "<1s")
    }
}

/// vm-6: a save that changes nothing must change nothing on disk.
@MainActor
final class EdgeWhitespaceRestoreTests: XCTestCase {

    private func apply(_ code: String, baseline: String) -> String {
        ChatHistoryViewModel.contentToApply(snippetCode: code, preservingEdgeWhitespaceOf: baseline)
    }

    /// ⚠️ THE REGRESSION GUARD. `hasSuffix("\n")` restored exactly ONE newline, so a file ending
    /// in several blank lines had them collapsed by a save that changed nothing else.
    /// Mutation that must kill this: restore `if baseline.hasSuffix("\n") { out += "\n" }`.
    func testMultipleTrailingBlankLinesSurviveANoEditSave() {
        let onDisk = "import Foundation\n\n\n"
        // What the viewer shows after `normalizedCode` trims both edges.
        let trimmed = onDisk.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(apply(trimmed, baseline: onDisk), onDisk,
                       "a no-edit save must reproduce the file byte-for-byte")
    }

    /// ⚠️ CRLF: "\r\n" is ONE grapheme cluster, so `hasSuffix("\n")` is FALSE for a CRLF file and
    /// the old guard never fired — the final terminator was DROPPED, not converted.
    func testACRLFTerminatorIsNotDropped() {
        let onDisk = "line one\r\nline two\r\n"
        let trimmed = onDisk.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(onDisk.hasSuffix("\n"),
                       "precondition: this is exactly why the old single-newline guard missed")
        XCTAssertEqual(apply(trimmed, baseline: onDisk), onDisk,
                       "the literal terminator run is restored, whatever bytes it is")
    }

    /// Leading and trailing together, the ordinary case.
    func testBothEdgesAreRestored() {
        let onDisk = "\n  import Foundation\n\n"
        let trimmed = onDisk.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(apply(trimmed, baseline: onDisk), onDisk)
    }

    /// A REAL edit still applies — the restore must not resurrect the old body.
    func testARealEditIsPreservedWithItsEdgesRestored() {
        let onDisk = "\nold body\n\n"
        XCTAssertEqual(apply("new body", baseline: onDisk), "\nnew body\n\n")
    }

    /// Control: a baseline with no edge whitespace degrades to a no-op, not to damage.
    func testATrimmedBaselineIsANoOp() {
        XCTAssertEqual(apply("let a = 1", baseline: "let a = 0"), "let a = 1")
    }
}

/// tc-8 / mc-8: the shared-parse overloads, and heading markup.
final class SharedParseAndHeadingTests: XCTestCase {

    // MARK: - tc-8: both overloads must agree

    /// The dict form is what `resolveChip` calls; the String form is what the exporter calls.
    /// If they ever disagree, a row's chip and its exported line describe different things.
    func testBothPrimaryLabelFormsAgree() {
        let params = #"{"file_path":"/Users/me/Notes.swift","content":"let a = 1"}"#
        let viaString = ToolArgFormatter.primaryLabel(tool: "create_new_file", params: params)
        let viaDict = ToolArgFormatter.primaryLabel(
            tool: "create_new_file", dict: ToolArgFormatter.parsedParamsForRow(params))
        XCTAssertEqual(viaString, viaDict)
        XCTAssertEqual(viaString, "Notes.swift")
    }

    /// `final_answer` returns BEFORE any parse — that early exit must stay ahead of the shared one.
    func testFinalAnswerStillShortCircuitsAheadOfTheParse() {
        XCTAssertEqual(ToolArgFormatter.primaryLabel(tool: "final_answer", dict: nil), "")
        XCTAssertEqual(
            ToolArgFormatter.primaryLabel(tool: "final_answer", params: #"{"answer":"long prose"}"#), "")
    }

    /// ⚠️ nil (undecodable JSON) must stay distinguishable from "decoded but no path" — the two
    /// `skip` diagnostics say different things and both are the on-device answer to "why is the
    /// button missing?".
    func testUndecodableParamsAndMissingPathAreBothHandled() {
        let undecodable = TimelineFileViewerAction.resolve(
            data: ToolExecutionData(id: UUID(), name: "write_file", params: "not json",
                                    output: "ok", isSuccess: true, isExecuting: false),
            params: nil)
        XCTAssertNil(undecodable)

        let noPath = TimelineFileViewerAction.resolve(
            data: ToolExecutionData(id: UUID(), name: "write_file", params: "{}",
                                    output: "ok", isSuccess: true, isExecuting: false),
            params: [:])
        XCTAssertNil(noPath)
    }

    /// The String form still resolves — the wrapper must actually parse.
    func testTheStringDrivenResolveStillWorks() throws {
        let action = TimelineFileViewerAction.resolve(
            data: ToolExecutionData(
                id: UUID(), name: "write_file",
                params: #"{"file_path":"/Users/me/A.swift","content":"x"}"#,
                output: "ok", isSuccess: true, isExecuting: false, preWriteContent: ""))
        XCTAssertEqual(try XCTUnwrap(action).fileName, "A.swift")
    }

    // MARK: - mc-8: heading markup must survive

    /// ⚠️ `plainText` STRIPS markup, so bold/italic/code/links inside a heading rendered flat
    /// while the identical markup one line lower, in a paragraph, rendered correctly.
    /// Mutation that must kill this: restore `heading.plainText`.
    func testHeadingKeepsItsInlineMarkup() throws {
        let blocks = parseMarkdown("## A **bold** word and `code`")
        let heading = try XCTUnwrap(blocks.compactMap { block -> String? in
            if case .heading(_, let text) = block.type { return text }
            return nil
        }.first)
        XCTAssertTrue(heading.contains("**bold**"), "bold markup must reach the renderer: \(heading)")
        XCTAssertTrue(heading.contains("`code`"), "inline code too: \(heading)")
    }

    /// No ATX prefix leaks in — the children are formatted, not the node.
    func testHeadingTextCarriesNoHashPrefix() throws {
        let blocks = parseMarkdown("### Plain heading")
        let heading = try XCTUnwrap(blocks.compactMap { block -> String? in
            if case .heading(_, let text) = block.type { return text }
            return nil
        }.first)
        XCTAssertEqual(heading, "Plain heading")
    }
}

/// mc-15: a file marker must take only itself with it.
final class FileMarkerStrippingTests: XCTestCase {

    private func paragraphs(_ blocks: [ContentBlock]) -> [String] {
        blocks.compactMap { if case .paragraph(let t) = $0.type { return t } else { return nil } }
    }

    /// A marker alone still disappears entirely — the sentinel is not prose.
    func testAMarkerOnItsOwnIsStillConsumedWhole() {
        let blocks = parseMarkdown("--- Start of file: Notes.swift ---")
        XCTAssertTrue(paragraphs(blocks).isEmpty,
                      "a bare marker renders nothing — got \(blocks.map { "\($0.type)" })")
    }

    /// ⚠️ THE REGRESSION GUARD. The injected marker is followed by content with NO blank line, so
    /// cmark parses the two as ONE paragraph — the common shape. The whole node used to be
    /// discarded, silently taking the file's first lines with it.
    /// Mutation that must kill this: make `consumedFileMarker` `return` the node again.
    func testContentMergedWithTheMarkerSurvives() {
        let blocks = parseMarkdown("--- Start of file: Notes.swift ---\nthe first real line\nand a second")
        let text = paragraphs(blocks).joined(separator: "\n")
        XCTAssertTrue(text.contains("the first real line"), "file content must not vanish: \(text)")
        XCTAssertTrue(text.contains("and a second"))
        XCTAssertFalse(text.contains("Start of file:"), "…but the sentinel itself is still hidden")
    }

    /// ⚠️ The claim must still be applied when content survives, or the following fence loses its
    /// filename badge — a worse outcome than losing the prose, and the reason this isn't a plain
    /// "fall through when there's other text".
    func testTheFilenameClaimStillReachesTheFollowingFence() {
        let blocks = parseMarkdown("""
        --- Start of file: Notes.swift ---
        some prose

        ```swift
        let a = 1
        ```
        """)
        let named = blocks.compactMap { block -> String? in
            if case .code(_, _, let fileName) = block.type { return fileName }
            return nil
        }
        XCTAssertEqual(named.first ?? nil, "Notes.swift",
                       "the fence must still be badged even though the paragraph rendered")
    }

    /// The End marker's branch is a loose `contains`, so prose that merely MENTIONS it used to
    /// vanish too.
    func testProseMentioningTheEndMarkerSurvives() {
        let blocks = parseMarkdown("I looked for the --- End of file: marker and found it")
        let text = paragraphs(blocks).joined()
        XCTAssertTrue(text.contains("I looked for the"), "prose must survive: \(text)")
    }

    /// ⚠️ The captured filename is what the rest of the app LINKS BY, so the marker text must not
    /// be normalised before the capture. A backslash is a legal macOS filename character, and a
    /// blanket `replacingOccurrences(of: "\\", with: "")` added during mc-15 silently turned
    /// `back\slash.txt` into `backslash.txt`. Mutation that must kill this: reinstate that strip.
    func testAFilenameContainingABackslashIsCapturedVerbatim() {
        let blocks = parseMarkdown(#"""
        --- Start of file: back\slash.txt ---

        ```swift
        let a = 1
        ```
        """#)
        let named = blocks.compactMap { block -> String? in
            if case .code(_, _, let fileName) = block.type { return fileName }
            return nil
        }
        XCTAssertEqual(named.first ?? nil, #"back\slash.txt"#,
                       "the filename must reach the fence exactly as the marker spelled it")
    }

    /// Control: ordinary prose is untouched.
    func testOrdinaryProseIsUnaffected() {
        let blocks = parseMarkdown("Just a normal paragraph.")
        XCTAssertEqual(paragraphs(blocks).first, "Just a normal paragraph.")
    }
}

/// ⚠️ The cold read caught this: the first vm-6 fix was NOT idempotent.
@MainActor
final class EdgeWhitespaceIdempotenceTests: XCTestCase {

    private func apply(_ code: String, baseline: String) -> String {
        ChatHistoryViewModel.contentToApply(snippetCode: code, preservingEdgeWhitespaceOf: baseline)
    }

    /// ⚠️ THE REGRESSION GUARD for the fix's own regression. The real save loop holds the BUFFER
    /// fixed (the user's text) while the DISK becomes whatever was last written — so a helper that
    /// is not idempotent grows the file on every ⌘S, and the drift guard cannot see it because it
    /// compares both sides trimmed. Measured before the fix: \n\n\n, \n\n\n\n, \n\n\n\n\n …
    /// Mutation that must kill this: restore `!out.hasSuffix(trail)`.
    func testRepeatedSavesOfAnUnchangedBufferDoNotGrowTheFile() {
        let buffer = "hello\n"          // the user typed a trailing newline
        var disk = "hello\n\n"          // the file has a blank line at EOF
        var seen: [String] = []
        for _ in 0..<6 { disk = apply(buffer, baseline: disk); seen.append(disk) }
        XCTAssertEqual(Set(seen).count, 1,
                       "every save must produce the same bytes — got \(seen.map(\.debugDescription))")
    }

    /// The same on the LEADING edge, which had this flaw before the session touched it.
    func testRepeatedSavesDoNotGrowTheLeadingEdge() {
        let buffer = " x"
        var disk = "  x"
        var seen: [String] = []
        for _ in 0..<6 { disk = apply(buffer, baseline: disk); seen.append(disk) }
        XCTAssertEqual(Set(seen).count, 1, "got \(seen.map(\.debugDescription))")
    }

    /// …and the restore still WORKS for the case it exists for: a viewer-trimmed buffer.
    func testATrimmedBufferStillGetsItsEdgesBack() {
        XCTAssertEqual(apply("hello", baseline: "\n  hello\n\n"), "\n  hello\n\n")
        // stable under repetition too
        XCTAssertEqual(apply("hello", baseline: apply("hello", baseline: "\n  hello\n\n")),
                       "\n  hello\n\n")
    }
}

/// tc-2's executor half. The chip tests hand-feed `preWriteContent`/`postWriteContent`, so they
/// cannot notice that the EXECUTOR never captures them — which was half of the original defect.
final class SnapshotToolContractDriftTests: XCTestCase {

    /// ⚠️ THE REGRESSION GUARD. Every tool that gets a viewer chip must also get a pre-write
    /// snapshot, or the chip is an affordance with no data behind it. `read_file` is the one
    /// deliberate exception — it is chip-eligible to offer "open this file", and it mutates
    /// nothing, so there is nothing to snapshot.
    /// Mutation that must kill this: remove `create_file` from either set.
    func testEveryChipEligibleWriteToolAlsoCapturesAPreSnapshot() {
        let chipWrites = TimelineFileViewerAction.chipEligibleToolsForTesting.subtracting(["read_file"])
        let missing = chipWrites.subtracting(SnapshotToolContract.preSnapshot)
        XCTAssertTrue(missing.isEmpty,
                      "these render a diff chip but the executor captures no baseline for them: \(missing.sorted())")
    }

    /// …and the reverse: a snapshot nothing renders is a file read for nothing.
    func testEverySnapshottedToolIsChipEligible() {
        let orphaned = SnapshotToolContract.preSnapshot
            .subtracting(TimelineFileViewerAction.chipEligibleToolsForTesting)
        XCTAssertTrue(orphaned.isEmpty,
                      "the executor snapshots these but no chip consumes them: \(orphaned.sorted())")
    }

    /// The edit family carries find/replace strings only, so its post-state exists nowhere but on
    /// disk — every one of them needs the read-back, and nothing else should pay for one.
    func testOnlyTheEditFamilyTakesAPostSnapshot() {
        XCTAssertEqual(SnapshotToolContract.postSnapshot,
                       ["edit_code_single", "edit_code_batch", "edit_code"],
                       "a tool whose params carry the full post-state must not pay for a read-back")
        XCTAssertTrue(SnapshotToolContract.postSnapshot.isSubset(of: SnapshotToolContract.preSnapshot),
                      "a post-snapshot without a pre-snapshot cannot produce a diff")
    }

    // MARK: - [CR52/CR59] The fourth leg — live Code Viewer tabs

    /// ⚠️ THE LEG THAT WAS MISSING. The two guards above bind `preSnapshot` ↔ `chipEligibleTools`
    /// in both directions. `AgentLiveWriteEvent.liveWriteToolNames` — the set that decides whether
    /// a write gets a LIVE tab at all — was bound to nothing, and `create_file` was absent from it
    /// while present in all three siblings, from the day the set was introduced.
    ///
    /// ⚠️ The invariant is DERIVED, not restated. Asserting the four names as a literal would just
    /// repeat the line it guards and would have passed on the day the omission shipped — the
    /// "drift tests from the invariant, not the implementation" trap. A live tab shows the PROPOSED
    /// FILE, so it exists exactly for the mutating tools whose params already carry the full
    /// post-state: `preSnapshot − postSnapshot`. That is verbatim what `AgentLiveWriteEvent`'s own
    /// doc declares ("FULL-CONTENT writers only"), and `testOnlyTheEditFamilyTakesAPostSnapshot`
    /// above is what keeps the subtraction meaningful.
    ///
    /// ⚠️ `read_file` is NOT subtracted here, unlike the chip leg. It is chip-eligible but is not
    /// in `preSnapshot` at all — it mutates nothing — so the subtraction already excludes it.
    /// Mutation that must kill this: remove `"create_file"` from `liveWriteToolNames`.
    func testEveryFullContentWriterGetsALiveTab() {
        let fullContentWriters = SnapshotToolContract.preSnapshot
            .subtracting(SnapshotToolContract.postSnapshot)
        let missing = fullContentWriters.subtracting(AgentLiveWriteEvent.liveWriteToolNames)
        XCTAssertTrue(missing.isEmpty,
                      "these carry the whole file in their params but open no live tab, so the write happens with no viewer, no pill and no banner: \(missing.sorted())")
    }

    /// …and the reverse: a live tab for a tool the executor never snapshots has no baseline, so its
    /// rejected state could never be reconciled and ⌘S on it would be refused as drift forever.
    /// Mutation that must kill this: add a name to `liveWriteToolNames` that is not in `preSnapshot`
    /// (e.g. `"read_file"`, or an edit-family name).
    func testEveryLiveTabToolIsAFullContentWriterTheExecutorSnapshots() {
        let fullContentWriters = SnapshotToolContract.preSnapshot
            .subtracting(SnapshotToolContract.postSnapshot)
        let unbacked = AgentLiveWriteEvent.liveWriteToolNames.subtracting(fullContentWriters)
        XCTAssertTrue(unbacked.isEmpty,
                      "these open a live tab with no pre-write snapshot behind it, or carry only find/replace params: \(unbacked.sorted())")
    }
}

// MARK: - Thoughts & Reasoning Visibility Toggle Tests

final class TimelineThoughtsToggleTests: XCTestCase {

    func testAppSettingKeyConstant() {
        XCTAssertEqual(AppSettings.showTimelineThoughtsKey, "showTimelineThoughts")
    }

    func testFilterVisibleNodesWhenThoughtsShown() {
        let t1 = TimelineNode.thought(id: UUID(), text: "Step 1 — Thinking")
        let a1 = TimelineNode.action(.toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "ok", isSuccess: true, isExecuting: false)))
        let nodes: [TimelineNode] = [t1, a1]

        let visible = AgentTimelineView.filterVisibleNodes(nodes, showThoughts: true)
        XCTAssertEqual(visible.count, 2)
    }

    func testFilterVisibleNodesWhenThoughtsHidden() {
        let t1 = TimelineNode.thought(id: UUID(), text: "Step 1 — Thinking")
        let a1 = TimelineNode.action(.toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "ok", isSuccess: true, isExecuting: false)))
        let t2 = TimelineNode.thought(id: UUID(), text: "Step 2 — Thinking again")
        let nodes: [TimelineNode] = [t1, a1, t2]

        let visible = AgentTimelineView.filterVisibleNodes(nodes, showThoughts: false)
        XCTAssertEqual(visible.count, 1)
        if case .action = visible[0] {
            // expected
        } else {
            XCTFail("Expected tool action node to remain")
        }
    }

    func testFilterVisibleNodesFallbackWhenOnlyThoughts() {
        let t1 = TimelineNode.thought(id: UUID(), text: "Thinking 1")
        let t2 = TimelineNode.thought(id: UUID(), text: "Thinking 2")
        let nodes: [TimelineNode] = [t1, t2]

        // When only thoughts exist, do not return an empty list: keep thoughts visible as fallback.
        let visible = AgentTimelineView.filterVisibleNodes(nodes, showThoughts: false)
        XCTAssertEqual(visible.count, 2)
    }

    func testSummaryTitleWhenThoughtsHidden() {
        let summary: (status: AgentTimelineView.TimelineSummaryStatus, failedTools: Int, toolCount: Int) = (.succeeded, 0, 3)
        let title = AgentTimelineView.summaryTitle(
            nodesCount: 8,
            summary: summary,
            terminalOutcome: .completed,
            isStreaming: false,
            showThoughts: false
        )
        XCTAssertEqual(title, "Executed 3 tools")
    }

    func testSummaryTitleWhenThoughtsShown() {
        let summary: (status: AgentTimelineView.TimelineSummaryStatus, failedTools: Int, toolCount: Int) = (.succeeded, 0, 3)
        let title = AgentTimelineView.summaryTitle(
            nodesCount: 8,
            summary: summary,
            terminalOutcome: .completed,
            isStreaming: false,
            showThoughts: true
        )
        XCTAssertEqual(title, "Executed 8 steps (3 tools)")
    }

    func testSummaryTitleWithFailedToolsWhenThoughtsHidden() {
        let summary: (status: AgentTimelineView.TimelineSummaryStatus, failedTools: Int, toolCount: Int) = (.degraded, 1, 3)
        let title = AgentTimelineView.summaryTitle(
            nodesCount: 8,
            summary: summary,
            terminalOutcome: .completed,
            isStreaming: false,
            showThoughts: false
        )
        XCTAssertEqual(title, "Executed 3 tools · 1 failed")
    }

    func testSummaryTitleZeroToolsFallsBackToThoughtSteps() {
        let summary: (status: AgentTimelineView.TimelineSummaryStatus, failedTools: Int, toolCount: Int) = (.succeeded, 0, 0)
        let title = AgentTimelineView.summaryTitle(
            nodesCount: 2,
            summary: summary,
            terminalOutcome: .completed,
            isStreaming: false,
            showThoughts: false
        )
        XCTAssertEqual(title, "Thought for 2 steps")
    }
}
