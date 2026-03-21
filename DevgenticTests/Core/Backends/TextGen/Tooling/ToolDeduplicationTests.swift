//
//  ToolDeduplicationTests.swift
//  DevgenticTests
//
//  TDD: T3 — Tool Deduplication Signatures
//

import XCTest
@testable import devgentic

final class ToolDeduplicationTests: XCTestCase {

    // MARK: - Helpers

    private func makePendingToolCall(name: String, arguments: [String: JSONValue] = [:]) -> PendingToolCall {
        PendingToolCall(id: UUID().uuidString, name: name, arguments: arguments)
    }

    // MARK: - T3a: Identical Tool + Args → Deduplicated

    func testDedup_IdenticalCalls_ReturnsOne() {
        let call1 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/tmp")])
        let call2 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/tmp")])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - T3b: Same Tool, Different Args → NOT Deduplicated

    func testDedup_SameToolDifferentArgs_ReturnsTwo() {
        let call1 = makePendingToolCall(name: "read_file", arguments: ["path": .string("/a.txt")])
        let call2 = makePendingToolCall(name: "read_file", arguments: ["path": .string("/b.txt")])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - T3c: Different Tools, Same Args → NOT Deduplicated

    func testDedup_DifferentToolsSameArgs_ReturnsTwo() {
        let call1 = makePendingToolCall(name: "read_file", arguments: ["path": .string("/a.txt")])
        let call2 = makePendingToolCall(name: "delete_file", arguments: ["path": .string("/a.txt")])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - T3d: Empty Args → Valid Signature

    func testDedup_EmptyArgs_ValidSignature() {
        let call1 = makePendingToolCall(name: "get_system_stats", arguments: [:])
        let call2 = makePendingToolCall(name: "get_system_stats", arguments: [:])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - T3e: Three Calls, Two Identical → Returns Two

    func testDedup_ThreeCallsTwoIdentical_ReturnsTwo() {
        let call1 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/tmp")])
        let call2 = makePendingToolCall(name: "read_file", arguments: ["path": .string("/a.txt")])
        let call3 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/tmp")])
        let result = deduplicateToolCalls([call1, call2, call3])
        XCTAssertEqual(result.count, 2)
    }
}
