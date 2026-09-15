// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SyntheticSkillsStoreMigrationTests.swift
//  devgenticTests
//
//  The V3→V6 skills upgrade, end to end, on a REAL store file.
//
//  ⚠️⚠️ THIS IS THE TEST THAT WOULD HAVE CAUGHT THE BLOCKER, AND IT COULD NOT BE WRITTEN BEFORE NOW.
//  The V6 sweep sourced its work from the V4/V5 registry table, which no released store has, so
//  every upgrading user's skills were silently discarded. In-memory containers cannot see that: they
//  are created at V6 with no version stamp to migrate from, and the whole suite stayed green.
//
//  The obstacle to testing it for real was that NO STORE ON THIS MACHINE HAS SKILLS CONFIGURED —
//  checked the live store and all three backups, zero profile blobs mention one. So this synthesises
//  the missing ingredient and nothing else: it takes a genuine `schemaVersion: 7` blob out of the
//  real pre-V3 store, injects a `skillConfig` pointing at real folders on disk, and then runs the
//  REAL migration plan and the REAL sweep over the result.
//
//  What is synthetic: one JSON key. What is real: the store file, its version stamp, the profile's
//  own configuration, the blob migration ladder v7→v8→v9, the schema migration V3→V6, the ingest
//  from disk, and the re-link.
//
//  ⚠️ READ-ONLY on Application Support — the store is copied before anything opens it, because
//  opening runs the migration and rewrites the file.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SyntheticSkillsStoreMigrationTests: XCTestCase {

    private static let appSupport = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    private static let sourceStore = "DevgenticSD.store.pre-schemaV3-backup"
    /// The profile whose blob gets the injected skills. A real Agent profile in that store.
    private static let targetProfile = "Agent 3"

    private var work: URL!
    private var store: URL!
    private var skillsRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        store = work.appendingPathComponent("synthetic.store")
        skillsRoot = work.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        SkillStore.shared.setContainerForTesting(nil)
        SkillLibraryMigration.captureURLOverride = nil
        if let work { try? FileManager.default.removeItem(at: work) }
        try await super.tearDown()
    }

    // MARK: - sqlite plumbing

    /// ⚠️ Hex in, hex out. The blob is JSON that can contain quotes; going through `X'…'` literals
    /// means no escaping rules to get wrong, and a corrupted blob would fail as a decode error that
    /// looks like a migration bug.
    @discardableResult
    private func sqlite(_ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [store.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "sqlite", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: output])
        }
        return output
    }

    private func hexToData(_ hex: String) -> Data? {
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        return Data(bytes)
    }

    // MARK: - Fixture

    private func makeSkillFolder(_ name: String) throws -> URL {
        let dir = skillsRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: A real \(name) skill.\n---\n\n# \(name)\nDo the \(name) thing."
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return dir
    }

    /// Copies the real store and injects a pre-V6 `skillConfig` into one real profile's blob.
    private func stageStoreWithSkills(named names: [String]) throws -> [String: URL] {
        let source = Self.appSupport.appendingPathComponent(Self.sourceStore)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "\(Self.sourceStore) absent — this gate only runs on a machine that has it")
        try FileManager.default.copyItem(at: source, to: store)

        var folders: [String: URL] = [:]
        for name in names { folders[name] = try makeSkillFolder(name) }

        let hex = try sqlite("SELECT hex(ZCONFIGDATA) FROM ZBACKENDPROFILE WHERE ZDISPLAYNAME='\(Self.targetProfile)';")
        let blob = try XCTUnwrap(hexToData(hex), "could not read the profile blob")
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: blob) as? [String: Any])

        // Sanity: this must be a genuine pre-skills blob, or the test proves nothing.
        XCTAssertEqual(json["schemaVersion"] as? Int, 7, "expected a v7 blob — the released shape")
        XCTAssertNil(json["skillSelections"], "the premise is a profile that predates selections")
        XCTAssertNil(json["skillConfig"], "and that has no skills yet")

        // The one synthetic ingredient: the shape a released build actually persisted.
        json["skillConfig"] = [
            "folderURLs": [skillsRoot.absoluteString],
            "lastScannedAt": Date().timeIntervalSinceReferenceDate,
            "manifests": names.map { name in
                [
                    "id": UUID().uuidString,
                    "name": name,
                    "description": "A real \(name) skill.",
                    "folderPath": folders[name]!.path,
                    "resourceCount": 0,
                    "hasScripts": false,
                    "isEnabled": true
                ] as [String: Any]
            }
        ]

        let rewritten = try JSONSerialization.data(withJSONObject: json)
        let rewrittenHex = rewritten.map { String(format: "%02X", $0) }.joined()
        try sqlite("UPDATE ZBACKENDPROFILE SET ZCONFIGDATA = X'\(rewrittenHex)' WHERE ZDISPLAYNAME='\(Self.targetProfile)';")
        return folders
    }

    /// Opens the staged store through the REAL plan, so the V3→V6 migration actually runs.
    private func migrate() throws -> ModelContainer {
        SkillLibraryMigration.captureURLOverride = work.appendingPathComponent("capture.json")
        let container = try ModelContainer(
            for: DevgenticSchema.schema,
            migrationPlan: DevgenticMigrationPlan.self,
            configurations: ModelConfiguration(DevgenticSchema.configurationName,
                                               schema: DevgenticSchema.schema, url: store))
        SkillStore.shared.setContainerForTesting(container)
        return container
    }

    private func targetSelections(in container: ModelContainer) throws -> [SkillSelection] {
        let profiles = try container.mainContext.fetch(FetchDescriptor<BackendProfile>())
        let profile = try XCTUnwrap(profiles.first { $0.displayName == Self.targetProfile })
        guard case .agent(let config) = profile.details else {
            XCTFail("the target profile is not an agent after migration"); return []
        }
        return config.skillSelections ?? []
    }

    // MARK: - The chain

    /// ⚠️ The blob ladder alone, before the sweep: a v7 `skillConfig` must become v9 selections that
    /// carry `legacyFolderPath` and NO `skillID`. This is the state the sweep has to find, and it is
    /// produced on the READ path by `ProfileMigrator` with no store access at all.
    func testAV7BlobBecomesSelectionsAwaitingRelink() throws {
        let folders = try stageStoreWithSkills(named: ["code-review", "data-cleaner"])
        let container = try migrate()

        let selections = try targetSelections(in: container)
        XCTAssertEqual(selections.count, 2, "both manifests must survive v7→v8→v9")
        XCTAssertEqual(selections.map(\.name).sorted(), ["code-review", "data-cleaner"])
        XCTAssertTrue(selections.allSatisfy(\.isAwaitingRelink),
                      "before the sweep runs they address a FOLDER, not a library skill")
        XCTAssertEqual(Set(selections.compactMap(\.legacyFolderPath)),
                       Set(folders.values.map(\.path)),
                       "the folder addresses must survive into v9 — they are the only record left")
    }

    /// ⚠️⚠️ THE WHOLE POINT. The capture file is EMPTY — a V3 store has no V4/V5 registry rows to
    /// capture from, which is exactly why the shipped sweep found nothing and discarded every
    /// upgrading user's skills. The profiles are the only remaining record, and the sweep must
    /// recover the folders from them, ingest, and re-link.
    ///
    /// **Mutation check:** source `SkillLibraryImportSweep.run` from `peekPendingImports()` alone
    /// and this goes red — while every in-memory sweep test stays green, as they did in production.
    func testTheSweepRecoversAndRelinksSkillsFromProfilesAloneOnARealV3Store() throws {
        try stageStoreWithSkills(named: ["code-review", "data-cleaner"])
        let container = try migrate()

        XCTAssertTrue(SkillLibraryMigration.peekPendingImports().isEmpty,
                      "premise: a V3 store yields NO capture entries — the registry never existed")

        let outcome = SkillLibraryImportSweep.run(container: container)

        XCTAssertNil(outcome.abortReason)
        XCTAssertEqual(outcome.imported.sorted(), ["code-review", "data-cleaner"],
                       "both folders must be ingested into the library")
        XCTAssertEqual(outcome.selectionsRelinked, 2)
        XCTAssertEqual(outcome.selectionsStillPending, 0)

        let selections = try targetSelections(in: container)
        XCTAssertTrue(selections.allSatisfy { !$0.isAwaitingRelink },
                      "every link must now address a real library skill")
        XCTAssertEqual(selections.compactMap(\.skillID).count, 2)
    }

    /// And the skills are genuinely usable afterwards — the bodies came off disk into the library.
    func testTheRecoveredSkillsResolveAndCarryTheirInstructions() throws {
        try stageStoreWithSkills(named: ["code-review"])
        let container = try migrate()
        _ = SkillLibraryImportSweep.run(container: container)

        let selections = try targetSelections(in: container)
        let config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                                 tools: [], skillSelections: selections)
        let resolved = try XCTUnwrap(SkillResolution.resolve(for: config, profileName: Self.targetProfile))

        XCTAssertEqual(resolved.manifests.map(\.name), ["code-review"],
                       "a recovered skill must reach a run, not merely exist in the library")
        let skill = try XCTUnwrap(try SkillStore.shared.fetchSkill(id: try XCTUnwrap(selections.first?.skillID)).get())
        XCTAssertTrue(try XCTUnwrap(skill.latestVersion).body.contains("Do the code-review thing."),
                      "the instructions must have come off disk into the library")
    }

    /// ⚠️ Idempotence. The sweep runs on EVERY launch; a second pass must not re-ingest folders it
    /// already imported. Re-harvesting is prevented by the selections no longer awaiting re-link —
    /// if that ever stops being true, this store gains a duplicate skill on every restart.
    func testASecondLaunchImportsNothingFurther() throws {
        try stageStoreWithSkills(named: ["code-review", "data-cleaner"])
        let container = try migrate()

        _ = SkillLibraryImportSweep.run(container: container)
        let second = SkillLibraryImportSweep.run(container: container)

        XCTAssertTrue(second.imported.isEmpty, "a relaunch must not duplicate the library")
        XCTAssertEqual(second.selectionsRelinked, 0)
        let skills = try container.mainContext.fetch(FetchDescriptor<SkillSD>())
        XCTAssertEqual(skills.count, 2, "still exactly the two skills")
    }

    /// A folder that has gone away (unmounted volume, deleted directory) must be reported and must
    /// leave its link pending — never silently dropped, and never blocking its siblings.
    func testAMissingFolderIsReportedAndItsSiblingStillImports() throws {
        let folders = try stageStoreWithSkills(named: ["code-review", "data-cleaner"])
        try FileManager.default.removeItem(at: try XCTUnwrap(folders["data-cleaner"]))
        let container = try migrate()

        let outcome = SkillLibraryImportSweep.run(container: container)

        XCTAssertEqual(outcome.imported, ["code-review"], "the readable folder still imports")
        XCTAssertEqual(outcome.failed.count, 1, "and the missing one is reported to the user")
        XCTAssertEqual(outcome.selectionsStillPending, 1)

        let selections = try targetSelections(in: container)
        let pending = selections.filter(\.isAwaitingRelink)
        XCTAssertEqual(pending.map(\.name), ["data-cleaner"],
                       "its link stays pending so a later launch can still repair it")
    }
}
