// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillResolutionTests.swift
//  devgenticTests
//
//  What a run actually gets, resolved against the V6 library.
//
//  The test worth reading first is `testTheLibraryIsAuthoritativeForDescription`. That is the entire
//  reason a profile stores a REFERENCE instead of a copy — `description` is what the model routes
//  on, and under the old copy model editing a skill changed behaviour only for whichever profile
//  happened to press Rescan.
//
//  ⚠️ REWRITTEN 2026-09-14 from the registry-backed version. These were quarantined, not deleted,
//  because the behaviours they encode are still owed by the replacement: library authority for
//  description, deterministic name-collision handling, and unresolved selections being REPORTED
//  rather than silently dropped. One behaviour is new and did not exist before — version pinning.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SkillResolutionTests: XCTestCase {

    private var container: ModelContainer!
    private var store: SkillStore!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(for: DevgenticSchema.schema,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = SkillStore.shared
        store.setContainerForTesting(container)
    }

    override func tearDown() async throws {
        store?.setContainerForTesting(nil)
        store = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func seed(_ name: String, description: String = "Does a thing.", isDraft: Bool = false) throws -> SkillSD {
        try store.create(name: name, description: description, body: "# \(name)", isDraft: isDraft).get()
    }

    private func config(selections: [SkillSelection]? = nil) -> AgentConfig {
        AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                    tools: [], skillSelections: selections)
    }

    // MARK: - The library path

    func testResolvesLinkedSkillsFromTheLibrary() throws {
        let alpha = try seed("alpha")
        let beta = try seed("beta")
        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [
                .link(skillID: alpha.id, name: "alpha"),
                .link(skillID: beta.id, name: "beta")
            ]), profileName: "P"))

        XCTAssertEqual(outcome.manifests.map(\.name), ["alpha", "beta"])
        XCTAssertTrue(outcome.unresolved.isEmpty)
    }

    /// ⚠️ THE POINT OF THE WHOLE REFERENCE MODEL. The selection carries a stale `name` and no
    /// description at all; everything the model routes on comes from the library, so one edit
    /// reaches every linked profile at once.
    func testTheLibraryIsAuthoritativeForDescription() throws {
        let skill = try seed("code-review", description: "The CURRENT description.")
        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [
                SkillSelection(skillID: skill.id, name: "a-stale-name")
            ]), profileName: "P"))

        XCTAssertEqual(outcome.manifests.first?.description, "The CURRENT description.")
        XCTAssertEqual(outcome.manifests.first?.name, "code-review",
                       "even the NAME comes from the library — the stored one is a label for reporting")
    }

    func testDisabledSelectionsAreExcluded() throws {
        let alpha = try seed("alpha")
        let beta = try seed("beta")
        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [
                .link(skillID: alpha.id, name: "alpha", isEnabled: false),
                .link(skillID: beta.id, name: "beta")
            ]), profileName: "P"))

        XCTAssertEqual(outcome.manifests.map(\.name), ["beta"])
        XCTAssertTrue(outcome.unresolved.isEmpty, "disabled is a choice, not a failure — it must not be reported as one")
    }

    /// This order becomes prompt bytes, so it must not depend on insertion or storage order.
    func testResolvedSkillsAreNameSorted() throws {
        let zebra = try seed("zebra")
        let alpha = try seed("alpha")
        let middle = try seed("middle")
        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [
                .link(skillID: zebra.id, name: "zebra"),
                .link(skillID: middle.id, name: "middle"),
                .link(skillID: alpha.id, name: "alpha")
            ]), profileName: "P"))

        XCTAssertEqual(outcome.manifests.map(\.name), ["alpha", "middle", "zebra"])
    }

    /// ⚠️ The tools path is the cautionary tale: a deleted MCP source leaves orphan references with
    /// no row to un-tick and no error anyone sees.
    func testAMissingSkillIsReportedNotSilentlyDropped() throws {
        let alpha = try seed("alpha")
        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [
                .link(skillID: alpha.id, name: "alpha"),
                .link(skillID: "skill_deleted", name: "ghost")
            ]), profileName: "P"))

        XCTAssertEqual(outcome.manifests.map(\.name), ["alpha"])
        XCTAssertEqual(outcome.unresolved.map(\.name), ["ghost"],
                       "the user needs a NAMED row to remove — a silent drop leaves them wondering why a skill stopped working")
    }

    /// A draft is in the library but must never reach a run.
    func testADraftSkillDoesNotResolve() throws {
        let draft = try seed("half-written", isDraft: true)
        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [.link(skillID: draft.id, name: "half-written")]), profileName: "P"))

        XCTAssertTrue(outcome.manifests.isEmpty)
        XCTAssertEqual(outcome.unresolved.map(\.name), ["half-written"],
                       "reported, so the user can see why a linked skill is not being offered")
    }

    /// ⚠️ Unreadable ≠ "this profile has no skills". Reporting everything as unresolved keeps the
    /// configuration intact and lets the next run retry.
    func testAnUnreadableLibraryReportsEverythingUnresolved() throws {
        let alpha = try seed("alpha")
        let selections: [SkillSelection] = [.link(skillID: alpha.id, name: "alpha")]
        store.setContainerForTesting(nil)

        let outcome = try XCTUnwrap(SkillResolution.resolve(for: config(selections: selections), profileName: "P"))
        XCTAssertTrue(outcome.manifests.isEmpty)
        XCTAssertEqual(outcome.unresolved.count, 1)
    }

    // MARK: - Pinning (new in V6)

    func testAPinnedVersionIsResolvedInsteadOfTheLatest() throws {
        let skill = try seed("code-review", description: "Version one.")
        let firstID = try XCTUnwrap(skill.latestVersion).id
        _ = try store.addVersion(toSkillWithID: skill.id, description: "Version two.",
                                 body: "# v2", allowedTools: nil, files: [], note: "n").get()

        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [
                .link(skillID: skill.id, name: "code-review", pinnedVersionID: firstID)
            ]), profileName: "P"))

        XCTAssertEqual(outcome.manifests.first?.description, "Version one.",
                       "a pin is what lets one agent keep a known-good skill while everyone else moves forward")
    }

    func testAnUnpinnedSelectionFollowsTheLatest() throws {
        let skill = try seed("code-review", description: "Version one.")
        _ = try store.addVersion(toSkillWithID: skill.id, description: "Version two.",
                                 body: "# v2", allowedTools: nil, files: [], note: "n").get()

        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [.link(skillID: skill.id, name: "code-review")]), profileName: "P"))
        XCTAssertEqual(outcome.manifests.first?.description, "Version two.")
    }

    /// ⚠️ A dangling pin resolves to NOTHING, deliberately. Falling back to `latest` would hand the
    /// model different instructions from the ones the user pinned — the single thing pinning exists
    /// to prevent — and it would do so silently.
    func testADanglingPinIsReportedRatherThanFallingBackToLatest() throws {
        let skill = try seed("code-review", description: "Current.")
        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [
                .link(skillID: skill.id, name: "code-review", pinnedVersionID: "skver_gone")
            ]), profileName: "P"))

        XCTAssertTrue(outcome.manifests.isEmpty, "a pin that cannot be honoured must not silently become 'latest'")
        XCTAssertEqual(outcome.unresolved.count, 1)
    }

    // MARK: - Name collisions

    /// Skills are addressed by NAME at run time but keyed by an opaque id, so two `code-review`s are
    /// an ordinary situation with a real consequence: one is unreachable.
    func testTwoSkillsSharingANameResolveToOneDeterministically() throws {
        let first = try seed("code-review", description: "First.")
        let second = try seed("code-review", description: "Second.")
        let selections: [SkillSelection] = [
            .link(skillID: first.id, name: "code-review"),
            .link(skillID: second.id, name: "code-review")
        ]

        let a = try XCTUnwrap(SkillResolution.resolve(for: config(selections: selections), profileName: "P"))
        let b = try XCTUnwrap(SkillResolution.resolve(for: config(selections: selections.reversed()), profileName: "P"))

        XCTAssertEqual(a.manifests.count, 1)
        XCTAssertEqual(a.nameCollisions, ["code-review"])
        XCTAssertEqual(a.manifests.first?.description, b.manifests.first?.description,
                       "⚠️ the SAME copy must win regardless of selection order — unstable behaviour across runs is worse than either choice")
    }

    func testDistinctNamesProduceNoCollisionReport() throws {
        let alpha = try seed("alpha")
        let beta = try seed("beta")
        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config(selections: [
                .link(skillID: alpha.id, name: "alpha"),
                .link(skillID: beta.id, name: "beta")
            ]), profileName: "P"))
        XCTAssertTrue(outcome.nameCollisions.isEmpty)
    }

    // MARK: - No skills at all

    func testNoSkillsAtAllResolvesToNil() {
        XCTAssertNil(SkillResolution.resolve(for: config(), profileName: "P"),
                     "an explicit nil keeps the 'no load_skill tool, no prompt layer' behaviour distinct from an empty list")
    }

    func testAnEmptySelectionListResolvesToNil() {
        XCTAssertNil(SkillResolution.resolve(for: config(selections: []), profileName: "P"))
    }
}
