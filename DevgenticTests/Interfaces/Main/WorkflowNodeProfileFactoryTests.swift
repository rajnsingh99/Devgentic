// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowNodeProfileFactoryTests.swift
//  DevgenticTests
//
//  Created on 29/08/26.
//
//  Phase 1 of node-owned workflow configuration: the rules that make a node's config DETACHED.
//  These are pure-function tests by design — the factory was extracted from the view precisely so
//  the detachment rules are assertable without a view-inspection harness.
//

import XCTest
@testable import devgentic

final class WorkflowNodeProfileFactoryTests: XCTestCase {

    private let workflowID = UUID()
    private let nodeID = UUID()

    private func agentProfile(
        _ name: String = "Source",
        evaluator: UUID? = nil,
        instructions: String = "Original instructions."
    ) -> BackendProfileModel {
        var capabilities = AgentCapabilities()
        if let evaluator {
            capabilities.selfReflection = SelfReflectionConfig(maxTrials: 3, evaluatorProfileID: evaluator)
        }
        return BackendProfileSnapshot(
            displayName: name,
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude", apiKey: "sk-test-key"),
                tools: [],
                instructions: instructions,
                capabilities: capabilities
            ))
        )
    }

    // MARK: - Fresh

    /// A fresh node is MLX-backed, which is what makes it need no credential: `ProfileValidator`
    /// demands an API key only for the four cloud providers.
    func testFreshProfileDefaultsToMLXAndIsOwned() {
        let fresh = WorkflowNodeProfileFactory.freshProfile(
            type: .agent, name: "Summarizer",
            workflowID: workflowID, nodeID: nodeID,
            defaultMLXModelName: "mlx-community/Llama-3"
        )

        guard case .agent(let config) = fresh.details else { return XCTFail("expected an agent") }
        XCTAssertEqual(config.llmConfig.apiProvider, .mlx)
        XCTAssertEqual(config.llmConfig.modelName, "mlx-community/Llama-3")
        XCTAssertTrue(config.llmConfig.apiProvider.isLocal, "a local provider needs no API key")
        XCTAssertNil(config.llmConfig.apiKey)

        XCTAssertEqual(fresh.displayName, "Summarizer")
        XCTAssertEqual(fresh.ownerWorkflowID, workflowID)
        XCTAssertEqual(fresh.ownerNodeID, nodeID)
        XCTAssertTrue(fresh.isNodeOwned)
    }

    /// ⚠️ An EMPTY model name must still produce a profile. `saveProfile` validates leniently on
    /// insert precisely so a row can be created before it is configured — refusing here would leave
    /// a user with no MLX models installed unable to add a node at all, not even to import into.
    func testFreshProfileIsStillCreatedWhenNoMLXModelIsInstalled() {
        let fresh = WorkflowNodeProfileFactory.freshProfile(
            type: .bot, name: "Empty", workflowID: workflowID, nodeID: nodeID,
            defaultMLXModelName: ""
        )
        guard case .bot(let config) = fresh.details else { return XCTFail("expected a bot") }
        XCTAssertEqual(config.llmConfig.modelName, "")
        XCTAssertEqual(config.llmConfig.apiProvider, .mlx, "the provider is still MLX — only the model is unpicked")
        XCTAssertTrue(fresh.isNodeOwned)
    }

    func testFreshBotAndAgentProduceTheirRequestedType() {
        let bot = WorkflowNodeProfileFactory.freshProfile(
            type: .bot, name: "B", workflowID: workflowID, nodeID: nodeID, defaultMLXModelName: "m")
        let agent = WorkflowNodeProfileFactory.freshProfile(
            type: .agent, name: "A", workflowID: workflowID, nodeID: nodeID, defaultMLXModelName: "m")
        XCTAssertEqual(bot.profileType, .bot)
        XCTAssertEqual(agent.profileType, .agent)
    }

    // MARK: - Import

    /// THE DETACHMENT CONTRACT: a copy is a NEW row, owned by the node, and the source is untouched.
    func testImportProducesANewOwnedRowAndLeavesTheSourceAlone() {
        let source = agentProfile("Researcher")
        let imported = WorkflowNodeProfileFactory.importedProfile(
            from: source, workflowID: workflowID, nodeID: nodeID)

        XCTAssertNotEqual(imported.id, source.id, "a copy is a new row, not an alias")
        XCTAssertEqual(imported.ownerWorkflowID, workflowID)
        XCTAssertEqual(imported.ownerNodeID, nodeID)
        XCTAssertTrue(imported.isNodeOwned)

        XCTAssertNil(source.ownerNodeID, "the source must not be converted into an owned row")
        XCTAssertFalse(source.isNodeOwned)
    }

    /// Decision #2 (2026-08-29): keep the source's name. The row is private, so there is no list for
    /// a name to collide in, and the node card renders `displayName`.
    func testImportKeepsTheSourceName() {
        let source = agentProfile("Researcher")
        let imported = WorkflowNodeProfileFactory.importedProfile(
            from: source, workflowID: workflowID, nodeID: nodeID)
        XCTAssertEqual(imported.displayName, "Researcher")
    }

    /// ⚠️ The credential must ride along inside `ProfileDetails` — `saveProfile` is what re-secures
    /// it into the Keychain under the NEW row's id. An imported cloud node with no key would fail
    /// validator Rule 4 and be unrunnable.
    func testImportCarriesTheCredentialSoTheCopyCanRun() {
        let source = agentProfile("Cloud Agent")
        let imported = WorkflowNodeProfileFactory.importedProfile(
            from: source, workflowID: workflowID, nodeID: nodeID)

        guard case .agent(let config) = imported.details else { return XCTFail("expected an agent") }
        XCTAssertEqual(config.llmConfig.apiKey, "sk-test-key",
                       "the in-memory copy carries the key; the store strips it into the Keychain on save")
    }

    /// ⚠️ Copy-by-default carries EVERYTHING, including the source's own ownership. Importing from a
    /// row that is itself node-owned must re-stamp — otherwise the new node's row still claims to
    /// belong to the old node, and the save-time reconcile would delete it out from under the
    /// workflow that just created it.
    func testImportRestampsOwnershipEvenWhenTheSourceWasItselfOwned() {
        var source = agentProfile("Already Owned")
        source.ownerWorkflowID = UUID()
        source.ownerNodeID = UUID()

        let imported = WorkflowNodeProfileFactory.importedProfile(
            from: source, workflowID: workflowID, nodeID: nodeID)

        XCTAssertEqual(imported.ownerWorkflowID, workflowID)
        XCTAssertEqual(imported.ownerNodeID, nodeID)
        XCTAssertNotEqual(imported.ownerNodeID, source.ownerNodeID)
    }

    /// ⚠️ THE CROSS-PROFILE POINTER. `evaluatorProfileID` is a profile UUID inside `AgentConfig`, so
    /// copy-by-default smuggles it across the detachment boundary. Severed while it is still inert
    /// (no reader ships today) — the moment one does, a "detached" node would fail because of a
    /// profile deleted somewhere else, which is the coupling this whole design removes.
    func testImportSeversTheSelfReflectionEvaluatorPointer() {
        let evaluator = UUID()
        let source = agentProfile("Reflective", evaluator: evaluator)

        // Precondition: the source really does carry the pointer.
        guard case .agent(let sourceConfig) = source.details else { return XCTFail("expected an agent") }
        XCTAssertEqual(sourceConfig.capabilities.selfReflection?.evaluatorProfileID, evaluator)

        let imported = WorkflowNodeProfileFactory.importedProfile(
            from: source, workflowID: workflowID, nodeID: nodeID)

        guard case .agent(let config) = imported.details else { return XCTFail("expected an agent") }
        XCTAssertNil(config.capabilities.selfReflection?.evaluatorProfileID,
                     "a detached node must not hold a live pointer to another profile")
        XCTAssertNotNil(config.capabilities.selfReflection,
                        "the capability itself stays enabled — only the cross-profile pointer is cleared")
        XCTAssertEqual(config.capabilities.selfReflection?.maxTrials, 3,
                       "its other settings must survive — severing is not resetting")
    }

    /// The no-op case: severing must not disturb a profile that holds no pointer.
    func testSeveringIsANoOpWithoutAnEvaluator() {
        let source = agentProfile("Plain")
        let severed = WorkflowNodeProfileFactory.severingCrossProfileReferences(source)
        XCTAssertEqual(severed.details, source.details)
    }

    /// Copy-by-default is the whole reason `duplicated(as:)` is used — this pins that ordinary
    /// configuration survives the copy, so a future refactor to a field list fails here.
    func testImportPreservesOrdinaryConfiguration() {
        let source = agentProfile("Detailed", instructions: "Very specific instructions.")
        let imported = WorkflowNodeProfileFactory.importedProfile(
            from: source, workflowID: workflowID, nodeID: nodeID)

        guard case .agent(let config) = imported.details else { return XCTFail("expected an agent") }
        XCTAssertEqual(config.instructions, "Very specific instructions.")
        XCTAssertEqual(config.llmConfig.modelName, "claude")
        XCTAssertEqual(imported.profileType, .agent)
    }
}
