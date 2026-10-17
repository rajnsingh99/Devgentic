// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InjectedToolNameReservationTests.swift
//  devgenticTests
//
//  Readiness CR-2: a configured tool sharing a name with an injected one crashed the app.
//
//  ⚠️ THE DEFECT. `resolveExecutableTools` de-duplicated tool names, then the CALLER appended
//  `final_answer`, `remember`, `forget`, `recall` and `get_conversation_history`. MCP tool names are
//  the server's raw names, so a memory server exposing `recall` survived the de-dup and gained a
//  twin. Anthropic 400d every request; every other provider TRAPPED in `ToolExecutionLoop`'s
//  `Dictionary(uniqueKeysWithValues:)` on the first non-final tool batch.
//

import XCTest
@testable import devgentic

final class InjectedToolNameReservationTests: XCTestCase {

    private func tool(_ name: String, output: String = "ok") -> AgentTool {
        AgentTool(name: name, description: "test tool",
                  parameters: ToolParameters(type: "object", properties: [:], required: []),
                  requiresConfirmation: false, run: { _ in (output, []) })
    }

    // MARK: - The rule

    /// A configured tool may not take a reserved name; the drop is reported, not silent.
    func testAConfiguredToolCannotTakeAReservedName() {
        let result = AgentConnect.deduplicatingToolNames(
            [tool("ask_user"), tool("recall"), tool("read_file")], firstConfiguredIndex: 1)
        XCTAssertEqual(result.kept.map(\.name), ["ask_user", "read_file"])
        XCTAssertEqual(result.shadowingReserved, ["recall"])
        XCTAssertTrue(result.duplicates.isEmpty)
    }

    /// The control: injected tools BEFORE the split keep their reserved names — otherwise the rule
    /// would strip `ask_user` itself and the test above would pass for the wrong reason.
    func testInjectedToolsBeforeTheSplitKeepTheirNames() {
        let result = AgentConnect.deduplicatingToolNames([tool("ask_user"), tool("load_skill")], firstConfiguredIndex: 2)
        XCTAssertEqual(result.kept.map(\.name), ["ask_user", "load_skill"])
        XCTAssertTrue(result.shadowingReserved.isEmpty)
    }

    /// Ordinary duplicates still resolve first-wins, as before.
    func testOrdinaryDuplicatesAreStillFirstWins() {
        let first = tool("search", output: "first")
        let result = AgentConnect.deduplicatingToolNames([first, tool("search", output: "second")], firstConfiguredIndex: 0)
        XCTAssertEqual(result.kept.count, 1)
        XCTAssertEqual(result.duplicates, ["search"])
    }

    // MARK: - The composition that crashed

    /// ⚠️⚠️ THE CR-2 PROPERTY. Whatever name a configured tool takes, the final loadout — resolver
    /// output PLUS everything the caller appends afterwards — has unique names.
    func testTheFinalLoadoutHasUniqueNamesForEveryReservedName() {
        let callerAppended = [FinalAnswerTool().name, RememberTool(projectPath: "", conversationID: nil).name,
                              ForgetTool(projectPath: "").name, RecallTool(projectPath: "").name,
                              ConversationHistoryTool(chatHistory: [], correlation: "").name]
        for reservedName in callerAppended {
            let resolved = AgentConnect.deduplicatingToolNames(
                [tool("ask_user"), tool(reservedName), tool("read_file")], firstConfiguredIndex: 1).kept
            let loadout = resolved.map(\.name) + callerAppended
            XCTAssertEqual(Set(loadout).count, loadout.count,
                           "a configured '\(reservedName)' must not survive to sit beside the injected one: \(loadout)")
        }
    }

    /// ⚠️ DRIFT GUARD, from the invariant: every tool the caller appends AFTER resolution must be
    /// reserved. Adding a sixth injected tool without reserving its name reopens CR-2.
    func testEveryToolAppendedAfterResolutionIsReserved() {
        let appendedAfterResolution = [FinalAnswerTool().name, RememberTool(projectPath: "", conversationID: nil).name,
                                       ForgetTool(projectPath: "").name, RecallTool(projectPath: "").name,
                                       ConversationHistoryTool(chatHistory: [], correlation: "").name]
        for name in appendedAfterResolution {
            XCTAssertTrue(AgentConnect.reservedInjectedToolNames.contains(name), "'\(name)' is injected but not reserved")
        }
    }

    // MARK: - The wiring

    /// ⚠️ The tests above pin the RULE. This pins that `resolveExecutableTools` still applies it,
    /// and captures the split BEFORE configured tools are appended — computing it after would mark
    /// every tool as injected and reserve nothing.
    func testResolveExecutableToolsAppliesTheRule() throws {
        let source = try Self.read("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        let split = try XCTUnwrap(source.range(of: "let firstConfiguredToolIndex = activeTools.count"))
        let loop = try XCTUnwrap(source.range(of: "for toolConfig in profileTools where toolConfig.isEnabled"))
        let call = try XCTUnwrap(source.range(of: "Self.deduplicatingToolNames(activeTools, firstConfiguredIndex: firstConfiguredToolIndex)"))
        XCTAssertLessThan(split.lowerBound, loop.lowerBound, "the split must be taken before configured tools are appended")
        XCTAssertLessThan(loop.lowerBound, call.lowerBound, "and the rule applied after they are")
        XCTAssertTrue(source.contains("activeTools = deduplicated.kept"), "the filtered list must replace the loadout")
    }

    // MARK: - The backstop

    /// Even if a future injection point bypasses the rule, a duplicate must not take the app down:
    /// the execution loop logs it and calls the first registration.
    func testTheExecutionLoopSurvivesDuplicateToolNames() async throws {
        let call = PendingToolCall(id: UUID().uuidString, name: "recall", arguments: [:])
        let stream = AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            Task {
                do {
                    let observations = try await executeToolCalls(
                        toolCalls: [call],
                        availableTools: [tool("recall", output: "first"), tool("recall", output: "second")],
                        conversationID: UUID(), currentIteration: 1,
                        iterationSpan: TestTraceContext.make(),
                        toolMediator: ToolExecutionMediator(), interactionMemory: RunInteractionMemory(),
                        continuation: continuation, approvalNodeID: nil, onTraceUpdate: { _ in }
                    )
                    XCTAssertEqual(observations.count, 1)
                    XCTAssertTrue(observations.first?.output.contains("first") == true,
                                  "the first registration wins: \(observations.first?.output ?? "nil")")
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
        for try await _ in stream {}
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) — source-reading tests need the checkout present.")
    }
}
