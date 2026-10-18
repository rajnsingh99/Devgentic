// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WrapToolTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

// MARK: - Mock DevgenticTool for Testing

private struct MockTool: DevgenticTool {
    let category = "Test"
    let name = "mock_tool"
    let description = "A mock tool for testing"

    struct Arguments: Decodable, Sendable {
        let value: String
    }

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(properties: [("value", "string", "test value")], required: ["value"])
    }

    func call(arguments: Arguments) async throws -> String {
        return "result:\(arguments.value)"
    }
}

private struct ThrowingTool: DevgenticTool {
    let category = "Test"
    let name = "throwing_tool"
    let description = "A tool that always throws"

    struct Arguments: Decodable, Sendable {
        let value: String
    }

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(properties: [("value", "string", "test value")], required: ["value"])
    }

    func call(arguments: Arguments) async throws -> String {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tool execution failed"])
    }
}

final class WrapToolTests: XCTestCase {

    // MARK: - Helpers

    private func makeAgentTool<T: DevgenticTool>(from tool: T) -> AgentTool {
        AgentTool(
            name: tool.name,
            description: tool.description,
            parameters: tool.parameterSchema,
            requiresConfirmation: false
        ) { data in
            let args = try JSONDecoder().decode(T.Arguments.self, from: data)
            return try await tool.execute(arguments: args)
        }
    }

    private func jsonData(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - T9a: Valid JSON Args → Decoded and Executed

    func testWrapTool_ValidArgs_ReturnsOutput() async throws {
        let agentTool = makeAgentTool(from: MockTool())
        let data = try jsonData(["value": "hello"])
        let result = try await agentTool.run(data)
        XCTAssertEqual(result.output, "result:hello")
        XCTAssertTrue(result.artifacts.isEmpty)
    }

    // MARK: - T9b: Invalid JSON Args → Throws DecodingError

    func testWrapTool_InvalidArgs_ThrowsError() async {
        let agentTool = makeAgentTool(from: MockTool())
        do {
            let data = try jsonData(["wrong_key": "x"])
            _ = try await agentTool.run(data)
            XCTFail("Expected error for invalid arguments")
        } catch {
            XCTAssertTrue(error is DecodingError, "Expected DecodingError, got \(type(of: error))")
        }
    }

    // MARK: - T9c: Tool Throws → Error Propagates

    func testWrapTool_ToolThrows_ErrorPropagates() async {
        let agentTool = makeAgentTool(from: ThrowingTool())
        do {
            let data = try jsonData(["value": "test"])
            _ = try await agentTool.run(data)
            XCTFail("Expected error from throwing tool")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Tool execution failed"))
        }
    }

    // MARK: - T9d: Tool Returns Correctly Typed Output

    func testWrapTool_OutputPreservesContent() async throws {
        let agentTool = makeAgentTool(from: MockTool())
        let data = try jsonData(["value": "world"])
        let result = try await agentTool.run(data)
        XCTAssertEqual(result.output, "result:world")
    }
}
