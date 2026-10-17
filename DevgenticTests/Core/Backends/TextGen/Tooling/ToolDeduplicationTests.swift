// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    // MARK: - T3f: Path Normalization — Trailing Slash

    func testDedup_TrailingSlash_Normalized() {
        let call1 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/Users/alice/Desktop/Acme")])
        let call2 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/Users/alice/Desktop/Acme/")])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 1, "Trailing slash should be normalized, producing identical signatures")
    }

    // MARK: - T3g: Path Normalization — Tilde Expansion

    func testDedup_TildeExpansion_Normalized() {
        let expanded = NSString("~/Desktop").expandingTildeInPath
        let call1 = makePendingToolCall(name: "read_file", arguments: ["path": .string("~/Desktop")])
        let call2 = makePendingToolCall(name: "read_file", arguments: ["path": .string(expanded)])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 1, "Tilde path should normalize to same as expanded path")
    }

    // MARK: - T3h: Path Normalization — Dot Segments

    func testDedup_DotSegments_Normalized() {
        let call1 = makePendingToolCall(name: "read_file", arguments: ["path": .string("/Users/alice/Desktop/./file.txt")])
        let call2 = makePendingToolCall(name: "read_file", arguments: ["path": .string("/Users/alice/Desktop/file.txt")])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 1, "Dot segments should be resolved during normalization")
    }

    // MARK: - T3i: Path Normalization — Non-Path Args Not Affected

    func testDedup_NonPathArgs_NotAffected() {
        let call1 = makePendingToolCall(name: "spotlight_search", arguments: ["search_term": .string("Acme")])
        let call2 = makePendingToolCall(name: "spotlight_search", arguments: ["search_term": .string("Acme/")])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 2, "Non-path string args should NOT be normalized (Acme != Acme/)")
    }

    // MARK: - T3j: Path Normalization — Root Slash Preserved

    func testDedup_RootSlash_Preserved() {
        let call1 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/")])
        let call2 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/")])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 1, "Root '/' should remain unchanged and still dedup correctly")
    }

    // MARK: - T3k: Semantic Dedup — Multiple write_file to Same Path

    func testSemanticDedup_MultipleWritesToSamePath_KeepsLast() {
        // Model emits 3 write_file calls to the same path with slightly different content
        // (common repetition pattern from small models). Only the last should survive.
        let call1 = makePendingToolCall(name: "write_file", arguments: ["path": .string("/Users/alice/Desktop/test.txt"), "content": .string("\nHello")])
        let call2 = makePendingToolCall(name: "write_file", arguments: ["path": .string("/Users/alice/Desktop/test.txt"), "content": .string("\nHello\n")])
        let call3 = makePendingToolCall(name: "write_file", arguments: ["path": .string("/Users/alice/Desktop/test.txt"), "content": .string("Hello\n")])
        let result = deduplicateToolCalls([call1, call2, call3])
        XCTAssertEqual(result.count, 1, "Multiple writes to same path should collapse to last intent")
        XCTAssertEqual(result.first?.arguments["content"], .string("Hello\n"), "Should keep the last write's content")
    }

    // MARK: - T3l: Semantic Dedup — Write + Read to Same Path Preserved

    func testSemanticDedup_ReadAndWriteSamePath_BothPreserved() {
        // read_file is NOT destructive — should not be collapsed with write_file
        let read = makePendingToolCall(name: "read_file", arguments: ["path": .string("/Users/alice/Desktop/test.txt")])
        let write = makePendingToolCall(name: "write_file", arguments: ["path": .string("/Users/alice/Desktop/test.txt"), "content": .string("Hello")])
        let result = deduplicateToolCalls([read, write])
        XCTAssertEqual(result.count, 2, "read_file and write_file to same path should both survive")
    }

    // MARK: - T3m: Semantic Dedup — Writes to Different Paths Preserved

    func testSemanticDedup_WritesToDifferentPaths_AllPreserved() {
        let call1 = makePendingToolCall(name: "write_file", arguments: ["path": .string("/tmp/a.txt"), "content": .string("Hello")])
        let call2 = makePendingToolCall(name: "write_file", arguments: ["path": .string("/tmp/b.txt"), "content": .string("Hello")])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 2, "Writes to different paths should both survive")
    }

    // MARK: - T3n: Semantic Dedup — Non-Destructive Tools Not Affected

    func testSemanticDedup_MultipleListDirectory_NotCollapsed() {
        // list_directory is NOT in the destructive set — even multiple calls to same path
        // with different args should survive exact dedup but NOT trigger semantic dedup
        let call1 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/tmp"), "recursive": .bool(true)])
        let call2 = makePendingToolCall(name: "list_directory", arguments: ["path": .string("/tmp"), "recursive": .bool(false)])
        let result = deduplicateToolCalls([call1, call2])
        XCTAssertEqual(result.count, 2, "Non-destructive tools should not be semantically deduped")
    }

    // MARK: - T3o: Semantic Dedup — Mixed Tools with Writes

    func testSemanticDedup_MixedToolsWithWrites_CorrectCollapsing() {
        // read + 3 writes to same path + read = should keep read, last write, read
        let read1 = makePendingToolCall(name: "read_file", arguments: ["path": .string("/tmp/test.txt")])
        let write1 = makePendingToolCall(name: "write_file", arguments: ["path": .string("/tmp/test.txt"), "content": .string("v1")])
        let write2 = makePendingToolCall(name: "write_file", arguments: ["path": .string("/tmp/test.txt"), "content": .string("v2")])
        let write3 = makePendingToolCall(name: "write_file", arguments: ["path": .string("/tmp/test.txt"), "content": .string("v3")])
        let read2 = makePendingToolCall(name: "read_file", arguments: ["path": .string("/tmp/other.txt")])
        let result = deduplicateToolCalls([read1, write1, write2, write3, read2])
        XCTAssertEqual(result.count, 3, "Should keep read1, last write (v3), read2")
        XCTAssertEqual(result[0].name, "read_file")
        XCTAssertEqual(result[1].name, "write_file")
        XCTAssertEqual(result[1].arguments["content"], .string("v3"), "Should keep last write content")
        XCTAssertEqual(result[2].name, "read_file")
    }
}
