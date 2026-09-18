// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileBlobDowngradeTests.swift
//  devgenticTests
//
//  Covers G18: an older build reading a profile blob written by a newer one.
//
//  `ProfileMigrator` is forward-only — its steps are shaped `if storedVersion < N`. A blob stamped
//  ABOVE the version this build knows matched no step, was passed through untouched, and was handed
//  to a decoder that could not read it. The decode failure then presented as "this profile is
//  corrupt", when the truth was "this profile is from the future" — two situations whose remedies
//  are opposite. Corrupt invites the user to reconfigure, which overwrites the blob and makes the
//  loss permanent. From-the-future needs them to change nothing and update the app.
//
//  ⚠️ The schema layer cannot help here. With a single declared schema version, an older build's
//  column layout matches, so the store opens without complaint — the difference lives entirely
//  inside an opaque `Data` column that SwiftData never inspects.
//

import XCTest
import SwiftData
@testable import devgentic

final class ProfileBlobDowngradeTests: XCTestCase {

    /// A well-formed profile blob stamped with an arbitrary version.
    private func blob(version: Int) throws -> Data {
        let json: [String: Any] = [
            "schemaVersion": version,
            "profileType": "Bot",
            "llmConfig": [
                "apiProvider": "Ollama (Local)",
                "modelName": "llama3",
            ],
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    // MARK: - The refusal

    func testABlobFromANewerBuildIsRefusedRatherThanDecoded() throws {
        let future = try blob(version: ProfileMigrator.currentVersion + 1)

        guard case .tooNew(let storedVersion) = ProfileMigrator.migrateIfNeeded(future) else {
            return XCTFail("A newer-versioned blob must be refused, not migrated")
        }
        XCTAssertEqual(storedVersion, ProfileMigrator.currentVersion + 1)
    }

    /// Being far ahead must behave the same as being one ahead — the old code's failure mode was
    /// that NO step matched, and that is equally true for +1 and +100.
    func testAnyFutureVersionIsRefused() throws {
        for ahead in [1, 2, 7, 100] {
            let future = try blob(version: ProfileMigrator.currentVersion + ahead)
            guard case .tooNew = ProfileMigrator.migrateIfNeeded(future) else {
                return XCTFail("+\(ahead) must be refused")
            }
        }
    }

    // MARK: - The forward path is untouched

    /// The whole point of the migrator. Every version at or below current must still migrate — a
    /// refusal here would break the ordinary upgrade path, which is the case that actually happens.
    func testEveryKnownVersionStillMigrates() throws {
        for version in 0...ProfileMigrator.currentVersion {
            let data = try blob(version: version)
            guard case .migrated = ProfileMigrator.migrateIfNeeded(data) else {
                return XCTFail("v\(version) must migrate, not be refused")
            }
        }
    }

    /// A blob with no version key at all is v0 legacy data, not future data.
    func testAnUnstampedBlobIsTreatedAsLegacyNotFuture() throws {
        let unstamped = try JSONSerialization.data(withJSONObject: [
            "profileType": "Bot",
            "llmConfig": ["apiProvider": "Ollama (Local)", "modelName": "llama3"],
        ])

        guard case .migrated = ProfileMigrator.migrateIfNeeded(unstamped) else {
            return XCTFail("An unstamped blob must migrate as v0")
        }
    }

    /// Bytes that are not a JSON object carry no version to judge, so they must reach the decoder
    /// and produce a real decoding error — not be misreported as "from the future".
    func testGarbageIsNotMistakenForAFutureVersion() {
        guard case .migrated = ProfileMigrator.migrateIfNeeded(Data("{ not json".utf8)) else {
            return XCTFail("Unparseable bytes must pass through to the decoder")
        }
    }

    // MARK: - The property that makes this a data-safety fix

    /// ⚠️ The reason the refusal is worth having: the bytes must survive it. A refusal that
    /// discarded the blob would be no better than the decode failure it replaced.
    func testRefusingDoesNotAlterTheStoredBytes() throws {
        let future = try blob(version: ProfileMigrator.currentVersion + 1)
        let before = future

        _ = ProfileMigrator.migrateIfNeeded(future)
        _ = ProfileMigrator.migrateIfNeeded(future)

        XCTAssertEqual(future, before)
    }

    /// ⚠️ This replaced an assertion on the literal `6`, which guarded the WRONG DIRECTION: it
    /// failed on a safe, correctly-paired bump and passed on the dangerous one where the writer and
    /// the refusal disagree. Pinning a number tests that nobody changed it, which is not the
    /// property anyone cares about.
    ///
    /// What matters is that the migration CHAIN is complete: every version below current must climb
    /// all the way to current. Add a `ProfileSchemaVersion` case without its `migrateToV<n>` step and
    /// a blob stops short of the top, this fails, and the gap is named — which is the real
    /// self-lockout risk, since the encoder would meanwhile be stamping the new number on every save.
    func testEveryOlderVersionMigratesAllTheWayToCurrent() throws {
        for version in 0..<ProfileMigrator.currentVersion {
            let data = try blob(version: version)

            guard case .migrated(let migrated) = ProfileMigrator.migrateIfNeeded(data) else {
                return XCTFail("v\(version) must migrate")
            }
            let stamped = (try JSONSerialization.jsonObject(with: migrated) as? [String: Any])?["schemaVersion"] as? Int

            XCTAssertEqual(
                stamped, ProfileMigrator.currentVersion,
                "v\(version) stopped at \(stamped.map(String.init) ?? "nil") — a migrateToV<n> step is missing"
            )
        }
    }

    /// The writer and the refusal must be the same number. They are now derived from one symbol, so
    /// this cannot fail — which is the point: it records WHY the derivation exists, so a future
    /// reader does not "simplify" `currentVersion` back into its own literal.
    func testTheStampedVersionAndTheRefusalCeilingAreTheSameNumber() {
        XCTAssertEqual(ProfileMigrator.currentVersion, ProfileSchemaVersion.current.rawValue)
    }

    // MARK: - The reason must reach the UI, not die in the log

    /// Persists a profile carrying `bytes`, then returns it re-materialized in a FRESH context.
    ///
    /// ⚠️ The fresh context is essential. `BackendProfile` caches the decoded value in a `@Transient`
    /// populated by `init`, so an instance built in-process never re-decodes and reports itself
    /// healthy no matter what you assign to `configData`. Only a fresh materialization — an app
    /// launch reading an existing store — exercises the path these tests are about.
    @MainActor
    private func reloadedProfile(withBlob bytes: Data) throws -> BackendProfile {
        let container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let seed = ModelContext(container)
        let profile = BackendProfile(
            displayName: "Seeded",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        seed.insert(profile)
        profile.configData = bytes
        try seed.save()

        let fresh = ModelContext(container)
        return try XCTUnwrap(try fresh.fetch(FetchDescriptor<BackendProfile>()).first)
    }

    /// ⚠️ The whole value of G18's refusal is that a from-the-future profile is presented
    /// DIFFERENTLY from a corrupt one. If the distinction stops at the log line, the user still sees
    /// "Discard and Reconfigure" for data that is perfectly intact — the exact action that destroys
    /// it. That is the storage-half-without-product-half failure this repo keeps hitting, so it gets
    /// a test rather than a comment.
    @MainActor
    func testAFutureBlobIsReportedAsFromANewerBuildNotAsCorrupt() throws {
        let future = ProfileMigrator.currentVersion + 1
        let model = try reloadedProfile(withBlob: try blob(version: future))

        XCTAssertTrue(model.hasUnreadableConfiguration)
        XCTAssertEqual(model.configurationUnreadableReason, .writtenByNewerBuild(storedVersion: future))
    }

    @MainActor
    func testDamagedBytesAreReportedAsUndecodableNotAsFromTheFuture() throws {
        let model = try reloadedProfile(withBlob: Data("{ not json at all".utf8))

        XCTAssertTrue(model.hasUnreadableConfiguration)
        XCTAssertEqual(model.configurationUnreadableReason, .undecodable)
    }

    /// A readable profile must report no reason at all — otherwise the banner fires for everyone and
    /// the signal is worthless.
    @MainActor
    func testAReadableProfileReportsNoReason() throws {
        let model = try reloadedProfile(withBlob: try blob(version: ProfileMigrator.currentVersion))

        XCTAssertFalse(model.hasUnreadableConfiguration)
        XCTAssertNil(model.configurationUnreadableReason)
    }

    /// The refusal is only worth something if the bytes are still there for the newer build to read.
    @MainActor
    func testAnOpportunisticSaveCannotOverwriteAFutureBlob() throws {
        let original = try blob(version: ProfileMigrator.currentVersion + 1)
        let model = try reloadedProfile(withBlob: original)

        // Exactly what ToolLibraryContainerView / MLXContextWindowHealer do: read, then write back.
        let readBack = model.details
        model.details = readBack

        XCTAssertEqual(model.configData, original, "the newer build's configuration must survive")
    }
}
