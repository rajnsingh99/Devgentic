// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TestFixtures.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

enum TestFixtures {

    /// Every fixture in `DevgenticTests/Core/Utils/Fixtures/`, as (name, extension).
    ///
    /// ⚠️ Hand-listed on purpose. The bundle cannot be asked "what SHOULD you contain" — an empty
    /// Resources directory answers "nothing" perfectly happily, which is exactly the state this
    /// list exists to detect. Adding a fixture here without shipping it turns the canary red,
    /// which is the correct direction.
    static let inventory: [(name: String, ext: String)] = [
        ("sample", "csv"), ("sample", "docx"), ("sample", "pdf"), ("sample", "pptx"),
        ("sample", "rtf"), ("sample", "xlsx"),
        ("empty", "pdf"), ("sample_scanned", "pdf"),
    ]

    /// Locates a fixture in the test bundle.
    ///
    /// Throws `XCTSkip` rather than trapping: the calling test cannot run, but every other test
    /// in the target still can. `FixtureAvailabilityTests` is what makes the absence visible.
    static func url(_ name: String, ext: String, in owner: AnyObject) throws -> URL {
        let bundle = Bundle(for: type(of: owner))
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw XCTSkip(
                "Missing test fixture '\(name).\(ext)' in \(bundle.bundleURL.lastPathComponent). "
                + "It lives at DevgenticTests/Core/Utils/Fixtures/ and is copied into the test "
                + "bundle's Resources by the synced group. An EMPTY Resources directory means the "
                + "built .xctest is stale — delete "
                + "DerivedData/.../devgentic.app/Contents/PlugIns/devgenticTests.xctest and rebuild; "
                + "an incremental build will not repair it. See FixtureAvailabilityTests."
            )
        }
        return url
    }

    /// Fixtures that are not in `bundle`, as "name.ext".
    static func missing(in bundle: Bundle) -> [String] {
        inventory
            .filter { bundle.url(forResource: $0.name, withExtension: $0.ext) == nil }
            .map { "\($0.name).\($0.ext)" }
    }
}

/// The canary. ⚠️ Its whole job is to FAIL where the loader skips.
final class FixtureAvailabilityTests: XCTestCase {

    func testEveryDocumentFixtureIsInTheTestBundle() {
        let bundle = Bundle(for: type(of: self))
        let missing = TestFixtures.missing(in: bundle)

        XCTAssertTrue(
            missing.isEmpty,
            "\(missing.count) of \(TestFixtures.inventory.count) document fixtures are absent from "
            + "the test bundle: \(missing.joined(separator: ", ")). CONSEQUENCE: every test that "
            + "reads one has SKIPPED — the suite is green while \(missing.count) fixtures' worth of "
            + "extractor coverage did not run. If ALL of them are listed the built .xctest is "
            + "stale: delete it and rebuild, because an incremental build treats it as up to date."
        )
    }

    /// ⚠️ Non-vacuity. A canary that reads an empty inventory passes while checking nothing —
    /// the same shape as the empty Resources directory it exists to catch.
    func testTheInventoryIsNotEmpty() {
        XCTAssertGreaterThanOrEqual(TestFixtures.inventory.count, 8,
                                    "the fixture inventory shrank; the check above may be vacuous")
    }
}
