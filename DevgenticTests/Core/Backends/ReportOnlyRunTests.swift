// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReportOnlyRunTests.swift
//  DevgenticTests
//
//  Tier 3 wakes the agent when a background task finishes. That run is UNATTENDED — not typed,
//  nothing waiting on it, the user possibly in another app — so it may answer but must not act.
//

import XCTest
@testable import devgentic

final class ReportOnlyRunTests: XCTestCase {

    private func tool(_ name: String) -> Tool {
        Tool(name: name, description: "", sourceId: UUID(),
             parameters: ToolParameters(type: "object", properties: [:], required: []))
    }

    /// ⚠️ FALSE by default. The opposite default would silently disarm the toolset for any run that
    /// forgot to declare itself attended — a safe-looking default that removes a capability
    /// without anyone noticing.
    func testAnOrdinaryRunIsUnaffected() {
        XCTAssertFalse(ReportOnlyRun.isActive)
        let tools = [tool("read_file"), tool("run_command")]
        XCTAssertEqual(ReportOnlyRun.allowedProfileTools(tools).map(\.name), ["read_file", "run_command"])
    }

    func testAReportOnlyRunGetsNoProfileTools() {
        ReportOnlyRun.$isActive.withValue(true) {
            let tools = [tool("read_file"), tool("run_command"), tool("overwrite_file")]
            XCTAssertTrue(ReportOnlyRun.allowedProfileTools(tools).isEmpty,
                          "an unattended run kept tools it could act with")
        }
    }

    /// ⚠️ THE POINT OF THE CONSTRAINT, stated as a test rather than a comment. A model that wakes
    /// to a failed build and still holds `overwrite_file` will start editing while nobody is
    /// watching — against the user's own API key.
    func testNoWritingToolSurvivesAReportOnlyRun() {
        let dangerous = ["overwrite_file", "edit_code_single", "create_new_file",
                         "run_command", "start_background_task", "delete_file"]
        ReportOnlyRun.$isActive.withValue(true) {
            let allowed = Set(ReportOnlyRun.allowedProfileTools(dangerous.map(tool)).map(\.name))
            for name in dangerous {
                XCTAssertFalse(allowed.contains(name), "\(name) survived into an unattended run")
            }
        }
    }

    /// The task-local must not leak past its scope, or one woken run would disarm every later
    /// attended turn on the same task tree.
    func testTheFlagIsScopedToItsRun() {
        ReportOnlyRun.$isActive.withValue(true) {
            XCTAssertTrue(ReportOnlyRun.isActive)
        }
        XCTAssertFalse(ReportOnlyRun.isActive, "the constraint outlived its run")
    }

    /// ⚠️ `final_answer` is INJECTED by `AgentConnect`, never a profile tool, so emptying the
    /// profile list leaves the one call the run exists to make. If this ever stops being true,
    /// report-only runs become unable to answer at all — silently, because they would simply
    /// produce nothing.
    func testFinalAnswerIsNotAProfileToolAndSoSurvives() {
        XCTAssertTrue(NativeToolCatalog.injectedToolNames.contains("final_answer"),
                      "final_answer moved out of the injected set — a report-only run can no "
                      + "longer answer, because stripping profile tools now strips it too")
        XCTAssertNil(NativeToolCatalog.entry(named: "final_answer"),
                     "final_answer became a catalogue tool; see above")
    }

    /// The constraint is applied where the loadout is ASSEMBLED, not at one caller — otherwise it
    /// is honoured on one pipeline and ignored on the other.
    func testBothPipelinesApplyTheConstraint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = "Devgentic/Core/Backends/TextGen/AgentConnect.swift"
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("AgentConnect.swift not reachable — running outside a checkout")
        }
        let guarded = source.components(separatedBy: "profileTools: ReportOnlyRun.allowedProfileTools(").count - 1
        let raw = source.components(separatedBy: "profileTools: rawTools").count - 1
        XCTAssertEqual(guarded, 2, "a pipeline assembles its loadout without the constraint")
        XCTAssertEqual(raw, 0, "an unconstrained `profileTools: rawTools` came back")
    }
}
