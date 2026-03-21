//
//  ToolExecutionMediatorTests.swift
//  DevgenticTests
//
//  TDD: T5 — Permission Pre-flight + T7 — Dispatch Outcomes
//

import XCTest
@testable import devgentic

final class ToolExecutionMediatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeAgentTool(name: String, requiresConfirmation: Bool = false) -> AgentTool {
        AgentTool(
            name: name,
            description: "test tool",
            parameters: SchemaBuilder.empty(),
            requiresConfirmation: requiresConfirmation,
            textOnlyRun: { _ in "mock output" }
        )
    }

    private let mediator = ToolExecutionMediator()

    // MARK: - T5: Permission Pre-flight Mapping

    func testPermissions_FsSmartSearch_RequiresFileSystemPermissions() {
        let perms = ToolExecutionMediator.getRequiredPermissions(for: "fs_smart_search")
        XCTAssertEqual(perms.count, 3)
        XCTAssertTrue(perms.contains(.desktop))
        XCTAssertTrue(perms.contains(.documents))
        XCTAssertTrue(perms.contains(.downloads))
    }

    func testPermissions_FsReadMetadata_RequiresFileSystemPermissions() {
        let perms = ToolExecutionMediator.getRequiredPermissions(for: "fs_read_metadata")
        XCTAssertEqual(perms.count, 3)
    }

    func testPermissions_FsWatchFolder_RequiresFileSystemPermissions() {
        let perms = ToolExecutionMediator.getRequiredPermissions(for: "fs_watch_folder")
        XCTAssertEqual(perms.count, 3)
    }

    func testPermissions_FsOrganizeBatch_RequiresFileSystemPermissions() {
        let perms = ToolExecutionMediator.getRequiredPermissions(for: "fs_organize_batch")
        XCTAssertEqual(perms.count, 3)
    }

    func testPermissions_RunApplescript_RequiresAccessibility() {
        let perms = ToolExecutionMediator.getRequiredPermissions(for: "run_applescript")
        XCTAssertEqual(perms, [.accessibility])
    }

    func testPermissions_ListDirectory_NoSpecialPermissions() {
        let perms = ToolExecutionMediator.getRequiredPermissions(for: "list_directory")
        XCTAssertTrue(perms.isEmpty)
    }

    func testPermissions_UnknownTool_NoSpecialPermissions() {
        let perms = ToolExecutionMediator.getRequiredPermissions(for: "some_unknown_tool")
        XCTAssertTrue(perms.isEmpty)
    }

    // MARK: - T7: Dispatch Outcomes

    func testPrepareDispatch_KnownTool_NoConfirmation_ReturnsPendingExecution() {
        let tool = makeAgentTool(name: "read_file", requiresConfirmation: false)
        let outcome = mediator.prepareDispatch(toolName: "read_file", arguments: [:], availableTools: [tool])

        if case .executed(let result, _) = outcome {
            if case .systemError(let reason) = result {
                XCTAssertEqual(reason, "Pending Execution")
            } else {
                XCTFail("Expected .systemError('Pending Execution'), got \(result)")
            }
        } else {
            XCTFail("Expected .executed, got \(outcome)")
        }
    }

    func testPrepareDispatch_KnownTool_RequiresConfirmation_ReturnsRequiresConfirmation() {
        let tool = makeAgentTool(name: "write_file", requiresConfirmation: true)
        let outcome = mediator.prepareDispatch(toolName: "write_file", arguments: [:], availableTools: [tool])

        if case .requiresConfirmation = outcome {
            // pass
        } else {
            XCTFail("Expected .requiresConfirmation, got \(outcome)")
        }
    }

    func testPrepareDispatch_UnknownTool_ReturnsHallucinated() {
        let tool = makeAgentTool(name: "read_file")
        let outcome = mediator.prepareDispatch(toolName: "hallucinated_tool", arguments: [:], availableTools: [tool])

        if case .executed(let result, _) = outcome {
            if case .hallucinated(let toolName, let available) = result {
                XCTAssertEqual(toolName, "hallucinated_tool")
                XCTAssertTrue(available.contains("read_file"))
            } else {
                XCTFail("Expected .hallucinated, got \(result)")
            }
        } else {
            XCTFail("Expected .executed, got \(outcome)")
        }
    }

    func testPrepareDispatch_Hallucination_ContainsAvailableToolNames() {
        let tools = [
            makeAgentTool(name: "read_file"),
            makeAgentTool(name: "write_file"),
            makeAgentTool(name: "list_directory")
        ]
        let outcome = mediator.prepareDispatch(toolName: "fake_tool", arguments: [:], availableTools: tools)

        if case .executed(let result, _) = outcome,
           case .hallucinated(_, let available) = result {
            XCTAssertEqual(available.sorted(), ["list_directory", "read_file", "write_file"])
        } else {
            XCTFail("Expected hallucinated result with available tool names")
        }
    }
}
