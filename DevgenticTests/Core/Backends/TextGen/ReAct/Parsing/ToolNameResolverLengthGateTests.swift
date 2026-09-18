// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolNameResolverLengthGateTests.swift
//  DevgenticTests
//
//  #15.4 — the fuzzy-match length gate: keep near-equal-length typos, reject short→long
//  prefix fragments that Jaro-Winkler's prefix boost over-scores. The target tool's
//  arg-schema check (in `resolve`) remains the primary guard against destructive remaps.
//

import XCTest
@testable import devgentic

final class ToolNameResolverLengthGateTests: XCTestCase {

    func testLengthGate_AllowsNearEqualLengthTypos() {
        XCTAssertTrue(ToolNameResolver.lengthCompatible("read_file", "read_fil"))     // 9 vs 8
        XCTAssertTrue(ToolNameResolver.lengthCompatible("delete_file", "delete_fil")) // 11 vs 10
        XCTAssertTrue(ToolNameResolver.lengthCompatible("search", "serch"))           // 6 vs 5
    }

    func testLengthGate_RejectsPrefixFragments() {
        XCTAssertFalse(ToolNameResolver.lengthCompatible("read", "read_file_recursive")) // 4 vs 19
        XCTAssertFalse(ToolNameResolver.lengthCompatible("list", "list_directory"))      // 4 vs 14
    }

    func testLengthGate_RejectsTooShort() {
        XCTAssertFalse(ToolNameResolver.lengthCompatible("rd", "read")) // shorter < 3 chars
        XCTAssertFalse(ToolNameResolver.lengthCompatible("", "read_file"))
    }
}
