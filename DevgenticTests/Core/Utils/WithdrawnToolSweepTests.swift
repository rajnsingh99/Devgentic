// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WithdrawnToolSweepTests.swift
//  DevgenticTests
//
//  Measured on device 2026-09-23, after `batch_command` was withdrawn from the catalogue:
//
//    [TOOLRESOLVE] ⚠️ 'batch_command' NOT RESOLVED — the agent will run WITHOUT this capability.
//    [TOOLSCHEMA] 1 tool(s) absent from the snapshot, priced at 0 … Absent: batch_command.
//
//  on EVERY send, forever. The second is the real cost — the context gauge and the pre-send fit
//  check both over-report headroom. And the user cannot fix it: the Tool Library renders from
//  `UnifiedToolStore`, so a name with no matching source has no row to un-tick.
//

import XCTest
@testable import devgentic

@MainActor
final class WithdrawnToolSweepTests: XCTestCase {

    private func tool(_ name: String, source: UUID = ToolSource.builtInSourceID) -> Tool {
        Tool(name: name, description: "d", sourceId: source,
             parameters: ToolParameters(type: "object", properties: [:], required: []))
    }

    // MARK: - Which names are withdrawn

    /// The case that produced the device log.
    func testAWithdrawnBuiltInIsIdentified() {
        XCTAssertNil(NativeToolCatalog.entry(named: "batch_command"),
                     "fixture assumes batch_command is withdrawn")
        XCTAssertEqual(WithdrawnToolSweep.withdrawnNames(in: [tool("batch_command")]), ["batch_command"])
    }

    func testALiveBuiltInIsLeftAlone() {
        XCTAssertTrue(WithdrawnToolSweep.withdrawnNames(in: [tool("run_command"), tool("read_file")]).isEmpty,
                      "a tool the catalogue still has was marked for removal")
    }

    /// ⚠️⚠️ THE ONE THAT WOULD DESTROY USER CONFIGURATION. An MCP tool absent from the catalogue is
    /// the NORMAL case — the catalogue never carries MCP names at all, and a server can be offline,
    /// unauthenticated or slow to hand over its list. The device log shows two servers failing
    /// authentication at launch with 29 tools between them; pruning those would delete the user's
    /// setup because a remote endpoint had a bad day.
    func testAnMCPToolIsNEVERPruned() {
        let server = UUID()
        let names = WithdrawnToolSweep.withdrawnNames(in: [
            tool("some_remote_thing", source: server),
            tool("read_file_from_server", source: server)
        ])
        XCTAssertTrue(names.isEmpty,
                      "an MCP tool was marked for removal — its server may simply be offline, and "
                      + "pruning it deletes configuration the user must then rebuild by hand")
    }

    /// ⚠️ Injected control-plane tools are built per run by `AgentConnect` and are deliberately NOT
    /// catalogue entries. Treating one as withdrawn would strip it from every profile that names it.
    func testAnInjectedControlPlaneToolIsNotTreatedAsWithdrawn() {
        let injected = NativeToolCatalog.injectedToolNames
        XCTAssertFalse(injected.isEmpty, "no injected names — this guard is checking nothing")
        for name in injected {
            XCTAssertTrue(WithdrawnToolSweep.withdrawnNames(in: [tool(name)]).isEmpty,
                          "\(name) is injected at run time, not a catalogue entry, and must not be "
                          + "pruned from a profile that names it")
        }
    }

    func testAMixedListPrunesOnlyTheWithdrawnName() {
        let names = WithdrawnToolSweep.withdrawnNames(in: [
            tool("read_file"),
            tool("batch_command"),
            tool("run_command"),
            tool("remote_tool", source: UUID())
        ])
        XCTAssertEqual(names, ["batch_command"])
    }

    func testAnEmptyToolListIsHandled() {
        XCTAssertTrue(WithdrawnToolSweep.withdrawnNames(in: []).isEmpty)
    }

    // MARK: - The advice that stops the polling loop

    /// ⚠️ MEASURED FAILURE (2026-09-23). A status line reading only "running, 8s" gave the model no
    /// next step, so it called `command_status` (since withdrawn) twenty times, ~2.3 s apart, until the iteration cap
    /// killed the run. The user got twenty identical lines and the build was still going.
    func testARunningTaskIsToldNotToPoll() async throws {
        let conversation = UUID()
        defer { BackgroundProcessRegistry.shared.discard(conversationID: conversation) }
        _ = try BackgroundProcessRegistry.shared.launch(
            command: "sleep 30", workingDirectory: NSTemporaryDirectory(),
            timeout: 60, conversationID: conversation)

        let status = try await CommandOutputTool(conversationID: conversation)
            .call(arguments: .init(task_id: "bg_1", since_line: nil))

        XCTAssertTrue(status.contains("Do NOT read this again in a loop"),
                      "a running task's status offers no next step, so the model asks again — this "
                      + "is the 20-poll loop that burned a whole run on device: \(status)")
        XCTAssertTrue(status.contains("notify_on_completion"),
                      "the advice must point at the capability that actually solves this")
    }

    /// ⚠️ The advice is for a RUNNING task only. Telling a model that has its answer not to poll is
    /// noise in every terminal observation, and noise in an observation is read every turn.
    func testAFinishedTaskIsNotToldAnything() async throws {
        let conversation = UUID()
        defer { BackgroundProcessRegistry.shared.discard(conversationID: conversation) }
        _ = try BackgroundProcessRegistry.shared.launch(
            command: "echo done", workingDirectory: NSTemporaryDirectory(),
            timeout: 30, conversationID: conversation)

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline,
              BackgroundProcessRegistry.shared.snapshot(conversationID: conversation, taskID: "bg_1")?.status.isTerminal != true {
            usleep(20_000)
        }

        let status = try await CommandOutputTool(conversationID: conversation)
            .call(arguments: .init(task_id: "bg_1", since_line: nil))
        XCTAssertFalse(status.contains("Do NOT read this again"),
                       "a FINISHED task carries do-not-poll advice it has no use for: \(status)")
    }

    // MARK: - The Code system prompt names no tool that does not exist

    /// ⚠️⚠️ THE DEFECT THIS WAS WRITTEN FOR. After `batch_command` was withdrawn, the Code system
    /// prompt still told the model to "use `batch_command` to run build / lint / tests" — SIX times
    /// across its two variants. The model was instructed to call a tool absent from its loadout.
    ///
    /// ⚠️ The sweep that was supposed to catch this grepped for `"batch_command"` WITH QUOTES,
    /// looking for string literals; the prompt writes it as a backticked word inside a multi-line
    /// string, so it never matched. This test looks at the rendered prompt instead of the source.
    func testTheCodeSystemPromptOnlyNamesToolsThatExist() {
        // Words the prompt backticks that are not tool names: parameters, paths, file names.
        let notTools: Set<String> = [
            "path", "working_directory", "old_string", "new_string", "task_id", "since_line",
            "command", "answer", "background", "notify_on_completion", "task_name",
            "timeout_seconds", "src/App.java", "context.md", ".devgentic/context.md",
            "/usr/bin", "/opt/homebrew", "/tmp", "status", "n"
        ]

        for provider: ApiProvider in [.anthropic, .openAI] {
            let prompt = CodeSystemPrompt.production(
                projectPath: "/tmp/p", projectName: "p",
                currentDate: "2026-09-23", apiProvider: provider)

            // Backticked snake_case words — the shape the prompt uses for every tool it names.
            let backticked = prompt.components(separatedBy: "`")
                .enumerated()
                .filter { $0.offset % 2 == 1 }
                .map(\.element)
                .filter { $0.contains("_") && !$0.contains(" ") && !$0.contains("/") }

            XCTAssertFalse(backticked.isEmpty, "no backticked names found — this guard is checking nothing")

            for name in Set(backticked) where !notTools.contains(name) {
                let known = NativeToolCatalog.entry(named: name) != nil
                    || NativeToolCatalog.injectedToolNames.contains(name)
                XCTAssertTrue(known,
                    "the \(provider.rawValue) Code prompt tells the model to use '\(name)', which is "
                    + "in neither the catalogue nor the injected set. Either it was withdrawn and "
                    + "the prompt was not swept, or it is a parameter name that belongs in "
                    + "`notTools` above.")
            }
        }
    }

    // MARK: - Wiring

    /// Without this the sweep is a type nothing runs, and the device symptom persists on every send.
    func testTheSweepRunsAtLaunch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent("Devgentic/DevgenticApp.swift"), encoding: .utf8) else {
            throw XCTSkip("DevgenticApp.swift not reachable — running outside a checkout")
        }
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("WithdrawnToolSweep.run()"),
                      "nothing runs the sweep, so a withdrawn name stays in the profile and the "
                      + "context gauge keeps over-reporting headroom on every send")
    }
}
