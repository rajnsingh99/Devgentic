// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  A finished run reaches a ChatOps chat with its OUTCOME, not just its text. A run stopped by a time
//  limit or by Stop is stamped and cancelled — no error card is written — so its content is only the
//  partial text it had produced; the remote chat used to receive that as a complete answer.
//

import XCTest
@testable import devgentic

final class RemoteMirrorOutcomeTests: XCTestCase {

    private func text(_ body: String, _ outcome: ExecutionOutcome?, _ reason: String? = nil) -> String {
        RemoteMirrorService.finalResponse(body: body, outcome: outcome, reason: reason)
    }

    // MARK: - Time-out and stop

    func testATimedOutRunStatesItAfterItsPartialText() {
        let reason = ActiveStreamManager.globalCeilingMessage(limit: 90 * 60)
        XCTAssertEqual(text("Here is half", .timedOut, reason),
                       "Here is half\n\n⏱ \(reason) The text above is what it had written so far.")
    }

    func testATimedOutRunWithNoTextStillSaysSo() {
        XCTAssertEqual(text("", .timedOut, "Run stopped: limit."), "⏱ Run stopped: limit.",
                       "it used to send nothing at all, or \"Response complete.\"")
        XCTAssertEqual(text("", .timedOut, "  "), "⏱ The run timed out before it finished.")
    }

    func testAStoppedRunStatesIt() {
        XCTAssertEqual(text("Partial", .cancelled, "Cancelled by user"),
                       "Partial\n\n⏹ Cancelled by user. The text above is what it had written so far.")
        XCTAssertEqual(text("", .cancelled, nil), "⏹ The run was stopped before it finished.")
    }

    /// The line continues after the reason, so the reason must end its sentence — the Stop reason
    /// "Cancelled by user" used to run straight into "The text above…". One already punctuated is
    /// left alone.
    func testTheReasonAlwaysEndsItsSentence() {
        XCTAssertEqual(text("", .cancelled, "Cancelled by user"), "⏹ Cancelled by user.")
        XCTAssertEqual(text("", .timedOut, "Stopped. Really!"), "⏱ Stopped. Really!")
        XCTAssertEqual(text("", .timedOut, "Was it slow?"), "⏱ Was it slow?")
    }

    // MARK: - Failure

    func testAFailedRunWithProseSaysItFailed() {
        XCTAssertEqual(text("Some prose", .failed, "Tool crashed"),
                       "Some prose\n\n⚠️ The run failed before it finished: Tool crashed. The text above is what it had written so far.")
    }

    /// The error card arrives in a later pass and carries the sanitised details and a suggestion —
    /// claiming the send with the bare reason first would suppress it.
    func testAFailedRunWithNoProseWaitsForItsErrorCard() {
        XCTAssertEqual(text("", .failed, "Tool crashed"), "")
    }

    // MARK: - Normal endings are untouched

    func testCompletedRunsAreUnchanged() {
        XCTAssertEqual(text("The answer", .completed, "ignored"), "The answer")
        XCTAssertEqual(text("The answer", .completedWithWarnings, nil), "The answer")
        XCTAssertEqual(text("The answer", nil, nil), "The answer")
    }

    /// The reason leaves the Mac for a third-party service, like error details do.
    func testTheReasonIsSanitised() {
        let home = NSHomeDirectory()
        let out = text("", .timedOut, "Stopped while writing \(home)/secret/notes.txt")
        XCTAssertFalse(out.contains(home), "a home path must not reach the remote chat: \(out)")
    }
}

/// ⚠️ WIRING — the helper is worth nothing if the final-response branch stops calling it.
final class RemoteMirrorOutcomeWiringTests: XCTestCase {

    func testTheFinalResponseCarriesTheOutcome() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Devgentic").path) else {
            throw XCTSkip("sources not reachable — running outside a checkout")
        }
        let code = try String(contentsOf: repoRoot.appendingPathComponent("Devgentic/ChatOps/Services/RemoteMirrorService.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let pattern = #"if annotatesOutcome \{\s*let annotated = Self\.finalResponse\(body: responseText, outcome: message\.terminalOutcome,\s*reason: message\.terminalReason\)[\s\S]{0,800}?responseText = annotated\s*\}\s*guard !responseText\.isEmpty else \{ return \}"#
        XCTAssertNotNil(code.range(of: pattern, options: .regularExpression),
                        "the outcome must be applied BEFORE the emptiness check and the send-once claim")
        // The two contents that already say how the run ended (or are not replies) opt out.
        XCTAssertNotNil(code.range(of: #"responseText = lines\.joined\(separator: "\\n\\n"\)\s*annotatesOutcome = false"#, options: .regularExpression))
        XCTAssertNotNil(code.range(of: #"case \.checkpoint:[\s\S]{0,600}?responseText = ""\s*annotatesOutcome = false"#, options: .regularExpression))
    }
}
