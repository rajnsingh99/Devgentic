// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WokenRunAttendanceTests.swift
//  DevgenticTests
//
//  A run that a FINISHED PROCESS started has nobody watching it, and the codebase already has one
//  predicate for that: `WorkflowRunAttendance.canReachAHuman`.
//
//  ⚠️⚠️ THE EXPOSURE IS NOT THEORETICAL, and `MessageSource.backgroundTask` alone does not close it.
//  `SessionToolApprovals` keys its BLANKET autonomous grant on `(conversation, origin)`, so a
//  surface boundary protects that one. But the per-tool "Allow for this chat" grant is keyed on
//  `Scope(conversationID:nodeID:)` with NO origin — its only guard is `canReachAHuman`. Left at the
//  `true` default, a build finishing overnight would spend an approval the user granted while
//  sitting at the keyboard, with no banner on any surface.
//
//  The other two readers are `ToolExecutionLoop`'s WF-SE11 arms: with nobody reachable, `ask_user`
//  and a tool confirmation are REFUSED with an honest observation instead of parking indefinitely
//  until a run deadline cancels everything.
//

import XCTest
@testable import devgentic

final class WokenRunAttendanceTests: XCTestCase {

    // MARK: - The predicate

    func testABackgroundTaskRunCannotReachAHuman() {
        WorkflowRunAttendance.$isAttended.withValue(false) {
            XCTAssertFalse(WorkflowRunAttendance.canReachAHuman,
                           "a woken run with no remote responder must not be treated as answerable")
        }
    }

    /// ⚠️ `isAttended` alone is NOT the question. A ChatOps run also binds it false, and a human IS
    /// reachable there — `RemoteMirrorService` mirrors confirmations with working Approve/Deny.
    /// Keying any refusal on `isAttended` alone deleted that shipped flow once already (WF-SE11).
    func testARemoteResponderStillCountsAsReachable() {
        WorkflowRunAttendance.$isAttended.withValue(false) {
            WorkflowRunAttendance.$hasRemoteResponder.withValue(true) {
                XCTAssertTrue(WorkflowRunAttendance.canReachAHuman,
                              "a ChatOps run has a human who can tap Approve; refusing there "
                              + "removes a shipped capability with no remedy")
            }
        }
    }

    /// The grant gate, exercised through the real actor rather than a transcription of its rule.
    func testAStandingGrantIsNotServedToAnUnattendedRun() async {
        let defaults = UserDefaults(suiteName: "woken-attendance-\(UUID().uuidString)")!
        let approvals = SessionToolApprovals(defaults: defaults)
        let conversation = UUID()

        // ⚠️ `.moderate`, not a shell tool. `allow` REFUSES a durable grant for anything
        // `.destructive` outright, so `run_command` can never reach this gate — using it would
        // make the fixture store nothing and the test pass for the wrong reason.
        await approvals.allow(toolName: "overwrite_file", risk: .moderate, conversationID: conversation)

        let attended = await WorkflowRunAttendance.$isAttended.withValue(true) {
            await approvals.isAllowed(toolName: "overwrite_file", conversationID: conversation)
        }
        XCTAssertTrue(attended, "bad fixture — the grant was never stored")

        let unattended = await WorkflowRunAttendance.$isAttended.withValue(false) {
            await approvals.isAllowed(toolName: "overwrite_file", conversationID: conversation)
        }
        XCTAssertFalse(unattended,
                       "a run nobody can answer was served a grant the user gave on a live banner")
    }

    // MARK: - The binding

    /// ⚠️ Bound in `startMessageStream`, NOT at whatever eventually triggers a woken run — the same
    /// argument `$origin` makes. Without this the trigger has to remember, and "a new surface cannot
    /// forget" is the property the origin binding exists to provide.
    func testTheStreamBindsUnattendedForABackgroundTaskSource() throws {
        let body = try startMessageStreamBody()
        guard let compare = body.range(of: "userMessage.messageSource == .backgroundTask") else {
            return XCTFail("a woken run is not marked unattended: it would inherit the `true` "
                           + "default and spend standing grants with nobody watching")
        }
        guard let bind = body.range(of: "WorkflowRunAttendance.$isAttended.withValue") else {
            return XCTFail("`$isAttended` is never bound here")
        }
        XCTAssertLessThan(compare.lowerBound, bind.lowerBound,
                          "attendance must be decided before it is bound")
    }

    /// ⚠️ ADDITIVE. Deriving attendance from the source for ALL sources is the obvious version and
    /// is wrong: ChatOps binds `isAttended = false` + `hasRemoteResponder = true` at its call site,
    /// and the scheduler binds false at its own. Overriding them here would flip a ChatOps run back
    /// to attended and delete the Router's first-match behaviour (WF-EX5), whose arbitration park
    /// has no deadline to end it.
    func testEveryOtherSourceKeepsWhateverItsCallerBound() throws {
        let body = try startMessageStreamBody()
        XCTAssertTrue(body.contains(": WorkflowRunAttendance.isAttended"),
                      "the non-background branch must re-bind the CALLER's value. Hard-coding "
                      + "`true` there would override ChatOps and the scheduler, both of which bind "
                      + "false around this call")
    }

    func testTheExistingUnattendedCallersAreStillBinding() throws {
        for (path, who) in [("Devgentic/Interfaces/Main/SchedulerCoordinator.swift", "the scheduler"),
                            ("Devgentic/Interfaces/Main/MessagingCoordinator.swift", "ChatOps")] {
            let source = try sourceFile(path)
            XCTAssertTrue(source.contains("WorkflowRunAttendance.$isAttended.withValue(false)"),
                          "\(who) stopped binding unattended — the stream's own binding is "
                          + "additive and deliberately does not cover it")
        }
    }

    // MARK: - Source access

    private func startMessageStreamBody() throws -> String {
        let source = try sourceFile("Devgentic/Core/Utils/ActiveStreamManager.swift")
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("func startMessageStream(") }) else {
            XCTFail("startMessageStream not found — this guard is checking nothing")
            return ""
        }
        guard let end = lines[start...].firstIndex(where: { $0.contains("activeTasks[agentMessage.id] = streamTask") }) else {
            XCTFail("the stream task assignment moved — this guard is checking nothing")
            return ""
        }
        return lines[start...end]
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return source
    }
}
