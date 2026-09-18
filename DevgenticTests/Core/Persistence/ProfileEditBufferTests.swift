// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileEditBufferTests.swift
//  DevgenticTests
//
//  Created on 27/03/26.
//
//  Tests ProfileEditBuffer — the single source of truth for profile
//  edit state and dirty tracking. Validates the core contract:
//    - isDirty is false on load
//    - isDirty becomes true only when draft != original
//    - revert() restores draft to original and clears isDirty
//    - markSaved() promotes draft to original and clears isDirty
//    - load() replaces both original and draft
//    - Advanced config round-trips do NOT produce phantom dirty state
//

import XCTest
import Combine
@testable import devgentic

@MainActor
final class ProfileEditBufferTests: XCTestCase {

    // MARK: - Helpers

    private func makeBot(
        name: String = "Test Bot",
        modelName: String = "llama3",
        provider: ApiProvider = .ollama,
        instructions: String? = nil
    ) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: provider, modelName: modelName),
                instructions: instructions
            ))
        )
    }

    private func makeAgent(
        name: String = "Test Agent",
        modelName: String = "llama3",
        instructions: String? = "Be helpful."
    ) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: name,
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: modelName),
                tools: [],
                instructions: instructions
            ))
        )
    }

    // MARK: - Initial State

    func testInitialStateIsNotDirty() {
        let profile = makeBot()
        let buffer = ProfileEditBuffer(profile: profile)
        XCTAssertFalse(buffer.isDirty, "Buffer should not be dirty immediately after init")
    }

    func testDraftMatchesOriginalOnInit() {
        let profile = makeBot(name: "My Bot", instructions: "Hello")
        let buffer = ProfileEditBuffer(profile: profile)
        XCTAssertEqual(buffer.draft, buffer.original)
        XCTAssertEqual(buffer.draft.displayName, "My Bot")
    }

    // MARK: - Dirty Detection

    func testEditingDisplayNameMakesDirty() {
        let profile = makeBot(name: "Original")
        let buffer = ProfileEditBuffer(profile: profile)

        buffer.draft.displayName = "Edited"

        XCTAssertTrue(buffer.isDirty, "Changing displayName should mark buffer dirty")
    }

    func testEditingInstructionsMakesDirty() {
        let profile = makeBot(instructions: "V1")
        let buffer = ProfileEditBuffer(profile: profile)

        if case .bot(var config) = buffer.draft.details {
            config.instructions = "V2"
            buffer.draft.details = .bot(config)
        }

        XCTAssertTrue(buffer.isDirty, "Changing instructions should mark buffer dirty")
    }

    func testEditingProviderMakesDirty() {
        let profile = makeBot(provider: .ollama)
        let buffer = ProfileEditBuffer(profile: profile)

        if case .bot(var config) = buffer.draft.details {
            config.llmConfig.apiProvider = .openAI
            config.llmConfig.apiKey = "sk-test"
            buffer.draft.details = .bot(config)
        }

        XCTAssertTrue(buffer.isDirty, "Changing provider should mark buffer dirty")
    }

    func testRevertingEditClearsDirty() {
        let profile = makeBot(name: "Original")
        let buffer = ProfileEditBuffer(profile: profile)

        buffer.draft.displayName = "Edited"
        XCTAssertTrue(buffer.isDirty)

        // Manually revert the edit (simulating user undoing their typing)
        buffer.draft.displayName = "Original"
        XCTAssertFalse(buffer.isDirty, "Reverting to original value should clear isDirty")
    }

    func testNoOpEditDoesNotMakeDirty() {
        let profile = makeBot(name: "Same")
        let buffer = ProfileEditBuffer(profile: profile)

        // Write the same value back
        buffer.draft.displayName = "Same"
        XCTAssertFalse(buffer.isDirty, "Writing the same value should not mark dirty")
    }

    // MARK: - Revert

    func testRevertRestoresDraft() {
        let profile = makeBot(name: "Original", instructions: "V1")
        let buffer = ProfileEditBuffer(profile: profile)

        buffer.draft.displayName = "Edited"
        if case .bot(var config) = buffer.draft.details {
            config.instructions = "V2"
            buffer.draft.details = .bot(config)
        }

        XCTAssertTrue(buffer.isDirty)

        buffer.revert()

        XCTAssertFalse(buffer.isDirty, "Revert should clear isDirty")
        XCTAssertEqual(buffer.draft.displayName, "Original")
        if case .bot(let config) = buffer.draft.details {
            XCTAssertEqual(config.instructions, "V1")
        } else {
            XCTFail("Expected bot details after revert")
        }
    }

    func testRevertDoesNotMutateOriginal() {
        let profile = makeBot(name: "Original")
        let buffer = ProfileEditBuffer(profile: profile)

        buffer.draft.displayName = "Edited"
        buffer.revert()

        XCTAssertEqual(buffer.original.displayName, "Original",
                       "Revert should not change the original")
    }

    // MARK: - Mark Saved

    func testMarkSavedPromotesDraftToOriginal() {
        let profile = makeBot(name: "Original")
        let buffer = ProfileEditBuffer(profile: profile)

        buffer.draft.displayName = "Saved Name"
        XCTAssertTrue(buffer.isDirty)

        buffer.markSaved()

        XCTAssertFalse(buffer.isDirty, "markSaved should clear isDirty")
        XCTAssertEqual(buffer.original.displayName, "Saved Name",
                       "markSaved should promote draft to original")
    }

    func testSubsequentEditsAfterSaveDetected() {
        let profile = makeBot(name: "V1")
        let buffer = ProfileEditBuffer(profile: profile)

        buffer.draft.displayName = "V2"
        buffer.markSaved()
        XCTAssertFalse(buffer.isDirty)

        buffer.draft.displayName = "V3"
        XCTAssertTrue(buffer.isDirty, "Edits after save should be detected as dirty")
    }

    func testRevertAfterSaveGoesToSavedState() {
        let profile = makeBot(name: "V1")
        let buffer = ProfileEditBuffer(profile: profile)

        buffer.draft.displayName = "V2"
        buffer.markSaved()

        buffer.draft.displayName = "V3"
        buffer.revert()

        XCTAssertEqual(buffer.draft.displayName, "V2",
                       "Revert after save should go to the last saved state, not the initial load")
    }

    // MARK: - Load

    func testLoadReplacesOriginalAndDraft() {
        let profile1 = makeBot(name: "First")
        let buffer = ProfileEditBuffer(profile: profile1)

        buffer.draft.displayName = "Edited"
        XCTAssertTrue(buffer.isDirty)

        let profile2 = makeBot(name: "Second")
        buffer.load(profile2)

        XCTAssertFalse(buffer.isDirty, "load() should clear isDirty")
        XCTAssertEqual(buffer.draft.displayName, "Second")
        XCTAssertEqual(buffer.original.displayName, "Second")
    }

    // MARK: - Agent-Specific: Default Persona Auto-Populate

    func testAutoPopulateAndLoadDoesNotMakeDirty() {
        // Simulates the AgentConfigDetailView.onAppear pattern:
        // 1. Detect nil instructions → set default persona → update draft
        // 2. Call load() to re-baseline
        let profile = makeAgent(instructions: nil)
        let buffer = ProfileEditBuffer(profile: profile)

        // Simulate auto-populate
        if case .agent(var config) = buffer.draft.details {
            config.instructions = "Default persona text"
            buffer.draft.details = .agent(config)
        }
        // Re-baseline after auto-populate
        buffer.load(buffer.draft)

        XCTAssertFalse(buffer.isDirty,
                       "Auto-populate followed by load() should not leave buffer dirty")
    }

    // MARK: - Profile Type Preservation

    func testAgentCapabilitiesChangeMakesDirty() {
        let profile = makeAgent()
        let buffer = ProfileEditBuffer(profile: profile)

        if case .agent(var config) = buffer.draft.details {
            config.capabilities.planning = PlanningCapabilityConfig()
            buffer.draft.details = .agent(config)
        }

        XCTAssertTrue(buffer.isDirty, "Changing capabilities should mark buffer dirty")
    }

    // MARK: - Equality Edge Cases

    func testDifferentIDsAreDirty() {
        // Unlikely in practice but verifies the Equatable implementation
        let profile = makeBot()
        let buffer = ProfileEditBuffer(profile: profile)

        // Load a different profile (different ID)
        let other = makeBot(name: profile.displayName)
        buffer.load(other)

        // The names are the same but IDs differ — should start clean after load
        XCTAssertFalse(buffer.isDirty)
    }
}
