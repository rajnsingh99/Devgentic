// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RedundantProfileWriteTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class RedundantProfileWriteTests: XCTestCase {

    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let project = URL(fileURLWithPath: "/tmp/devgentic-tests/redundant-write")

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BackendProfileStore.shared.configureContainer(container)

        // Never `.standard` — under the test host that is the shipping app's own domain.
        suiteName = "RedundantProfileWriteTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        container = nil
        try super.tearDownWithError()
    }

    /// A manager with a model selected and a project open — the state a real send happens in.
    ///
    /// ⚠️ The model matters: `saveProfile` rejects a modelless profile, so without one the refresh
    /// writes nothing for an unrelated reason and every assertion below would pass vacuously.
    private func makeConfiguredManager() -> CodeSessionManager {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateModel(
            "qwen2.5-coder:7b",
            provider: .ollama,
            cognitiveProfile: CognitiveProfile(capability: .parallelActions, dialect: .heuristicJson),
            apiKey: nil,
            baseURL: nil,
            thinkingEnabled: false
        )
        manager.updateProjectPath(project)
        return manager
    }

    private func lastSelected(of manager: CodeSessionManager) throws -> Date? {
        let id = try XCTUnwrap(manager.codeProfileID, "the manager has no profile row")
        return try XCTUnwrap(BackendProfileStore.shared.fetchProfile(byId: id)).lastSelected
    }

    // MARK: - The regression

    func testASecondRefreshWithNothingChangedDoesNotRewriteTheRow() throws {
        let manager = makeConfiguredManager()

        manager.refreshInstructionsOnProfile()
        let afterFirst = try lastSelected(of: manager)
        XCTAssertNotNil(afterFirst, "the first refresh must actually write")

        manager.refreshInstructionsOnProfile()
        let afterSecond = try lastSelected(of: manager)

        XCTAssertEqual(
            afterFirst, afterSecond,
            "The second refresh rewrote the row although nothing changed. Every send pays for a "
            + "write and a WAL entry, and `lastSelected` moving reorders \"recently used\" for a "
            + "profile the user is typing in rather than selecting."
        )
    }

    func testRepeatedSendsCostNothingAfterTheFirst() throws {
        // The shape the user actually hits — a conversation, not two calls.
        let manager = makeConfiguredManager()
        manager.refreshInstructionsOnProfile()
        let settled = try lastSelected(of: manager)

        for _ in 0..<8 { manager.refreshInstructionsOnProfile() }

        XCTAssertEqual(settled, try lastSelected(of: manager),
                       "an eight-message conversation still rewrote the profile row")
    }

    // MARK: - The guard must not be over-broad

    func testSwitchingProjectLeavesTheRowPointingAtTheNewFolder() throws {
        // ⚠️ NOT a guard test, despite the obvious reading — and that is written down because
        // MUTATION proved it. `updateProjectPath` performs its own save, so this passes even with
        // the refresh guard forced permanently closed. It was named `testAChangedProjectStillWrites`
        // and read as if it pinned the guard's other direction; it never did.
        //
        // `testAChangedQuickSettingStillWrites` is the one that actually pins that direction —
        // quick settings reach disk ONLY through the refresh. This test is kept for the invariant
        // it does hold: whatever writes it, the row must end up on the new folder or the agent
        // stays confined to the previous project.
        let manager = makeConfiguredManager()
        manager.refreshInstructionsOnProfile()

        let other = URL(fileURLWithPath: "/tmp/devgentic-tests/redundant-write-other")
        manager.updateProjectPath(other)
        manager.refreshInstructionsOnProfile()

        let id = try XCTUnwrap(manager.codeProfileID)
        let stored = try XCTUnwrap(BackendProfileStore.shared.fetchProfile(byId: id))
        guard case .code(let config) = stored.details else {
            return XCTFail("the stored row is not a .code profile")
        }
        XCTAssertEqual(config.projectPath, other.path,
                       "switching project folders did not reach disk — the agent would stay "
                       + "confined to the previous project.")
    }

    func testAChangedQuickSettingStillWrites() throws {
        // Quick settings are applied inside the same refresh, so the guard must see them too.
        let manager = makeConfiguredManager()
        manager.refreshInstructionsOnProfile()
        let before = try lastSelected(of: manager)

        var settings = CodeQuickSettings.default
        settings.maxIterations = 7
        CodeQuickSettingsStore.save(settings, for: project.path, defaults: defaults, now: Date())
        manager.refreshInstructionsOnProfile()

        XCTAssertNotEqual(before, try lastSelected(of: manager),
                          "a changed iteration cap did not reach the profile, so the run would "
                          + "still execute under the previous limit.")
    }

    func testTheWrittenRowIsCorrectNotJustUnwritten() throws {
        // A guard that skipped everything would pass the tests above if they only counted writes.
        // Assert the row actually holds what the refresh computed.
        let manager = makeConfiguredManager()
        manager.refreshInstructionsOnProfile()
        manager.refreshInstructionsOnProfile()

        let id = try XCTUnwrap(manager.codeProfileID)
        let stored = try XCTUnwrap(BackendProfileStore.shared.fetchProfile(byId: id))
        guard case .code(let config) = stored.details else {
            return XCTFail("the stored row is not a .code profile")
        }
        XCTAssertEqual(config.projectPath, project.path)
        let instructions = try XCTUnwrap(config.instructions,
                                         "the skipped second refresh left the row without instructions")
        XCTAssertFalse(instructions.isEmpty)
        XCTAssertTrue(instructions.contains(project.path),
                      "the instructions must name the project root the run is confined to")
    }
}
