// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteSessionStoreTests.swift
//  DevgenticTests
//
//  C4 of the ChatOps remote-interface plan: the conversation cursor, collected into one store.
//
//  ⚠️ C4 IS THE FIRST COMMIT THAT TOUCHES A LIVE CODE PATH. C0–C3 added dormant code; this one
//  rewrites three properties that 30 call sites already read. So the tests that matter are not
//  about the new API's ergonomics — they are about an installed user's cursor surviving the change.
//
//  ⚠️ EVERY TEST USES AN INJECTED `UserDefaults` SUITE. Reading or writing `.standard` here would
//  mean a test run could move the developer's own ChatOps cursor, and a crash mid-test would leave
//  it moved.
//

import XCTest
@testable import devgentic

@MainActor
final class RemoteSessionStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: RemoteSessionStore!

    override func setUp() {
        super.setUp()
        suiteName = "RemoteSessionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = RemoteSessionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - The compatibility contract

    /// ⚠️ THE TEST THIS COMMIT EXISTS FOR. The store reads and writes the SAME keys the three
    /// properties used before, which is why C4 needs no data migration. Change one of these strings
    /// and every existing user's cursor silently disappears: their next `/status` reports no active
    /// conversation, and `/new` creates a duplicate instead of reusing the one they were in.
    ///
    /// Mutation that must turn this red: alter any key returned by `defaultsKey(for:)`.
    func testTheStoreUsesExactlyTheKeysTheShippedPropertiesAlreadyUse() {
        XCTAssertEqual(RemoteSessionStore.defaultsKey(for: .telegram), AppSettings.chatOpsActiveConversationIDKey)
        XCTAssertEqual(RemoteSessionStore.defaultsKey(for: .discord), AppSettings.chatOpsDiscordActiveConversationIDKey)
        XCTAssertEqual(RemoteSessionStore.defaultsKey(for: .slack), AppSettings.chatOpsSlackActiveConversationIDKey)

        // Pinned as literals too: the AppSettings constants are themselves the shipped strings, and
        // asserting only that two symbols agree would stay green if BOTH were renamed together.
        XCTAssertEqual(RemoteSessionStore.defaultsKey(for: .telegram), "chatOpsActiveConversationID")
        XCTAssertEqual(RemoteSessionStore.defaultsKey(for: .discord), "chatOpsDiscordActiveConversationID")
        XCTAssertEqual(RemoteSessionStore.defaultsKey(for: .slack), "chatOpsSlackActiveConversationID")
    }

    /// An installed user's cursor was written by the OLD property body, straight into the raw key.
    /// The new store must read it without any migration step.
    func testACursorWrittenByThePreviousBuildIsReadWithoutMigration() {
        let existing = UUID()
        defaults.set(existing.uuidString, forKey: "chatOpsActiveConversationID")

        XCTAssertEqual(store.activeConversation(for: .telegram), existing, """
            A cursor written by the shipped build is unreadable. That is a silent data loss on \
            upgrade, not a test failure about API shape.
            """)
    }

    // MARK: - Cursor behaviour

    func testACursorRoundTripsAndCanBeCleared() {
        let conversation = UUID()
        XCTAssertNil(store.activeConversation(for: .telegram), "a fresh store points nowhere")

        store.setActiveConversation(conversation, for: .telegram)
        XCTAssertEqual(store.activeConversation(for: .telegram), conversation)

        store.setActiveConversation(nil, for: .telegram)
        XCTAssertNil(store.activeConversation(for: .telegram), "nil is how `reset()` clears the cursor on disconnect")
    }

    /// Mutation that must turn this red: make `defaultsKey(for:)` return one key for every provider.
    func testEachProviderKeepsItsOwnCursor() {
        let telegram = UUID(), discord = UUID(), slack = UUID()
        store.setActiveConversation(telegram, for: .telegram)
        store.setActiveConversation(discord, for: .discord)
        store.setActiveConversation(slack, for: .slack)

        XCTAssertEqual(store.activeConversation(for: .telegram), telegram)
        XCTAssertEqual(store.activeConversation(for: .discord), discord)
        XCTAssertEqual(store.activeConversation(for: .slack), slack)

        // Clearing one must not disturb the others — `resetDiscord()` runs on a Discord disconnect
        // while Telegram may still be connected and mid-conversation.
        store.setActiveConversation(nil, for: .discord)
        XCTAssertEqual(store.activeConversation(for: .telegram), telegram)
        XCTAssertNil(store.activeConversation(for: .discord))
        XCTAssertEqual(store.activeConversation(for: .slack), slack)
    }

    /// Matches the previous property bodies, which used `UUID(uuidString:)` and returned nil on
    /// failure. A corrupt value must read as "no cursor", never crash.
    func testAnUnparseableStoredValueReadsAsNoCursor() {
        defaults.set("not-a-uuid", forKey: "chatOpsActiveConversationID")
        XCTAssertNil(store.activeConversation(for: .telegram))
    }

    func testEveryProviderHasAKey() {
        let keys = RemoteChannel.Provider.allCases.map(RemoteSessionStore.defaultsKey(for:))
        XCTAssertEqual(Set(keys).count, RemoteChannel.Provider.allCases.count, "two providers share a key: \(keys)")
    }

    // MARK: - One storage

    /// ⚠️ THE "ONE STORAGE" INVARIANT, AND THE ONLY WAY TO CHECK IT. The three cursor properties on
    /// `ChatOpsConfigManager` must DELEGATE, not re-open `UserDefaults` beside the store. A second
    /// reader is exactly the two-source window this commit exists to close, and it would be
    /// invisible at runtime because both paths read the same key — until one of them is changed.
    ///
    /// Cannot be a behavioural test: the properties reach `RemoteSessionStore.shared`, which is
    /// bound to `.standard`, and no test may write there.
    ///
    /// Mutation that must turn this red: restore any inline
    /// `UserDefaults.standard.string(forKey: AppSettings.chatOps…)` in a cursor property.
    func testTheCursorPropertiesDelegateAndDoNotOpenUserDefaultsThemselves() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Models/ChatOpsConfig.swift")

        for property in ["var activeConversationID", "var discordActiveConversationID", "var slackActiveConversationID"] {
            guard let start = source.range(of: property) else {
                return XCTFail("\(property) is gone from ChatOpsConfigManager")
            }
            // Joined body, not lines: getter and setter are several statements apart.
            let body = String(source[start.upperBound...].prefix(500))

            XCTAssertTrue(body.contains("RemoteSessionStore.shared"), """
                \(property) no longer delegates to RemoteSessionStore.
                """)
            XCTAssertFalse(body.contains("UserDefaults"), """
                \(property) reads or writes UserDefaults directly again. That reintroduces a second \
                storage path beside RemoteSessionStore — invisible at runtime because both read the \
                same key, until one is changed and the two disagree.
                """)
        }
    }

    /// The observation wrappers must survive the rewrite. Nothing observes these three today, but a
    /// settings row showing the bound conversation would, and losing `withMutation` makes such a
    /// row silently stale rather than obviously broken.
    func testTheCursorPropertiesStillParticipateInObservation() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Models/ChatOpsConfig.swift")
        for property in ["activeConversationID", "discordActiveConversationID", "slackActiveConversationID"] {
            XCTAssertTrue(source.contains("access(keyPath: \\.\(property))"), "\(property) lost its access(keyPath:)")
            XCTAssertTrue(source.contains("withMutation(keyPath: \\.\(property))"), "\(property) lost its withMutation(keyPath:)")
        }
    }

    // MARK: - Helpers

    private static func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/DevgenticTests/ChatOps/Services/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) not reachable from \(repoRoot.path) — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
