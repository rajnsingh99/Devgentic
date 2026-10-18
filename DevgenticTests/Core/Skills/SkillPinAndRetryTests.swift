// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillPinAndRetryTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SkillPinBehaviourTests: XCTestCase {

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

    private func config(_ selections: [SkillSelection]) -> AgentConfig {
        AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                    tools: [], skillSelections: selections)
    }

    /// The whole point of a pin: an update must NOT reach a pinned profile.
    func testAPinnedProfileDoesNotSeeALaterVersion() throws {
        let skill = try store.create(name: "code-review", description: "v1", body: "ONE").get()
        let firstID = try XCTUnwrap(skill.latestVersion).id
        _ = try store.addVersion(toSkillWithID: skill.id, description: "v2", body: "TWO",
                                 allowedTools: nil, files: [], note: "update").get()

        let pinned = try XCTUnwrap(SkillResolution.resolve(
            for: config([.link(skillID: skill.id, name: "code-review", pinnedVersionID: firstID)]),
            profileName: "Pinned"))
        let following = try XCTUnwrap(SkillResolution.resolve(
            for: config([.link(skillID: skill.id, name: "code-review")]), profileName: "Latest"))

        XCTAssertEqual(pinned.manifests.first?.description, "v1")
        XCTAssertEqual(following.manifests.first?.description, "v2",
                       "the control: an unpinned profile DOES move, so the assertion above means something")
    }

    /// ⚠️ Changing a pin must not disturb `isEnabled`. Removing and re-adding the selection — the
    /// obvious implementation — would silently re-enable a skill the user had switched off, making a
    /// pin change read as a settings reset.
    func testChangingAPinPreservesTheEnabledFlag() throws {
        let skill = try store.create(name: "code-review", description: "v1", body: "ONE").get()
        let versionID = try XCTUnwrap(skill.latestVersion).id

        var selection = SkillSelection.link(skillID: skill.id, name: "code-review", isEnabled: false)
        selection.pinnedVersionID = versionID

        XCTAssertFalse(selection.isEnabled)
        XCTAssertEqual(selection.pinnedVersionID, versionID)

        // And a disabled-but-pinned selection still contributes nothing to a run.
        let outcome = try XCTUnwrap(SkillResolution.resolve(for: config([selection]), profileName: "P"))
        XCTAssertTrue(outcome.manifests.isEmpty)
        XCTAssertTrue(outcome.unresolved.isEmpty, "disabled is a choice, not a failure")
    }

    /// ⚠️ A pin whose version is gone resolves to NOTHING and is REPORTED. Falling back to latest
    /// would hand the model instructions the user deliberately froze away from — silently.
    func testADanglingPinIsReportedSoTheUserCanSeeWhyTheSkillStopped() throws {
        let skill = try store.create(name: "code-review", description: "v1", body: "ONE").get()
        let outcome = try XCTUnwrap(SkillResolution.resolve(
            for: config([.link(skillID: skill.id, name: "code-review", pinnedVersionID: "skver_gone")]),
            profileName: "P"))

        XCTAssertTrue(outcome.manifests.isEmpty)
        XCTAssertEqual(outcome.unresolved.map(\.name), ["code-review"])
    }

    /// A pin survives the profile blob round trip — it is stored, not just held in memory.
    func testAPinRoundTripsThroughTheProfileBlob() throws {
        var selection = SkillSelection.link(skillID: "skill_abc", name: "code-review")
        selection.pinnedVersionID = "skver_xyz"

        let data = try JSONEncoder().encode(ProfileDetails.agent(config([selection])))
        guard case .agent(let decoded) = try JSONDecoder().decode(ProfileDetails.self, from: data) else {
            return XCTFail("expected an agent config")
        }
        XCTAssertEqual(decoded.skillSelections?.first?.pinnedVersionID, "skver_xyz")
    }
}
