// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillSelectionMigrationTests.swift
//  devgenticTests
//
//  The v7 → v8 profile-blob cut-over: skills become registry references.
//
//  Two properties matter more than the happy path, because both failures are silent and both make
//  a profile look broken to its owner:
//
//    - a v7 blob must still DECODE. `skillSelections` is absent from every already-persisted blob,
//      and a non-optional decode there throws `keyNotFound`, which escapes the `decodeIfPresent` at
//      the ProfileDetails call site and fails the WHOLE profile.
//    - `migrateToV8` runs on the READ path, on EVERY decode, and is never written back — so it must
//      be idempotent and total, not merely correct once.
//

import XCTest
@testable import devgentic

final class SkillSelectionMigrationTests: XCTestCase {

    // MARK: - Helpers

    /// ⚠️ The ProfileDetails blob is FLAT — the config's fields sit at the top level beside
    /// `schemaVersion`, with a `profileType` discriminator. It is not nested under a per-type key,
    /// which is why `migrateToV8` reads `skillConfig` straight off the root (as `migrateToV7` reads
    /// `tools`). A fixture that nests it would decode as an empty agent and prove nothing.
    private func v7Blob(
        manifests: [[String: Any]],
        folderURLs: [String] = ["/Users/test/skills"],
        profileType: String = "Agent",
        extraKeys: [String: Any] = [:]
    ) throws -> Data {
        var root: [String: Any] = [
            "schemaVersion": 7,
            "profileType": profileType,
            "llmConfig": ["apiProvider": "Ollama (Local)", "modelName": "llama3"],
            "tools": [],
            "capabilities": [:],
            "skillConfig": [
                "folderURLs": folderURLs,
                "manifests": manifests,
                "lastScannedAt": 0
            ]
        ]
        root.merge(extraKeys) { _, new in new }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func manifestJSON(_ name: String, isEnabled: Bool = true, root: String = "/Users/test/skills") -> [String: Any] {
        [
            "id": UUID().uuidString,
            "name": name,
            "description": "Skill \(name).",
            "folderPath": "\(root)/\(name)",
            "resourceCount": 0,
            "hasScripts": false,
            "isEnabled": isEnabled
        ]
    }

    private func migrated(_ data: Data) throws -> [String: Any] {
        guard case .migrated(let out) = ProfileMigrator.migrateIfNeeded(data) else {
            throw XCTSkip("expected a .migrated outcome")
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    private func selections(in json: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(json["skillSelections"] as? [[String: Any]])
    }

    // MARK: - Migration

    func testMigrateToV8_DerivesSelectionsFromTheManifestCopies() throws {
        let data = try v7Blob(manifests: [manifestJSON("alpha"), manifestJSON("beta", isEnabled: false)])

        let json = try migrated(data)

        // ⚠️ Asserts the END of the ladder, not the v8 step in isolation. `migrateIfNeeded` applies
        // every step in order, and v9 reshapes `folderPath` into `legacyFolderPath` — so this now
        // checks that v8's DERIVATION (manifest copies → selections) survives v9's RESHAPE. Pinning
        // the intermediate shape would just mean re-editing this test on every future step.
        XCTAssertEqual(json["schemaVersion"] as? Int, 9)
        let out = try selections(in: json)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map { $0["name"] as? String }, ["alpha", "beta"])
        XCTAssertEqual(out.map { $0["legacyFolderPath"] as? String },
                       ["/Users/test/skills/alpha", "/Users/test/skills/beta"],
                       "v8 derived these from the manifest copies and v9 moved them to the legacy key")
        XCTAssertEqual(out.compactMap { $0["skillID"] as? String }, [],
                       "no step in the ladder may invent an id — only the launch sweep can know one")
        XCTAssertEqual(out.map { $0["isEnabled"] as? Bool }, [true, false],
                       "per-skill enablement is the one thing the profile owns — it must survive the cut-over")
    }

    /// ⚠️ Runs on every decode of the same bytes. A second pass must change nothing.
    func testMigrateToV8_IsIdempotent() throws {
        let data = try v7Blob(manifests: [manifestJSON("alpha")])

        let once = try migrated(data)
        let twice = try migrated(try JSONSerialization.data(withJSONObject: once))

        XCTAssertEqual(try selections(in: once).count, 1)
        XCTAssertEqual(try selections(in: twice).count, 1,
                       "re-migrating an already-migrated blob must not append a second copy")
    }

    /// An explicitly emptied selection list means "migrated, links nothing" and must not be
    /// re-populated from the legacy copies the blob still carries.
    func testMigrateToV8_DoesNotResurrectAnEmptiedSelectionList() throws {
        let data = try v7Blob(manifests: [manifestJSON("alpha")],
                              extraKeys: ["skillSelections": []])

        let json = try migrated(data)

        XCTAssertTrue(try selections(in: json).isEmpty,
                      "an empty list is a decision, not a missing value — refilling it would resurrect skills the user unlinked")
    }

    // MARK: - Totality

    func testMigrateToV8_IsTotalOverMalformedInput() throws {
        // A manifest missing `folderPath`, one missing `name`, one that is not an object at all,
        // and a skillConfig whose `manifests` is the wrong type.
        let ragged: [[String: Any]] = [
            ["name": "no-path", "description": "d"],
            ["folderPath": "/Users/test/skills/no-name", "description": "d"],
            manifestJSON("good")
        ]
        let json = try migrated(try v7Blob(manifests: ragged))
        XCTAssertEqual(json["schemaVersion"] as? Int, 9, "a ragged blob must still be stamped, never throw")
        XCTAssertEqual(try selections(in: json).map { $0["name"] as? String }, ["good"],
                       "unusable entries are dropped; the usable one survives")

        // skillConfig present but shaped wrong.
        let wrongShape: [String: Any] = [
            "schemaVersion": 7, "profileType": "Agent",
            "llmConfig": ["apiProvider": "Ollama (Local)", "modelName": "llama3"],
            "tools": [], "capabilities": [:], "skillConfig": ["manifests": "not an array"]
        ]
        let out = try migrated(try JSONSerialization.data(withJSONObject: wrongShape))
        XCTAssertEqual(out["schemaVersion"] as? Int, 9)

        // No skillConfig at all.
        let none: [String: Any] = [
            "schemaVersion": 7, "profileType": "Agent",
            "llmConfig": ["apiProvider": "Ollama (Local)", "modelName": "llama3"],
            "tools": [], "capabilities": [:]
        ]
        XCTAssertEqual(try migrated(try JSONSerialization.data(withJSONObject: none))["schemaVersion"] as? Int, 9)
    }

    /// `isEnabled` predates the cut-over but a blob written before it existed would omit the key.
    /// Defaulting to true matches `SkillFolderScanner`, which hardcodes it on every parsed skill.
    func testMigrateToV8_DefaultsMissingIsEnabledToTrue() throws {
        var manifest = manifestJSON("legacy")
        manifest.removeValue(forKey: "isEnabled")

        let out = try selections(in: try migrated(try v7Blob(manifests: [manifest])))

        XCTAssertEqual(out.first?["isEnabled"] as? Bool, true)
    }

    // MARK: - Decode compatibility (the failure that marks a profile unreadable)

    /// ⚠️ THE ONE THAT MATTERS ON FIRST LAUNCH. Every persisted blob lacks `skillSelections`.
    func testV7Blob_StillDecodesAfterTheCutOver() throws {
        let data = try v7Blob(manifests: [manifestJSON("alpha")])
        guard case .migrated(let out) = ProfileMigrator.migrateIfNeeded(data) else {
            return XCTFail("expected .migrated")
        }

        let details = try JSONDecoder().decode(ProfileDetails.self, from: out)

        guard case .agent(let config) = details else { return XCTFail("expected an agent config") }
        XCTAssertEqual(config.skillSelections?.map(\.name), ["alpha"],
                       "the migration must hand the decoder selections derived from the legacy copies")
        XCTAssertNotNil(config.skillConfig,
                        "the legacy field is RETAINED for the dual-read window — deleting it now would strand un-re-saved profiles")
    }

    /// A blob with no skills at all must decode with both fields nil, not throw and not invent an
    /// empty list (which would mean something different to the resolver).
    func testBlobWithNoSkills_DecodesWithBothFieldsNil() throws {
        let json: [String: Any] = [
            "schemaVersion": 7, "profileType": "Agent",
            "llmConfig": ["apiProvider": "Ollama (Local)", "modelName": "llama3"],
            "tools": [], "capabilities": [:]
        ]
        guard case .migrated(let out) = ProfileMigrator.migrateIfNeeded(try JSONSerialization.data(withJSONObject: json)) else {
            return XCTFail("expected .migrated")
        }

        let details = try JSONDecoder().decode(ProfileDetails.self, from: out)
        guard case .agent(let config) = details else { return XCTFail("expected an agent config") }
        XCTAssertNil(config.skillSelections)
        XCTAssertNil(config.skillConfig)
    }

    // MARK: - Round trip

    // MARK: - Reachability of the legacy resolution arm (audit finding #23)

    /// ⚠️ PINS THE REAL BEHAVIOUR, which is not what `SkillResolution`'s header claimed.
    ///
    /// That header said the legacy arm is "read only when `skillSelections` is nil, i.e. a profile
    /// written before v8 that has not been re-saved". That case CANNOT occur: `migrateToV8` runs on
    /// the READ path of every decode, and whenever `skillConfig.manifests` parses it sets
    /// `skillSelections`. So a migrated v7 blob always arrives with selections, and the legacy arm
    /// never fires for it.
    ///
    /// The arm is still reachable, but only by a narrower route (see the next test), so it is kept —
    /// with an honest comment rather than a wrong one.
    func testAMigratedV7BlobAlwaysCarriesSelectionsSoTheLegacyArmDoesNotFire() throws {
        let data = try v7Blob(manifests: [manifestJSON("alpha")])
        guard case .migrated(let out) = ProfileMigrator.migrateIfNeeded(data) else {
            return XCTFail("expected .migrated")
        }
        guard case .agent(let config) = try JSONDecoder().decode(ProfileDetails.self, from: out) else {
            return XCTFail("expected an agent config")
        }

        XCTAssertNotNil(config.skillSelections,
                        "the migration sets selections, so the legacy fallback is unreachable for this case")
        XCTAssertNotNil(config.skillConfig, "and the legacy blob is still present alongside them")
    }

    /// The route by which the legacy arm IS still reachable: a blob already stamped v8 (so the
    /// migration is skipped) that carries `skillConfig` but no `skillSelections`. `encodeIfPresent`
    /// omits a nil selections list, so any code path constructing an `AgentConfig` with a legacy
    /// config and no selections produces exactly this.
    func testAV8BlobWithoutSelectionsStillReachesTheLegacyArm() throws {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try v7Blob(manifests: [manifestJSON("alpha")])) as? [String: Any])
        root["schemaVersion"] = 8           // already migrated — migrateToV8 will not run
        root.removeValue(forKey: "skillSelections")

        let data = try JSONSerialization.data(withJSONObject: root)
        guard case .migrated(let out) = ProfileMigrator.migrateIfNeeded(data) else {
            return XCTFail("expected .migrated")
        }
        guard case .agent(let config) = try JSONDecoder().decode(ProfileDetails.self, from: out) else {
            return XCTFail("expected an agent config")
        }

        XCTAssertNil(config.skillSelections, "no selections — this is the legacy arm's live case")
        XCTAssertEqual(config.skillConfig?.manifests.map(\.name), ["alpha"],
                       "and the legacy copies are what resolution must fall back to")
    }

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

    /// Code mode reuses `AgentConfig` and has its OWN decode and encode arm. Both were touched;
    /// this is the test that fails if only one of them was.
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
        XCTAssertEqual(out.skillSelections?.map(\.name), ["alpha"],
                       "the .code arm has its own decode/encode — a cut-over that only touched .agent loses this")
        XCTAssertEqual(out.projectPath, "/Users/test/project")
    }

    /// ⚠️ CHANGED IN V6 — this asserted the identity was the PATH.
    ///
    /// A path is a statement about the world, and the world moves: rename a parent, relocate a repo,
    /// unmount a volume, open the store on another machine, and every link broke at once. An opaque
    /// `skill_…` describes nothing, so nothing can invalidate it.
    func testSelectionIdentityIsTheSkillID() {
        let selection = SkillSelection(skillID: "skill_abc", name: "code-review")
        XCTAssertEqual(selection.id, "skill_abc",
                       "identity must be the id — two skills can legitimately share a NAME")
        XCTAssertFalse(selection.isAwaitingRelink)
    }

    /// A pre-V6 selection still needs a stable identity for `ForEach`, and it must not be able to
    /// collide with a real id.
    func testAPreV6SelectionFallsBackToAPrefixedLegacyIdentity() {
        let selection = SkillSelection(skillID: nil, legacyFolderPath: "/a/b/code-review", name: "code-review")
        XCTAssertEqual(selection.id, "legacy:/a/b/code-review")
        XCTAssertTrue(selection.isAwaitingRelink)
        XCTAssertFalse(selection.id.hasPrefix("skill_"),
                       "a placeholder identity must be unmistakable for a real one")
    }

    /// ⚠️ Re-linking repairs an ADDRESS. Silently re-enabling a skill the user switched off, or
    /// dropping a pin they set, would make a repair look like a settings reset.
    func testRelinkingPreservesTheUsersOwnPreferences() {
        let pending = SkillSelection(skillID: nil, legacyFolderPath: "/a/b/x", name: "x",
                                     pinnedVersionID: "skver_pinned", isEnabled: false)
        let relinked = pending.relinked(to: "skill_real", name: "x-renamed")

        XCTAssertEqual(relinked.skillID, "skill_real")
        XCTAssertEqual(relinked.name, "x-renamed")
        XCTAssertEqual(relinked.pinnedVersionID, "skver_pinned")
        XCTAssertFalse(relinked.isEnabled)
        XCTAssertNil(relinked.legacyFolderPath, "once re-linked the legacy path has no further use")
    }
}

// MARK: - v8 → v9

/// The blob step that turns a folder-addressed selection into a library-addressed one.
///
/// ⚠️ It CANNOT resolve the id — `migrateIfNeeded` runs on the read path of every decode and must be
/// pure, so it has no store to consult. It only reshapes; the launch sweep re-links.
final class SkillSelectionV9MigrationTests: XCTestCase {

    private func migrate(_ json: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard case .migrated(let out) = ProfileMigrator.migrateIfNeeded(data) else {
            throw XCTSkip("expected a migrated outcome")
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    private func v8Blob(selections: [[String: Any]]) -> [String: Any] {
        ["schemaVersion": 8, "type": "agent", "skillSelections": selections]
    }

    func testFolderPathBecomesLegacyFolderPathAndTheIDIsLeftAbsent() throws {
        let out = try migrate(v8Blob(selections: [
            ["folderPath": "/skills/alpha", "name": "alpha", "isEnabled": true]
        ]))

        let selections = try XCTUnwrap(out["skillSelections"] as? [[String: Any]])
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections[0]["legacyFolderPath"] as? String, "/skills/alpha")
        XCTAssertEqual(selections[0]["name"] as? String, "alpha")
        XCTAssertNil(selections[0]["folderPath"], "the old key must not linger — two addresses is how they drift")
        XCTAssertNil(selections[0]["skillID"], "⚠️ a pure migration CANNOT know the id; inventing one would be worse than leaving it absent")
        XCTAssertEqual(out["schemaVersion"] as? Int, 9)
    }

    func testIsIdempotent() throws {
        let once = try migrate(v8Blob(selections: [["folderPath": "/skills/alpha", "name": "alpha", "isEnabled": true]]))
        let twice = try migrate(once)
        XCTAssertEqual(NSDictionary(dictionary: once), NSDictionary(dictionary: twice))
    }

    func testAnAlreadyLinkedSelectionIsLeftUntouched() throws {
        let out = try migrate([
            "schemaVersion": 9, "type": "agent",
            "skillSelections": [["skillID": "skill_abc", "name": "alpha", "isEnabled": true]]
        ])
        let selections = try XCTUnwrap(out["skillSelections"] as? [[String: Any]])
        XCTAssertEqual(selections[0]["skillID"] as? String, "skill_abc")
        XCTAssertNil(selections[0]["legacyFolderPath"])
    }

    /// ⚠️ An entry with no usable address is DROPPED, not carried. It could never resolve and could
    /// never be re-linked — a permanently unresolvable row in the UI is worse than one fewer link.
    func testAnAddresslessEntryIsDropped() throws {
        let out = try migrate(v8Blob(selections: [
            ["name": "no-address", "isEnabled": true],
            ["folderPath": "", "name": "empty-path"],
            ["folderPath": "/skills/good", "name": "good"]
        ]))
        let selections = try XCTUnwrap(out["skillSelections"] as? [[String: Any]])
        XCTAssertEqual(selections.map { $0["name"] as? String }, ["good"])
    }

    /// Total over malformed input: a stamped blob, never a throw.
    func testIsTotalOverMalformedInput() throws {
        let out = try migrate(["schemaVersion": 8, "type": "agent", "skillSelections": "not an array"])
        XCTAssertEqual(out["schemaVersion"] as? Int, 9)
    }

    func testAMissingNameFallsBackToTheFoldersLastComponent() throws {
        let out = try migrate(v8Blob(selections: [["folderPath": "/skills/derived-name"]]))
        let selections = try XCTUnwrap(out["skillSelections"] as? [[String: Any]])
        XCTAssertEqual(selections[0]["name"] as? String, "derived-name")
        XCTAssertEqual(selections[0]["isEnabled"] as? Bool, true)
    }
}
