// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalToolManagerTests.swift
//  DevgenticTests
//
//  TDD: T6 — Safe Tool Whitelist
//

import XCTest
@testable import devgentic

final class LocalToolManagerTests: XCTestCase {

    // MARK: - T6a: Whitelisted Tools → requiresConfirmation = false

    func testWhitelist_ListDirectory_NoConfirmation() {
        let wrapper = NativeToolWrapper(nativeTool: ListDirectoryTool())
        XCTAssertFalse(wrapper.requiresConfirmation)
    }

    func testWhitelist_ReadFile_NoConfirmation() {
        let wrapper = NativeToolWrapper(nativeTool: ReadFileTool())
        XCTAssertFalse(wrapper.requiresConfirmation)
    }

    func testWhitelist_GetSystemStats_NoConfirmation() {
        let wrapper = NativeToolWrapper(nativeTool: GetSystemStatsTool())
        XCTAssertFalse(wrapper.requiresConfirmation)
    }

    func testWhitelist_SpotlightSearch_NoConfirmation() {
        let wrapper = NativeToolWrapper(nativeTool: SmartSearchTool())
        XCTAssertFalse(wrapper.requiresConfirmation)
    }

    func testWhitelist_FsReadMetadata_NoConfirmation() {
        let wrapper = NativeToolWrapper(nativeTool: ReadMetadataTool())
        XCTAssertFalse(wrapper.requiresConfirmation)
    }

    // MARK: - T6b: Non-Whitelisted Tools → requiresConfirmation = true

    func testNonWhitelist_WriteFile_RequiresConfirmation() {
        let wrapper = NativeToolWrapper(nativeTool: WriteFileTool())
        XCTAssertTrue(wrapper.requiresConfirmation)
    }

    func testNonWhitelist_DeleteFile_RequiresConfirmation() {
        let wrapper = NativeToolWrapper(nativeTool: DeleteFileTool())
        XCTAssertTrue(wrapper.requiresConfirmation)
    }

    func testNonWhitelist_MoveFile_RequiresConfirmation() {
        let wrapper = NativeToolWrapper(nativeTool: MoveFileTool())
        XCTAssertTrue(wrapper.requiresConfirmation)
    }

    func testNonWhitelist_CopyFile_RequiresConfirmation() {
        let wrapper = NativeToolWrapper(nativeTool: CopyFileTool())
        XCTAssertTrue(wrapper.requiresConfirmation)
    }

    // MARK: - T6c: Tool Registration Properties

    func testWrapper_HasNonEmptyNameAndDescription() {
        let wrapper = NativeToolWrapper(nativeTool: ListDirectoryTool())
        XCTAssertFalse(wrapper.name.isEmpty)
        XCTAssertFalse(wrapper.description.isEmpty)
    }

    func testWrapper_NameMatchesUnderlyingTool() {
        let wrapper = NativeToolWrapper(nativeTool: ReadFileTool())
        XCTAssertEqual(wrapper.name, "read_file")
    }
}
