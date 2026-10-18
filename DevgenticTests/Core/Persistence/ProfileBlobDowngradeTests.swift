// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileBlobDowngradeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
        let future = try blob(version: ProfileBlobGate.currentVersion + 1)

        guard case .tooNew(let storedVersion) = ProfileBlobGate.check(future) else {
            return XCTFail("A newer-versioned blob must be refused, not decoded")
        }
        XCTAssertEqual(storedVersion, ProfileBlobGate.currentVersion + 1)
    }

    /// Being far ahead must behave the same as being one ahead — the old code's failure mode was
    /// that NO step matched, and that is equally true for +1 and +100.
    func testAnyFutureVersionIsRefused() throws {
        for ahead in [1, 2, 7, 100] {
            let future = try blob(version: ProfileBlobGate.currentVersion + ahead)
            guard case .tooNew = ProfileBlobGate.check(future) else {
                return XCTFail("+\(ahead) must be refused")
            }
        }
    }

    // MARK: - Older blobs are refused too (2026-10-03 history reset)

    /// Nothing upgrades a pre-reset blob any more, so it must be REFUSED — never handed to a decoder
    /// that might partially succeed and quietly drop settings.
    func testAnOlderVersionIsRefusedAsUnsupported() throws {
        for version in 0..<ProfileBlobGate.currentVersion {
            guard case .unsupported(let stored) = ProfileBlobGate.check(try blob(version: version)) else {
                return XCTFail("v\(version) must be refused, not decoded")
            }
            XCTAssertEqual(stored, version)
        }
    }

    /// A blob with no version key at all predates versioning — refused, not mistaken for current.
    func testAnUnstampedBlobIsRefusedAsUnsupported() throws {
        let unstamped = try JSONSerialization.data(withJSONObject: [
            "profileType": "Bot",
            "llmConfig": ["apiProvider": "Ollama (Local)", "modelName": "llama3"],
        ])
        guard case .unsupported(0) = ProfileBlobGate.check(unstamped) else {
            return XCTFail("An unstamped blob must be refused as version 0")
        }
    }

    func testTheCurrentVersionIsDecodable() throws {
        guard case .decodable = ProfileBlobGate.check(try blob(version: ProfileBlobGate.currentVersion)) else {
            return XCTFail("the current version must reach the decoder")
        }
    }

    /// Bytes that are not a JSON object carry no version to judge, so they must reach the decoder
    /// and produce a real decoding error — not be misreported as "from the future".
    func testGarbageIsNotMistakenForAFutureVersion() {
        guard case .decodable = ProfileBlobGate.check(Data("{ not json".utf8)) else {
            return XCTFail("Unparseable bytes must pass through to the decoder")
        }
    }

    // MARK: - The property that makes this a data-safety fix

    /// ⚠️ The reason the refusal is worth having: the bytes must survive it. A refusal that
    /// discarded the blob would be no better than the decode failure it replaced.
    func testRefusingDoesNotAlterTheStoredBytes() throws {
        let future = try blob(version: ProfileBlobGate.currentVersion + 1)
        let before = future

        _ = ProfileBlobGate.check(future)
        _ = ProfileBlobGate.check(future)

        XCTAssertEqual(future, before)
    }

    /// The writer and the refusal must be the same number. They are now derived from one symbol, so
    /// this cannot fail — which is the point: it records WHY the derivation exists, so a future
    /// reader does not "simplify" `currentVersion` back into its own literal.
    func testTheStampedVersionAndTheRefusalCeilingAreTheSameNumber() {
        XCTAssertEqual(ProfileBlobGate.currentVersion, ProfileSchemaVersion.current.rawValue)
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
        let future = ProfileBlobGate.currentVersion + 1
        let model = try reloadedProfile(withBlob: try blob(version: future))

        XCTAssertTrue(model.hasUnreadableConfiguration)
        XCTAssertEqual(model.configurationUnreadableReason, .writtenByNewerBuild(storedVersion: future))
    }

    @MainActor
    func testAPreResetBlobIsReportedUnreadableAndKeptIntact() throws {
        let old = try blob(version: 0)
        let model = try reloadedProfile(withBlob: old)

        XCTAssertTrue(model.hasUnreadableConfiguration)
        XCTAssertEqual(model.configurationUnreadableReason, .undecodable)
        let readBack = model.details
        model.details = readBack
        XCTAssertEqual(model.configData, old, "an opportunistic save must not overwrite the refused bytes")
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
        let model = try reloadedProfile(withBlob: try blob(version: ProfileBlobGate.currentVersion))

        XCTAssertFalse(model.hasUnreadableConfiguration)
        XCTAssertNil(model.configurationUnreadableReason)
    }

    /// The refusal is only worth something if the bytes are still there for the newer build to read.
    @MainActor
    func testAnOpportunisticSaveCannotOverwriteAFutureBlob() throws {
        let original = try blob(version: ProfileBlobGate.currentVersion + 1)
        let model = try reloadedProfile(withBlob: original)

        // Exactly what ToolLibraryContainerView / MLXContextWindowHealer do: read, then write back.
        let readBack = model.details
        model.details = readBack

        XCTAssertEqual(model.configData, original, "the newer build's configuration must survive")
    }
}
