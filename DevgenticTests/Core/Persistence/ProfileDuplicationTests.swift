// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ProfileDuplicationTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Register A31 — duplicating a profile dropped `fileContextStrategy`.
//
//  The defect was structural, not a typo: `DuplicateProfileSheet` built its copy by calling the
//  memberwise init with four arguments, and every parameter of that init has a default, so omitting
//  the fifth compiled cleanly and produced `nil`. The fix makes duplication copy-by-default
//  (`duplicated(as:)` re-stamps identity on a whole-value copy), so the test that matters most here
//  is the LAST one — it fails if a future property is dropped the same way, without anyone having to
//  remember to extend this file.
//

import XCTest
@testable import devgentic

final class ProfileDuplicationTests: XCTestCase {

    private func agent(strategy: FileContextStrategy?) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: "Researcher",
            lastSelected: Date(timeIntervalSince1970: 1_000_000),
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5"),
                tools: [],
                instructions: "Be precise.")),
            fileContextStrategy: strategy)
    }

    // MARK: - The reported defect

    /// ⚠️ This is the case that actually changed behaviour. Agent's DEFAULT is `.stateless`, so a
    /// dropped strategy resolves back to `.stateless` — meaning it is an agent set explicitly to
    /// `.directInjection` whose copy silently switched to handing the model file PATHS instead of
    /// file CONTENT. Same prompt, different answer, nothing on screen to explain it.
    func testDuplicatingAnAgentPreservesDirectInjection() {
        let source = agent(strategy: .directInjection)
        let copy = source.duplicated(as: "Researcher copy")

        XCTAssertEqual(copy.fileContextStrategy, .directInjection)
        XCTAssertEqual(copy.resolvedFileContextStrategy, .directInjection,
                       "dropping the override resolves to .stateless — a different send-time behaviour")
    }

    func testDuplicatingAnAgentPreservesStateless() {
        let copy = agent(strategy: .stateless).duplicated(as: "copy")
        XCTAssertEqual(copy.fileContextStrategy, .stateless)
    }

    /// A profile that never had an override must not gain one — the copy should resolve exactly as
    /// the source does, by the same route.
    func testDuplicatingAProfileWithNoOverrideKeepsItUnset() {
        let source = agent(strategy: nil)
        let copy = source.duplicated(as: "copy")

        XCTAssertNil(copy.fileContextStrategy)
        XCTAssertEqual(copy.resolvedFileContextStrategy, source.resolvedFileContextStrategy)
    }

    /// Documents *why* the bug was invisible for bots: their only available strategy is
    /// `.directInjection`, so `resolve` returns the same answer whether the override survived or
    /// not. The stored value was still being lost — it just could not be observed at send time.
    func testABotsResolvedStrategyIsUnaffectedEitherWay() {
        let bot = BackendProfileSnapshot(
            displayName: "Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"))),
            fileContextStrategy: .directInjection)

        XCTAssertEqual(bot.duplicated(as: "copy").resolvedFileContextStrategy, .directInjection)
        XCTAssertEqual(FileContextStrategy.resolve(nil, for: .bot), .directInjection)
    }

    // MARK: - Identity

    func testDuplicateTakesANewIdentityAndName() {
        let source = agent(strategy: .directInjection)
        let copy = source.duplicated(as: "Researcher copy")

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.displayName, "Researcher copy")
        XCTAssertEqual(source.displayName, "Researcher", "the source must not be mutated")
    }

    /// A copy has never been used, so it must not inherit the source's position in the
    /// most-recently-selected ordering.
    func testDuplicateClearsLastSelected() {
        XCTAssertNil(agent(strategy: .stateless).duplicated(as: "copy").lastSelected)
    }

    func testDuplicateCarriesTheProfileDetailsThemselves() throws {
        let copy = agent(strategy: .stateless).duplicated(as: "copy")
        guard case .agent(let config) = copy.details else {
            return XCTFail("expected the duplicate to still be an agent")
        }
        XCTAssertEqual(config.instructions, "Be precise.")
        XCTAssertEqual(config.llmConfig.modelName, "claude-opus-5")
    }

    // MARK: - The guard that outlives this file

    /// ⚠️ The point of the fix. Reflects over every stored property and asserts a duplicate differs
    /// from its source in the three identity fields and NOTHING else.
    ///
    /// A property added to `BackendProfileSnapshot` later is covered by this automatically: if
    /// someone reverts duplication to an explicit field list and forgets the new field, this fails
    /// and names it. That is precisely the failure mode A31 was — a silent omission that compiled.
    func testADuplicateDiffersFromItsSourceOnlyInIdentity() {
        let identityFields: Set<String> = ["id", "displayName", "lastSelected"]

        let source = agent(strategy: .directInjection)
        let copy = source.duplicated(as: "Researcher copy")

        let sourceFields = Dictionary(uniqueKeysWithValues:
            Mirror(reflecting: source).children.compactMap { child -> (String, Any)? in
                child.label.map { ($0, child.value) }
            })
        let copyFields = Dictionary(uniqueKeysWithValues:
            Mirror(reflecting: copy).children.compactMap { child -> (String, Any)? in
                child.label.map { ($0, child.value) }
            })

        XCTAssertFalse(sourceFields.isEmpty, "reflection found no stored properties — the guard would be vacuous")
        XCTAssertEqual(Set(sourceFields.keys), Set(copyFields.keys))

        for (name, sourceValue) in sourceFields where !identityFields.contains(name) {
            let copyDescription = copyFields[name].map { String(describing: $0) } ?? "<missing>"
            XCTAssertEqual(
                String(describing: sourceValue),
                copyDescription,
                "'\(name)' was not carried into the duplicate. Duplication must copy the whole "
                + "value and re-stamp identity — never list fields, which is how A31 happened.")
        }
    }
}
