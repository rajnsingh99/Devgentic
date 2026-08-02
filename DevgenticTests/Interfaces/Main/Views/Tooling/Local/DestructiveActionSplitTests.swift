//
//  DestructiveActionSplitTests.swift
//  DevgenticTests
//
//  Four tools bundled frequent, harmless reads with irreversible actions behind one `action`
//  argument: `manage_calendar` (read/search/create + delete), `manage_reminders` (read/create/
//  complete + delete), `manage_processes` (list_top + kill), `finder_tags` (read/add/remove/search
//  + set, which discards every existing tag).
//
//  A tool carries exactly ONE `requiresConfirmation`, so that single setting had to cover both
//  halves. Neither option it left was acceptable: prompt on every read and the user learns to
//  approve without looking — which is how the delete gets approved — or prompt on none and the
//  delete lands silently. The user could not express "ask before destroying, not before looking".
//
//  Splitting is the codebase's own established answer to this shape (`create_file` →
//  `create_new_file`/`overwrite_file`). These tests pin the three properties the split has to
//  have, because each can regress independently:
//    1. the destructive action is GONE from the multiplexer (not merely discouraged),
//    2. the survivors still do their non-destructive work,
//    3. the new tools are classified `.destructive`, so the banner does not present a SIGKILL
//       with the same pencil icon as a rename.
//

import XCTest
@testable import devgentic

final class DestructiveActionSplitTests: XCTestCase {

    // MARK: - The destructive action no longer runs from the multiplexer

    /// Deliberately an explicit refusal that NAMES the new tool, not an "unknown action" error.
    /// A model that has just been told `delete` exists (by an older prompt, a cached schema, or
    /// its own priors) needs to be told where it went, or it will retry the same call.
    func testCalendarDeleteIsRefusedAndPointsAtTheNewTool() async throws {
        let out = try await runCalendar(action: "delete", eventID: "some-event-id")
        XCTAssertTrue(out.contains("delete_calendar_event"), out)
        XCTAssertTrue(out.hasPrefix("Error:"), "must classify as a tool failure: \(out)")
    }

    func testReminderDeleteIsRefusedAndPointsAtTheNewTool() async throws {
        let json = try JSONEncoder().encode(["action": "delete", "reminder_title": "anything"])
        let args = try JSONDecoder().decode(ManageRemindersTool.Arguments.self, from: json)
        let out = try await ManageRemindersTool().call(arguments: args)
        XCTAssertTrue(out.contains("delete_reminder"), out)
        XCTAssertTrue(out.hasPrefix("Error:"), out)
    }

    func testProcessKillIsRefusedAndPointsAtTheNewTool() async throws {
        let json = try JSONEncoder().encode(["action": "kill", "target": "Finder"])
        let args = try JSONDecoder().decode(ManageProcessesTool.Arguments.self, from: json)
        let out = try await ManageProcessesTool().call(arguments: args)
        XCTAssertTrue(out.contains("kill_process"), out)
        XCTAssertTrue(out.hasPrefix("Error:"), out)
        XCTAssertFalse(out.contains("Result:"), "it must not fall through and run anything: \(out)")
    }

    func testFinderTagsSetIsRefusedAndPointsAtTheNewTool() async throws {
        let json = try JSONEncoder().encode(["action": "set", "path": "/tmp/whatever"] as [String: String])
        let args = try JSONDecoder().decode(FinderTagsTool.Arguments.self, from: json)
        let out = try await FinderTagsTool().call(arguments: args)
        XCTAssertTrue(out.contains("replace_finder_tags"), out)
        XCTAssertTrue(out.hasPrefix("Error:"), out)
    }

    // MARK: - The survivors still work

    /// A security fix that breaks the tool is not a fix. `list_top` is the whole remaining job of
    /// `manage_processes`, and it must still run — including when `action` is omitted entirely,
    /// since it is now the only thing the tool does.
    ///
    /// Asserts the CONTENT rather than a caption. This previously pinned `hasPrefix("Result:")`,
    /// which broke when the caption changed for an unrelated reason (2026-07-31: the tool stopped
    /// piping `ps` through `sort | head`, because `sort` was ordering the column header in with
    /// the data and `head` then cutting it — so the model received four unlabelled numeric
    /// columns and could not tell %CPU from %MEM). The labelled header is the thing worth
    /// pinning, so this now checks for it.
    func testManageProcessesStillListsProcesses() async throws {
        for payload in [["action": "list_top"], [:]] {
            let json = try JSONEncoder().encode(payload)
            let args = try JSONDecoder().decode(ManageProcessesTool.Arguments.self, from: json)
            let out = try await ManageProcessesTool().call(arguments: args)

            XCTAssertFalse(out.hasPrefix("Error"), "listing must still work for \(payload): \(out)")
            XCTAssertTrue(out.contains("PID"), "the column header must survive for \(payload): \(out)")
            XCTAssertTrue(out.contains("%CPU"), "an unlabelled %CPU column cannot be told from %MEM: \(out)")
        }
    }

    /// `add`/`remove` are relative — they preserve tags they do not name. That is exactly what
    /// distinguishes them from the `set` that was split out, so it is worth pinning behaviourally
    /// rather than trusting the description.
    func testFinderTagsAddAndRemovePreserveOtherTags() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tag-split-\(UUID().uuidString).txt")
        try "x".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }

        _ = try await runTags(action: "add", path: scratch.path, tags: ["Alpha", "Beta"])
        _ = try await runTags(action: "remove", path: scratch.path, tags: ["Alpha"])

        let remaining = (try? scratch.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        XCTAssertTrue(remaining.contains("Beta"), "remove must not disturb tags it was not given: \(remaining)")
        XCTAssertFalse(remaining.contains("Alpha"), remaining.description)
    }

    /// The behaviour that earned `set` its own tool: it discards everything it was not given.
    /// Pinned here so the split tool's semantics are documented by a test rather than a comment,
    /// and so the "was / now" reporting the user relies on to see what was lost keeps working.
    func testReplaceFinderTagsDiscardsExistingTagsAndReportsThem() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tag-replace-\(UUID().uuidString).txt")
        try "x".write(to: scratch, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scratch) }

        _ = try await runTags(action: "add", path: scratch.path, tags: ["Keep", "Lose"])

        let replaceArgs = try JSONDecoder().decode(
            ReplaceFinderTagsTool.Arguments.self,
            from: Data(#"{"path":"\#(scratch.path)","tags":["Only"]}"#.utf8)
        )
        let out = try await ReplaceFinderTagsTool().call(arguments: replaceArgs)

        let now = (try? scratch.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        XCTAssertEqual(Set(now), ["Only"], "set must replace, not merge: \(now)")
        XCTAssertTrue(out.contains("Keep"), "the user must be told what was discarded: \(out)")
    }

    // MARK: - The new tools are labelled as what they are

    /// Before the split all four multiplexers fell through to `.moderate` — "Modifies", pencil
    /// icon — so a `kill -9` was presented in the same register as renaming a file.
    func testTheSplitToolsClassifyDestructive() {
        for tool in ["delete_calendar_event", "delete_reminder", "kill_process", "replace_finder_tags"] {
            XCTAssertEqual(HITLRiskTier.classify(toolName: tool), .destructive, tool)
        }
    }

    /// And the survivors are NOT destructive — the point was to separate them, so a read-only
    /// half inheriting the scary label would defeat it just as thoroughly.
    func testTheSurvivingMultiplexersAreNotDestructive() {
        for tool in ["manage_calendar", "manage_reminders", "manage_processes", "finder_tags"] {
            XCTAssertNotEqual(HITLRiskTier.classify(toolName: tool), .destructive, tool)
        }
    }

    /// Splitting is about confirmation granularity, not arbitrary code execution — these run
    /// bounded, named operations and must stay out of the shell-equivalent set (§3.5, invariant 14).
    func testSplitToolsAreNotArbitraryCodeExecution() {
        for tool in ["delete_calendar_event", "delete_reminder", "kill_process", "replace_finder_tags"] {
            XCTAssertFalse(ToolCapability.executesArbitraryCode(tool), tool)
        }
    }

    // MARK: - Helpers

    private func runCalendar(action: String, eventID: String) async throws -> String {
        let json = Data(#"{"action":"\#(action)","event_id":"\#(eventID)"}"#.utf8)
        let args = try JSONDecoder().decode(ManageCalendarTool.Arguments.self, from: json)
        return try await ManageCalendarTool().call(arguments: args)
    }

    private func runTags(action: String, path: String, tags: [String]) async throws -> String {
        let tagList = tags.map { "\"\($0)\"" }.joined(separator: ",")
        let json = Data(#"{"action":"\#(action)","path":"\#(path)","tags":[\#(tagList)]}"#.utf8)
        let args = try JSONDecoder().decode(FinderTagsTool.Arguments.self, from: json)
        return try await FinderTagsTool().call(arguments: args)
    }

    // MARK: - kill_process pid validation (audit fix 2026-07-31)

    /// ⚠️ A non-positive pid is not a process. `kill -9 -- -1` signals EVERY process the user can
    /// signal — the whole login session — and `0` signals this app's own process group. The `--`
    /// added for option-injection safety is exactly what makes `-1` parse as a target rather than
    /// a malformed signal, so the separator and this guard belong together.
    ///
    /// Deliberately asserted at the ARGUMENT layer, never executed.
    func testKillProcessRefusesNonPositivePids() async throws {
        for target in ["-1", "0", "-9", "-12345"] {
            let json = Data(#"{"target":"\#(target)"}"#.utf8)
            let args = try JSONDecoder().decode(KillProcessTool.Arguments.self, from: json)
            let out = try await KillProcessTool().call(arguments: args)
            XCTAssertTrue(out.hasPrefix("Error:"), "pid \(target) must be refused, got: \(out)")
            XCTAssertTrue(out.contains("positive"), "the refusal should say why: \(out)")
        }
    }

    /// A process NAME beginning with `-` is still allowed through to killall — that is what the
    /// `--` separator is for, and it is not a pid so the guard must not catch it.
    func testKillProcessStillAcceptsNamesAndPositivePids() throws {
        for target in ["1234", "Finder", "-weird-name"] {
            let json = Data(#"{"target":"\#(target)"}"#.utf8)
            XCTAssertNoThrow(try JSONDecoder().decode(KillProcessTool.Arguments.self, from: json),
                             "\(target) should decode")
        }
    }
}
