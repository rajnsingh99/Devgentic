// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RejectedProfileCreationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class RejectedProfileCreationTests: XCTestCase {

    private func profile(named name: String) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"))))
    }

    // MARK: - The refusal is reachable

    /// The register's exact scenario: a 150-character name. Nothing in the sheet stops the user
    /// typing it — `isContinueButtonDisabled` only checks for emptiness — so this is a rejection an
    /// ordinary user reaches by pasting a sentence into the name field.
    func testAnOverlongNameIsRejected() {
        let errors = ProfileValidator.validate(profile(named: String(repeating: "a", count: 150)))

        XCTAssertTrue(errors.contains { $0.field == "displayName" },
                      "the create path must actually refuse this — otherwise A64's catch arm is dead code")
    }

    func testANameAtTheLimitIsAccepted() {
        let atLimit = String(repeating: "a", count: ProfileValidationLimits.maxDisplayNameLength)
        let errors = ProfileValidator.validate(profile(named: atLimit))

        XCTAssertFalse(errors.contains { $0.field == "displayName" },
                       "the cap is inclusive — an off-by-one here would refuse a legal name")
    }

    func testAnEmptyNameIsRejected() {
        let errors = ProfileValidator.validate(profile(named: "   "))
        XCTAssertTrue(errors.contains { $0.field == "displayName" })
    }

    // MARK: - The message is worth rendering

    /// ⚠️ This string is now drawn under the name field. If it were empty the sheet would stay open
    /// showing nothing, which is worse than the toast it replaced — the user would see a button that
    /// did nothing at all.
    func testTheRejectionCarriesAUsableMessage() throws {
        let errors = ProfileValidator.validate(profile(named: String(repeating: "a", count: 150)))
        let nameError = try XCTUnwrap(errors.first { $0.field == "displayName" })

        XCTAssertFalse(nameError.message.trimmingCharacters(in: .whitespaces).isEmpty)
        XCTAssertTrue(nameError.message.contains("\(ProfileValidationLimits.maxDisplayNameLength)"),
                      "the message has to state the limit — 'invalid name' does not tell the user what to fix")
    }

    /// The sheet renders `error.localizedDescription`, so the store's wrapper has to forward the
    /// validator's message rather than flattening it to something generic.
    func testTheStoreErrorForwardsTheValidatorMessage() throws {
        let errors = ProfileValidator.validate(profile(named: String(repeating: "a", count: 150)))
        let nameError = try XCTUnwrap(errors.first { $0.field == "displayName" })

        let storeError = ProfileStoreError.validationFailed(errors)

        XCTAssertEqual(storeError.errorDescription, nameError.message,
                       "a generic 'Validation failed.' here would make the inline error useless")
        XCTAssertFalse(storeError.localizedDescription.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// A valid profile must not trip any of this — otherwise the sheet would refuse to close on a
    /// perfectly good create, which is a worse failure than the one being fixed.
    func testAValidProfileProducesNoErrors() {
        XCTAssertTrue(ProfileValidator.validate(profile(named: "Coding Assistant")).isEmpty)
    }
}
