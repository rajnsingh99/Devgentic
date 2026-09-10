// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ProfileValidationSeverityTests.swift
//  devgenticTests
//
//  Covers G92: an advisory capability warning was used as a hard gate.
//
//  `ProfileValidator` emitted every finding into one flat array, and both callers treated a
//  non-empty array as fatal. So the sentence "Selected model does not support tool calling. Agent
//  features MAY NOT work correctly" acquired the force of "A model must be selected" — a local
//  agent profile could be created (creation validates leniently) and then never saved again, not
//  even a rename, with an error toast whose own wording does not claim the save failed.
//
//  The tests below pin the distinction rather than the wording, so a future rule cannot become a
//  gate merely by being appended to the array.
//

import XCTest
@testable import devgentic

final class ProfileValidationSeverityTests: XCTestCase {

    /// A local agent on a model detection reports as tool-incapable — the exact shape G92 blocked.
    private func localAgentWithNoToolCapability(
        provider: ApiProvider = .ollama,
        name: String = "Local Agent"
    ) -> BackendProfileSnapshot {
        let config = AgentConfig(
            llmConfig: ProviderConfig(
                apiProvider: provider,
                modelName: "llama3",
                baseURL: "http://localhost:11434"
            ),
            tools: [],
            // ⚠️ Present so the exact-set assertions below stay about the CAPABILITY finding.
            // Without it the strict run also reports the missing-instructions advisory (A35), and
            // this test would be asserting two unrelated rules at once.
            instructions: "Be helpful."
        )
        // cognitiveCapability is a stored property defaulting to .none, so this is the state a
        // picker leaves behind when nothing tool-capable is installed.
        XCTAssertEqual(config.llmConfig.cognitiveProfile.capability, .none, "test premise")
        return BackendProfileSnapshot(displayName: name, details: .agent(config))
    }

    // MARK: - The capability finding is reported, but never blocks

    func testCapabilityFindingIsStillReported() {
        let errors = ProfileValidator.validate(localAgentWithNoToolCapability(), strict: true)

        // Demoting it must not DELETE it — the signal is the point; only the gate was wrong.
        XCTAssertTrue(
            errors.contains { $0.field == "modelCapabilities" },
            "The capability finding must still be produced: \(errors)"
        )
    }

    func testCapabilityFindingIsAdvisoryNotBlocking() {
        let errors = ProfileValidator.validate(localAgentWithNoToolCapability(), strict: true)

        XCTAssertTrue(errors.blocking.isEmpty, "Nothing here should refuse a save: \(errors.blocking)")
        XCTAssertEqual(errors.advisories.map(\.field), ["modelCapabilities"])
    }

    func testBothLocalProvidersBehaveTheSame() {
        for provider in [ApiProvider.ollama, .mlx] {
            let errors = ProfileValidator.validate(
                localAgentWithNoToolCapability(provider: provider),
                strict: true
            )
            XCTAssertTrue(errors.blocking.isEmpty, "\(provider.rawValue) should not block")
            XCTAssertFalse(errors.advisories.isEmpty, "\(provider.rawValue) should still advise")
        }
    }

    // MARK: - Real errors are untouched

    /// The demotion must be surgical. If it also softened the structural rules, a profile with no
    /// model at all would start saving — which is the failure this validator exists to prevent.
    func testStructuralFailuresStillBlock() {
        let noModel = BackendProfileSnapshot(
            displayName: "Broken",
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: ""),
                tools: []
            ))
        )
        let errors = ProfileValidator.validate(noModel, strict: true)

        XCTAssertTrue(errors.blocking.contains { $0.field == "modelName" })
    }

    func testMissingCloudAPIKeyStillBlocks() {
        let noKey = BackendProfileSnapshot(
            displayName: "Cloud",
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-sonnet-4"),
                tools: []
            ))
        )
        let errors = ProfileValidator.validate(noKey, strict: true)

        XCTAssertTrue(errors.blocking.contains { $0.field == "apiKey" })
    }

    func testEmptyProfileNameStillBlocks() {
        let unnamed = localAgentWithNoToolCapability(name: "   ")
        let errors = ProfileValidator.validate(unnamed, strict: true)

        XCTAssertTrue(errors.blocking.contains { $0.field == "displayName" })
    }

    /// A profile with BOTH a real error and an advisory must still be refused — and refused for
    /// the real reason. Filtering to `.blocking` is what makes the surfaced message the actionable
    /// one, since `ProfileStoreError.errorDescription` shows only `errors.first`.
    func testAdvisoryDoesNotMaskARealErrorInTheSurfacedMessage() {
        let bothWrong = BackendProfileSnapshot(
            displayName: "",
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                tools: []
            ))
        )
        let errors = ProfileValidator.validate(bothWrong, strict: true)

        XCTAssertFalse(errors.advisories.isEmpty, "test premise: an advisory is present")
        XCTAssertFalse(errors.blocking.isEmpty)
        XCTAssertTrue(
            errors.blocking.allSatisfy { $0.field != "modelCapabilities" },
            "The advisory must never reach the blocking set"
        )
    }

    // MARK: - The default protects future rules

    /// A new rule must have to opt IN to being ignorable. If the default were `.advisory`, adding a
    /// genuine structural check without thinking about severity would silently stop enforcing it.
    func testSeverityDefaultsToBlocking() {
        let finding = ProfileValidationError(field: "anything", message: "…")

        XCTAssertEqual(finding.severity, .blocking)
    }

    /// Equality deliberately ignores severity, matching the existing exclusion of `id`.
    func testEqualityIgnoresSeverity() {
        let a = ProfileValidationError(field: "f", message: "m", severity: .blocking)
        let b = ProfileValidationError(field: "f", message: "m", severity: .advisory)

        XCTAssertEqual(a, b)
    }

    // MARK: - Lenient mode is unchanged

    /// Creation was already permitted; the fix must not have altered that half, or the
    /// create-vs-edit asymmetry would simply have moved rather than closed.
    func testLenientModeStillEmitsNoCapabilityFinding() {
        let errors = ProfileValidator.validate(localAgentWithNoToolCapability(), strict: false)

        XCTAssertFalse(errors.contains { $0.field == "modelCapabilities" })
        XCTAssertTrue(errors.blocking.isEmpty)
    }

    /// The defect in one sentence: strict and lenient must now agree on whether this profile can be
    /// written. Before the fix they disagreed, and that disagreement WAS the lockout.
    func testStrictAndLenientAgreeOnWhetherTheProfileCanBeSaved() {
        let profile = localAgentWithNoToolCapability()

        let onCreate = ProfileValidator.validate(profile, strict: false).blocking
        let onUpdate = ProfileValidator.validate(profile, strict: true).blocking

        XCTAssertTrue(onCreate.isEmpty)
        XCTAssertTrue(onUpdate.isEmpty, "Creatable but not editable is the G92 defect: \(onUpdate)")
    }

    // MARK: - G96: strict must be a superset of lenient

    /// `.code` validated its instructions the wrong way round: the LENIENT arm checked the length
    /// and the STRICT arm did not, so an over-long system prompt blocked creation and then passed
    /// every update — the inverse of `.bot` and `.agent`.
    func testCodeProfileValidatesInstructionsUnderStrictLikeEveryOtherType() {
        let tooLong = String(repeating: "a", count: ProfileValidationLimits.maxInstructionsLength + 1)
        let code = BackendProfileSnapshot(
            displayName: "Code",
            details: .code(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "qwen2.5-coder"),
                tools: [],
                instructions: tooLong
            ))
        )

        XCTAssertTrue(
            ProfileValidator.validate(code, strict: true).contains { $0.field == "instructions" },
            "strict must catch what lenient catches"
        )
    }

    /// The property that was actually violated, stated directly: for any profile, every finding the
    /// lenient pass produces must also appear in the strict pass. Strict is a SUPERSET, never a
    /// different set — a rule that fires only when creating is a rule nobody can act on.
    func testStrictFindingsAreASupersetOfLenientForEveryProfileType() {
        let tooLong = String(repeating: "a", count: ProfileValidationLimits.maxInstructionsLength + 1)
        let llm = ProviderConfig(apiProvider: .ollama, modelName: "llama3")
        let cases: [(String, ProfileDetails)] = [
            ("bot", .bot(BotConfig(llmConfig: llm, instructions: tooLong))),
            ("agent", .agent(AgentConfig(llmConfig: llm, tools: [], instructions: tooLong))),
            ("code", .code(AgentConfig(llmConfig: llm, tools: [], instructions: tooLong))),
        ]

        for (name, details) in cases {
            let profile = BackendProfileSnapshot(displayName: name, details: details)
            let lenient = Set(ProfileValidator.validate(profile, strict: false).map(\.field))
            let strict = Set(ProfileValidator.validate(profile, strict: true).map(\.field))

            XCTAssertTrue(
                lenient.isSubset(of: strict),
                "\(name): lenient found \(lenient.subtracting(strict)) that strict missed"
            )
        }
    }

    // MARK: - G96 part two: the provider list is correct, not a gap

    /// ⚠️ This was filed as an oversight ("the rule hardcodes [.ollama, .mlx] so .openAICompatible is
    /// exempt") and is REFUTED here, deliberately as a test so nobody "fixes" it back.
    ///
    /// The list is not "local providers" — it is "providers whose capability is actually MEASURED".
    /// Only Ollama and MLX run an analyzer. `.openAICompatible` is a free-text endpoint with no
    /// picker to analyse from, is seeded `.parallelActions`, and is routed through AgentConnect's
    /// cloud arm, which consults no capability. Warning here would state a confident conclusion
    /// about someone's private LM Studio endpoint on the basis of a default value.
    func testOpenAICompatibleGetsNoCapabilityClaimBecauseNothingMeasuresIt() {
        var config = ProviderConfig(apiProvider: .openAICompatible, modelName: "local-model")
        config.baseURL = "http://localhost:1234/v1"
        config.cognitiveCapability = .none

        let profile = BackendProfileSnapshot(
            displayName: "Custom endpoint",
            details: .agent(AgentConfig(llmConfig: config, tools: []))
        )
        let errors = ProfileValidator.validate(profile, strict: true)

        XCTAssertFalse(
            errors.contains { $0.field == "modelCapabilities" },
            "A capability claim here would be derived from a default, not a measurement: \(errors)"
        )
        XCTAssertTrue(errors.blocking.isEmpty, "and it must certainly not block: \(errors.blocking)")
    }
}
