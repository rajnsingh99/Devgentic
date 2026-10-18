// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPToolSchemaDecodingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class MCPToolSchemaDecodingTests: XCTestCase {

    // MARK: - Helpers

    private func decodeParameters(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> ToolParameters {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ToolParameters.self, from: data)
    }

    // MARK: - The shapes that used to drop a tool entirely

    /// The single most common real-world case: a tool where every argument is
    /// optional, so the server omits `required` altogether.
    func testDecode_MissingRequiredKey_DefaultsToEmptyAndKeepsTool() throws {
        let params = try decodeParameters("""
        { "type": "object", "properties": { "query": { "type": "string" } } }
        """)

        XCTAssertEqual(params.required, [], "Absent `required` must mean 'nothing required', not a decode failure")
        XCTAssertEqual(params.type, "object")
        XCTAssertEqual(params.properties["query"]?.type, "string")
    }

    /// A schema with no `type` at the top level is an object schema by convention.
    func testDecode_MissingTopLevelType_DefaultsToObject() throws {
        let params = try decodeParameters("""
        { "properties": { "path": { "type": "string" } }, "required": ["path"] }
        """)

        XCTAssertEqual(params.type, "object")
        XCTAssertEqual(params.required, ["path"])
    }

    /// A tool that takes no arguments at all.
    func testDecode_EmptyObjectSchema_YieldsEmptyProperties() throws {
        let params = try decodeParameters("{}")

        XCTAssertEqual(params.type, "object")
        XCTAssertTrue(params.properties.isEmpty)
        XCTAssertTrue(params.required.isEmpty)
    }

    /// The nullable-union form: `"type": ["string", "null"]`.
    func testDecode_UnionType_PicksFirstNonNullMember() throws {
        let params = try decodeParameters("""
        { "type": "object", "properties": { "cursor": { "type": ["string", "null"] } } }
        """)

        XCTAssertEqual(params.properties["cursor"]?.type, "string",
                       "A nullable union must resolve to its meaningful member, not fail")
    }

    /// A property described only by `enum` / `oneOf` / `$ref`, with no `type` at all.
    func testDecode_PropertyWithoutType_FallsBackToString() throws {
        let params = try decodeParameters("""
        {
          "type": "object",
          "properties": {
            "mode": { "enum": ["fast", "slow"], "description": "Execution mode" },
            "ref":  { "$ref": "#/definitions/Thing" }
          }
        }
        """)

        XCTAssertEqual(params.properties.count, 2, "Neither property may be dropped")
        XCTAssertEqual(params.properties["mode"]?.type, "string")
        XCTAssertEqual(params.properties["mode"]?.description, "Execution mode")
        XCTAssertEqual(params.properties["ref"]?.type, "string")
    }

    /// `items` carrying a nested object schema rather than the flat `["type": "string"]`
    /// shape the local tools use. Lossy by design — the nested structure is dropped —
    /// but it must not take the whole tool with it.
    func testDecode_ObjectValuedItems_KeepsStringEntriesAndKeepsTool() throws {
        let params = try decodeParameters("""
        {
          "type": "object",
          "properties": {
            "edits": {
              "type": "array",
              "items": { "type": "object", "properties": { "path": { "type": "string" } } }
            }
          }
        }
        """)

        let edits = try XCTUnwrap(params.properties["edits"])
        XCTAssertEqual(edits.type, "array")
        XCTAssertEqual(edits.items?["type"], "object",
                       "This is an array OF OBJECTS, so the item type is `object`")
        XCTAssertNil(edits.items?["properties"],
                     "The nested property map is dropped — documented lossiness, not a failure")
    }

    /// A property whose value is not an object at all must not fail the tool.
    func testDecode_MalformedPropertyValue_DoesNotThrow() throws {
        let params = try decodeParameters("""
        { "type": "object", "properties": { "weird": "not-an-object" } }
        """)

        // Whatever the fallback, the important guarantee is that decoding succeeded
        // and the tool survives to reach the agent.
        XCTAssertEqual(params.type, "object")
    }

    // MARK: - Regression guard: the local-tool shape must be untouched

    /// The exact shape `AdvancedFileSystemTools` and friends build by hand.
    func testDecode_CanonicalLocalToolSchema_Unchanged() throws {
        let params = try decodeParameters("""
        {
          "type": "object",
          "properties": {
            "sourcePaths": {
              "type": "array",
              "description": "Array of full file paths to move.",
              "items": { "type": "string" }
            },
            "destinationFolder": { "type": "string", "description": "The target folder path." }
          },
          "required": ["sourcePaths", "destinationFolder"]
        }
        """)

        XCTAssertEqual(params.type, "object")
        XCTAssertEqual(Set(params.required), ["sourcePaths", "destinationFolder"])
        XCTAssertEqual(params.properties["sourcePaths"]?.type, "array")
        XCTAssertEqual(params.properties["sourcePaths"]?.items?["type"], "string")
        XCTAssertEqual(params.properties["destinationFolder"]?.description, "The target folder path.")
    }

    /// Encode → decode round-trip must be stable, since `parametersData` is persisted
    /// as JSON in `MCPToolDefinitionModel`.
    func testRoundTrip_EncodeThenDecode_PreservesValues() throws {
        let original = ToolParameters(
            type: "object",
            properties: [
                "path": ToolParameterProperty(type: "string", description: "A path", items: nil),
                "names": ToolParameterProperty(type: "array", description: nil, items: ["type": "string"]),
            ],
            required: ["path"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolParameters.self, from: data)

        XCTAssertEqual(decoded, original, "Persisted schemas must survive a round-trip unchanged")
    }

    // MARK: - The memberwise init must still exist

    /// The lenient `init(from:)` lives in an extension precisely so the synthesized
    /// memberwise init survives for the ~12 local-tool call sites. If someone moves it
    /// into the struct body, this stops compiling.
    func testMemberwiseInit_StillAvailable() {
        let property = ToolParameterProperty(type: "string", description: "d", items: nil)
        let params = ToolParameters(type: "object", properties: ["a": property], required: ["a"])

        XCTAssertEqual(params.properties["a"]?.description, "d")
    }
}
