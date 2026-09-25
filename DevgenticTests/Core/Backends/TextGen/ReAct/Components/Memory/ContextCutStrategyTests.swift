// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ContextCutStrategyTests.swift
//  DevgenticTests
//
//  "If a tool result doesn't fit, keep …" — the gauge's global setting and each tool's override
//  (2026-09-24).
//

import XCTest
@testable import devgentic

final class ContextCutStrategyTests: XCTestCase {

    /// 400 numbered lines, so what survives is readable in a failure message.
    private let log = (1...400).map { "line \($0) of the output" }.joined(separator: "\n")

    // MARK: - Each cut keeps what it says

    func testKeepStartKeepsTheStart() {
        let fitted = ToolResultBudget.fit(log, limit: 2_000, strategy: .keepStart)
        XCTAssertTrue(fitted.hasPrefix("line 1 of the output"))
        XCTAssertFalse(fitted.contains("line 400 of"), "the end survived a keep-start cut")
        XCTAssertTrue(fitted.contains("omitted from the end"))
        XCTAssertLessThanOrEqual(fitted.count, 2_000)
    }

    /// A build's verdict is its last line — keep-end is the cut that must never lose it.
    func testKeepEndKeepsTheEnd() {
        let fitted = ToolResultBudget.fit(log, limit: 2_000, strategy: .keepEnd)
        XCTAssertTrue(fitted.hasSuffix("line 400 of the output"))
        XCTAssertFalse(fitted.contains("line 1 of the output"), "the start survived a keep-end cut")
        XCTAssertTrue(fitted.contains("omitted from the start"))
        XCTAssertLessThanOrEqual(fitted.count, 2_000)
    }

    func testKeepStartAndEndKeepsBoth() {
        let fitted = ToolResultBudget.fit(log, limit: 2_000, strategy: .keepStartAndEnd)
        XCTAssertTrue(fitted.hasPrefix("line 1 of the output"))
        XCTAssertTrue(fitted.hasSuffix("line 400 of the output"))
        XCTAssertTrue(fitted.contains("omitted from the middle"))
    }

    /// Every cut lands on a line boundary — the kept part is whole lines.
    func testEveryCutKeepsWholeLines() {
        for strategy in [ContextCutStrategy.keepStart, .keepEnd, .keepStartAndEnd] {
            let fitted = ToolResultBudget.fit(log, limit: 2_000, strategy: strategy)
            let kept = fitted.components(separatedBy: "\n").filter { $0.hasPrefix("line ") }
            for line in kept {
                XCTAssertTrue(line.hasSuffix("of the output"), "\(strategy) cut a line in half: \(line)")
            }
        }
    }

    // MARK: - Automatic

    func testAutomaticKeepsTheEndOfCommandOutput() {
        XCTAssertEqual(ContextCutStrategy.automatic.resolved(forTool: "run_command"), .keepEnd)
        XCTAssertEqual(ContextCutStrategy.automatic.resolved(forTool: "get_task_output"), .keepEnd)
        XCTAssertEqual(ContextCutStrategy.automatic.resolved(forTool: "command_output"), .keepEnd)
    }

    func testAutomaticKeepsTheStartOfReadsAndSearches() {
        XCTAssertEqual(ContextCutStrategy.automatic.resolved(forTool: "read_file"), .keepStart)
        XCTAssertEqual(ContextCutStrategy.automatic.resolved(forTool: "project_tree"), .keepStart)
        XCTAssertEqual(ContextCutStrategy.automatic.resolved(forTool: "code_search_text"), .keepStart)
        XCTAssertEqual(ContextCutStrategy.automatic.resolved(forTool: "list_directory"), .keepStart)
    }

    func testAutomaticKeepsBothEndsOfAnythingElse() {
        XCTAssertEqual(ContextCutStrategy.automatic.resolved(forTool: "some_mcp_tool"), .keepStartAndEnd)
        XCTAssertEqual(ContextCutStrategy.automatic.resolved(forTool: "git"), .keepStartAndEnd)
    }

    func testAnExplicitChoiceIsNotReinterpreted() {
        XCTAssertEqual(ContextCutStrategy.keepStart.resolved(forTool: "run_command"), .keepStart)
    }

    // MARK: - The policy: override beats default

    func testAPerToolOverrideBeatsTheDefault() {
        let policy = ToolCutPolicy(defaultStrategy: .keepStart, overrides: ["run_command": .keepStartAndEnd])
        XCTAssertEqual(policy.strategy(forTool: "run_command"), .keepStartAndEnd)
        XCTAssertEqual(policy.strategy(forTool: "read_file"), .keepStart)
    }

    func testTheRunPolicyReadsEachToolsOverride() {
        var withOverride = Tool(name: "read_file", description: "", sourceId: UUID(),
                                parameters: ToolParameters(type: "object", properties: [:], required: []))
        withOverride.cutStrategy = .keepEnd
        let plain = Tool(name: "git", description: "", sourceId: UUID(),
                         parameters: ToolParameters(type: "object", properties: [:], required: []))

        let policy = ToolCutPolicy.forRun(tools: [withOverride, plain])
        XCTAssertEqual(policy.overrides, ["read_file": .keepEnd])
    }

    /// The gauge writes the global setting to UserDefaults; a run must read it.
    func testTheGlobalDefaultIsReadFromTheGaugeSetting() {
        let key = ContextCutStrategy.defaultsKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        UserDefaults.standard.set(ContextCutStrategy.keepEnd.rawValue, forKey: key)
        XCTAssertEqual(ContextCutStrategy.globalDefault, .keepEnd)
        XCTAssertEqual(ToolCutPolicy.forRun(tools: []).defaultStrategy, .keepEnd)

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(ContextCutStrategy.globalDefault, .automatic, "an unset setting must mean Automatic")
    }

    /// ⚠️ Profiles saved before the field existed have no `cutStrategy` key. They must decode —
    /// a required key would fail every existing profile's tool list.
    func testAToolSavedBeforeTheFieldExistedStillDecodes() throws {
        let json = #"{"name":"read_file","description":"d","isEnabled":true,"requiresConfirmation":false,"sourceId":"00000000-0000-0000-0000-000000000001","parameters":{"type":"object","properties":{},"required":[]},"isFavorite":false}"#
        let tool = try JSONDecoder().decode(Tool.self, from: Data(json.utf8))
        XCTAssertNil(tool.cutStrategy)
    }

    /// ⚠️ `Tool` has a HAND-WRITTEN decoder. The field was encoded but never decoded, so the Tool
    /// Library's choice was lost on every profile read — and the test above, which only checks an
    /// ABSENT key, passed throughout.
    func testAChosenStrategySurvivesAnEncodeDecodeRoundTrip() throws {
        var tool = Tool(name: "read_file", description: "", sourceId: UUID(),
                        parameters: ToolParameters(type: "object", properties: [:], required: []))
        tool.cutStrategy = .keepEnd
        let decoded = try JSONDecoder().decode(Tool.self, from: JSONEncoder().encode(tool))
        XCTAssertEqual(decoded.cutStrategy, .keepEnd)
        XCTAssertEqual(decoded, tool, "a Tool field is dropped by the hand-written decoder")
    }

    // MARK: - The wiring

    private func source(_ relative: String) throws -> String {
        // EIGHT components: file → Memory → Components → ReAct → TextGen → Backends → Core → DevgenticTests → root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 { root = root.deletingLastPathComponent() }
        let url = root.appendingPathComponent(relative)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "running outside a checkout")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// ⚠️ Every test above passes with the setting ignored at run time. These fail if a consumer
    /// stops reading the policy.
    func testTheNativePathAndTheScratchpadApplyThePolicy() throws {
        let executor = try source("Devgentic/Core/Backends/TextGen/ReAct/ReActAgentExecutor.swift")
        XCTAssertTrue(executor.contains("strategy: input.cutPolicy.strategy(forTool: obs.toolName)"),
                      "the native path no longer applies the chosen cut")
        let memory = try source("Devgentic/Core/Backends/TextGen/ReAct/Components/Memory/WorkingMemoryStrategy.swift")
        XCTAssertTrue(memory.contains("strategy: cutPolicy.strategy(forTool: toolName)"),
                      "the scratchpad path no longer applies the chosen cut")
    }

    func testEveryRunIsGivenThePolicy() throws {
        let connect = try source("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        XCTAssertTrue(connect.contains("cutPolicy: cutPolicy"), "chat/code runs no longer receive the policy")
        XCTAssertTrue(connect.contains("cutPolicy: nodeCutPolicy"), "workflow nodes no longer receive the policy")
        XCTAssertTrue(connect.contains("windowed.cutPolicy = cutPolicy"), "the chat/code scratchpad ignores the policy")
        XCTAssertTrue(connect.contains("memory.cutPolicy = nodeCutPolicy"), "the workflow scratchpad ignores the policy")
    }

    /// Code rebuilds its tool list from a preset on every send. Without the carry-over, a per-tool
    /// choice made in the Tool Library would be silently reset on the next message.
    func testCodeKeepsAPerToolChoiceAcrossSends() throws {
        let code = try source("Devgentic/Interfaces/Code/CodeSessionManager.swift")
        XCTAssertTrue(code.contains("carried.cutStrategy = user.cutStrategy"),
                      "Code's preset merge drops the per-tool cut strategy")
    }
}
