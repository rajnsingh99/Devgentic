// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DeleteFileSafetyTests.swift
//  DevgenticTests
//
//  TDD: Tier 1a — DeleteFileTool Critical Path Safety Guard
//

import XCTest
@testable import devgentic

final class DeleteFileSafetyTests: XCTestCase {

    // MARK: - Blocked Critical Paths

    func testCriticalPath_Root_IsBlocked() {
        XCTAssertTrue(DeleteFileTool.isCriticalPath("/"))
    }

    func testCriticalPath_Users_IsBlocked() {
        XCTAssertTrue(DeleteFileTool.isCriticalPath("/Users"))
    }

    func testCriticalPath_System_IsBlocked() {
        XCTAssertTrue(DeleteFileTool.isCriticalPath("/System"))
    }

    func testCriticalPath_Library_IsBlocked() {
        XCTAssertTrue(DeleteFileTool.isCriticalPath("/Library"))
    }

    func testCriticalPath_Bin_IsBlocked() {
        XCTAssertTrue(DeleteFileTool.isCriticalPath("/bin"))
    }

    func testCriticalPath_Usr_IsBlocked() {
        XCTAssertTrue(DeleteFileTool.isCriticalPath("/usr"))
    }

    func testCriticalPath_HomeDirectory_IsBlocked() {
        XCTAssertTrue(DeleteFileTool.isCriticalPath(NSHomeDirectory()))
    }

    // MARK: - Allowed Normal Paths

    func testNormalPath_TmpFile_IsAllowed() {
        XCTAssertFalse(DeleteFileTool.isCriticalPath("/tmp/some_file.txt"))
    }

    func testNormalPath_UserSubdirectory_IsAllowed() {
        XCTAssertFalse(DeleteFileTool.isCriticalPath("/Users/alice/Documents/test.txt"))
    }

    func testNormalPath_UsrLocal_IsAllowed() {
        // /usr is blocked but /usr/local should NOT be — it's a subdirectory
        XCTAssertFalse(DeleteFileTool.isCriticalPath("/usr/local/bin/tool"))
    }

    func testNormalPath_LibrarySubdir_IsAllowed() {
        // /Library is blocked but subdirectories are NOT
        XCTAssertFalse(DeleteFileTool.isCriticalPath("/Library/Preferences/com.test.plist"))
    }

    // MARK: - Edge Cases

    func testCriticalPath_ExactMatchOnly_NotSubstring() {
        // Verify these are exact path matches, not substring matches
        XCTAssertFalse(DeleteFileTool.isCriticalPath("/Users/admin"))
        XCTAssertFalse(DeleteFileTool.isCriticalPath("/System/Library"))
        XCTAssertFalse(DeleteFileTool.isCriticalPath("/bin/zsh"))
    }
}
