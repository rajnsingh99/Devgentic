//
//  MediatorExecutionGuardTests.swift
//  DevgenticTests
//
//  A gate that returns the right VALUE but still runs the tool is not a gate.
//
//  Every existing test of the mediator's rejection paths asserts on the returned
//  `ToolExecutionResult` — that a missing argument yields a validation error, that an unknown
//  name yields `.hallucinated`. None of them asserts the SIDE EFFECT did not happen, which is the
//  half that matters: `delete_file` rejected for a missing path must also not have deleted
//  anything.
//
//  This codebase has already shipped that exact defect once. The workflow Action-node
//  confirmation gate added on 2026-07-31 was unreachable dead code — `selectTool` hardcoded
//  `requiresConfirmation: false`, so the branch could never be entered. It was written,
//  documented and reviewed without anyone tracing the value to its producer. These tests trace
//  the effect instead of the return value.
//

import XCTest
@testable import devgentic

final class MediatorExecutionGuardTests: XCTestCase {

    /// Counts how many times a tool's body actually ran. `AgentTool.run` is `@Sendable`, so this
    /// has to be safe to touch from whatever executor task invokes it.
    private final class ExecutionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.lock(); count += 1; lock.unlock() }
        var invocations: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func makeCountingTool(
        name: String,
        requiredParameter: String? = nil,
        counter: ExecutionCounter,
        requiresConfirmation: Bool = false
    ) -> AgentTool {
        let schema: ToolParameters
        if let requiredParameter {
            schema = SchemaBuilder.object(
                properties: [(requiredParameter, "string", "a required argument")],
                required: [requiredParameter]
            )
        } else {
            schema = SchemaBuilder.empty()
        }

        return AgentTool(
            name: name,
            description: "counts its own invocations",
            parameters: schema,
            requiresConfirmation: requiresConfirmation,
            textOnlyRun: { _ in
                counter.record()
                return "the tool ran"
            }
        )
    }

    private let mediator = ToolExecutionMediator()

    // MARK: - Positive control

    /// Without this, every assertion below would pass on a counter that never increments for any
    /// reason at all.
    func testValidCall_ActuallyRunsTheTool() async {
        let counter = ExecutionCounter()
        let tool = makeCountingTool(name: "probe", requiredParameter: "path", counter: counter)

        let result = await mediator.executePreparedTool(
            toolName: "probe",
            arguments: ["path": .string("/tmp/real")],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )

        XCTAssertEqual(counter.invocations, 1, "the control case must actually invoke the tool")
        XCTAssertTrue(result.isSuccess)
    }

    // MARK: - Argument validation must prevent execution

    func testMissingRequiredArgument_ToolNeverRuns() async {
        let counter = ExecutionCounter()
        let tool = makeCountingTool(name: "probe", requiredParameter: "path", counter: counter)

        let result = await mediator.executePreparedTool(
            toolName: "probe",
            arguments: [:],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )

        XCTAssertEqual(counter.invocations, 0, """
            The tool ran despite failing pre-dispatch validation. For a destructive tool that \
            means the irreversible action happened and the model was told the arguments were bad.
            """)
        XCTAssertFalse(result.isSuccess)
    }

    func testEmptyRequiredArgument_ToolNeverRuns() async {
        let counter = ExecutionCounter()
        let tool = makeCountingTool(name: "probe", requiredParameter: "path", counter: counter)

        let result = await mediator.executePreparedTool(
            toolName: "probe",
            arguments: ["path": .string("")],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )

        XCTAssertEqual(counter.invocations, 0)
        XCTAssertFalse(result.isSuccess)
    }

    func testWhitespaceOnlyRequiredArgument_ToolNeverRuns() async {
        let counter = ExecutionCounter()
        let tool = makeCountingTool(name: "probe", requiredParameter: "path", counter: counter)

        _ = await mediator.executePreparedTool(
            toolName: "probe",
            arguments: ["path": .string("   \n\t ")],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )

        XCTAssertEqual(counter.invocations, 0,
                       "a whitespace-only path is not a path; the tool must not run on it")
    }

    func testNullRequiredArgument_ToolNeverRuns() async {
        let counter = ExecutionCounter()
        let tool = makeCountingTool(name: "probe", requiredParameter: "path", counter: counter)

        _ = await mediator.executePreparedTool(
            toolName: "probe",
            arguments: ["path": .null],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )

        XCTAssertEqual(counter.invocations, 0)
    }

    // MARK: - A hallucinated name must not reach any tool

    func testHallucinatedToolName_NoAvailableToolRuns() async {
        let counter = ExecutionCounter()
        let tool = makeCountingTool(name: "real_tool", counter: counter)

        let result = await mediator.executePreparedTool(
            toolName: "imaginary_tool",
            arguments: [:],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )

        XCTAssertEqual(counter.invocations, 0,
                       "a call for a tool that does not exist must not reach a tool that does")
        if case .hallucinated = result {} else {
            XCTFail("expected .hallucinated, got \(result)")
        }
    }

    /// The mediator strips `<|`-style decoration a model may append to a tool name before looking
    /// it up. That recovery must resolve to the RIGHT tool — a sanitiser that matched loosely
    /// would run something the model did not ask for.
    func testDecoratedToolName_ResolvesToTheIntendedTool() async {
        let wanted = ExecutionCounter()
        let other = ExecutionCounter()
        let tools = [
            makeCountingTool(name: "read_file", counter: wanted),
            makeCountingTool(name: "delete_file", counter: other),
        ]

        _ = await mediator.executePreparedTool(
            toolName: "read_file<|end|>",
            arguments: [:],
            availableTools: tools,
            parentContext: TestTraceContext.make()
        )

        XCTAssertEqual(wanted.invocations, 1, "the decorated name should still resolve")
        XCTAssertEqual(other.invocations, 0, "and must not reach any other tool")
    }

    // MARK: - Confirmation

    /// `prepareDispatch` is the gate the HITL banner sits behind. It must not run anything —
    /// the whole point is that the user decides first.
    func testRequiresConfirmation_PrepareDispatchRunsNothing() {
        let counter = ExecutionCounter()
        let tool = makeCountingTool(name: "delete_file", counter: counter, requiresConfirmation: true)

        let outcome = mediator.prepareDispatch(
            toolName: "delete_file",
            arguments: ["path": .string("/tmp/x")],
            availableTools: [tool]
        )

        guard case .requiresConfirmation = outcome else {
            return XCTFail("expected .requiresConfirmation, got \(outcome)")
        }
        XCTAssertEqual(counter.invocations, 0, """
            The tool ran while the user was still being asked whether to allow it. That is the \
            confirmation gate failing open — the shape of the Action-node gate that shipped as \
            dead code.
            """)
    }

    // MARK: - Artifacts

    /// Media artifacts are the one part of a tool's result that is not a String, so they have
    /// their own opportunity to be dropped between the tool and the executor.
    func testSuccessfulCall_PreservesMediaArtifacts() async {
        let artifact = MediaArtifact(
            kind: .image,
            reference: .diskPath(URL(fileURLWithPath: "/tmp/harness-artifact.png")),
            mimeType: "image/png"
        )
        let tool = AgentTool(
            name: "artifact_tool",
            description: "returns an artifact",
            parameters: SchemaBuilder.empty(),
            run: { _ in ("done", [artifact]) }
        )

        let result = await mediator.executePreparedTool(
            toolName: "artifact_tool",
            arguments: [:],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.artifacts.count, 1,
                       "an artifact produced by the tool must survive the mediator")
    }

    /// A failed call carries no artifacts — attaching one to a failure would put a file
    /// reference into the timeline for an operation that did not happen.
    func testFailedCall_CarriesNoArtifacts() async {
        let tool = AgentTool(
            name: "failing_tool",
            description: "throws",
            parameters: SchemaBuilder.empty(),
            run: { _ in throw NSError(domain: "test", code: 1) }
        )

        let result = await mediator.executePreparedTool(
            toolName: "failing_tool",
            arguments: [:],
            availableTools: [tool],
            parentContext: TestTraceContext.make()
        )

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.artifacts.isEmpty)
    }
}
