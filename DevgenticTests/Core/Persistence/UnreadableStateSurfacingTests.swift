// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UnreadableStateSurfacingTests.swift
//  DevgenticTests
//
//  Created on 05/08/26.
//
//  Guards the PRODUCT half of the blob-decode guards (SWIFTDATA_GAP_REGISTER.md G12/G77).
//
//  The storage half — refuse to overwrite bytes we could not read — shipped 2026-08-04 and is
//  covered by BlobWriteRefusalTests. But every accessor it added had ZERO non-test consumers, so the
//  user saw nothing: a corrupted Agent rendered as a blank Bot, an unreadable canvas rendered as the
//  new-workflow invitation, and a dead search index answered questions with no indication it was
//  down. The blank UI then invited the one edit that destroys the preserved bytes.
//
//  These tests pin the QUERIES the UI binds to. The SwiftUI wiring itself is not unit-testable here;
//  what is testable — and what actually broke — is whether the signal can reach a view at all.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class UnreadableStateSurfacingTests: XCTestCase {

    /// A blob shape no build can decode into `ProfileDetails`.
    private static let unreadable = Data(#"{"kind":"agent","payloadFromTheFuture":true}"#.utf8)

    private func makeStore() throws -> ModelContainer {
        let container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BackendProfileStore.shared.configureContainer(container)
        return container
    }

    /// Seeds a profile that decodes cleanly, then corrupts its blob — returning the container so the
    /// caller can re-materialize. ⚠️ A fresh fetch is essential: `BackendProfile` caches the decoded
    /// value in a `@Transient` set by `init`, so the seeding instance never re-decodes.
    @discardableResult
    private func seedCorruptedAgent(in container: ModelContainer, name: String = "Code Reviewer") throws -> UUID {
        let context = container.mainContext
        let profile = BackendProfile(
            displayName: name,
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-sonnet-4")
            ))
        )
        context.insert(profile)
        try context.save()
        profile.configData = Self.unreadable
        try context.save()
        return profile.id
    }

    // MARK: - The signal must reach the UI layer at all

    /// ⚠️ THE core finding. `hasUnreadableConfiguration` lives on the `@Model`, but the entire UI
    /// binds to `BackendProfileSnapshot` (`typealias BackendProfileModel = BackendProfileSnapshot`),
    /// and `snapshot()` does not copy the flag. It was architecturally unreachable, not merely
    /// unused. This store-level query is the bridge.
    func testUnreadableProfileIsReportedToTheUILayer() throws {
        let container = try makeStore()
        let id = try seedCorruptedAgent(in: container)

        let unreadable = BackendProfileStore.shared.unreadableProfiles()

        XCTAssertEqual(unreadable.count, 1, "The UI has no other way to learn this profile is broken.")
        XCTAssertEqual(unreadable.first?.id, id)
        XCTAssertTrue(BackendProfileStore.shared.isConfigurationUnreadable(for: id))
    }

    /// ⚠️ The mislabelling that makes this worse than a missing indicator.
    /// `BackendProfileSnapshot.profileType` derives from `details`, and a failed decode yields a
    /// `.bot` placeholder — so a corrupted AGENT reports as a BOT everywhere: Bot icon, the literal
    /// word "Bot", routed to `BotConfigDetailView` where tools/capabilities/skills are not rendered
    /// at all. The surviving COLUMNS still know the truth, which is what the warning shows.
    func testSurvivingColumnsStillKnowWhatTheProfileWas() throws {
        let container = try makeStore()
        let id = try seedCorruptedAgent(in: container)

        let info = try XCTUnwrap(BackendProfileStore.shared.unreadableProfiles().first)
        XCTAssertEqual(info.storedType, .agent, "The row still says Agent even though details says Bot.")
        // ⚠️ ApiProvider raw values are DISPLAY strings ("Anthropic", "Ollama (Local)"), which is why
        // wasSummary reads well without extra mapping.
        XCTAssertEqual(info.storedProvider, "Anthropic")
        XCTAssertEqual(info.storedModel, "claude-sonnet-4")
        XCTAssertEqual(info.displayName, "Code Reviewer")
        XCTAssertTrue(info.wasSummary.contains("Agent"))
        XCTAssertTrue(info.wasSummary.contains("claude-sonnet-4"))

        // And confirm the mislabelling this defends against is real.
        let snapshot = try XCTUnwrap(try BackendProfileStore.shared.fetchProfile(byId: id))
        XCTAssertEqual(snapshot.profileType, .bot,
                       "If this ever stops being .bot the placeholder changed — revisit the warning copy.")
    }

    /// A healthy profile must produce NO signal. The banner has to be silent when nothing is wrong,
    /// or it becomes noise the user learns to ignore.
    func testHealthyProfilesAreNotReported() throws {
        let container = try makeStore()
        let context = container.mainContext
        context.insert(BackendProfile(
            displayName: "Fine",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        ))
        try context.save()

        XCTAssertTrue(BackendProfileStore.shared.unreadableProfiles().isEmpty)
    }

    // MARK: - The explicit escape hatch

    /// Discarding must rebuild as the type the ROW claims, not the `.bot` placeholder — otherwise
    /// "reconfigure" silently demotes the user's Agent to a Bot, which is the very mislabelling this
    /// whole change exists to stop.
    func testDiscardRebuildsAsTheStoredTypeNotThePlaceholderType() throws {
        let container = try makeStore()
        let id = try seedCorruptedAgent(in: container)

        let didDiscard = BackendProfileStore.shared.discardUnreadableConfiguration(for: id, reason: "unit test")
        XCTAssertTrue(didDiscard)

        XCTAssertFalse(BackendProfileStore.shared.isConfigurationUnreadable(for: id),
                       "The flag must clear so the profile is editable again.")
        let snapshot = try XCTUnwrap(try BackendProfileStore.shared.fetchProfile(byId: id))
        XCTAssertEqual(snapshot.profileType, .agent,
                       "Reconfiguring an Agent must produce an Agent, not the Bot placeholder.")
        if case .agent(let config) = snapshot.details {
            XCTAssertEqual(config.llmConfig.apiProvider, .anthropic, "The surviving provider is carried over.")
            XCTAssertEqual(config.llmConfig.modelName, "claude-sonnet-4")
        } else {
            XCTFail("Expected .agent, got \(snapshot.details)")
        }
    }

    /// Discarding a profile that is NOT broken must be a no-op — it is a destructive verb, and it
    /// must not be usable as a general-purpose reset.
    func testDiscardIsANoOpOnAHealthyProfile() throws {
        let container = try makeStore()
        let context = container.mainContext
        let profile = BackendProfile(
            displayName: "Fine",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        context.insert(profile)
        try context.save()

        XCTAssertFalse(
            BackendProfileStore.shared.discardUnreadableConfiguration(for: profile.id, reason: "unit test")
        )
        if case .bot(let config) = profile.details {
            XCTAssertEqual(config.llmConfig.modelName, "llama3", "A healthy profile must be untouched.")
        } else {
            XCTFail("Expected .bot")
        }
    }

    // MARK: - The canvas counts the overlay quotes

    /// The overlay says "it last held 5 nodes, 6 connections". Those counts live OUTSIDE the blob and
    /// were written by the last SUCCESSFUL save, which is exactly why they survive a decode failure
    /// and can be quoted with confidence.
    func testStoredCountsSurviveAnUnreadableLayout() throws {
        let container = try ModelContainer(
            for: WorkflowLayoutSD.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        WorkflowLayoutStore.shared.configureContainer(container)

        let profileID = UUID()
        let context = container.mainContext
        let row = WorkflowLayoutSD(
            workflowProfileID: profileID,
            layout: WorkflowLayout(
                nodes: [], edges: [],
                annotations: (0..<3).map { StickyNote(position: .zero, text: "note \($0)") }
            )
        )
        context.insert(row)
        try context.save()
        row.layoutData = Self.unreadable
        try context.save()

        let counts = WorkflowLayoutStore.shared.storedCounts(for: profileID)
        XCTAssertEqual(counts.annotations, 3, "The counts must survive so the overlay can be specific.")
    }

    /// No row → zeroes, not a crash. The overlay falls back to its non-specific copy.
    func testStoredCountsForAMissingRowAreZero() throws {
        let container = try ModelContainer(
            for: WorkflowLayoutSD.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        WorkflowLayoutStore.shared.configureContainer(container)
        let counts = WorkflowLayoutStore.shared.storedCounts(for: UUID())
        XCTAssertEqual(counts.nodes, 0)
        XCTAssertEqual(counts.edges, 0)
        XCTAssertEqual(counts.annotations, 0)
    }
}
