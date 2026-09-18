// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeToolArgumentTests.swift
//  DevgenticTests
//
//  TDD: T4 — Argument Alias Resolution for NativeFileSystemTools
//

import XCTest
@testable import devgentic

final class NativeToolArgumentTests: XCTestCase {

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from dict: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - ListDirectoryTool Aliases

    func testListDirectory_PrimaryKey_Path() throws {
        let args = try decode(ListDirectoryTool.Arguments.self, from: ["path": "/tmp"])
        XCTAssertEqual(args.path, "/tmp")
    }

    func testListDirectory_Alias_Directory() throws {
        let args = try decode(ListDirectoryTool.Arguments.self, from: ["directory": "/home"])
        XCTAssertEqual(args.path, "/home")
    }

    func testListDirectory_Alias_Folder() throws {
        let args = try decode(ListDirectoryTool.Arguments.self, from: ["folder": "/docs"])
        XCTAssertEqual(args.path, "/docs")
    }

    func testListDirectory_Alias_Dir() throws {
        let args = try decode(ListDirectoryTool.Arguments.self, from: ["dir": "/bin"])
        XCTAssertEqual(args.path, "/bin")
    }

    func testListDirectory_Alias_DirectoryPath() throws {
        let args = try decode(ListDirectoryTool.Arguments.self, from: ["directoryPath": "/usr"])
        XCTAssertEqual(args.path, "/usr")
    }

    func testListDirectory_UnknownKey_ThrowsDecodingError() {
        XCTAssertThrowsError(try decode(ListDirectoryTool.Arguments.self, from: ["unknown_key": "/tmp"])) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
                return
            }
            XCTAssertTrue(context.debugDescription.contains("Checked aliases"))
        }
    }

    // MARK: - ReadFileTool Aliases

    func testReadFile_PrimaryKey_Path() throws {
        let args = try decode(ReadFileTool.Arguments.self, from: ["path": "/tmp/a.txt"])
        XCTAssertEqual(args.path, "/tmp/a.txt")
    }

    func testReadFile_Alias_FilePath() throws {
        let args = try decode(ReadFileTool.Arguments.self, from: ["file_path": "/tmp/b.txt"])
        XCTAssertEqual(args.path, "/tmp/b.txt")
    }

    func testReadFile_Alias_File() throws {
        let args = try decode(ReadFileTool.Arguments.self, from: ["file": "/tmp/c.txt"])
        XCTAssertEqual(args.path, "/tmp/c.txt")
    }

    func testReadFile_EmptyDict_ThrowsDecodingError() {
        XCTAssertThrowsError(try decode(ReadFileTool.Arguments.self, from: [String: Any]())) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - WriteFileTool Aliases

    func testWriteFile_PrimaryKeys() throws {
        let args = try decode(WriteFileTool.Arguments.self, from: ["path": "/f.txt", "content": "hello"])
        XCTAssertEqual(args.path, "/f.txt")
        XCTAssertEqual(args.content, "hello")
        XCTAssertNil(args.append)
    }

    func testWriteFile_ContentAlias_Text() throws {
        let args = try decode(WriteFileTool.Arguments.self, from: ["path": "/f.txt", "text": "hello"])
        XCTAssertEqual(args.content, "hello")
    }

    func testWriteFile_ContentAlias_Body() throws {
        let args = try decode(WriteFileTool.Arguments.self, from: ["path": "/f.txt", "body": "hello"])
        XCTAssertEqual(args.content, "hello")
    }

    func testWriteFile_AppendBool() throws {
        let args = try decode(WriteFileTool.Arguments.self, from: ["path": "/f.txt", "content": "hello", "append": true])
        XCTAssertEqual(args.append, true)
    }

    func testWriteFile_AppendStringCoercion() throws {
        let args = try decode(WriteFileTool.Arguments.self, from: ["path": "/f.txt", "content": "hello", "append": "true"])
        XCTAssertEqual(args.append, true)
    }

    func testWriteFile_MissingPath_ThrowsDecodingError() {
        XCTAssertThrowsError(try decode(WriteFileTool.Arguments.self, from: ["content": "hello"])) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
                return
            }
        }
    }

    func testWriteFile_MissingContent_ThrowsDecodingError() {
        XCTAssertThrowsError(try decode(WriteFileTool.Arguments.self, from: ["path": "/f.txt"])) { error in
            guard case DecodingError.dataCorrupted = error else {
                XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
                return
            }
        }
    }

    // MARK: - MoveFileTool Aliases

    func testMoveFile_PrimaryKeys() throws {
        let args = try decode(MoveFileTool.Arguments.self, from: ["source": "/a", "destination": "/b"])
        XCTAssertEqual(args.source, "/a")
        XCTAssertEqual(args.destination, "/b")
    }

    func testMoveFile_Aliases_FromTo() throws {
        let args = try decode(MoveFileTool.Arguments.self, from: ["from": "/a", "to": "/b"])
        XCTAssertEqual(args.source, "/a")
        XCTAssertEqual(args.destination, "/b")
    }

    func testMoveFile_Aliases_SrcDest() throws {
        let args = try decode(MoveFileTool.Arguments.self, from: ["src": "/a", "dest": "/b"])
        XCTAssertEqual(args.source, "/a")
        XCTAssertEqual(args.destination, "/b")
    }

    // MARK: - CopyFileTool Aliases

    func testCopyFile_PrimaryKeys() throws {
        let args = try decode(CopyFileTool.Arguments.self, from: ["source": "/a", "destination": "/b"])
        XCTAssertEqual(args.source, "/a")
        XCTAssertEqual(args.destination, "/b")
    }

    func testCopyFile_Aliases_FromCopyPath() throws {
        let args = try decode(CopyFileTool.Arguments.self, from: ["from": "/a", "copy_path": "/b"])
        XCTAssertEqual(args.source, "/a")
        XCTAssertEqual(args.destination, "/b")
    }

    // MARK: - CreateFolderTool Aliases

    func testCreateFolder_PrimaryKey_Path() throws {
        let args = try decode(CreateFolderTool.Arguments.self, from: ["path": "/new"])
        XCTAssertEqual(args.path, "/new")
    }

    func testCreateFolder_Alias_Folder() throws {
        let args = try decode(CreateFolderTool.Arguments.self, from: ["folder": "/new"])
        XCTAssertEqual(args.path, "/new")
    }

    func testCreateFolder_Alias_Name() throws {
        let args = try decode(CreateFolderTool.Arguments.self, from: ["name": "/new"])
        XCTAssertEqual(args.path, "/new")
    }

    func testCreateFolder_Alias_Directory() throws {
        let args = try decode(CreateFolderTool.Arguments.self, from: ["directory": "/new"])
        XCTAssertEqual(args.path, "/new")
    }

    // MARK: - DeleteFileTool Aliases

    func testDeleteFile_PrimaryKey_Path() throws {
        let args = try decode(DeleteFileTool.Arguments.self, from: ["path": "/tmp/file.txt"])
        XCTAssertEqual(args.path, "/tmp/file.txt")
    }

    func testDeleteFile_Alias_File() throws {
        let args = try decode(DeleteFileTool.Arguments.self, from: ["file": "/tmp/file.txt"])
        XCTAssertEqual(args.path, "/tmp/file.txt")
    }

    func testDeleteFile_Alias_Target() throws {
        let args = try decode(DeleteFileTool.Arguments.self, from: ["target": "/tmp/file.txt"])
        XCTAssertEqual(args.path, "/tmp/file.txt")
    }
}
