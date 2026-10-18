// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SmartSearchNullCoercionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SmartSearchNullCoercionTests: XCTestCase {

    // MARK: - Helpers

    private func decode(_ dict: [String: Any]) throws -> SmartSearchTool.Arguments {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(SmartSearchTool.Arguments.self, from: data)
    }

    // MARK: - Null String Coercion

    func testScope_LiteralNull_CoercedToNil() throws {
        let args = try decode(["search_term": "test", "search_scope": "null"])
        XCTAssertNil(args.search_scope, "Literal 'null' string from LLM should be coerced to nil")
    }

    func testScope_LiteralNullUppercase_CoercedToNil() throws {
        let args = try decode(["search_term": "test", "search_scope": "NULL"])
        XCTAssertNil(args.search_scope, "Case-insensitive 'NULL' should be coerced to nil")
    }

    func testScope_LiteralNullMixedCase_CoercedToNil() throws {
        let args = try decode(["search_term": "test", "search_scope": "Null"])
        XCTAssertNil(args.search_scope, "Case-insensitive 'Null' should be coerced to nil")
    }

    func testScope_ValidPath_PreservedAsIs() throws {
        let args = try decode(["search_term": "test", "search_scope": "/Users/alice/Documents"])
        XCTAssertEqual(args.search_scope, "/Users/alice/Documents")
    }

    func testScope_Omitted_IsNil() throws {
        let args = try decode(["search_term": "test"])
        XCTAssertNil(args.search_scope)
    }

    // MARK: - Search Term Aliases

    func testSearchTerm_PrimaryKey() throws {
        let args = try decode(["search_term": "hello"])
        XCTAssertEqual(args.search_term, "hello")
    }

    func testSearchTerm_Alias_Query() throws {
        let args = try decode(["query": "hello"])
        XCTAssertEqual(args.search_term, "hello")
    }

    func testSearchTerm_Alias_Keyword() throws {
        let args = try decode(["keyword": "hello"])
        XCTAssertEqual(args.search_term, "hello")
    }

    // MARK: - Scope Aliases

    func testScope_Alias_Path() throws {
        let args = try decode(["search_term": "test", "path": "/tmp"])
        XCTAssertEqual(args.search_scope, "/tmp")
    }

    func testScope_Alias_Folder() throws {
        let args = try decode(["search_term": "test", "folder": "/home"])
        XCTAssertEqual(args.search_scope, "/home")
    }
}
