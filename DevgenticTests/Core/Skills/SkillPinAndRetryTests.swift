// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillPinAndRetryTests.swift
//  devgenticTests
//
//  Two surfaces that existed only as unreachable code until now.
//
//  ⚠️ `pinnedVersionID` had NO production write path: resolution read it, the profile card warned
//  about it, and both branches were permanently dead. `SkillImportSweepOutcome.failed` was computed
//  and delivered only to `os_log`, so a user upgrading with an external drive unplugged saw skills
//  simply missing with no way to learn why or retry.
//
//  The tests below go through the real store and the real sweep, because the defect in both cases
//  was that correct logic had no caller — which a policy-only test cannot see.
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

// MARK: - Failed imports

@MainActor
final class SkillFailedImportRetryTests: XCTestCase {

    private var container: ModelContainer!
    private var store: SkillStore!
    private var work: URL!
    private var captureURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        captureURL = work.appendingPathComponent("pending.json")
        SkillLibraryMigration.captureURLOverride = captureURL

        container = try ModelContainer(for: DevgenticSchema.schema,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = SkillStore.shared
        store.setContainerForTesting(container)
    }

    override func tearDown() async throws {
        SkillLibraryMigration.captureURLOverride = nil
        store?.setContainerForTesting(nil)
        store = nil
        container = nil
        if let work { try? FileManager.default.removeItem(at: work) }
        try await super.tearDown()
    }

    private func makeSkillFolder(_ name: String) throws -> URL {
        let dir = work.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: A skill.\n---\n\n# \(name)"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    /// ⚠️ THE PROPERTY THE BANNER RESTS ON: after a sweep, the capture file holds exactly what
    /// failed. The view reads it directly rather than being handed a value from a launch-time run,
    /// because a handed value is gone the moment the user navigates away — which is exactly when
    /// they come looking for it.
    func testAfterASweepTheCaptureHoldsExactlyWhatFailed() throws {
        let good = try makeSkillFolder("good-one")
        let missing = work.appendingPathComponent("never-existed")
        try JSONEncoder().encode([
            SkillLibraryMigration.LegacySkillRef(folderPath: good.path, name: "good-one"),
            SkillLibraryMigration.LegacySkillRef(folderPath: missing.path, name: "ghost")
        ]).write(to: captureURL)

        SkillLibraryImportSweep.run(container: container)

        XCTAssertEqual(SkillLibraryMigration.peekPendingImports().map(\.name), ["ghost"],
                       "what remains pending IS the failure list the UI shows")
        XCTAssertEqual(try store.fetchSkills().get().map(\.name), ["good-one"])
    }

    /// The retry the button performs: once the folder is reachable, a second pass imports it and
    /// the banner empties.
    func testRetryingAfterTheFolderReappearsImportsItAndClearsTheList() throws {
        let path = work.appendingPathComponent("came-back")
        try JSONEncoder().encode([
            SkillLibraryMigration.LegacySkillRef(folderPath: path.path, name: "came-back")
        ]).write(to: captureURL)

        SkillLibraryImportSweep.run(container: container)
        XCTAssertEqual(SkillLibraryMigration.peekPendingImports().count, 1, "still missing")
        XCTAssertTrue(try store.fetchSkills().get().isEmpty)

        // The drive comes back.
        _ = try makeSkillFolder("came-back")
        SkillLibraryImportSweep.run(container: container)

        XCTAssertTrue(SkillLibraryMigration.peekPendingImports().isEmpty,
                      "a successful retry must clear the banner")
        XCTAssertEqual(try store.fetchSkills().get().map(\.name), ["came-back"])
    }

    /// Retrying repeatedly must not duplicate what already imported.
    func testRepeatedRetriesDoNotDuplicate() throws {
        let good = try makeSkillFolder("stable")
        let missing = work.appendingPathComponent("gone")
        try JSONEncoder().encode([
            SkillLibraryMigration.LegacySkillRef(folderPath: good.path, name: "stable"),
            SkillLibraryMigration.LegacySkillRef(folderPath: missing.path, name: "gone")
        ]).write(to: captureURL)

        SkillLibraryImportSweep.run(container: container)
        SkillLibraryImportSweep.run(container: container)
        SkillLibraryImportSweep.run(container: container)

        XCTAssertEqual(try store.fetchSkills().get().filter { $0.name == "stable" }.count, 1,
                       "⚠️ the successful folder is dropped from the capture, so a retry cannot re-import it")
        XCTAssertEqual(SkillLibraryMigration.peekPendingImports().map(\.name), ["gone"])
    }

    /// "Forget" is the user deciding those skills are not coming back. Nothing else clears the
    /// capture, so without it the banner would be permanent.
    func testForgettingClearsTheCaptureForGood() throws {
        let missing = work.appendingPathComponent("gone")
        try JSONEncoder().encode([
            SkillLibraryMigration.LegacySkillRef(folderPath: missing.path, name: "gone")
        ]).write(to: captureURL)

        SkillLibraryMigration.setPendingImports([])

        XCTAssertTrue(SkillLibraryMigration.peekPendingImports().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))
        SkillLibraryImportSweep.run(container: container)
        XCTAssertTrue(try store.fetchSkills().get().isEmpty, "and a later sweep finds nothing to do")
    }
}
