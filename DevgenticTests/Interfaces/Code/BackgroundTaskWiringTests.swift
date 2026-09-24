// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskWiringTests.swift
//  DevgenticTests
//
//  ⚠️ THE WIRING, not the policy. `BackgroundProcessRegistryTests` proves the registry behaves;
//  these prove anything actually REACHES it. F2 shipped non-functional with 163 green tests
//  because every one of them tested the policy and none tested the call site.
//
//  Each test here fails if a specific wire is cut: the tool's background branch going back to
//  `/dev/null`, the catalogue dropping the conversation id, the preset not offering the tools, or
//  quit-time teardown being removed.
//

import XCTest
@testable import devgentic

final class BackgroundTaskWiringTests: XCTestCase {

    private let conversation = UUID()

    override func tearDown() {
        BackgroundProcessRegistry.shared.discard(conversationID: conversation)
        super.tearDown()
    }

    private func arguments(_ json: String) throws -> ShellCommandArguments {
        try JSONDecoder().decode(ShellCommandArguments.self, from: Data(json.utf8))
    }

    private func waitForTerminal(_ taskID: String, within seconds: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if BackgroundProcessRegistry.shared
                .snapshot(conversationID: conversation, taskID: taskID)?.status.isTerminal == true { return }
            usleep(20_000)
        }
    }

    // MARK: - batch_command reaches the registry

    /// End to end through the tool. A revert to `FileHandle.nullDevice` + bare `run()` leaves the
    /// registry empty and fails here — which the old code did, silently, for every background call.
    func testBackgroundLaunchRegistersACollectableTask() async throws {
        let tool = StartBackgroundTaskTool(conversationID: conversation)
        let output = try await tool.call(arguments: arguments(
            #"{"command":"echo wired-through","working_directory":"/tmp","background":true}"#))

        XCTAssertTrue(output.contains("bg_1"), "the caller was not given a task id: \(output)")
        XCTAssertFalse(output.contains("PID"),
                       "a pid is not a usable handle — macOS recycles them, and the task id exists "
                       + "so the caller never has to hold one")

        let registered = BackgroundProcessRegistry.shared.snapshots(conversationID: conversation)
        XCTAssertEqual(registered.count, 1, "the background branch did not reach the registry")

        waitForTerminal("bg_1")
        let log = try XCTUnwrap(BackgroundProcessRegistry.shared.readLog(
            conversationID: conversation, taskID: "bg_1"))
        XCTAssertTrue(log.text.contains("wired-through"),
                      "background output was discarded — the /dev/null defect is back")
    }

    /// The bound `batch_command` computed and then dropped on this branch.
    func testTheToolsTimeoutIsAppliedToABackgroundTask() async throws {
        let tool = StartBackgroundTaskTool(conversationID: conversation)
        _ = try await tool.call(arguments: arguments(
            #"{"command":"sleep 30","working_directory":"/tmp","background":true,"timeout_seconds":1}"#))

        waitForTerminal("bg_1")
        XCTAssertEqual(BackgroundProcessRegistry.shared.snapshot(conversationID: conversation, taskID: "bg_1")?.status,
                       .timedOut,
                       "timeout_seconds was accepted and ignored, exactly as it was before")
    }

    /// An unregistered background process has no bound, no collectable output and no owner at
    /// quit. Refusing is the honest outcome; launching anyway would recreate the orphan.
    func testBackgroundIsRefusedWithoutAConversationRatherThanLaunchedUnregistered() async throws {
        let tool = StartBackgroundTaskTool(conversationID: nil)
        let output = try await tool.call(arguments: arguments(
            #"{"command":"echo nope","working_directory":"/tmp","background":true}"#))

        XCTAssertTrue(output.hasPrefix("Error:"), "expected a refusal, got: \(output)")
        XCTAssertTrue(output.contains("foreground"), "the refusal must name the way forward")
    }

    /// ⚠️ REWRITTEN 2026-09-21. This asserted that a foreground command must NOT register, which
    /// was true when only the background path used the registry — and became FALSE the moment
    /// foreground started registering too, so that it could be stopped and cleaned up at quit.
    /// The pin caught a deliberate change, which is what a pin is for; it was updated rather than
    /// deleted, and what it guards now is the distinction that actually still holds.
    ///
    /// Both modes register. What differs is the MODEL-FACING contract: foreground hands back the
    /// output, background hands back a handle. Collapsing that would make the two indistinguishable
    /// to the caller even though one blocks and one does not.
    func testForegroundReturnsOutputWhileBackgroundReturnsAHandle() async throws {
        // ⚠️ `run_command`, not the background tool. A blanket rename during the intent split put
        // the wrong one here and this assertion caught it immediately — which is the point of
        // naming the two contracts rather than toggling between them with a boolean.
        let tool = RunCommandTool(conversationID: conversation)
        let output = try await tool.call(arguments: arguments(
            #"{"command":"echo still-synchronous","working_directory":"/tmp"}"#))

        XCTAssertTrue(output.contains("still-synchronous"),
                      "foreground must return the command's OUTPUT to the caller")
        XCTAssertFalse(output.contains("Started background task"),
                       "foreground must not hand back a task id in place of its result")

        // It is registered — that is what makes it stoppable and quit-safe — and it is finished,
        // because the call blocked until it was.
        let tasks = BackgroundProcessRegistry.shared.snapshots(conversationID: conversation)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertTrue(tasks[0].status.isTerminal,
                      "a foreground call returned while its task was still marked running")
    }

    // MARK: - No tool-side cap (2026-09-24)

    /// ⚠️ The tools used to cut their own output to 8,000 chars / 1,000 lines — whatever the model's
    /// window, and before the DB ever saw it. User decision: no limit below what fits. The tool
    /// returns everything; `ToolResultBudget` fits it to the room the model actually has.
    func testRunCommandReturnsLongOutputWhole() async throws {
        let output = try await RunCommandTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"yes x | head -n 12000","working_directory":"/tmp"}"#))
        XCTAssertGreaterThanOrEqual(output.filter { $0 == "x" }.count, 12_000,
                                    "run_command cut its own output — a tool-side cap is back")
    }

    func testCommandOutputReturnsALongLogWhole() async throws {
        _ = try await StartBackgroundTaskTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"yes x | head -n 12000","working_directory":"/tmp","background":true}"#))
        waitForTerminal("bg_1")

        let read = try await CommandOutputTool(conversationID: conversation)
            .call(arguments: JSONDecoder().decode(CommandOutputTool.Arguments.self,
                                                  from: Data(#"{"task_id":"bg_1"}"#.utf8)))
        XCTAssertGreaterThanOrEqual(read.filter { $0 == "x" }.count, 12_000,
                                    "command_output cut the log itself — a tool-side cap is back")
    }

    // MARK: - The three tools read the same registry

    func testCommandOutputReadsWhatBatchCommandStarted() async throws {
        _ = try await StartBackgroundTaskTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"echo one; echo two","working_directory":"/tmp","background":true}"#))
        waitForTerminal("bg_1")

        let read = try await CommandOutputTool(conversationID: conversation)
            .call(arguments: JSONDecoder().decode(CommandOutputTool.Arguments.self,
                                                  from: Data(#"{"task_id":"bg_1"}"#.utf8)))
        XCTAssertTrue(read.contains("one"), "command_output is not reading the same registry: \(read)")
        XCTAssertTrue(read.contains("two"))
    }

    func testCommandStatusAndStopOperateOnTheSameTask() async throws {
        _ = try await StartBackgroundTaskTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"sleep 30","working_directory":"/tmp","background":true}"#))

        // ⚠️ The LIST-EVERYTHING form, absorbed from the withdrawn `command_status`: omitting
        // task_id must still enumerate the conversation's tasks, or that capability died with it.
        let status = try await CommandOutputTool(conversationID: conversation)
            .call(arguments: JSONDecoder().decode(CommandOutputTool.Arguments.self, from: Data("{}".utf8)))
        XCTAssertTrue(status.contains("bg_1"), "command_output's list form cannot see the task: \(status)")
        XCTAssertTrue(status.contains("running"))

        let stopped = try await CommandStopTool(conversationID: conversation)
            .call(arguments: JSONDecoder().decode(CommandStopTool.Arguments.self,
                                                  from: Data(#"{"task_id":"bg_1"}"#.utf8)))
        // ⚠️ Asserts the task it ACTED ON, not the sentence it used. This read
        // `contains("Stopped")` and broke when the reply was reworded from "Stopped" to "Stop
        // requested" — a correctness fix to the wording, failing a test that was pinning prose.
        // The reply's job is to name the right task and not be an error; whether the stop LANDED
        // is the registry's answer, on the line below.
        XCTAssertFalse(stopped.hasPrefix("Error:"), "command_stop refused: \(stopped)")
        XCTAssertTrue(stopped.contains("bg_1"), "the reply does not name the task it acted on: \(stopped)")
        XCTAssertEqual(BackgroundProcessRegistry.shared.snapshot(conversationID: conversation, taskID: "bg_1")?.status,
                       .stopped)
    }

    /// A model that mistypes an id should get the ids that DO exist, not a bare failure.
    func testAnUnknownTaskIdIsAnsweredWithTheKnownOnes() async throws {
        _ = try await StartBackgroundTaskTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"echo hi","working_directory":"/tmp","background":true}"#))

        let read = try await CommandOutputTool(conversationID: conversation)
            .call(arguments: JSONDecoder().decode(CommandOutputTool.Arguments.self,
                                                  from: Data(#"{"task_id":"bg_7"}"#.utf8)))
        XCTAssertTrue(read.contains("bg_1"), "the refusal should name the tasks that exist: \(read)")
    }

    // MARK: - task_name

    /// The tool → registry half of the path. The registry → timeline-row half is asserted in
    /// `BackgroundTaskObserverTests`, which is where an observer actually exists; a row can only
    /// appear if one is running.
    func testATaskNameReachesTheTimelineRow() async throws {
        _ = try await StartBackgroundTaskTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"echo named","working_directory":"/tmp","task_name":"Build and test"}"#))

        let task = try XCTUnwrap(BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first)
        XCTAssertEqual(task.name, "Build and test")
        XCTAssertEqual(task.command, "echo named", "the command is kept alongside the label")
    }

    /// Optional on purpose: a model that omits it loses nothing, and every surface falls back to
    /// the command. Requiring it would turn a nicety into a refusal for the smaller models.
    func testAnUnnamedTaskIsStillUsable() async throws {
        _ = try await StartBackgroundTaskTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"echo unnamed","working_directory":"/tmp"}"#))

        let task = try XCTUnwrap(BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first)
        XCTAssertNil(task.name)
        XCTAssertEqual(task.command, "echo unnamed")
    }

    /// `run_command` takes it too — a foreground build deserves a label as much as a background one.
    func testForegroundAlsoAcceptsATaskName() async throws {
        _ = try await RunCommandTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"echo fg","working_directory":"/tmp","task_name":"Quick check"}"#))

        let task = try XCTUnwrap(BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first)
        XCTAssertEqual(task.name, "Quick check")
    }

    // MARK: - Wording shared across both modes

    /// ⚠️ THE SPLIT LEFT THE OLD NAME EMBEDDED IN ITS SIBLINGS.
    ///
    /// `command_output` / `command_stop` are `.library`, so they are offered in
    /// BOTH modes — but the tool that STARTS a background task differs by mode:
    /// `batch_command(background: true)` in chat, `start_background_task` in Code, where
    /// `batch_command` is superseded and absent from the loadout entirely.
    ///
    /// Two descriptions and one error message said "started with batch_command", which pointed a
    /// Code-mode model at a tool it cannot see. A recovery hint that cannot be followed is worse
    /// than none: it costs an iteration AND teaches a name that will never resolve.
    ///
    /// The rename changed the tool and left its name in the prose around it — the shape
    /// `feedback_rename_sweeps_miss_derived_vocabulary` was written for.
    func testTheSharedBackgroundToolsNameNoStarter() {
        for name in ["command_output", "command_stop"] {
            guard let entry = NativeToolCatalog.entry(named: name) else {
                return XCTFail("\(name) is not in the catalogue — this guard is checking nothing")
            }
            let description = entry.agentTool(conversationID: UUID(), requiresConfirmation: false).description
            XCTAssertFalse(description.isEmpty,
                           "\(name) has no description — the assertions below would pass vacuously")
            XCTAssertFalse(description.contains("batch_command"),
                           "\(name) names `batch_command`, which a Code-mode agent does not have")
            XCTAssertFalse(description.contains("start_background_task"),
                           "\(name) names `start_background_task`, which a chat agent does not have")
        }
    }

    /// The same rule for the refusal these three share — model-facing text on every mistaken id.
    func testTheUnknownTaskRefusalNamesNoStarter() {
        let refusal = BackgroundTaskToolSupport.unknown("bg_9", conversationID: UUID())
        XCTAssertFalse(refusal.contains("batch_command"),
                       "the remedy points a Code-mode model at a tool it cannot call: \(refusal)")
        XCTAssertFalse(refusal.contains("start_background_task"),
                       "the remedy points a chat agent at a tool it cannot call: \(refusal)")
        XCTAssertTrue(refusal.contains("start one"),
                      "the refusal must still say what to do, just without naming the wrong tool")
    }

    // MARK: - Catalogue and preset

    /// The catalogue must build the shell tools WITH the conversation. `{ _ in RunCommandTool() }`
    /// compiles fine and silently disables background scoping for every conversation.
    ///
    /// ⚠️ Was `testTheCatalogueSuppliesTheConversationToBatchCommand` until `batch_command` was
    /// withdrawn from the catalogue — its `call` was a two-line dispatcher over the same statics
    /// these two use, so it was a duplicate offered under a different name in chat.
    func testTheCatalogueSuppliesTheConversationToTheShellTools() throws {
        for name in ["run_command", "start_background_task", "command_output"] {
            guard let entry = NativeToolCatalog.entry(named: name) else {
                return XCTFail("\(name) is not in the catalogue")
            }
            let tool = entry.agentTool(conversationID: conversation, requiresConfirmation: false)
            XCTAssertEqual(tool.name, name)
        }
    }

    /// ⚠️ The withdrawal must be real: a name still in the catalogue is still selectable.
    ///
    /// ⚠️ THERE IS DELIBERATELY NO RENAME MAP. One was built, tested, and then removed: nothing
    /// seeds a default tool list, so a profile created after the withdrawal cannot contain the old
    /// name, and with no released users the only holders were local development profiles. A
    /// standing "withdrawn names resolve to something else" mechanism is a first-party cousin of
    /// the guess-by-name fallback `resolveExecutableTools` deleted on purpose. A stored name that
    /// no longer resolves is reported by its ⚠️ NOT RESOLVED error — loud, and the honest outcome.
    func testBatchCommandIsGoneFromTheCatalogue() {
        XCTAssertNil(NativeToolCatalog.entry(named: "batch_command"),
                     "batch_command is still in the catalogue — chat profiles can still pick the "
                     + "duplicate, which is what the withdrawal exists to stop")
    }

    /// ⚠️ THE SCHEMA, not the Swift type. `Arguments.task_id` is `String?`, so decoding `{}`
    /// succeeds whatever the schema says — the schema is what the MODEL is shown. Put `task_id`
    /// back in `required` and the list-everything form becomes unreachable to the model while the
    /// Swift code still happily supports it, which is exactly the shape that survives a test suite.
    func testCommandOutputLetsTheModelOmitTheTaskID() {
        let schema = CommandOutputTool(conversationID: conversation).parameterSchema
        XCTAssertTrue(schema.properties.keys.contains("task_id"),
                      "task_id is not advertised at all")
        XCTAssertFalse(schema.required.contains("task_id"),
                       "task_id is REQUIRED, so the model cannot ask for the list of every task — "
                       + "the capability absorbed from the withdrawn command_status is unreachable")
    }

    /// The withdrawal must be real, and `command_output` must still be there to absorb it.
    func testCommandStatusIsGoneAndCommandOutputRemains() {
        XCTAssertNil(NativeToolCatalog.entry(named: "command_status"),
                     "command_status is still selectable — it is a strict subset of command_output "
                     + "and costs a tool slot for nothing")
        XCTAssertNotNil(NativeToolCatalog.entry(named: "command_output"),
                        "the only remaining read path is gone")
        XCTAssertNotNil(NativeToolCatalog.entry(named: "command_stop"),
                        "stopping is an ACTION — nothing else can deliver it")
    }

    /// Both halves must be offered to EVERY profile now, not just Code.
    func testTheSplitIsAvailableToChatProfilesToo() {
        for name in ["run_command", "start_background_task"] {
            guard let entry = NativeToolCatalog.entry(named: name) else {
                return XCTFail("\(name) is not in the catalogue")
            }
            XCTAssertEqual(entry.visibility, .library,
                           "\(name) is not offered to chat profiles, so withdrawing batch_command "
                           + "left them with no shell tool at all")
        }
    }

    func testThePresetOffersTheBackgroundTools() {
        let names = Set(CodeToolPreset.defaultTools.map(\.name))
        for tool in ["run_command", "start_background_task", "command_output", "command_stop"] {
            XCTAssertTrue(names.contains(tool), "\(tool) is not in the Code preset")
        }
    }

    /// Quit teardown. Without this call a background build outlives the app as a launchd orphan —
    /// the gap MCP's children were already covered for.
    func testQuitTeardownTerminatesBackgroundTasks() throws {
        let source = try Self.readSource("Devgentic/AppDelegate.swift")
        XCTAssertTrue(source.contains("BackgroundProcessRegistry.shared.terminateAll()"),
                      "nothing kills background tasks at quit; they are re-parented to launchd")
    }

    // MARK: - Source access

    private static func readSource(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Code
            .deletingLastPathComponent()   // Interfaces
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        guard let text = try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8) else {
            throw XCTSkip("\(relativePath) not reachable — running outside a checkout")
        }
        return text
    }
}

/// The guide is a hand-maintained description of what the preset grants. It had no test, and when
/// three tools were added it silently kept describing sixteen.
final class CodeToolsGuideDriftTests: XCTestCase {

    @MainActor
    func testEveryPresetToolHasAGuideEntry() {
        let documented = Set(CodeToolsGuideView.tools.map(\.name))
        let granted = Set(CodeToolPreset.defaultTools.map(\.name))

        XCTAssertTrue(granted.subtracting(documented).isEmpty,
            "tools the Code agent has but the guide does not describe: "
            + "\(granted.subtracting(documented).sorted())")
        XCTAssertTrue(documented.subtracting(granted).isEmpty,
            "tools the guide describes that the agent does not have: "
            + "\(documented.subtracting(granted).sorted())")
    }

    @MainActor
    func testTheGuideIsNotEmpty() {
        XCTAssertGreaterThan(CodeToolsGuideView.tools.count, 10,
                             "the assertions above would pass vacuously on an empty guide")
    }
}
