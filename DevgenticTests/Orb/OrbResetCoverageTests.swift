// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbResetCoverageTests.swift
//  DevgenticTests
//
//  [Audit Batch 2 · #44] A source-reading guard so the reset list cannot fall behind a phase again.
//
//  It already did: `resetAll()` predated Phase 6 and silently skipped all five of its keys. That
//  mattered more than a normal omission because those five controls live only inside the Developer
//  card — so once Developer mode was switched back off, Reset was the ONLY way to turn voice
//  approvals off, and it did not.
//

import XCTest
@testable import devgentic

final class OrbResetCoverageTests: XCTestCase {

    /// Keys deliberately excluded, each with the reason it is not a "Orb setting".
    /// ⚠️ Adding to this set is a decision — state why, or add the key to the reset instead.
    private let exempt: [String: String] = [:]

    func testEveryOrbSettingsKeyIsCoveredByResetAll() throws {
        let appSettings = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Orb
            .deletingLastPathComponent()   // devgenticTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Devgentic/Interfaces/Main/Views/Sidebar/Settings/AppSettings.swift")
        let source = try String(contentsOf: appSettings, encoding: .utf8)

        // `static let orbSomethingKey = "storedName"` → capture the STORED NAME, which is what
        // `resetAll` actually removes.
        let pattern = #"static let (orb\w*Key)\s*=\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: range)

        XCTAssertGreaterThan(matches.count, 10, "Found almost no Orb keys — the regex or the path is wrong, and a passing test would be meaningless.")

        let covered = Set(OrbConfigManager.allResettableKeys)
        var missing: [String] = []
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source) else { continue }
            let symbol = String(source[nameRange])
            let stored = String(source[valueRange])
            if exempt[stored] != nil { continue }
            if !covered.contains(stored) { missing.append("\(symbol) (\"\(stored)\")") }
        }

        XCTAssertTrue(missing.isEmpty, """
            These Orb settings keys are NOT cleared by "Reset Orb": \(missing.joined(separator: ", ")).
            The Recovery row promises "reset every Orb setting", and several Orb controls are \
            reachable only inside the Developer card — so a key missing here can become unreachable \
            entirely. Add it to OrbConfigManager.allResettableKeys, or add it to `exempt` with a reason.
            """)
    }

    /// The Phase 6 keys specifically, named so a regression reads as itself rather than as a
    /// generic count mismatch.
    func testThePhaseSixKeysAreResettable() {
        let covered = Set(OrbConfigManager.allResettableKeys)
        for key in [AppSettings.orbAmbientAnnouncementsKey,
                    AppSettings.orbAmbientThresholdKey,
                    AppSettings.orbVoiceApprovalsKey,
                    AppSettings.orbApprovalKeywordsKey,
                    AppSettings.orbDenialKeywordsKey] {
            XCTAssertTrue(covered.contains(key), "\(key) must be cleared by Reset Orb — its control is Developer-only.")
        }
    }

    func testTheResetListHasNoDuplicates() {
        let keys = OrbConfigManager.allResettableKeys
        XCTAssertEqual(Set(keys).count, keys.count, "A duplicate in the reset list is a merge accident.")
    }
}
