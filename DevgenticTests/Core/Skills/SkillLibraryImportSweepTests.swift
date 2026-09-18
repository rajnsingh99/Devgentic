// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillLibraryImportSweepTests.swift
//  devgenticTests
//
//  The launch pass that finishes the V5→V6 migration.
//
//  ⚠️ Every test here goes through the REAL ingest, the REAL store and REAL `BackendProfile` rows.
//  A policy-only test of the re-link arithmetic would stay green over a sweep that never ran, and
//  this codebase has shipped exactly that shape before.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SkillLibraryImportSweepTests: XCTestCase {

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

    // MARK: - Fixtures

    @discardableResult
    private func makeSkillFolder(_ name: String, in parent: URL? = nil, description: String = "Does a thing.") throws -> URL {
        let dir = (parent ?? work).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\nDo it."
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    private func capture(_ refs: [SkillLibraryMigration.LegacySkillRef]) throws {
        try JSONEncoder().encode(refs).write(to: captureURL)
    }

    private func ref(_ name: String, at url: URL) -> SkillLibraryMigration.LegacySkillRef {
        .init(folderPath: url.path, name: name)
    }

    @discardableResult
    private func makeProfile(_ displayName: String, selections: [SkillSelection]) throws -> BackendProfile {
        let config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                                 tools: [], skillSelections: selections)
        let profile = BackendProfile(displayName: displayName, details: .agent(config))
        container.mainContext.insert(profile)
        try container.mainContext.save()
        return profile
    }

    private func selections(of profile: BackendProfile) -> [SkillSelection] {
        guard case .agent(let config) = profile.details else { return [] }
        return config.skillSelections ?? []
    }

    // MARK: - Launch order

    /// ⚠️⚠️ THE BUG THIS FILE MISSED. `SkillStore.configureContainer` was `nonisolated` and deferred
    /// its assignment through `Task { @MainActor in … }`. The launch site is itself inside a
    /// `Task { @MainActor in … }`, so the assignment queued BEHIND the sweep: the sweep ran with no
    /// container, every store call returned `.containerUnavailable`, the pass aborted, and because
    /// an aborted pass keeps the capture file it failed identically on every launch after that. A
    /// user upgrading from V5 would have had an empty Skills library forever.
    ///
    /// Every other test here injects the container in `setUp` and then calls the sweep, which is
    /// exactly the order that hides this. This one reproduces the launch sequence instead:
    /// configure, then immediately run, with no suspension in between.
    func testConfiguringTheContainerTakesEffectBeforeTheSweepRuns() async throws {
        let alpha = try makeSkillFolder("alpha")
        try capture([ref("alpha", at: alpha)])

        // Drop the container this test's setUp injected, then re-inject it the way launch does.
        store.setContainerForTesting(nil)
        SkillStore.shared.configureContainer(container)

        // No `await` between the two — a deferred assignment would still be pending here.
        let outcome = await SkillLibraryImportSweep.run(container: container)

        XCTAssertNil(outcome.abortReason,
                     "the sweep must see the container the line above gave it — a deferred assignment aborts the whole migration")
        XCTAssertEqual(outcome.imported, ["alpha"])
    }

    // MARK: - Keeping the map

    /// ⚠️⚠️ THE SWEEP'S OWN LOG CONTRADICTED ITS OWN CODE. When a profile's blob could not be
    /// decoded it logged that the links would be picked up on a later launch "provided the capture
    /// file still lists their folders" — and then cleared that file on the same pass. The skills
    /// were imported, the links left pending, and the only map from folder to skill deleted, so
    /// repairing the profile afterwards could never repair the links.
    ///
    /// **Mutation check:** drop the `unreadableProfiles.isEmpty` term and this goes red.
    func testAnUnreadableProfileKeepsTheCaptureFile() {
        var outcome = SkillImportSweepOutcome()
        outcome.unreadableProfiles = ["Agent 3"]
        XCTAssertFalse(SkillLibraryImportSweep.shouldClearCapture(outcome),
                       "the capture is the only map from those folders to the skills they became")
    }

    /// The control: a clean pass still clears, or the file would accumulate forever and re-import
    /// the same folders on every launch.
    func testACleanPassStillClearsTheCaptureFile() {
        XCTAssertTrue(SkillLibraryImportSweep.shouldClearCapture(SkillImportSweepOutcome()))
    }

    /// An ABORTED pass keeps it for the original reason, unchanged by the above.
    func testAnAbortedPassKeepsTheCaptureFile() {
        var outcome = SkillImportSweepOutcome()
        outcome.abortReason = "store unavailable"
        XCTAssertFalse(SkillLibraryImportSweep.shouldClearCapture(outcome))
    }

    /// ⚠️ A failed FOLDER is a different thing and must NOT keep the whole file — those are written
    /// back individually. Without this, one permanently missing folder would pin the capture file
    /// forever and re-import every sibling on every launch.
    func testAFailedFolderAloneDoesNotPinTheCaptureFile() {
        var outcome = SkillImportSweepOutcome()
        outcome.failed = [RejectedSkill(label: "gone", reason: "not found")]
        XCTAssertTrue(SkillLibraryImportSweep.shouldClearCapture(outcome))
    }

    // MARK: - Where the work comes from (the capture file is NOT the only source)

    /// ⚠️⚠️ THE BUG THIS WHOLE FILE MISSED, AND THE ONE TEST THAT WOULD HAVE CAUGHT IT.
    ///
    /// Every other test here seeds the capture file first, which is the state no real upgrade is in:
    /// the capture reads `SkillManifestSD`, the V4/V5 registry, and **V4 and V5 never shipped**. A
    /// released install is at schema V3, where that table is created EMPTY, so the capture always
    /// wrote nothing and this sweep returned at its first `guard` — silently discarding every
    /// upgrading user's skills while the suite stayed green.
    ///
    /// So: NO capture file. The only record that this profile ever had a skill is the
    /// `legacyFolderPath` its own selection carries, which is exactly the real V3→V6 shape.
    ///
    /// **Mutation check:** source `run` from `peekPendingImports()` alone and this goes red while
    /// every other test in the file stays green — which is precisely what happened in production.
    func testItImportsAndRelinksFromProfileLinksAloneWithNoCaptureFile() async throws {
        let alpha = try makeSkillFolder("alpha")
        let profile = try makeProfile("Agent 1", selections: [
            SkillSelection(skillID: nil, legacyFolderPath: alpha.path, name: "alpha")
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path),
                       "the premise: a real V3 upgrade has no capture file at all")

        let outcome = await SkillLibraryImportSweep.run(container: container)

        XCTAssertNil(outcome.abortReason)
        XCTAssertEqual(outcome.imported, ["alpha"], "the folder named only by a profile link must still be ingested")
        XCTAssertEqual(outcome.selectionsRelinked, 1)

        let linked = try XCTUnwrap(selections(of: profile).first)
        XCTAssertFalse(linked.isAwaitingRelink, "the selection must end up pointing at a real library skill")
        XCTAssertEqual(linked.name, "alpha")
        XCTAssertNotNil(linked.skillID)
    }

    /// The differential control for the test above: the same profile, but already linked, must not
    /// cause a re-import. Without this, a harvest that ignored `isAwaitingRelink` would look correct.
    func testAnAlreadyLinkedProfileContributesNoWorkAndImportsNothing() async throws {
        let alpha = try makeSkillFolder("alpha")
        let skill = try store.create(name: "alpha", description: "d", body: "b",
                                     allowedTools: nil, files: []).get()
        try makeProfile("Agent 1", selections: [.link(skillID: skill.id, name: "alpha")])

        let outcome = await SkillLibraryImportSweep.run(container: container)

        XCTAssertTrue(outcome.imported.isEmpty,
                      "a linked selection carries no legacy folder; re-ingesting would duplicate the skill")
        XCTAssertEqual(outcome.selectionsRelinked, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alpha.path + "/.imported"))
    }

    func testHarvestReadsBothAgentAndCodeProfilesAndDeduplicatesByFolder() throws {
        let shared = try makeSkillFolder("shared")
        let other = try makeSkillFolder("other")

        let agent = try makeProfile("A", selections: [
            SkillSelection(skillID: nil, legacyFolderPath: shared.path, name: "shared")
        ])
        let codeConfig = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                                     tools: [],
                                     skillSelections: [
                                        SkillSelection(skillID: nil, legacyFolderPath: shared.path, name: "shared"),
                                        SkillSelection(skillID: nil, legacyFolderPath: other.path, name: "other")
                                     ])
        let codeProfile = BackendProfile(displayName: "C", details: .code(codeConfig))
        container.mainContext.insert(codeProfile)
        try container.mainContext.save()

        let harvested = SkillLibraryImportSweep.harvestLegacyFolders(from: [agent, codeProfile])

        XCTAssertEqual(harvested.map(\.folderPath).sorted(), [other.path, shared.path].sorted())
        XCTAssertEqual(harvested.filter { $0.folderPath == shared.path }.count, 1,
                       "one folder referenced by two profiles must be ingested ONCE — twice would duplicate the skill")
    }

    /// ⚠️ `.code` is harvested even though the runtime gives Code profiles no skills, for the same
    /// reason `rewrittenDetails` rewrites it: the references are persisted, and skipping them leaves
    /// dead addresses that resurface the day skills are enabled for Code.
    func testACodeProfilesLinksAreHarvestedToo() throws {
        let only = try makeSkillFolder("code-only")
        let config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                                 tools: [],
                                 skillSelections: [SkillSelection(skillID: nil, legacyFolderPath: only.path, name: "code-only")])
        let profile = BackendProfile(displayName: "C", details: .code(config))
        container.mainContext.insert(profile)

        XCTAssertEqual(SkillLibraryImportSweep.harvestLegacyFolders(from: [profile]).map(\.folderPath),
                       [only.path])
    }

    func testProfileKindsThatCannotHoldSkillsContributeNothing() throws {
        let bot = BackendProfile(displayName: "B",
                                 details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"))))
        container.mainContext.insert(bot)
        XCTAssertTrue(SkillLibraryImportSweep.harvestLegacyFolders(from: [bot]).isEmpty)
    }

    // MARK: - Merging the two sources

    /// ⚠️ REWRITTEN when `LegacySkillRef.isAgentWritable` was deleted (2026-09-15). This used to
    /// assert that a captured ref won a collision so a granted permission was not revoked — but the
    /// permission's only source was a V5 attribute that never shipped, so the field could never
    /// carry anything and was removed.
    ///
    /// The property underneath it survives and still matters: one folder named by BOTH sources must
    /// be ingested ONCE. Two entries would import the same folder twice and put a duplicate skill in
    /// the library, which nothing downstream can tell apart because names are not unique.
    func testAFolderNamedByBothSourcesIsIngestedOnlyOnce() throws {
        let folder = try makeSkillFolder("shared")
        let merged = SkillLibraryImportSweep.mergedPending(
            captured: [ref("shared", at: folder)],
            harvested: [SkillLibraryMigration.LegacySkillRef(folderPath: folder.path, name: "shared")])

        XCTAssertEqual(merged.count, 1, "one folder, one ingest — two would duplicate the skill")
        XCTAssertEqual(merged.first?.folderPath, folder.path)
    }

    func testAHarvestedFolderTheCaptureNeverNamedIsStillIngested() throws {
        let captured = try makeSkillFolder("from-capture")
        let harvestedOnly = try makeSkillFolder("from-profile")

        let merged = SkillLibraryImportSweep.mergedPending(
            captured: [ref("from-capture", at: captured)],
            harvested: [SkillLibraryMigration.LegacySkillRef(folderPath: harvestedOnly.path,
                                                            name: "from-profile")])

        XCTAssertEqual(merged.map(\.folderPath).sorted(), [captured.path, harvestedOnly.path].sorted())
    }

    /// ⚠️ REVERSED WHEN SCHEMA V4/V5 WERE DELETED (2026-09-15), deliberately. This used to assert
    /// that a harvested failure was NOT recorded, reasoning that the path is self-healing: the
    /// selection stays `awaitingRelink`, so the next launch re-harvests it. That reasoning is still
    /// true for RETRYING — and it was the wrong call anyway, because it ignored what the file is
    /// for now.
    ///
    /// With the migration capture gone, this file's only remaining job is the Skills library's
    /// "could not be imported" list. A failure the user cannot SEE is one they cannot retry or
    /// dismiss, so every failure is recorded regardless of where the folder came from. Retrying is
    /// safe either way, because the harvest re-derives the same folder from the profile.
    func testAFailedHarvestedFolderIsRecordedSoTheUserCanSeeIt() async throws {
        let missing = work.appendingPathComponent("never-existed")
        try makeProfile("A", selections: [
            SkillSelection(skillID: nil, legacyFolderPath: missing.path, name: "ghost")
        ])

        let outcome = await SkillLibraryImportSweep.run(container: container)

        XCTAssertEqual(outcome.failed.count, 1, "the unreadable folder is reported in the outcome")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path),
                      "and persisted, or the library could not show it after the launch that failed")
        XCTAssertEqual(SkillLibraryMigration.peekPendingImports().map(\.folderPath), [missing.path])
    }

    // MARK: - Nothing to do

    func testNoCaptureFileIsANoOp() async {
        let outcome = await SkillLibraryImportSweep.run(container: container)
        XCTAssertTrue(outcome.imported.isEmpty)
        XCTAssertEqual(outcome.selectionsRelinked, 0)
        XCTAssertEqual(outcome.profilesExamined, 0, "a sweep with nothing pending must not even read profiles")
    }

    // MARK: - The happy path

    func testImportsCapturedFoldersAndRelinksTheProfilesThatReferencedThem() async throws {
        let alpha = try makeSkillFolder("alpha")
        let beta = try makeSkillFolder("beta")
        try capture([ref("alpha", at: alpha), ref("beta", at: beta)])

        let profile = try makeProfile("Agent", selections: [
            SkillSelection(skillID: nil, legacyFolderPath: alpha.path, name: "alpha"),
            SkillSelection(skillID: nil, legacyFolderPath: beta.path, name: "beta", isEnabled: false)
        ])

        let outcome = await SkillLibraryImportSweep.run(container: container)

        XCTAssertEqual(outcome.imported.sorted(), ["alpha", "beta"])
        XCTAssertEqual(outcome.selectionsRelinked, 2)
        XCTAssertEqual(outcome.selectionsStillPending, 0)

        let after = selections(of: profile)
        XCTAssertTrue(after.allSatisfy { !$0.isAwaitingRelink }, "every selection must now carry a real id")
        XCTAssertTrue(after.allSatisfy { $0.skillID?.hasPrefix("skill_") == true })
        XCTAssertNil(after.first { $0.name == "beta" }?.skillID.flatMap { _ in nil as String? })
        XCTAssertEqual(after.first { $0.name == "beta" }?.isEnabled, false,
                       "⚠️ re-linking repairs an ADDRESS — silently re-enabling a skill the user switched off would look like a settings reset")

        // And the whole chain actually resolves for a run.
        guard case .agent(let config) = profile.details else { return XCTFail("expected an agent") }
        let resolved = try XCTUnwrap(SkillResolution.resolve(for: config, profileName: "Agent"))
        XCTAssertEqual(resolved.manifests.map(\.name), ["alpha"], "beta is linked but disabled")
        XCTAssertTrue(resolved.awaitingRelink.isEmpty)
    }

    func testTheCaptureFileIsClearedOnlyAfterEverythingSucceeded() async throws {
        let alpha = try makeSkillFolder("alpha")
        try capture([ref("alpha", at: alpha)])

        await SkillLibraryImportSweep.run(container: container)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))
        XCTAssertTrue(SkillLibraryMigration.peekPendingImports().isEmpty)
    }

    /// ⚠️ A second run must not duplicate. The capture being cleared IS the idempotence — nothing in
    /// the library records where a skill came from, so a re-run of the same capture would create a
    /// second copy of every skill.
    func testRunningTwiceDoesNotDuplicate() async throws {
        let alpha = try makeSkillFolder("alpha")
        try capture([ref("alpha", at: alpha)])

        await SkillLibraryImportSweep.run(container: container)
        let second = await SkillLibraryImportSweep.run(container: container)

        XCTAssertTrue(second.imported.isEmpty)
        XCTAssertEqual(second.selectionsRelinked, 0)
        XCTAssertEqual(try store.fetchSkills().get().count, 1)
    }

    /// ⚠️ INVERTED, DELIBERATELY. This asserted that an agent-write permission travelled with a
    /// migrated skill. It cannot and must not: the permission's only source was
    /// `SkillManifestSD.isAgentWritable`, a schema V5 attribute that **never shipped**, so nothing a
    /// real store contains could ever have carried it.
    ///
    /// The behaviour now is the safer one and worth pinning in that direction: a recovered skill
    /// arrives NOT agent-writable, and the user grants `update_skill` access deliberately. A
    /// migration that silently handed an agent write access to instructions it then executes is
    /// precisely what default-deny exists to prevent.
    func testARecoveredSkillIsNotAgentWritableUntilTheUserSaysSo() async throws {
        let alpha = try makeSkillFolder("alpha")
        try capture([ref("alpha", at: alpha)])

        await SkillLibraryImportSweep.run(container: container)
        let skill = try XCTUnwrap(try store.fetchSkills().get().first)
        XCTAssertFalse(skill.isAgentWritable,
                       "no migration may grant an agent write access to a skill — the user does that")
    }

    // MARK: - Failure is reported and retried

    /// The ordinary case: an external volume that was not mounted at this launch.
    func testAnUnreachableFolderIsReportedAndKeptForTheNextLaunch() async throws {
        let alpha = try makeSkillFolder("alpha")
        let missing = work.appendingPathComponent("not-there")
        try capture([ref("alpha", at: alpha), ref("ghost", at: missing)])

        let profile = try makeProfile("Agent", selections: [
            SkillSelection(skillID: nil, legacyFolderPath: alpha.path, name: "alpha"),
            SkillSelection(skillID: nil, legacyFolderPath: missing.path, name: "ghost")
        ])

        let outcome = await SkillLibraryImportSweep.run(container: container)

        XCTAssertEqual(outcome.imported, ["alpha"], "one bad folder must not cost the user the good ones")
        XCTAssertEqual(outcome.failed.map(\.label), ["ghost"])
        XCTAssertEqual(outcome.selectionsStillPending, 1)

        XCTAssertEqual(SkillLibraryMigration.peekPendingImports().map(\.name), ["ghost"],
                       "⚠️ written BACK, not discarded — a volume that is mounted next launch should still import")

        let after = selections(of: profile)
        XCTAssertFalse(try XCTUnwrap(after.first { $0.name == "alpha" }).isAwaitingRelink)
        XCTAssertTrue(try XCTUnwrap(after.first { $0.name == "ghost" }).isAwaitingRelink)
    }

    /// ⚠️ THE ORDERING PROPERTY. Ingest → re-link → clear. If the capture were cleared before the
    /// profile pass, a failure there would leave skills in the library, profiles pointing at
    /// nothing, and no record of how to connect them.
    ///
    /// ⚠️ Tested on the PURE DECISION, not through the sweep — and the first version of this test
    /// was vacuous for trying the latter. It built a container with no `BackendProfile` entity
    /// expecting the fetch to throw; SwiftData returns an empty result instead, so the sweep
    /// completed "successfully", cleared the capture, and the test failed for the wrong reason. The
    /// production container always has that entity, so there is no realistic way to make the profile
    /// pass fail on demand — which is exactly why the rule has to live somewhere a test can reach.
    func testAnAbortedPassMustNotClearTheCapture() {
        var aborted = SkillImportSweepOutcome()
        aborted.abortReason = "profile save failed"
        XCTAssertFalse(SkillLibraryImportSweep.shouldClearCapture(aborted),
                       "the capture is the only map from folder to skill — an aborted pass must leave it for the next launch")

        var clean = SkillImportSweepOutcome()
        clean.imported = ["alpha"]
        XCTAssertTrue(SkillLibraryImportSweep.shouldClearCapture(clean))
    }

    /// Failed FOLDERS are not an abort: the pass worked, some folders did not, and those are written
    /// back individually. Conflating the two would keep retrying a completed migration forever.
    func testFailedFoldersAloneDoNotBlockClearing() {
        var outcome = SkillImportSweepOutcome()
        outcome.imported = ["alpha"]
        outcome.failed = [RejectedSkill(label: "ghost", reason: "not found")]
        XCTAssertTrue(SkillLibraryImportSweep.shouldClearCapture(outcome))
    }

    // MARK: - Matching the right skill

    /// ⚠️ One folder can yield several skills. Taking the first would silently repoint a link at a
    /// SIBLING — the link would still "work", against the wrong instructions.
    func testAFolderYieldingSeveralSkillsRelinksByNameNotByPosition() async throws {
        let bundle = work.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try makeSkillFolder("aaa-first", in: bundle, description: "The wrong one.")
        try makeSkillFolder("zzz-wanted", in: bundle, description: "The right one.")
        try capture([ref("zzz-wanted", at: bundle)])

        let profile = try makeProfile("Agent", selections: [
            SkillSelection(skillID: nil, legacyFolderPath: bundle.path, name: "zzz-wanted")
        ])

        await SkillLibraryImportSweep.run(container: container)

        let selection = try XCTUnwrap(selections(of: profile).first)
        XCTAssertFalse(selection.isAwaitingRelink)
        let skill = try XCTUnwrap(try store.fetchSkill(id: try XCTUnwrap(selection.skillID)).get())
        XCTAssertEqual(skill.name, "zzz-wanted")
        XCTAssertEqual(skill.latestVersion?.skillDescription, "The right one.")
    }

    /// If no imported skill carries the selection's name, the link is LEFT PENDING rather than
    /// pointed at something plausible.
    func testNoNameMatchLeavesTheSelectionPending() async throws {
        let bundle = work.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try makeSkillFolder("something-else", in: bundle)
        try capture([ref("renamed-since", at: bundle)])

        let profile = try makeProfile("Agent", selections: [
            SkillSelection(skillID: nil, legacyFolderPath: bundle.path, name: "renamed-since")
        ])

        let outcome = await SkillLibraryImportSweep.run(container: container)

        XCTAssertEqual(outcome.imported, ["something-else"])
        XCTAssertEqual(outcome.selectionsStillPending, 1)
        XCTAssertTrue(try XCTUnwrap(selections(of: profile).first).isAwaitingRelink)
    }

    // MARK: - Profiles it must not touch

    func testAlreadyLinkedSelectionsAreLeftExactlyAsTheyAre() async throws {
        let alpha = try makeSkillFolder("alpha")
        try capture([ref("alpha", at: alpha)])
        let existing = SkillSelection.link(skillID: "skill_already", name: "already",
                                           pinnedVersionID: "skver_pinned", isEnabled: false)
        let profile = try makeProfile("Agent", selections: [
            existing,
            SkillSelection(skillID: nil, legacyFolderPath: alpha.path, name: "alpha")
        ])

        await SkillLibraryImportSweep.run(container: container)

        let after = selections(of: profile)
        XCTAssertEqual(after.first { $0.skillID == "skill_already" }, existing,
                       "a selection that already points somewhere is not this sweep's to touch — pin included")
    }

    func testAProfileWithNothingPendingIsNotRewritten() async throws {
        let alpha = try makeSkillFolder("alpha")
        try capture([ref("alpha", at: alpha)])
        let profile = try makeProfile("Untouched", selections: [
            SkillSelection.link(skillID: "skill_already", name: "already")
        ])
        let before = profile.configData

        await SkillLibraryImportSweep.run(container: container)

        XCTAssertEqual(profile.configData, before,
                       "⚠️ writing every profile on every launch churns configData for nothing and defeats the no-op-save guard")
    }

    /// ⚠️ A profile whose pending selections matched NOTHING must not be written either.
    ///
    /// This is the unreachable-volume case and it recurs on EVERY launch until the volume is mounted
    /// or the user clears it, so a needless write is churn forever rather than a one-off.
    ///
    /// ⚠️ Asserted on `rewritten` directly, and the first attempt at this test was VACUOUS: it
    /// compared `profile.configData` before and after the sweep, but re-encoding unchanged details
    /// produces byte-identical bytes, so it passed with the guard removed. A mutation proved it.
    /// The has-pending guard alone is not enough — a profile can hold a pending selection and still
    /// have nothing to rewrite, which is precisely this case.
    func testSelectionsThatMatchedNothingProduceNoRewrite() {
        var outcome = SkillImportSweepOutcome()
        let pending = [SkillSelection(skillID: nil, legacyFolderPath: "/gone/ghost", name: "ghost")]

        XCTAssertNil(SkillLibraryImportSweep.rewritten(pending, map: [:], into: &outcome),
                     "nothing matched, so there is nothing to write — nil is what stops the caller touching the profile")
        XCTAssertEqual(outcome.selectionsStillPending, 1, "and it is still counted as waiting")
    }

    func testAMatchedSelectionDoesProduceARewrite() {
        var outcome = SkillImportSweepOutcome()
        let pending = [SkillSelection(skillID: nil, legacyFolderPath: "/found/alpha", name: "alpha")]
        let map = ["/found/alpha": [(id: "skill_a", name: "alpha")]]

        let result = SkillLibraryImportSweep.rewritten(pending, map: map, into: &outcome)
        XCTAssertEqual(result?.first?.skillID, "skill_a",
                       "the control: without this, the test above would pass simply because nothing ever rewrites")
        XCTAssertEqual(outcome.selectionsRelinked, 1)
    }

    /// ⚠️ An unreadable blob decodes to a `.bot` PLACEHOLDER with no skills and no error. Treating
    /// that as "no selections" is exactly the silent under-migration this guards against.
    func testAnUnreadableProfileIsReportedNotSilentlySkipped() async throws {
        let alpha = try makeSkillFolder("alpha")
        try capture([ref("alpha", at: alpha)])
        // ⚠️ Inserted through a SEPARATE context. `_cachedDetails` is populated at `init`, so a
        // profile whose `configData` is corrupted in the same context still answers from its cache
        // and never reports as unreadable — the first version of this test corrupted the bytes in
        // `mainContext` and therefore exercised nothing. Writing from another context forces
        // `mainContext` to materialise a fresh instance that actually decodes the stored bytes.
        let writer = ModelContext(container)
        let broken = BackendProfile(displayName: "Broken",
                                    details: .agent(AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m"), tools: [])))
        writer.insert(broken)
        try writer.save()
        broken.configData = Data("not json".utf8)
        try writer.save()

        let outcome = await SkillLibraryImportSweep.run(container: container)
        XCTAssertEqual(outcome.unreadableProfiles, ["Broken"])
    }
}

/// ⚠️⚠️ THE SWEEP GAINED A SUSPENSION POINT WHEN ITS INGEST MOVED OFF THE MAIN ACTOR, AND WITH IT
/// THE ABILITY TO OVERLAP WITH ITSELF.
///
/// Before that, a pass held the main actor from the profile fetch through the capture rewrite, so
/// two passes could not interleave. Freeing the main actor is precisely what lets the user open the
/// Skills window during a slow launch ingest and press "Try again" — and two passes over the same
/// pending list would ingest the same folder twice and create two skills with the same name.
/// Nothing records where a skill came from, so the user cannot tell the duplicates apart.
@MainActor
final class SkillSweepExclusivityTests: XCTestCase {

    override func tearDown() async throws {
        SkillLibraryImportSweep.endExclusive()
        try await super.tearDown()
    }

    /// **Mutation check:** delete the `beginExclusive()` guard from `run` and this goes red.
    func testASecondPassIsRefusedWhileOneIsRunning() {
        XCTAssertTrue(SkillLibraryImportSweep.beginExclusive(), "the first pass takes the guard")
        XCTAssertFalse(SkillLibraryImportSweep.beginExclusive(),
                       "a second overlapping pass must be refused — it would re-ingest the same folders and duplicate every skill")
    }

    /// The control: the guard is released, not a one-shot latch. A `beginExclusive` that never
    /// released would satisfy the test above and disable the sweep for the rest of the session —
    /// including the launch it exists for.
    func testTheGuardIsReleasedSoALaterPassCanRun() {
        XCTAssertTrue(SkillLibraryImportSweep.beginExclusive())
        SkillLibraryImportSweep.endExclusive()
        XCTAssertTrue(SkillLibraryImportSweep.beginExclusive(),
                      "a sweep must be runnable again once the previous one finished")
    }

    /// ⚠️ A refused pass must report WHY rather than looking like a clean no-op, or the retry button
    /// silently does nothing and the user presses it again.
    func testARefusedPassSaysSoRatherThanReportingSuccess() async throws {
        let container = try ModelContainer(for: DevgenticSchema.schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        XCTAssertTrue(SkillLibraryImportSweep.beginExclusive())
        let outcome = await SkillLibraryImportSweep.run(container: container)
        XCTAssertNotNil(outcome.abortReason,
                        "a refused pass is not a successful empty pass — the capture must be kept")
        XCTAssertFalse(SkillLibraryImportSweep.shouldClearCapture(outcome),
                       "and an aborted pass must never clear the capture file")
    }
}
