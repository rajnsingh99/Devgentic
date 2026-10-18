// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsNotificationChannelTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ChatOpsNotificationChannelTests: XCTestCase {

    @MainActor
    private final class FakeAnnouncer: RemoteAnnouncing {
        let provider: RemoteChannel.Provider
        var canAnnounce = true
        var mirroring: Set<UUID> = []
        private(set) var announced: [RemoteView] = []
        /// Whether this provider's post succeeds. ⚠️ A fake that always reports success cannot see
        /// the case the channel now has to get right: every target failing is NOT a delivery.
        var announceSucceeds = true

        init(_ provider: RemoteChannel.Provider) { self.provider = provider }

        func isMirroring(_ conversationID: UUID?) -> Bool {
            guard let conversationID else { return false }
            return mirroring.contains(conversationID)
        }
        func announce(_ view: RemoteView) async -> Bool {
            announced.append(view)
            return announceSucceeds
        }
    }

    /// ⚠️ `isEnabled` is backed by real `UserDefaults`, so every test saves and restores it rather
    /// than leaving the developer's own setting flipped.
    private func withChannelEnabled(
        _ announcers: [FakeAnnouncer],
        _ body: (ChatOpsNotificationChannel) async throws -> Void
    ) async rethrows {
        let channel = ChatOpsNotificationChannel(announcers: { announcers })
        let previous = UserDefaults.standard.bool(forKey: AppSettings.chatOpsNotificationsEnabledKey)
        channel.isEnabled = true
        defer { UserDefaults.standard.set(previous, forKey: AppSettings.chatOpsNotificationsEnabledKey) }
        try await body(channel)
    }

    private func payload(_ title: String, conversation: UUID? = nil) -> AppNotificationPayload {
        AppNotificationPayload(title: title, body: "\(title) body", conversationID: conversation)
    }

    // MARK: - Off by default

    /// ⚠️ THE DEFAULT IS THE PRODUCT DECISION. Enabling this publishes local, private notifications
    /// to a third-party service — a user should choose that knowingly, not discover it when their
    /// model-download history turns up in a shared Slack channel.
    ///
    /// Mutation that must turn this red: default `isEnabled` to true.
    @MainActor
    func testTheChannelIsOffUntilTheUserTurnsItOn() {
        let previous = UserDefaults.standard.object(forKey: AppSettings.chatOpsNotificationsEnabledKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.chatOpsNotificationsEnabledKey)
        defer { UserDefaults.standard.set(previous, forKey: AppSettings.chatOpsNotificationsEnabledKey) }

        let channel = ChatOpsNotificationChannel(announcers: { [] })
        XCTAssertFalse(channel.isEnabled, "notifications must not start flowing to a chat service unasked")
        XCTAssertTrue(channel.requiresConfiguration, "it cannot deliver anything until a channel is paired")
    }

    // MARK: - The double-post guard

    /// ⚠️ THE RULE THIS CHANNEL EXISTS TO GET RIGHT. A run started from Telegram already gets its
    /// answer from `RemoteMirrorService`; announcing "Query Completed" beside it says the same thing
    /// twice. The channel asks each provider whether it is already mirroring that conversation.
    ///
    /// Mutation that must turn this red: drop the `isMirroring` filter.
    @MainActor
    func testAConversationTheMirrorIsAlreadyStreamingIsNotAnnouncedAgain() async throws {
        let conversation = UUID()
        let telegram = FakeAnnouncer(.telegram)
        let slack = FakeAnnouncer(.slack)
        telegram.mirroring = [conversation]   // the run came from Telegram

        try await withChannelEnabled([telegram, slack]) { channel in
            try await channel.send(payload("Query Completed", conversation: conversation))
        }

        XCTAssertTrue(telegram.announced.isEmpty, "the mirror is already reporting this conversation to Telegram")
        XCTAssertEqual(slack.announced.count, 1, "Slack is not mirroring it, so Slack should still hear about it")
    }

    /// ⚠️ A notification with NO conversation — a finished model download, say — belongs to no
    /// conversation and can never be a duplicate. Treating nil as "mirrored" would silence the
    /// entire class.
    @MainActor
    func testAnAppWideNotificationIsNeverTreatedAsADuplicate() async throws {
        let telegram = FakeAnnouncer(.telegram)
        telegram.mirroring = [UUID()]

        try await withChannelEnabled([telegram]) { channel in
            try await channel.send(payload("Model ready"))
        }
        XCTAssertEqual(telegram.announced.count, 1)
    }

    /// The scheduled-task case: no remote session exists, so the mirror never sees it. This is the
    /// notification a remote user could not previously get at all.
    @MainActor
    func testAScheduledRunReachesEveryConnectedProvider() async throws {
        let telegram = FakeAnnouncer(.telegram), discord = FakeAnnouncer(.discord)

        try await withChannelEnabled([telegram, discord]) { channel in
            try await channel.send(payload("Scheduled Task Completed", conversation: UUID()))
        }
        XCTAssertEqual(telegram.announced.count, 1)
        XCTAssertEqual(discord.announced.count, 1)
    }

    // MARK: - Connectivity

    /// A stopped or unpaired bridge must announce nothing — otherwise a notification is addressed to
    /// a channel the user has disconnected.
    @MainActor
    func testADisconnectedProviderIsSkipped() async throws {
        let connected = FakeAnnouncer(.telegram)
        let disconnected = FakeAnnouncer(.slack)
        disconnected.canAnnounce = false

        try await withChannelEnabled([connected, disconnected]) { channel in
            try await channel.send(payload("Query Completed"))
        }
        XCTAssertEqual(connected.announced.count, 1)
        XCTAssertTrue(disconnected.announced.isEmpty)
    }

    // MARK: - What gets rendered

    /// ⚠️ `.info`, never `.failure`, even for "Query Failed": tone's only reader is
    /// `RemoteRenderLog.posted`, which logs a failure notice at `.error`. A failed query is the app
    /// reporting normally, not the render path going wrong.
    ///
    /// Mutation that must turn this red: infer the tone from the title.
    func testAFailureNotificationIsStillTonedAsInformation() throws {
        guard case .notice(let notice) = ChatOpsNotificationChannel.view(for:
            AppNotificationPayload(title: "Query Failed", body: "it did not work")) else {
            return XCTFail("expected a notice")
        }
        XCTAssertEqual(notice.tone, .info, "a failure notice would write an .error log line per notification")
        XCTAssertEqual(notice.icon, "🔔")
        XCTAssertEqual(notice.title, "Query Failed")
        XCTAssertEqual(notice.body, "it did not work")
    }

    /// End to end through the real renderer, so the wire text is pinned rather than assumed.
    func testANotificationRendersAsATitledMessage() throws {
        let view = ChatOpsNotificationChannel.view(for:
            AppNotificationPayload(title: "Scheduled Task Completed", body: "Morning briefing: 3 items"))
        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: view))
        XCTAssertEqual(draft.text, """
        🔔 *Scheduled Task Completed*
        Morning briefing: 3 items
        """)
        XCTAssertEqual(draft.parse_mode, "Markdown")
    }

    /// ⚠️ A notification body is app-authored but can carry user content — a scheduled task's name
    /// and its run summary both reach it. It goes through the notice path, so it is escaped.
    func testANotificationBodyCannotBreakTelegramsParser() throws {
        let view = ChatOpsNotificationChannel.view(for:
            AppNotificationPayload(title: "Scheduled Task Completed", body: "fix *bold in the summary"))
        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: view))
        XCTAssertTrue(draft.text.contains(#"fix \*bold"#), "got: \(draft.text)")
    }

    // MARK: - Registration

    /// The dispatcher already fans out to every registered channel, so registering is the whole
    /// integration — the four existing dispatch sites need no change.
    @MainActor
    func testTheChannelIdentifiesItselfForTheSettingsList() {
        let channel = ChatOpsNotificationChannel(announcers: { [] })
        XCTAssertEqual(channel.channelID, "chatops")
        XCTAssertFalse(channel.displayName.isEmpty)
    }

    // MARK: - Honest delivery reporting

    /// ⚠️⚠️ THE SETTINGS "TEST" BUTTON USED TO LIE. `NotificationService.dispatch` does
    /// `delivered += 1` for any channel whose `send` does not throw, and this channel's send left
    /// through a bare `return` when it had nobody to post to — so with the channel switched on and
    /// no provider connected, the test button reported success and nothing had been posted anywhere.
    ///
    /// Mutation that must turn this red: replace the throw with `return`.
    @MainActor
    func testNoPairedProviderIsReportedAsAFailureAndNotAsADelivery() async {
        let offline = FakeAnnouncer(.telegram)
        offline.canAnnounce = false

        await withChannelEnabled([offline]) { channel in
            do {
                try await channel.send(self.payload("Query Completed"))
                XCTFail("an undelivered notification must not report success — dispatch counts it")
            } catch {
                XCTAssertTrue(error is ChatOpsAnnounceError)
            }
        }
    }

    /// ⚠️ EVERY TARGET FAILING IS NOT A DELIVERY EITHER. The announce path logs its own failure, but
    /// logging is not reporting: without a throw the dispatcher still counted the send.
    ///
    /// Mutation that must turn this red: drop the `delivered > 0` guard.
    @MainActor
    func testEveryProviderFailingIsReportedAsAFailure() async {
        let broken = FakeAnnouncer(.discord)
        broken.announceSucceeds = false

        await withChannelEnabled([broken]) { channel in
            do {
                try await channel.send(self.payload("Download Finished"))
                XCTFail("nothing reached a remote channel, so this must not count as delivered")
            } catch {
                XCTAssertTrue(error is ChatOpsAnnounceError)
            }
        }
    }

    /// ⚠️ A PARTIAL FAILURE IS STILL A DELIVERY. Throwing here would make the dispatcher report a
    /// notification the user really did receive as lost.
    @MainActor
    func testOneProviderSucceedingIsEnough() async throws {
        let broken = FakeAnnouncer(.discord)
        broken.announceSucceeds = false
        let working = FakeAnnouncer(.slack)

        try await withChannelEnabled([broken, working]) { channel in
            try await channel.send(self.payload("Query Completed"))
            XCTAssertEqual(working.announced.count, 1)
        }
    }

    /// ⚠️⚠️ SUPPRESSION IS SUCCESS. The double-post guard deliberately posts nothing when the mirror
    /// is already streaming that conversation — treating that as a failure would make `dispatch`
    /// report the correct behaviour as a lost notification, and the two must not share an exit.
    ///
    /// Mutation that must turn this red: throw whenever `targets` is empty.
    @MainActor
    func testSuppressionByTheMirrorIsNotAFailure() async throws {
        let conversation = UUID()
        let mirroring = FakeAnnouncer(.telegram)
        mirroring.mirroring = [conversation]

        try await withChannelEnabled([mirroring]) { channel in
            // Must NOT throw: the remote user is watching the stream itself.
            try await channel.send(self.payload("Query Completed", conversation: conversation))
            XCTAssertTrue(mirroring.announced.isEmpty, "the double-post guard still holds")
        }
    }
}
