// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillImportPlanTests.swift
//  devgenticTests
//
//  What happens when an import's name is already in the library.
//
//  ⚠️ This decision USED TO BE IMPLICIT in `SkillStore.create` always inserting, which meant
//  re-importing a skill — the obvious way to update one — produced a second skill with the same
//  name. Skills are addressed by NAME at run time, so one of the two became unreachable by
//  `load_skill`: a library that looks right and an agent reading the wrong instructions. And with no
//  delete UI at the time, the duplicate could not be removed.
//

import XCTest
import SwiftData
@testable import devgentic

final class SkillImportPlanTests: XCTestCase {

    private typealias Row = (id: String, name: String, displayName: String, versionCount: Int)

    private let library: [Row] = [
        (id: "skill_a", name: "code-review", displayName: "Code Review", versionCount: 3),
        (id: "skill_b", name: "weekly-status", displayName: "Weekly Status", versionCount: 1)
    ]

    // MARK: - Classification

    func testANewNameCollidesWithNothing() {
        XCTAssertEqual(SkillImportPlan.collision(for: "brand-new", existing: library), .none)
    }

    func testOneMatchIsReportedWithWhatTheUserNeedsToDecide() {
        XCTAssertEqual(SkillImportPlan.collision(for: "code-review", existing: library),
                       .one(skillID: "skill_a", displayName: "Code Review", versionCount: 3))
    }

    func testSeveralMatchesAreReportedAsAmbiguous() {
        let crowded = library + [(id: "skill_c", name: "code-review", displayName: "Other", versionCount: 1)]
        XCTAssertEqual(SkillImportPlan.collision(for: "code-review", existing: crowded), .several(count: 2))
    }

    /// ⚠️ Matched on `name`, not `displayName`. `name` is what `load_skill` resolves, so it is the
    /// one whose collision costs something; two skills may share a label harmlessly.
    func testMatchingIsOnTheAddressableNameNotTheLabel() {
        let rows: [Row] = [(id: "skill_x", name: "actual-name", displayName: "code-review", versionCount: 1)]
        XCTAssertEqual(SkillImportPlan.collision(for: "code-review", existing: rows), .none)
    }

    // MARK: - Defaults

    func testANewNameDefaultsToCreating() {
        XCTAssertEqual(SkillImportPlan.defaultResolution(for: .none), .createNew)
    }

    /// ⚠️ Versioning is the default because it is REVERSIBLE — versions are append-only, so the
    /// previous one stays in the history — and because it reaches every profile linked to that
    /// skill, which is the whole point of the library owning one copy.
    func testOneMatchDefaultsToAddingAVersion() {
        XCTAssertEqual(
            SkillImportPlan.defaultResolution(for: .one(skillID: "skill_a", displayName: "Code Review", versionCount: 3)),
            .addVersion(skillID: "skill_a"))
    }

    /// ⚠️ THE CASE THAT MUST NOT GUESS. With several matches there is no defensible choice, and an
    /// update landing in a skill the user did not mean is silent and unrecoverable — the same
    /// reasoning that makes `update_skill` refuse on ambiguity.
    func testSeveralMatchesDefaultToSkipping() {
        XCTAssertEqual(SkillImportPlan.defaultResolution(for: .several(count: 2)), .skip)
    }

    /// ⚠️ "Import as new" is never a DEFAULT anywhere. It is the outcome that creates a name an
    /// agent cannot fully reach, and no later action merges the two back.
    func testCreateNewIsNeverTheDefaultWhenAnythingCollides() {
        for collision: SkillImportPlan.Collision in [
            .one(skillID: "skill_a", displayName: "X", versionCount: 1),
            .several(count: 4)
        ] {
            XCTAssertNotEqual(SkillImportPlan.defaultResolution(for: collision), .createNew)
        }
    }

    // MARK: - Explanations

    func testNoCollisionNeedsNoExplanation() {
        XCTAssertNil(SkillImportPlan.explanation(for: .none, skillName: "x"))
    }

    /// The explanation has to name the CONSEQUENCE, not the mechanism — "adding a version updates it
    /// everywhere it is linked" is what the user is actually deciding about.
    func testTheOneMatchExplanationNamesTheConsequence() throws {
        let text = try XCTUnwrap(SkillImportPlan.explanation(
            for: .one(skillID: "a", displayName: "Code Review", versionCount: 3), skillName: "code-review"))
        XCTAssertTrue(text.contains("everywhere it is linked"))
        XCTAssertTrue(text.contains("stays in its history"), "reversibility is why this is the default")
    }

    func testTheAmbiguousExplanationSaysWhyNothingIsPreselected() throws {
        let text = try XCTUnwrap(SkillImportPlan.explanation(for: .several(count: 2), skillName: "code-review"))
        XCTAssertTrue(text.contains("unreachable"))
    }
}

// MARK: - Through the store

@MainActor
final class SkillImportResolutionStoreTests: XCTestCase {

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

    private func ingested(_ name: String, description: String, body: String) -> IngestedSkill {
        IngestedSkill(name: name, description: description, body: body, allowedTools: nil,
                      files: [], sourceLabel: "\(name).zip")
    }

    /// ⚠️ THE DEFECT THIS WHOLE FILE EXISTS FOR: re-importing used to create a second skill.
    func testReImportingAsAVersionUpdatesInPlaceInsteadOfDuplicating() throws {
        let original = try store.create(name: "code-review", description: "v1", body: "OLD").get()

        let update = ingested("code-review", description: "v2", body: "NEW")
        _ = try store.addVersion(toSkillWithID: original.id, description: update.description,
                                 body: update.body, allowedTools: update.allowedTools,
                                 files: update.files, note: "Re-imported.",
                                 declaredName: update.name).get()

        XCTAssertEqual(try store.fetchSkills().get().count, 1, "re-importing must not add a second skill")
        XCTAssertEqual(original.latestVersion?.body, "NEW")
        XCTAssertEqual(original.versions.count, 2, "and the previous version must still be restorable")
    }

    /// The opt-in outcome still works — two skills may legitimately share a name.
    func testImportingAsNewStillProducesASecondSkill() throws {
        _ = try store.create(name: "code-review", description: "v1", body: "OLD").get()
        _ = try store.createSkill(from: ingested("code-review", description: "other", body: "OTHER")).get()
        XCTAssertEqual(try store.fetchSkills(named: "code-review").get().count, 2)
    }

    /// ⚠️ The store is the BACKSTOP for a mis-aimed "add version": two skills can share a name, so a
    /// user could point the update at a skill this import is not actually an update of.
    func testAddingAVersionWithAMismatchedNameIsRefusedByTheStore() throws {
        let other = try store.create(name: "something-else", description: "d", body: "b").get()
        let result = store.addVersion(toSkillWithID: other.id, description: "d", body: "b",
                                      allowedTools: nil, files: [], note: "n",
                                      declaredName: "code-review")
        guard case .failure(.nameImmutable) = result else {
            return XCTFail("a mis-aimed version must be refused, got \(result)")
        }
        XCTAssertEqual(other.versions.count, 1)
    }

    /// Deleting must actually remove it — the counterpart to the duplicate problem, since a
    /// duplicate the user cannot delete is the state that made this urgent.
    func testDeletingRemovesTheSkillAndItsVersions() throws {
        let skill = try store.create(name: "doomed", description: "d", body: "b").get()
        _ = try store.addVersion(toSkillWithID: skill.id, description: "d2", body: "b2",
                                 allowedTools: nil, files: [], note: "n").get()

        try store.deleteSkill(id: skill.id).get()
        XCTAssertTrue(try store.fetchSkills().get().isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<SkillVersionSD>()).isEmpty,
                      "versions must cascade — orphans would accumulate with no UI to reach them")
    }
}
