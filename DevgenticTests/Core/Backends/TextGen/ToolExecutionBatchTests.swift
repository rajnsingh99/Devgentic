// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolExecutionBatchTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ToolExecutionBatchTests: XCTestCase {

    // MARK: - Fixtures

    private func call(_ name: String, _ args: [String: JSONValue], id: String = UUID().uuidString) -> PendingToolCall {
        PendingToolCall(id: id, name: name, arguments: args)
    }

    private func params(_ names: [String], required: [String]? = nil) -> ToolParameters {
        ToolParameters(type: "object",
                       properties: Dictionary(uniqueKeysWithValues: names.map { ($0, ToolParameterProperty(type: "string", description: nil, items: nil)) }),
                       required: required ?? names)
    }

    private func tool(_ name: String, _ argNames: [String], confirm: Bool = false,
                      run: @escaping @Sendable (Data) async throws -> (output: String, artifacts: [MediaArtifact]) = { _ in ("ok", []) }) -> AgentTool {
        AgentTool(name: name, description: "test tool", parameters: params(argNames), requiresConfirmation: confirm, run: run)
    }

    /// Records calls a tool received, and how many ran at once.
    actor Recorder {
        private(set) var received: [[String: JSONValue]] = []
        private(set) var maxConcurrent = 0
        private var inFlight = 0
        func begin(_ args: [String: JSONValue]) { received.append(args); inFlight += 1; maxConcurrent = max(maxConcurrent, inFlight) }
        func end() { inFlight -= 1 }
    }

    private func recordingTool(_ name: String, _ argNames: [String], recorder: Recorder, confirm: Bool = false,
                               holdMilliseconds: UInt64 = 0) -> AgentTool {
        tool(name, argNames, confirm: confirm) { data in
            let args = (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
            await recorder.begin(args)
            if holdMilliseconds > 0 { try? await Task.sleep(nanoseconds: holdMilliseconds * 1_000_000) }
            await recorder.end()
            return ("done", [])
        }
    }

    /// Runs `executeToolCalls` to completion, answering any confirmation banner with `banner`.
    private func execute(_ calls: [PendingToolCall], tools: [AgentTool], workspaceRoot: String? = nil,
                         banner: (@Sendable (UUID) async -> Void)? = nil) async throws -> (observations: [ToolObservation], events: [AgentStreamEvent]) {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var observations: [ToolObservation] = []; var events: [AgentStreamEvent] = []
        }
        let box = Box()
        let stream = AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            Task {
                do {
                    let observations = try await executeToolCalls(
                        toolCalls: calls, availableTools: tools, conversationID: UUID(), currentIteration: 1,
                        iterationSpan: TestTraceContext.make(), toolMediator: ToolExecutionMediator(),
                        interactionMemory: RunInteractionMemory(), continuation: continuation,
                        approvalNodeID: nil, workspaceRoot: workspaceRoot, onTraceUpdate: { _ in })
                    box.lock.withLock { box.observations = observations }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
        for try await event in stream {
            box.lock.withLock { box.events.append(event) }
            if case .requestConfirmation(_, _, let operationID, _, _) = event, let banner {
                // Wait for the park to exist — a resume that arrives first is dropped.
                for _ in 0..<2_000 where !(await ExecutionSuspensionService.shared.hasPendingSuspensions()) { await Task.yield() }
                await banner(operationID)
            }
        }
        return box.lock.withLock { (box.observations, box.events) }
    }

    private func makeProject() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cr-batch2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // realpath, not `resolvingSymlinksInPath` — Foundation rewrites `/private/var/…` to `/var/…`.
        guard let real = realpath(root.path, nil) else { return root.path }
        defer { free(real) }
        return String(cString: real)
    }

    // MARK: - CR-43: dedupe by every path role

    func testTwoCopiesOfOneSourceBothRun() {
        let plan = planToolCalls([
            call("copy_file", ["source": .string("/p/a.txt"), "destination": .string("/p/b.txt")]),
            call("copy_file", ["source": .string("/p/a.txt"), "destination": .string("/p/c.txt")]),
        ])
        XCTAssertEqual(plan.run.count, 2, "copies to two destinations are two operations")
        XCTAssertTrue(plan.superseded.isEmpty)
    }

    func testACopyAndItsReverseAreDifferentOperations() {
        let plan = planToolCalls([
            call("move_file", ["source": .string("/p/a"), "destination": .string("/p/b")]),
            call("move_file", ["source": .string("/p/b"), "destination": .string("/p/a")]),
        ])
        XCTAssertEqual(plan.run.count, 2, "roles are compared in order, not as a set of paths")
    }

    func testRepeatedWritesToOneFileKeepTheLastAndReportTheRest() {
        let first = call("write_file", ["path": .string("/p/x.md"), "content": .string("v1")], id: "first")
        let last = call("write_file", ["path": .string("/p/x.md/"), "content": .string("v2")], id: "last")
        let plan = planToolCalls([first, last])
        XCTAssertEqual(plan.run.map(\.id), ["last"])
        XCTAssertEqual(plan.superseded.map(\.call.id), ["first"])
        XCTAssertEqual(plan.superseded.first?.by.id, "last")
    }

    /// THE CALL SITE: the replaced call reaches the model as "not run", paired to its own id.
    /// Mutation that must turn this red: stop seeding `observations` with the superseded calls.
    func testASupersededWriteIsReportedToTheModel() async throws {
        let recorder = Recorder()
        let first = call("write_file", ["path": .string("/tmp/cr43.md"), "content": .string("v1")], id: "w1")
        let last = call("write_file", ["path": .string("/tmp/cr43.md"), "content": .string("v2")], id: "w2")
        let (observations, _) = try await execute([first, last], tools: [recordingTool("write_file", ["path", "content"], recorder: recorder)])

        let ran = await recorder.received
        XCTAssertEqual(ran.map { $0["content"] }, [.string("v2")], "only the last write runs")
        let superseded = try XCTUnwrap(observations.first { $0.toolCallId == "w1" }, "the dropped call got no observation")
        XCTAssertFalse(superseded.isSuccess)
        XCTAssertEqual(superseded.failureCategory, .cancelled, "a superseded call is a choice, not a tool failure")
        XCTAssertTrue(superseded.result.contains("Not run"), superseded.result)
    }

    // MARK: - CR-45: same-file calls run in order

    func testCallsOnOneFileShareALaneAndOthersRunApart() {
        let lanes = executionLanes(for: [
            call("edit_code_single", ["file_path": .string("/p/A.swift"), "old_string": .string("a"), "new_string": .string("b")], id: "e1"),
            call("read_file", ["path": .string("/p/A.swift")], id: "r1"),
            call("edit_code_single", ["file_path": .string("/p/A.swift"), "old_string": .string("c"), "new_string": .string("d")], id: "e2"),
            call("edit_code_single", ["file_path": .string("/p/B.swift"), "old_string": .string("a"), "new_string": .string("b")], id: "e3"),
        ], workspaceRoot: nil)
        let byFirst = Dictionary(uniqueKeysWithValues: lanes.map { ($0.first!.id, $0.map(\.id)) })
        XCTAssertEqual(byFirst["e1"], ["e1", "e2"], "two edits of one file are one lane, in the model's order")
        XCTAssertEqual(byFirst["e3"], ["e3"])
        XCTAssertEqual(byFirst["r1"], ["r1"], "a read is never serialised")
    }

    /// `a.swift` and `<project>/a.swift` are one file: lanes compare the re-anchored path.
    func testARelativeAndAnAbsolutePathToOneFileShareALane() throws {
        let root = try makeProject()
        let lanes = executionLanes(for: [
            call("edit_code_single", ["file_path": .string("a.swift"), "old_string": .string("1"), "new_string": .string("2")]),
            call("edit_code_single", ["file_path": .string("\(root)/a.swift"), "old_string": .string("3"), "new_string": .string("4")]),
        ], workspaceRoot: root)
        XCTAssertEqual(lanes.count, 1)
    }

    /// A copy touching two lanes' files joins them.
    func testACallTouchingTwoLanesMergesThem() {
        let lanes = executionLanes(for: [
            call("write_file", ["path": .string("/p/a"), "content": .string("x")], id: "w1"),
            call("write_file", ["path": .string("/p/b"), "content": .string("y")], id: "w2"),
            call("copy_file", ["source": .string("/p/a"), "destination": .string("/p/b")], id: "c1"),
        ], workspaceRoot: nil)
        XCTAssertEqual(lanes.count, 1)
        XCTAssertEqual(lanes.first?.last?.id, "c1", "the copy runs after both writes it depends on")
    }

    /// THE CALL SITE: two edits of one file never overlap. (Holding each for 300 ms makes an overlap
    /// certain when they DO run in parallel; this direction cannot fail on a slow machine.)
    /// Mutation that must turn this red: give every autonomous call its own task again.
    func testEditsOfOneFileNeverRunAtTheSameTime() async throws {
        let recorder = Recorder()
        let edit = recordingTool("edit_code_single", ["file_path", "old_string", "new_string"], recorder: recorder, holdMilliseconds: 300)
        _ = try await execute([
            call("edit_code_single", ["file_path": .string("/tmp/cr45.swift"), "old_string": .string("a"), "new_string": .string("b")]),
            call("edit_code_single", ["file_path": .string("/tmp/cr45.swift"), "old_string": .string("c"), "new_string": .string("d")]),
        ], tools: [edit])
        let received = await recorder.received
        let maxConcurrent = await recorder.maxConcurrent
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(maxConcurrent, 1, "two edits of one file ran concurrently — the last write would win")
        XCTAssertEqual(received.first?["old_string"], .string("a"), "and in the order the model gave")
    }

    // MARK: - CR-44: edited arguments get the boundary

    /// The user edits a write to point outside the project: refused, nothing runs, and the model is
    /// told why. Mutation that must turn this red: drop the re-evaluation of the edited arguments.
    func testAnEditedWriteOutsideTheProjectIsRefused() async throws {
        let root = try makeProject()
        let recorder = Recorder()
        let write = recordingTool("write_file", ["path", "content"], recorder: recorder, confirm: true)
        let (observations, _) = try await execute(
            [call("write_file", ["path": .string("inside.txt"), "content": .string("x")])],
            tools: [write], workspaceRoot: root,
            banner: { id in
                await ExecutionSuspensionService.shared.resume(
                    for: id, approved: true, resolvedBy: .localUI,
                    editedArguments: ["path": .string("/tmp/cr44-outside-\(UUID().uuidString).txt"), "content": .string("x")])
            })
        let ran = await recorder.received
        XCTAssertTrue(ran.isEmpty, "an edited path outside the project was written: \(ran)")
        XCTAssertEqual(observations.first?.failureCategory, .permissionRejected)
        XCTAssertTrue(observations.first?.result.contains("edited") == true, observations.first?.result ?? "")
    }

    /// An edited RELATIVE path is anchored to the project, and the model is told its arguments changed.
    func testAnEditedRelativePathIsAnchoredAndReported() async throws {
        let root = try makeProject()
        let recorder = Recorder()
        let write = recordingTool("write_file", ["path", "content"], recorder: recorder, confirm: true)
        let (observations, events) = try await execute(
            [call("write_file", ["path": .string("first.txt"), "content": .string("x")])],
            tools: [write], workspaceRoot: root,
            banner: { id in
                await ExecutionSuspensionService.shared.resume(
                    for: id, approved: true, resolvedBy: .localUI,
                    editedArguments: ["path": .string("sub/edited.txt"), "content": .string("x")])
            })
        let ran = await recorder.received
        XCTAssertEqual(ran.first?["path"], .string("\(root)/sub/edited.txt"), "the edited path must resolve against the project, not $HOME")
        let observation = try XCTUnwrap(observations.first)
        XCTAssertTrue(observation.result.hasPrefix("[The user edited this call's arguments"), observation.result)
        XCTAssertTrue(observation.params.contains("edited.txt"), "the record must carry what ran: \(observation.params)")
        // CR-41: the result names the row it belongs to — the one created from the model's params.
        let succeeded = events.compactMap { event -> ToolOutput? in
            if case .toolSucceeded(let output, _, _) = event { return output }
            return nil
        }.first
        let row = events.compactMap { event -> String? in
            if case .toolCall(_, let params, _, _) = event { return params }
            return nil
        }.first
        XCTAssertNotNil(succeeded?.rowParams)
        XCTAssertEqual(succeeded?.rowParams, row, "an edited result must carry its row's params, or it lands on no row")
    }

    // MARK: - CR-51: fuzzy matching never changes the tool's meaning

    func testNamesThatDifferByAWordAreNotTypos() {
        XCTAssertFalse(ToolNameResolver.namesDifferOnlyByTypos("create_file", "create_folder"))
        XCTAssertFalse(ToolNameResolver.namesDifferOnlyByTypos("delete_file", "delete_folder"))
        XCTAssertTrue(ToolNameResolver.namesDifferOnlyByTypos("final_answr", "final_answer"))
        XCTAssertTrue(ToolNameResolver.namesDifferOnlyByTypos("finalanswer", "final_answer"))
        XCTAssertTrue(ToolNameResolver.namesDifferOnlyByTypos("read_fiel", "read_file"))
    }

    /// The defect itself. Mutation that must turn this red: drop the word gate.
    func testCreateFileIsNeverRunAsCreateFolder() {
        let resolver = ToolNameResolver(registeredTools: [tool("create_folder", ["path"]), tool("write_file", ["path", "content"])])
        let resolution = resolver.resolve(emittedName: "create_file", arguments: ["path": .string("notes.md"), "content": .string("# Notes")])
        if case .remapped(_, let canonical, _, _) = resolution {
            XCTAssertNotEqual(canonical, "create_folder", "create_file ran as create_folder — a directory named notes.md")
        }
        XCTAssertFalse(ToolNameResolver.jaroWinkler("create_file", "create_folder") < ToolNameResolver.fuzzyThreshold,
                       "fixture precondition: the pair clears the similarity threshold, so only the new guards stop it")
    }

    func testDeleteFileIsNeverRunAsDeleteFolder() {
        let resolver = ToolNameResolver(registeredTools: [tool("delete_folder", ["path"])])
        let resolution = resolver.resolve(emittedName: "delete_file", arguments: ["path": .string("/p/a.txt")])
        if case .remapped = resolution { XCTFail("delete_file ran as delete_folder") }
    }

    /// A typo'd name with arguments the target doesn't take is a different tool.
    /// Mutation that must turn this red: drop the foreign-argument check.
    func testAFuzzyMatchCarryingForeignArgumentsIsRejected() {
        let resolver = ToolNameResolver(registeredTools: [tool("read_file", ["path"])])
        let resolution = resolver.resolve(emittedName: "read_files", arguments: ["path": .string("a.txt"), "content": .string("new text")])
        if case .remapped = resolution { XCTFail("the content argument would have been silently dropped") }
    }

    func testARealTypoIsStillForgiven() {
        let resolver = ToolNameResolver(registeredTools: [tool("final_answer", ["answer"])])
        let resolution = resolver.resolve(emittedName: "final_answr", arguments: ["answer": .string("42")])
        guard case .remapped(_, let canonical, _, _) = resolution else { return XCTFail("got \(resolution)") }
        XCTAssertEqual(canonical, "final_answer")
    }

    /// THE CALL SITE: the native pipeline that validates every provider step uses the resolver.
    func testTheNativePipelineDoesNotPromoteCreateFileToCreateFolder() {
        let tools = [tool("create_folder", ["path"]), tool("write_file", ["path", "content"])]
        let step = ModernCognitiveStep(reasoning: "", toolCalls: [
            call("create_file", ["path": .string("notes.md"), "content": .string("# Notes")]),
        ])
        let validated = NativeParsePipeline(registeredTools: tools).validate(step: step)
        XCTAssertFalse(validated.toolCalls.contains { $0.name == "create_folder" })
    }

    // MARK: - CR-56: a Code workflow node is confined

    /// Source pin: the node path reads the Code profile's folder and hands it to the executor.
    /// Mutation that must turn this red: drop `workspaceRoot: nodeWorkspaceRoot` from the node's input.
    func testAWorkflowNodeRunPassesTheCodeProjectFolder() throws {
        let source = try Self.read("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        let node = try XCTUnwrap(source.range(of: "func streamWorkflowNodeResponse("))
        let body = source[node.lowerBound...]
        XCTAssertNotNil(body.range(of: #"case \.code\(let config\):[\s\S]{0,2500}?nodeWorkspaceRoot = config\.projectPath"#, options: .regularExpression))
        XCTAssertNotNil(body.range(of: #"var input = AgentInput\([\s\S]{0,1500}?workspaceRoot: nodeWorkspaceRoot,"#, options: .regularExpression),
                        "the node's AgentInput must carry the project folder")
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath)")
    }
}
