// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FilePathResolverTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class FilePathResolverTests: XCTestCase {

    // MARK: - Resolution

    func testResolve_AbsolutePath_Unchanged() {
        XCTAssertEqual(FilePathResolver.resolve("/tmp/devgentic_test"), "/tmp/devgentic_test")
        XCTAssertEqual(FilePathResolver.resolve("/Users/alice/Desktop/x"), "/Users/alice/Desktop/x")
    }

    func testResolve_TildePath_ExpandsToHome() {
        let home = NSHomeDirectory()
        XCTAssertEqual(FilePathResolver.resolve("~/Desktop/x"), "\(home)/Desktop/x")
        XCTAssertEqual(FilePathResolver.resolve("~"), home)
    }

    func testResolve_BareRelativePath_AnchorsToHome_NotRoot() {
        let home = NSHomeDirectory()
        // The bug: this used to stay "test_data" → resolved against CWD "/" →
        // "/test_data" → "volume is read only". It must land in HOME instead.
        XCTAssertEqual(FilePathResolver.resolve("test_data"), "\(home)/test_data")
        XCTAssertFalse(FilePathResolver.resolve("test_data").hasPrefix("/test_data"))
    }

    func testResolve_NestedRelativePath_AnchorsToHome() {
        let home = NSHomeDirectory()
        XCTAssertEqual(FilePathResolver.resolve("project/index.html"), "\(home)/project/index.html")
        XCTAssertEqual(FilePathResolver.resolve("Desktop/notes.txt"), "\(home)/Desktop/notes.txt")
    }

    // MARK: - write_file parent creation

    private func decodeWriteArgs(_ dict: [String: Any]) throws -> WriteFileTool.Arguments {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(WriteFileTool.Arguments.self, from: data)
    }

    func testWriteFile_CreatesMissingParentDirectory() async throws {
        // Parent dir doesn't exist yet — previously failed with the misleading
        // "the folder '<filename>' doesn't exist". Now write_file creates it.
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devgentic_fpr_\(UUID().uuidString)")
        let target = base.appendingPathComponent("nested/dir/file.txt")
        defer { try? FileManager.default.removeItem(at: base) }

        let tool = WriteFileTool()
        let args = try decodeWriteArgs(["path": target.path, "content": "hello alpha"])
        let result = try await tool.call(arguments: args)

        XCTAssertTrue(result.hasPrefix("Successfully"), "Expected success, got: \(result)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "File should exist after write")
        let written = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(written, "hello alpha")
    }

    func testWriteFile_MissingParent_ErrorNamesRealPath_NotLeafFolder() async throws {
        // If a write genuinely can't happen, the message must state the real target
        // path, not Foundation's misleading "the folder '<leaf>' doesn't exist" that
        // taught the model the whole filesystem was read-only. Point at a path whose
        // parent can't be created (a file used as a directory component).
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devgentic_fpr_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        // Create a FILE, then try to write "under" it as if it were a folder.
        try "x".data(using: .utf8)!.write(to: base)
        let target = base.appendingPathComponent("child.txt")

        let tool = WriteFileTool()
        let args = try decodeWriteArgs(["path": target.path, "content": "data"])
        let result = try await tool.call(arguments: args)

        XCTAssertTrue(result.hasPrefix("Error:"), "Expected an error, got: \(result)")
        XCTAssertTrue(result.contains(target.path), "Error should name the real target path: \(result)")
    }
}
