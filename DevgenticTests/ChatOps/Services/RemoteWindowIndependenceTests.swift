// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteWindowIndependenceTests.swift
//  devgenticTests
//
//  A remote message runs in its own conversation and leaves the Mac window alone.
//
//  ⚠️⚠️ WHAT THIS REPLACED. `submitRemoteMessage` assigned `vm.selectedConversationID` on every
//  remote turn, so a message arriving while the user worked elsewhere yanked the window to it —
//  clearing the web-search toggle and repointing the app-global composer profile, the exact write
//  `ChatOpsHosting` documents as forbidden ("exposed READ-ONLY on purpose: a remote write would
//  retarget the local user's composer").
//
//  ⚠️ THE NAVIGATION WAS NEVER LOAD-BEARING FOR ROUTING. Everything on that path is keyed by the
//  passed `conversationID`, and the mirror replies to the session's own chat id. The ONLY thing
//  that depended on the selection was one unguarded UI insert, whose comment read "the conversation
//  is now guaranteed to be selected" — the window was being moved to manufacture that guarantee.
//
//  ⚠️ THESE ARE DRIFT TESTS OVER REAL SOURCE, not behavioural ones, and the reason is LIFE-6: no
//  test may construct `MainApplicationViewModel`, because doing so runs `ChatOpsCoordinator.bootstrap()`
//  and opens real Telegram/Discord/Slack connections from the test host. Until that seam exists this
//  is what can fail when the guard is removed, and it is strictly better than nothing.
//

import XCTest
@testable import devgentic

final class RemoteWindowIndependenceTests: XCTestCase {

    private var submitRemote: String {
        get throws {
            let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/Interfaces/Main/MessagingCoordinator.swift")
            guard let start = source.range(of: "func submitRemoteMessage("),
                  let end = source.range(of: "\n    func ", range: start.upperBound..<source.endIndex) else {
                throw XCTSkip("could not locate submitRemoteMessage")
            }
            // ⚠️ Comments stripped: this method's own comments EXPLAIN the removed navigation, and a
            //   raw scan would match the explanation and fail against the fix it exists to pin.
            return source[start.upperBound..<end.lowerBound]
                .split(separator: "\n")
                .map { line -> Substring in
                    guard let c = line.range(of: "//") else { return line }
                    return line[line.startIndex..<c.lowerBound]
                }
                .joined(separator: "\n")
        }
    }

    // MARK: - The window is left alone

    func testARemoteMessageDoesNotMoveTheMacWindow() throws {
        let body = try submitRemote
        XCTAssertFalse(body.contains("selectedConversationID = "), """
            `submitRemoteMessage` assigns the main window's selection again. A message arriving while \
            the user is working elsewhere will yank the window to another conversation, clear the \
            web-search toggle, and repoint the app-global composer profile — the write \
            `ChatOpsHosting` documents as the one a remote path must never make.
            """)
    }

    /// ⚠️ The UI insert is what the navigation existed to make safe. Unguarded, it drops the remote
    /// user's question into whichever conversation happens to be displayed.
    func testTheRemoteUsersMessageIsOnlyInsertedIntoItsOwnConversationsView() throws {
        let body = try submitRemote
        guard let guardRange = body.range(of: "destinationConversationID == conversationID"),
              let insert = body.range(of: "currentChatMessages.insert(userMessage") else {
            return XCTFail("""
                The remote user's message is inserted into `currentChatMessages` without checking \
                that this conversation is the one on screen. With the navigation gone, that insert \
                lands in whatever conversation the local user is viewing.
                """)
        }
        XCTAssertTrue(guardRange.lowerBound < insert.lowerBound,
                      "the displayed-conversation check must precede the insert")
    }

    /// ⚠️ VIEWER identity, not the user's selection: a message arriving mid-switch must be filed
    /// against the conversation actually being loaded. `ConversationSyncService` uses the same
    /// authority for the same decision.
    func testTheGuardUsesViewerIdentityRatherThanTheRawSelection() throws {
        let body = try submitRemote
        XCTAssertTrue(body.contains("chatHistoryViewModel.destinationConversationID"), """
            The insert guard no longer uses `destinationConversationID`. `selectedConversationID` \
            lags an in-flight switch, so a message arriving during one would be filed against the \
            conversation being left.
            """)
    }

    // MARK: - The run does not need the window

    /// ⚠️ THE PROPERTY THAT MAKES DROPPING THE NAVIGATION SAFE. If switching conversations cancelled
    /// running streams, a remote run would need the window to stay put in order to finish.
    func testSwitchingConversationsDoesNotCancelRunningStreams() throws {
        let switcher = try ChatOpsSecurityTierMatrixTests.readSourceStrippingComments("Devgentic/Interfaces/Main/ConversationSwitchCoordinator.swift")
        XCTAssertFalse(switcher.contains("cancelStreams"), """
            Switching conversations now cancels streams. A remote run would then die whenever the \
            local user navigated away, and the answer would never reach the chat that asked for it.
            """)
    }

    /// `cancelStreams(forConversation:)` must stay reachable only from a deliberate Stop and from
    /// deleting the conversation — the two places where ending a run is the user's intent.
    func testStreamsAreOnlyCancelledDeliberately() throws {
        var callers: [String] = []
        for path in ["Devgentic/Interfaces/Main/MainApplicationViewModel+ChatOps.swift",
                     "Devgentic/Interfaces/Main/ConversationManagementCoordinator.swift",
                     "Devgentic/Interfaces/Main/ConversationSwitchCoordinator.swift",
                     "Devgentic/Interfaces/Main/MessagingCoordinator.swift"] {
            // ⚠️ COMMENTS STRIPPED. This method's own comment cites `cancelStreams(forConversation:)`
            //   to explain why the navigation could be removed, and a raw scan counted that comment
            //   as a third caller — the same trap, for the third time in one session.
            let source = try ChatOpsSecurityTierMatrixTests.readSourceStrippingComments(path)
            if source.contains("cancelStreams(forConversation") { callers.append(path) }
        }
        XCTAssertEqual(callers.count, 2, """
            Expected exactly two deliberate cancellers (the ChatOps `cancelRun` seam and \
            `deleteConversation`); found \(callers).
            """)
    }

    // MARK: - The seam it stopped violating

    /// The composer selection stays read-only on the remote seam — the rule the direct write broke.
    func testTheHostSeamStillExposesTheComposerProfileReadOnly() throws {
        let seam = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Services/ChatOpsHosting.swift")
        XCTAssertTrue(seam.contains("var defaultProfileID: UUID? { get }"), """
            `defaultProfileID` gained a setter. It is the app-global composer selection shared with \
            the Mac window and Jarvis; a remote write retargets the local user's composer.
            """)
    }
}
