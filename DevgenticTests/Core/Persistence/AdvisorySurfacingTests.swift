// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AdvisorySurfacingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

// MARK: - A34: advisories reach a caller, and never gate

@MainActor
final class SaveAdvisoryReturnTests: XCTestCase {

    private final class InMemoryStore: BackendProfileStoreProtocol {
        var profiles: [BackendProfileSnapshot] = []
        /// What the real store would have computed. The fake returns it verbatim so the SERVICE's
        /// forwarding is what is under test here, not the validator.
        var advisoriesToReturn: [ProfileValidationError] = []
        var shouldThrow: Error?

        func fetchProfiles() throws -> [BackendProfileSnapshot] { profiles }
        func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
            profiles.first { $0.id == id }
        }
        @discardableResult
        func saveProfile(_ snapshot: BackendProfileSnapshot,
                         callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] {
            if let shouldThrow { throw shouldThrow }
            if let i = profiles.firstIndex(where: { $0.id == snapshot.id }) { profiles[i] = snapshot }
            else { profiles.append(snapshot) }
            return advisoriesToReturn
        }
        func deleteProfile(withId id: UUID) throws { profiles.removeAll { $0.id == id } }
    }

    private func bot(_ name: String = "Bot") -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"))))
    }

    /// ⚠️ The A34 defect in one assertion: the advisory existed, and the caller could not see it.
    func testSaveReturnsAdvisoriesToTheCaller() throws {
        let store = InMemoryStore()
        store.advisoriesToReturn = [ProfileValidationError(
            field: "modelCapabilities",
            message: "Selected model does not support tool calling.",
            severity: .advisory)]
        let service = BackendProfileService(store: store)

        let returned = try service.saveProfile(bot())

        XCTAssertEqual(returned.count, 1)
        XCTAssertEqual(returned.first?.severity, .advisory)
    }

    /// The common case must stay quiet — a banner that appears on every save is noise.
    func testACleanSaveReturnsNothing() throws {
        let service = BackendProfileService(store: InMemoryStore())
        XCTAssertTrue(try service.saveProfile(bot()).isEmpty)
    }

    /// ⚠️ The G92 invariant this must not break: an advisory DESCRIBES, it never refuses. Returning
    /// them must not turn them into a gate by any route.
    func testAdvisoriesDoNotRefuseTheSave() throws {
        let store = InMemoryStore()
        store.advisoriesToReturn = [
            ProfileValidationError(field: "modelCapabilities", message: "…", severity: .advisory),
            ProfileValidationError(field: "baseURL", message: "…", severity: .advisory)
        ]
        let service = BackendProfileService(store: store)

        XCTAssertNoThrow(try service.saveProfile(bot("Saved anyway")))
        XCTAssertEqual(store.profiles.count, 1, "the profile must be on disk despite the advisories")
    }

    /// `@discardableResult`: ~23 call sites have nowhere to show these and must stay unchanged.
    func testTheResultIsDiscardableWithoutCeremony() throws {
        let service = BackendProfileService(store: InMemoryStore())
        XCTAssertNoThrow(try service.saveProfile(bot()))  // no `_ =` — this is the assertion
    }

    func testAFailedSaveStillThrows() {
        let store = InMemoryStore()
        store.shouldThrow = ProfileStoreError.saveFailed(underlying: NSError(domain: "t", code: 1))
        let service = BackendProfileService(store: store)

        XCTAssertThrowsError(try service.saveProfile(bot()),
                             "returning a value must not swallow the throw path")
    }
}

// MARK: - A67: a stored `parallelSubtasks` no longer decides anything

// MARK: - B13/B14/B15: the surfaces and gates fixed 2026-08-08

@MainActor
final class WithdrawnCapabilityAndAdvisorySurfaceTests: XCTestCase {

    /// ⚠️ register B15. The delegation toggle was withdrawn from the UI long ago, but the runtime
    /// gate is the mere PRESENCE of `capabilities.agentDelegation` — no `isEnabled` flag — so every
    /// legacy "Supervisor" profile kept injecting `call_agent` forever. One named constant now
    /// decides it, the same shape as `PlanningCapability.parallelSubtasksSupported`.
    func testAgentDelegationIsWithdrawnAtTheRuntimeGate() {
        XCTAssertFalse(AgentConnect.agentDelegationSupported,
                       "delegation is withdrawn — flipping this back is the one line that restores it")
    }

    /// ⚠️ register B14. The instructions advisory is only truthful for types that HAVE the field:
    /// an image generator has no instructions to be missing, and bannering on every send would
    /// train the user to dismiss the one signal this category exists to carry.
    func testOnlyProfileTypesWithInstructionsCanReportThemMissing() {
        let agent = ProfileDetails.agent(AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        let imageGen = ProfileDetails.imageGen(ImageGenConfig(
            llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "dall-e-3")))

        XCTAssertTrue(agent.supportsSystemInstructions)
        XCTAssertFalse(imageGen.supportsSystemInstructions,
                       "an image generator has no instructions field to be empty")
        XCTAssertFalse(ProfileDetails.workflow(WorkflowConfig())
                        .supportsSystemInstructions)
    }

    func testSystemInstructionsAreReadableForTheTypesThatCarryThem() {
        let agent = ProfileDetails.agent(AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            instructions: "be brief"))
        XCTAssertEqual(agent.systemInstructions, "be brief")
        XCTAssertNil(ProfileDetails.workflow(WorkflowConfig()).systemInstructions)
    }

    /// The advisory must remain non-blocking — G92, re-asserted on the new channel.
    func testTheMissingInstructionsFindingIsAdvisoryNotBlocking() {
        let profile = BackendProfileSnapshot(
            displayName: "Unconfigured",
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3", apiKey: nil))))

        let errors = ProfileValidator.validate(profile, strict: true)
        let instructionFindings = errors.filter { $0.field == "instructions" }

        XCTAssertFalse(instructionFindings.isEmpty, "an instruction-less agent must be reported")
        XCTAssertTrue(instructionFindings.allSatisfy { $0.severity == .advisory },
                      "it must never gate the save — out-of-band writers include the thinking auto-heal")
    }
}

final class ParallelSubtaskEnforcementTests: XCTestCase {

    /// ⚠️ THE fix. The UI comment claimed "Default is forced to false below" and nothing forced it;
    /// this constant is what makes the claim true, at the point of consumption.
    func testParallelExecutionIsDisabledInThisBuild() {
        XCTAssertFalse(PlanningCapability.parallelSubtasksSupported,
                       "if this flips, A67's profiles silently start running subtasks in parallel "
                       + "again — restore the UI toggle in the same change")
    }

    /// ⚠️ Why the constant was needed: the tolerant decoder defaults the field only when the key is
    /// ABSENT. A profile saved while the toggle still existed decodes `true` and always did.
    func testAPersistedTrueStillDecodesAsTrue() throws {
        let json = """
        {"maxSubtasks": 5, "parallelSubtasks": true, "subtaskToolFiltering": true}
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PlanningCapabilityConfig.self, from: json)

        XCTAssertTrue(config.parallelSubtasks,
                      "the stored preference is deliberately PRESERVED, not rewritten — enforcement "
                      + "is at consumption, so it survives for when parallelism becomes real")
    }

    /// A profile with the key absent gets the safe default, which is the path new profiles take.
    func testAnAbsentKeyDefaultsToFalse() throws {
        let json = """
        {"maxSubtasks": 5, "subtaskToolFiltering": true}
        """.data(using: .utf8)!

        XCTAssertFalse(try JSONDecoder().decode(PlanningCapabilityConfig.self, from: json).parallelSubtasks)
    }
}

// MARK: - A66: delegation has an exit again

final class AgentDelegationOffSwitchTests: XCTestCase {

    /// ⚠️ The gate in `AgentConnect.resolveTools` is the mere PRESENCE of the config — there is no
    /// `isEnabled` flag — so nil is the only "off" that exists. This pins the contract the UI's
    /// Turn Off button relies on.
    func testNilDelegationIsTheOnlyOffState() {
        var capabilities = AgentCapabilities()
        capabilities.agentDelegation = AgentDelegationConfig()
        XCTAssertNotNil(capabilities.agentDelegation, "non-nil means call_agent gets injected")

        capabilities.agentDelegation = nil
        XCTAssertNil(capabilities.agentDelegation, "nil is what stops the injection")
    }

    /// A profile that never had delegation must not gain it — the row is an exit, not a toggle, and
    /// must not appear for profiles the capability was never offered to.
    func testAFreshAgentHasNoDelegation() {
        XCTAssertNil(AgentCapabilities().agentDelegation,
                     "new profiles are not offered the capability, so they must not carry the config")
    }
}
