// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SaveFailureSurfacingTests.swift
//  DevgenticTests
//
//  Batch 7 of the RAG readiness register:
//    RAG-27 (CR-69) — a failed save on the SHARED mainContext cannot be rolled back
//                     (`SharedContextCommitTests`), so every store saves through
//                     `SharedContextSave`, which latches the failure and tells the user app-wide
//                     until a save of that context succeeds again.
//    RAG-39         — `try?` no longer hides thrown lookups; titles are SAVED by the store instead
//                     of left pending on the shared context; per-send bookkeeping skips no-op saves.
//
//  Failures are real: `PoisonParentSD` (see `SharedContextCommitTests`) fails validation on every
//  save of the context it sits in — standing in for another subsystem's bad pending change.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class SaveFailureSurfacingTests: XCTestCase {

    private var container: ModelContainer?
    private let conversationID = UUID()

    override func setUp() async throws {
        SharedContextSave.resetForTesting()
    }

    override func tearDown() async throws {
        SharedContextSave.resetForTesting()
        container = nil
    }

    private func configureStore() throws -> (ChatPersistenceStore, ModelContext) {
        let made = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self,
            PoisonParentSD.self, PoisonChildSD.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        container = made
        let store = ChatPersistenceStore.shared
        store.configureContainer(made)
        store.addConversation(from: Conversation(id: conversationID, messages: [], timestamp: Date(),
                                                 userDefinedTitle: nil, isPinned: false, backendEntityId: nil))
        return (store, made.mainContext)
    }

    private var changesNotSavedBanner: Advisory? {
        let banner = AdvisoryCenter.shared.current(for: UUID())   // ANY conversation
        return banner?.category == .changesNotSaved ? banner : nil
    }

    // MARK: - RAG-27: the failure is surfaced, app-wide, and clears on recovery

    /// THE wiring: another subsystem's poison makes the CHAT store's save fail; the user is told in
    /// every conversation; when the cause goes away the next save carries the pending change out
    /// and the banner clears.
    func testAFailedChatSaveIsSurfacedAppWideAndClearsWhenSavingRecovers() throws {
        let (store, context) = try configureStore()
        let poison = PoisonParentSD(name: "another subsystem's bad change")
        context.insert(poison)

        store.togglePinStatus(for: conversationID)
        XCTAssertTrue(SharedContextSave.isFailing, "the chat store's failed save was not latched")
        let banner = try XCTUnwrap(changesNotSavedBanner, "the user was not told that changes are not being saved")
        XCTAssertTrue(banner.message.contains("Restart"), banner.message)
        XCTAssertEqual(AdvisoryCenter.shared.current(for: Advisory.allConversations)?.category, .changesNotSaved,
                       "the Home screen (no selection) must show it too")

        // The cause resolves (a transient failure); the next save — any store's — succeeds.
        poison.children.append(PoisonChildSD(n: 1))
        store.togglePinStatus(for: conversationID)
        XCTAssertFalse(SharedContextSave.isFailing)
        XCTAssertNil(changesNotSavedBanner, "the banner outlived the failure")

        let fresh = ModelContext(try XCTUnwrap(container))
        let id = conversationID
        let stored = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ConversationSD>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertFalse(stored.isPinned, "two toggles: the failed first one stayed pending and went out with the second")
    }

    func testAThrowawayContextFailureIsNeverLatched() throws {
        let (_, _) = try configureStore()
        let scratch = ModelContext(try XCTUnwrap(container))
        scratch.insert(PoisonParentSD(name: "poison"))
        XCTAssertThrowsError(try SharedContextSave.save(scratch, "test: throwaway", scope: .throwaway))
        XCTAssertFalse(SharedContextSave.isFailing, "a discarded context can never recover, so it must not latch the banner")
        XCTAssertNil(changesNotSavedBanner)
    }

    /// Dismissing one failure episode must not silence a later one. Driven through the store, as
    /// in production: a store write fetches before it saves, and only that shape recovers reliably
    /// once the cause is repaired (a bare save right after the repair keeps failing on this SDK).
    func testDismissingOneEpisodeDoesNotSilenceTheNext() throws {
        let (store, context) = try configureStore()
        let poison = PoisonParentSD(name: "poison")
        context.insert(poison)
        store.togglePinStatus(for: conversationID)
        AdvisoryCenter.shared.dismiss(try XCTUnwrap(changesNotSavedBanner))

        poison.children.append(PoisonChildSD(n: 1))
        store.togglePinStatus(for: conversationID)
        XCTAssertFalse(SharedContextSave.isFailing, "sanity: the first episode recovered")

        context.insert(PoisonParentSD(name: "poison again"))
        store.togglePinStatus(for: conversationID)
        XCTAssertNotNil(changesNotSavedBanner, "the earlier dismissal silenced a NEW failure")
    }

    func testAnAppWideAdvisoryShowsInEveryConversationButAConversationsOwnStillWins() {
        let center = AdvisoryCenter()
        let mine = UUID()
        center.post(Advisory(conversationID: Advisory.allConversations, category: .changesNotSaved, message: "global",
                             actionLabel: nil, action: nil, dedupeKey: "g"))
        XCTAssertEqual(center.current(for: mine)?.message, "global")
        XCTAssertEqual(center.current(for: UUID())?.message, "global")
        center.post(Advisory(conversationID: mine, category: .contextOverflow, message: "local",
                             actionLabel: nil, action: nil, dedupeKey: "l"))
        XCTAssertEqual(center.current(for: mine)?.message, "local", "latest posted wins at equal priority, as before")
    }

    // MARK: - RAG-39

    func testRenameAndAutoTitleAreSavedNotLeftPending() throws {
        let (store, context) = try configureStore()
        store.setTitleIfUntitled("first question", for: conversationID)
        XCTAssertFalse(context.hasChanges, "the auto-title was left pending on the shared context")
        store.setTitleIfUntitled("second question", for: conversationID)
        XCTAssertEqual(store.getConversation(withId: conversationID)?.userDefinedTitle, "first question",
                       "the auto-title overwrote an existing title")
        store.setTitle("  Renamed  ", for: conversationID)
        XCTAssertFalse(context.hasChanges, "the rename was left pending on the shared context")

        let fresh = ModelContext(try XCTUnwrap(container))
        let id = conversationID
        let stored = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ConversationSD>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(stored.userDefinedTitle, "Renamed", "trimmed rename on disk; the auto-title never overwrote a title")

        store.setTitle("   ", for: conversationID)
        XCTAssertNil(store.getConversation(withId: conversationID)?.userDefinedTitle, "a blank rename clears the title")
    }

    /// The per-send bookkeeping writes skip unchanged values — observable here because a skipped
    /// write never reaches a (poisoned) save.
    func testUnchangedPerSendBookkeepingDoesNotSave() throws {
        let (store, context) = try configureStore()
        let profile = UUID()
        store.updateBackendForConversation(id: conversationID, backendEntityId: profile)
        store.updateProfileType(for: conversationID, profileTypeRaw: "code")

        context.insert(PoisonParentSD(name: "poison"))
        store.updateBackendForConversation(id: conversationID, backendEntityId: profile)
        store.updateProfileType(for: conversationID, profileTypeRaw: "code")
        XCTAssertFalse(SharedContextSave.isFailing, "an unchanged value was saved anyway")
    }

    // MARK: - Invariants over the source

    /// ONE save path: no store saves a context except through `SharedContextSave`, or its failure
    /// goes unsurfaced and stays pending unseen.
    func testNoContextIsSavedOutsideSharedContextSave() throws {
        let offenders = try swiftSources().filter { path, text in
            !path.hasSuffix("SharedContextSave.swift")
                && text.range(of: #"([cC]ontext|scratch|ctx)\??\.save\(\)"#, options: .regularExpression) != nil
        }.map(\.path)
        XCTAssertEqual(offenders, [], "these save a ModelContext directly — use SharedContextSave.save")
    }

    /// No unsaved title writes: only the store (and the model's own inits) assign the title.
    func testTitlesAreOnlyWrittenByTheStore() throws {
        let allowed = ["ChatPersistenceStore.swift", "ConversationSD.swift", "ConversationModel.swift"]
        let offenders = try swiftSources().filter { path, text in
            !allowed.contains { path.hasSuffix($0) }
                && text.range(of: #"\.userDefinedTitle\s*=[^=]"#, options: .regularExpression) != nil
        }.map(\.path)
        XCTAssertEqual(offenders, [], "these set a conversation title without saving it — use setTitle / setTitleIfUntitled")
    }

    /// Both banners must show an APP-WIDE advisory with no conversation selected (Home), or "changes
    /// are not being saved" is invisible exactly where a user lands after a relaunch prompt.
    func testBannersFallBackToAppWideAdvisoriesWithNoSelection() throws {
        let banner = try XCTUnwrap(sourceFiles(named: "AdvisoryBannerView.swift").first)
        let quick = try XCTUnwrap(sourceFiles(named: "QuickAccessContentView.swift").first)
        XCTAssertTrue(try String(contentsOf: banner, encoding: .utf8)
            .contains("AdvisoryCenter.shared.current(for: vm.selectedConversationID ?? Advisory.allConversations)"))
        XCTAssertTrue(try String(contentsOf: quick, encoding: .utf8)
            .contains("AdvisoryCenter.shared.current(for: session.conversationID ?? Advisory.allConversations)"))
    }

    func testLookupsNoLongerSwallowThrownFetches() throws {
        let store = try sourceFiles(named: "ChatPersistenceStore.swift").first.map { try String(contentsOf: $0, encoding: .utf8) }
        let text = try XCTUnwrap(store)
        XCTAssertFalse(text.contains("try? context.fetch(descriptor).first"),
                       "a thrown lookup reads as 'not found' again (RAG-39)")
    }

    // MARK: - Source access

    private func appRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Devgentic")
        guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("app sources not reachable") }
        return root
    }

    private func sourceFiles(named name: String? = nil) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: try appRoot(), includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == "swift" && (name == nil || $0.lastPathComponent == name)
        }
    }

    /// Every app source file with its non-comment lines.
    private func swiftSources() throws -> [(path: String, text: String)] {
        try sourceFiles().map { url in
            let code = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return (url.path, code)
        }
    }
}
