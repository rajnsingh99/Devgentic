// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MirrorConsentGateTests.swift
//  devgenticTests
//
//  Which runs are allowed to leave the machine.
//
//  ⚠️⚠️ THE FAILURE THIS PINS (MIR-1 / CRIT-6). The mirror's entry gate was
//  `guard remoteSessions[conversationID] != nil` — "has this conversation EVER been driven from
//  chat". `unregisterSession` had ZERO callers and only stopping the bridge cleared the map, so the
//  answer stayed yes forever. One prompt sent from Slack, and every later run in that conversation —
//  typed at the Mac, or fired by the scheduler — had its FULL response posted to the shared channel,
//  with no switch anywhere to turn it off. The sibling path to the same channel
//  (`ChatOpsNotificationChannel`) is default-OFF with a written rationale about exactly this.
//
//  ⚠️ THE GATE FAILS CLOSED. `.localUI` means "not attributed" rather than "typed by hand" — a new
//  surface that forgets to stamp `messageSource` lands there — so a non-matching source refuses to
//  mirror rather than assuming permission.
//

import XCTest
@testable import devgentic

@MainActor
final class MirrorConsentGateTests: XCTestCase {

    private var streamManager: ActiveStreamManager!
    private var mirror: RemoteMirrorService!
    private var transport: RecordingTransport!
    private var conversationID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        streamManager = ActiveStreamManager(
            persistenceService: NoopChatStore(),
            fileProcessorService: FileProcessorService()
        )
        mirror = RemoteMirrorService(activeStreamManager: streamManager)
        transport = RecordingTransport()
        conversationID = UUID()
        mirror.registerSession(
            conversationID: conversationID,
            info: RemoteSessionInfo(transport: transport, chatID: "chat-1", source: .telegram)
        )
    }

    override func tearDown() async throws {
        mirror.teardown()
        mirror = nil; streamManager = nil; transport = nil; conversationID = nil
        try await super.tearDown()
    }

    private func startRun(_ source: MessageSource) -> ChatMessage {
        let message = ChatMessage(conversationId: conversationID, timestamp: Date(),
                                  sender: .agent, content: .plainText(""))
        message.isStreaming = true
        mirror.activeStreamManager(streamManager, didStartStream: message,
                                   startedBy: source, for: conversationID)
        return message
    }

    // MARK: - The gate

    /// The run the remote user actually asked for must still be mirrored.
    func testARunStartedByThisProviderIsMirrored() {
        _ = startRun(.telegram)
        XCTAssertTrue(mirror.isMirroring(conversationID),
                      "a Telegram-started run in a Telegram session must be mirrored")
    }

    /// ⚠️ THE REGRESSION. Same conversation, same live session — but typed at the Mac.
    func testALocallyTypedRunInASessionBearingConversationIsNotMirrored() {
        _ = startRun(.localUI)
        XCTAssertFalse(mirror.isMirroring(conversationID), """
            A locally-typed run in a conversation that was once driven from chat is being mirrored. \
            This is the unintended-egress hole: the user's private answer is posted in full to a \
            third-party channel they last used days ago, with no switch to turn it off.
            """)
    }

    /// ⚠️ An unattended scheduled run is the sharpest version — nobody is even at the keyboard.
    func testAScheduledRunIsNotMirrored() {
        _ = startRun(.scheduled)
        XCTAssertFalse(mirror.isMirroring(conversationID))
    }

    func testQuickAccessAndJarvisRunsAreNotMirrored() {
        for source in [MessageSource.quickAccess, .jarvis] {
            _ = startRun(source)
            XCTAssertFalse(mirror.isMirroring(conversationID), "\(source.rawValue) run was mirrored")
        }
    }

    /// ⚠️ CROSS-PROVIDER LEAKAGE, closed for free by the same gate. With three bridges connected,
    /// each holds its own mirror; a Telegram-started run must not be posted to Discord and Slack too.
    func testARunStartedByAnotherProviderIsNotMirrored() {
        for source in [MessageSource.discord, .slack] {
            _ = startRun(source)
            XCTAssertFalse(mirror.isMirroring(conversationID), """
                A \(source.rawValue)-started run was mirrored by the TELEGRAM session. Three \
                connected bridges would each post the same answer to their own channel.
                """)
        }
    }

    func testAConversationWithNoSessionIsNeverMirrored() {
        let stranger = UUID()
        let message = ChatMessage(conversationId: stranger, timestamp: Date(),
                                  sender: .agent, content: .plainText(""))
        mirror.activeStreamManager(streamManager, didStartStream: message,
                                   startedBy: .telegram, for: stranger)
        XCTAssertFalse(mirror.isMirroring(stranger))
    }

    // MARK: - isMirroring is the double-post predicate

    /// ⚠️⚠️ THE REGRESSION THE FIX ITSELF WOULD HAVE INTRODUCED. `isMirroring` is the ONLY
    /// suppression in `ChatOpsNotificationChannel.send`. Leaving it sticky and conversation-keyed
    /// while the gate went per-run would mean a locally-typed run gets NO mirror (correct) and NO
    /// notification either — the remote user told nothing at all.
    func testIsMirroringIsFalseForARunTheGateRefused() {
        _ = startRun(.localUI)
        XCTAssertFalse(mirror.isMirroring(conversationID), """
            `isMirroring` still answers about the SESSION rather than the RUN. The notification \
            channel will now suppress itself for a run nothing is mirroring, and the message is lost \
            on both paths at once.
            """)
    }

    /// It must also go false when the mirrored run ENDS, or the next local run is suppressed.
    func testIsMirroringIsReleasedWhenTheRunEnds() {
        let message = startRun(.telegram)
        XCTAssertTrue(mirror.isMirroring(conversationID), "precondition: the run is mirrored")

        mirror.activeStreamManager(streamManager, didEndStream: message)
        XCTAssertFalse(mirror.isMirroring(conversationID), """
            The mirroring flag outlived its run. The notification channel would stay suppressed for \
            this conversation until the bridge stops.
            """)
    }

    /// ⚠️ THE SESSION IS AN ADDRESS BOOK AND MUST SURVIVE THE RUN. Releasing it at `didEndStream`
    /// would strand live buttons on already-resolved prompts: all four HITL resolution observers and
    /// `editResolvedPrompt` look the destination up there, and Stop drains suspensions through two
    /// deferred main-actor hops — i.e. after the stream has already ended.
    func testTheSessionSurvivesTheEndOfTheRun() {
        let message = startRun(.telegram)
        mirror.activeStreamManager(streamManager, didEndStream: message)

        // A fresh remote turn is admitted without re-registering, which is only possible if the
        // session is still there.
        _ = startRun(.telegram)
        XCTAssertTrue(mirror.isMirroring(conversationID), """
            The session was released at the end of the run, so a follow-up remote turn is no longer \
            mirrored and every HITL destination lookup after a run ends now fails.
            """)
    }

    // MARK: - Wiring

    /// The gate is worth nothing if the manager does not hand it the real source. `agentMessage`
    /// cannot carry it — every surface stamps that AFTER `startMessageStream` returns.
    func testTheStreamManagerPassesTheUsersSourceNotTheAgentMessages() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/Core/Utils/ActiveStreamManager.swift")
        XCTAssertTrue(source.contains("startedBy: userMessage.messageSource"), """
            The mirror fan-out no longer passes the USER message's source. `agentMessage.messageSource` \
            is still `.localUI` at that instant for every surface, so the gate would refuse every run \
            and mirroring would silently stop working entirely.
            """)
    }

    /// ⚠️ Do not "simplify" this by stamping the agent message earlier — `JarvisAmbientRunWatcher`
    /// reads that field at `didEndStream` and its classification is calibrated to today's timing.
    func testTheAgentMessageIsStillStampedByItsCallerNotByTheStreamManager() throws {
        let manager = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/Core/Utils/ActiveStreamManager.swift")
        XCTAssertFalse(manager.contains("agentMessage.messageSource = userMessage.messageSource"), """
            `startMessageStream` now stamps the agent message's source itself. \
            `JarvisAmbientRunWatcher` reads that field at `didEndStream` to decide what to announce; \
            moving the write changes which runs Jarvis speaks.
            """)
    }

    // MARK: - Doubles

    /// Records what the mirror tried to send. Nothing here asserts on it — the gate is observed via
    /// `isMirroring` — but a transport is required to register a session.
    private final class RecordingTransport: ChatOpsTransport, @unchecked Sendable {
        let transportID = "recording"
        nonisolated var capabilities: RemoteCapabilities { .telegram }

        private let lock = NSLock()
        private var _sent: [String] = []
        var sent: [String] { lock.withLock { _sent } }

        func sendTextMessage(chatID: String, text: String) async throws {
            lock.withLock { _sent.append(text) }
        }
        func sendChunkedMessage(chatID: String, text: String) async throws {
            lock.withLock { _sent.append(text) }
        }
        func editMessage(chatID: String, messageID: String, newText: String) async throws {}
        func sendTypingIndicator(chatID: String) async throws {}
        func render(_ view: RemoteView, to destination: RemoteDestination) async throws -> String? { nil }
    }

    /// The stream manager needs a store; nothing in these tests reads it.
    private final class NoopChatStore: ChatPersistenceProtocol {
        func addConversation(from conversation: Conversation) {}
        func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
        func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
        func getConversation(withId id: UUID) -> ConversationSD? { nil }
        func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
        func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
        func deleteConversation(with id: UUID) {}
        func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
        func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
        func togglePinStatus(for conversationId: UUID) {}
    }
}
