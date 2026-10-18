// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteConversationOriginTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class RemoteConversationOriginTests: XCTestCase {

    // MARK: - Detection

    /// ⚠️ THE CF-39 PIN. "Discord Chat" is the literal `DiscordChatOpsBridge` passes to
    /// `createConversationForScheduledTask(profileID:title:)`; before the fix it fell through to
    /// the local hint because only Telegram's literal was tested.
    func testDiscordConversationsAreRecognisedAsRemote() {
        XCTAssertEqual(ChatHistoryView.remoteOrigin(forConversationTitle: "Discord Chat"), .discord)
    }

    /// Same defect, third bridge — `SlackChatOpsBridge` stamps "Slack Chat".
    func testSlackConversationsAreRecognisedAsRemote() {
        XCTAssertEqual(ChatHistoryView.remoteOrigin(forConversationTitle: "Slack Chat"), .slack)
    }

    func testTelegramStillWorks() {
        XCTAssertEqual(ChatHistoryView.remoteOrigin(forConversationTitle: "Telegram Chat"), .telegram)
    }

    /// The titles are duplicated from three bridges that share no constant, so they are pinned
    /// here as LITERALS — deriving them from `bridgeTitle` would pin nothing.
    func testBridgeTitlesAreTheStringsTheBridgesActuallyStamp() {
        XCTAssertEqual(ChatHistoryView.RemoteOrigin.telegram.bridgeTitle, "Telegram Chat")
        XCTAssertEqual(ChatHistoryView.RemoteOrigin.discord.bridgeTitle, "Discord Chat")
        XCTAssertEqual(ChatHistoryView.RemoteOrigin.slack.bridgeTitle, "Slack Chat")
        XCTAssertEqual(ChatHistoryView.RemoteOrigin.allCases.count, 3,
                       "A fourth ChatOps bridge needs a case here or its conversations read as local.")
    }

    /// A local conversation must never be dressed up as remote, and the match is deliberately
    /// exact: the bridges write these titles verbatim, so anything else is the user's own text.
    func testLocalAndUnknownTitlesAreNotRemote() {
        XCTAssertNil(ChatHistoryView.remoteOrigin(forConversationTitle: nil))
        XCTAssertNil(ChatHistoryView.remoteOrigin(forConversationTitle: ""))
        XCTAssertNil(ChatHistoryView.remoteOrigin(forConversationTitle: "Refactor the parser"))
        XCTAssertNil(ChatHistoryView.remoteOrigin(forConversationTitle: "telegram chat"))
        XCTAssertNil(ChatHistoryView.remoteOrigin(forConversationTitle: "Discord Chat (archive)"))
    }

    // MARK: - Copy

    /// The hint used to name Telegram whatever the source was.
    func testSubtitleNamesTheServiceItDetected() {
        let discord = ChatHistoryView.placeholderSubtitle(for: .discord)
        XCTAssertTrue(discord.contains("Discord"), discord)
        XCTAssertFalse(discord.contains("Telegram"), discord)

        let slack = ChatHistoryView.placeholderSubtitle(for: .slack)
        XCTAssertTrue(slack.contains("Slack"), slack)
        XCTAssertFalse(slack.contains("Telegram"), slack)
    }

    /// "reply from your phone" was wrong for Slack and merely presumptuous for the rest.
    func testSubtitleDoesNotAssumeAPhone() {
        for origin in ChatHistoryView.RemoteOrigin.allCases {
            let subtitle = ChatHistoryView.placeholderSubtitle(for: origin)
            XCTAssertFalse(subtitle.contains("phone"), "\(origin): \(subtitle)")
        }
    }

    func testLocalSubtitleNamesNoServiceAtAll() {
        let local = ChatHistoryView.placeholderSubtitle(for: nil)
        XCTAssertEqual(local, "Start the conversation by typing a message below.")
    }
}


// MARK: - CF-39 · the RECORDED origin, which survives a rename

/// The title heuristic answers "what is this conversation called", not "where did it come from",
/// so renaming a Telegram conversation dropped the hint and naming a local one "Discord Chat"
/// faked one. The bridges now record provenance at creation.
///
/// ⚠️ These write to `UserDefaults.standard` (the same store `NotificationConfiguration` uses for
/// its per-conversation overrides), so each test uses a fresh UUID and cleans up after itself
/// rather than assuming an empty store.
final class RecordedRemoteOriginTests: XCTestCase {

    private var ids: [UUID] = []

    private func freshID() -> UUID {
        let id = UUID()
        ids.append(id)
        return id
    }

    override func tearDown() {
        ids.forEach { RemoteConversationOriginStore.forget(conversationID: $0) }
        ids = []
        super.tearDown()
    }

    /// ⚠️ THE PIN. The whole point: a rename must not lose the origin.
    func testARecordedOriginSurvivesARename() {
        let id = freshID()
        RemoteConversationOriginStore.record(.telegram, for: id)

        // The user renames it to something with no bridge title in it at all.
        let resolved = ChatHistoryView.remoteOrigin(forConversationID: id, title: "Grocery list")

        XCTAssertEqual(resolved, .telegram, "the recording is authoritative; the title is not")
    }

    /// Each bridge's own service must come back — not Telegram for all three, the defect the
    /// original single-service check had.
    func testEachServiceRoundTripsAsItself() {
        for origin in RemoteConversationOrigin.allCases {
            let id = freshID()
            RemoteConversationOriginStore.record(origin, for: id)
            XCTAssertEqual(RemoteConversationOriginStore.origin(for: id), origin)
        }
    }

    /// A conversation created before origins were recorded still gets its hint from the title —
    /// dropping that fallback would silently degrade every existing remote conversation.
    func testAnUnrecordedConversationStillFallsBackToTheTitle() {
        let id = freshID()
        XCTAssertNil(RemoteConversationOriginStore.origin(for: id), "premise: nothing recorded")
        XCTAssertEqual(ChatHistoryView.remoteOrigin(forConversationID: id, title: "Slack Chat"), .slack)
    }

    /// And a local conversation with an ordinary title is still local.
    func testALocalConversationHasNoOrigin() {
        let id = freshID()
        XCTAssertNil(ChatHistoryView.remoteOrigin(forConversationID: id, title: "Grocery list"))
        XCTAssertNil(ChatHistoryView.remoteOrigin(forConversationID: nil, title: nil))
    }

    /// The recording outranks a CONFLICTING title — the case that proves precedence, not just
    /// that both paths happen to agree.
    func testTheRecordingOutranksAConflictingTitle() {
        let id = freshID()
        RemoteConversationOriginStore.record(.discord, for: id)
        XCTAssertEqual(ChatHistoryView.remoteOrigin(forConversationID: id, title: "Telegram Chat"), .discord,
                       "a recorded Discord conversation must not be relabelled by a Telegram-shaped title")
    }

    /// Deleting a conversation drops its row, so a recycled id cannot inherit a stale origin.
    func testForgettingRemovesTheRecording() {
        let id = freshID()
        RemoteConversationOriginStore.record(.slack, for: id)
        RemoteConversationOriginStore.forget(conversationID: id)
        XCTAssertNil(RemoteConversationOriginStore.origin(for: id))
    }
}
