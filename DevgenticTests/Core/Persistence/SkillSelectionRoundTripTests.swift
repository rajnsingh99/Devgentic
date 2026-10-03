// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillSelectionRoundTripTests.swift
//  DevgenticTests
//
//  A profile's skill links survive the profile blob, on BOTH arms that carry them.
//

import XCTest
@testable import devgentic

final class SkillSelectionRoundTripTests: XCTestCase {

    func testRoundTrip_AgentConfigCarriesSelections() throws {
        let config = AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            tools: [],
            skillSelections: [
                SkillSelection(skillID: "skill_alpha", name: "alpha", isEnabled: true),
                SkillSelection(skillID: "skill_beta", name: "beta", pinnedVersionID: "skver_pinned", isEnabled: false)
            ]
        )

        let data = try JSONEncoder().encode(ProfileDetails.agent(config))
        let decoded = try JSONDecoder().decode(ProfileDetails.self, from: data)

        guard case .agent(let out) = decoded else { return XCTFail("expected an agent config") }
        XCTAssertEqual(out.skillSelections, config.skillSelections)
    }

    /// Code mode reuses `AgentConfig` and has its OWN decode and encode arm — the test that fails
    /// if a change touches only `.agent`.
    func testRoundTrip_CodeConfigAlsoCarriesSelections() throws {
        let config = AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            tools: [],
            skillSelections: [SkillSelection(skillID: "skill_alpha", name: "alpha")],
            projectPath: "/Users/test/project"
        )

        let data = try JSONEncoder().encode(ProfileDetails.code(config))
        let decoded = try JSONDecoder().decode(ProfileDetails.self, from: data)

        guard case .code(let out) = decoded else { return XCTFail("expected a code config") }
        XCTAssertEqual(out.skillSelections?.map(\.name), ["alpha"])
        XCTAssertEqual(out.projectPath, "/Users/test/project")
    }

    /// A path is a statement about the world, and the world moves; an opaque `skill_…` describes
    /// nothing, so nothing can invalidate it.
    func testSelectionIdentityIsTheSkillID() {
        let selection = SkillSelection(skillID: "skill_abc", name: "code-review")
        XCTAssertEqual(selection.id, "skill_abc",
                       "identity must be the id — two skills can legitimately share a NAME")
    }
}
