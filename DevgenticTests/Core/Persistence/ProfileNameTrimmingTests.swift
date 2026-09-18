// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileNameTrimmingTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Register A76 — new profiles were saved with the UNTRIMMED display name while every check around
//  the save compared the trimmed one, so a whitespace-padded duplicate slipped past the warning and
//  then evaded it forever.
//
//  `createDefaultProfile` is private to a SwiftUI view, so what is asserted here is the asymmetry
//  that made the bug possible: what duplicate detection compares, and what the validator measures.
//  Both work on trimmed text — which is precisely why persisting the raw string was wrong.
//

import XCTest
@testable import devgentic

final class ProfileNameTrimmingTests: XCTestCase {

    private func profile(named name: String) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"))))
    }

    /// The sheet's duplicate check is `trimmed.lowercased()` against existing names. Once a padded
    /// name is PERSISTED, that same comparison keeps matching — so the warning shows for a profile
    /// that already exists and the user can never resolve it by renaming.
    func testDuplicateDetectionComparesTrimmedNames() {
        let existing = ["Research"]
        let candidate = "  Research  ".trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(existing.contains { $0.lowercased() == candidate.lowercased() },
                      "' Research ' and 'Research' are the same name to every check in the sheet — "
                      + "so saving them as two distinct rows produces a sidebar that reads double")
    }

    /// ⚠️ The length cap measures the TRIMMED name, so a padded name at the boundary validates on
    /// one string and would have been stored as a longer one. Persisting the trimmed value keeps
    /// what was measured and what was written the same thing.
    func testTheLengthCapMeasuresTheTrimmedName() {
        let padded = "  " + String(repeating: "a", count: ProfileValidationLimits.maxDisplayNameLength) + "  "

        XCTAssertGreaterThan(padded.count, ProfileValidationLimits.maxDisplayNameLength)
        XCTAssertTrue(ProfileValidator.validate(profile(named: padded))
            .allSatisfy { $0.field != "displayName" },
                      "the validator trims before measuring — so the stored name must be trimmed too")
    }

    /// A whitespace-only name is refused, which is the other half of the same asymmetry.
    func testAWhitespaceOnlyNameIsRefused() {
        XCTAssertTrue(ProfileValidator.validate(profile(named: "   \n  "))
            .contains { $0.field == "displayName" })
    }

    /// Trimming must not touch interior spacing — "My  Agent" is a legitimate name.
    func testInteriorWhitespaceIsPreserved() {
        let name = "  My  Coding Agent  ".trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(name, "My  Coding Agent")
    }

    /// Duplication goes through the same name the user typed into the duplicate sheet, so the
    /// trimmed-vs-raw asymmetry must not reappear on that path either.
    func testDuplicatingUsesTheNameItWasGiven() {
        let copy = profile(named: "Research").duplicated(as: "Research copy")
        XCTAssertEqual(copy.displayName, "Research copy")
    }
}
