// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteMirrorRetryTests.swift
//  DevgenticTests
//
//  The mirror's send-once claim: it must survive a successful send and NOT survive a failed one.
//
//  ⚠️ THIS DRIVES THE REAL SERVICE, not a copy of its logic. `evaluateMessageState` is private and
//  reached only through `withObservationTracking`, so the test registers a real session, hands the
//  service a real `ChatMessage` through the delegate call `ActiveStreamManager` makes, and then
//  mutates the message exactly as a finishing stream does. A policy test over a hand-copied claim
//  would have passed against the bug.
//

import XCTest
@testable import devgentic

@MainActor
final class RemoteMirrorRetryTests: XCTestCase {

    // MARK: - Fake transport

    /// ⚠️ `@unchecked Sendable`: `ChatOpsTransport` is `Sendable` and this counts calls. Every
    /// access here happens on the main actor (the service is `@MainActor` and so is this test), and
    /// the counter is lock-guarded regardless.
    private final class CountingTransport: ChatOpsTransport, @unchecked Sendable {
        let transportID = "counting"
        nonisolated var capabilities: RemoteCapabilities { .telegram }

        struct SendFailed: Error {}

        private let lock = NSLock()
        private var _chunkedSends = 0
        private var _shouldThrow = true
        private var _sentTexts: [String] = []

        var chunkedSends: Int { lock.withLock { _chunkedSends } }
        var lastSentText: String? { lock.withLock { _sentTexts.last } }
        var shouldThrow: Bool {
            get { lock.withLock { _shouldThrow } }
            set { lock.withLock { _shouldThrow = newValue } }
        }

        func sendChunkedMessage(chatID: String, text: String) async throws {
            lock.withLock {
                _chunkedSends += 1
                _sentTexts.append(text)
            }
            if shouldThrow { throw SendFailed() }
        }

        func sendTextMessage(chatID: String, text: String) async throws {}
        func sendTypingIndicator(chatID: String) async throws {}
        private var _edits: [String] = []
        private var _renders = 0
        private var _views: [RemoteView] = []
        var views: [RemoteView] { lock.withLock { _views } }
        var renders: Int { lock.withLock { _renders } }
        var lastEditedText: String? { lock.withLock { _edits.last } }

        func editMessage(chatID: String, messageID: String, newText: String) async throws {
            lock.withLock { _edits.append(newText) }
        }

        /// Holds `render` open after it has been entered, so a resolution can land INSIDE the post —
        /// the window where the mirror has claimed the operation but has no message id yet.
        /// `renders` is counted on entry, so `waitForRenders` still clears while the post is held.
        private var _gateRenders = false
        private var _rendersReleased = false
        var gateRenders: Bool {
            get { lock.withLock { _gateRenders } }
            set { lock.withLock { _gateRenders = newValue } }
        }
        var rendersReleased: Bool {
            get { lock.withLock { _rendersReleased } }
            set { lock.withLock { _rendersReleased = newValue } }
        }

        /// ⚠️ Returns a real id: the mirror only records `hitlMessageIDs[operationID]` when the
        /// render hands one back, and without that entry no observer can edit anything.
        @discardableResult
        func render(_ view: RemoteView, to destination: RemoteDestination) async throws -> String? {
            // ⚠️ A DISTINCT id per render. Two clarifications really can be parked at once (a
            // fan-out workflow parks one per node), and returning a constant would hide exactly the
            // collision slice 4 exists to fix.
            let n = lock.withLock { () -> Int in _renders += 1; _views.append(view); return _renders }
            while gateRenders && !rendersReleased {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return "remote-msg-\(n)"
        }
    }

    /// The stream manager needs a store; nothing in these tests reads it. Same shape as the
    /// no-op stores the chat tests use.
    private final class NoopChatStore: ChatPersistenceProtocol {
        func addConversation(from conversation: Conversation) {}
        func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
        func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
        func getConversation(withId id: UUID) -> ConversationSD? { nil }
        func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
        func deleteConversation(with id: UUID) {}
        func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
        func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
        func togglePinStatus(for conversationId: UUID) {}
    }

    // MARK: - Fixture

    private var streamManager: ActiveStreamManager!
    private var mirror: RemoteMirrorService!
    private var transport: CountingTransport!
    private var conversationID: UUID!
    private var message: ChatMessage!
    private var center: InteractionCenter!

    override func setUp() async throws {
        try await super.setUp()
        center = InteractionCenter()
        streamManager = ActiveStreamManager(
            persistenceService: NoopChatStore(),
            fileProcessorService: FileProcessorService()
        )
        mirror = RemoteMirrorService(activeStreamManager: streamManager)
        transport = CountingTransport()
        conversationID = UUID()
        mirror.registerSession(
            conversationID: conversationID,
            info: RemoteSessionInfo(transport: transport, chatID: "chat-1", source: .telegram)
        )
        message = ChatMessage(
            conversationId: conversationID,
            timestamp: Date(),
            sender: .agent,
            content: .plainText("")
        )
        message.isStreaming = true
        // ⚠️ `startedBy: .telegram` MATCHES the session registered above, which is what admits the
        // run. This suite exercises retry behaviour and needs the run mirrored; passing the
        // `.localUI` default would now be refused by the consent gate and every assertion here
        // would pass vacuously against a mirror that never sent anything.
        mirror.activeStreamManager(streamManager, didStartStream: message,
                                   startedBy: .telegram, for: conversationID)
    }

    override func tearDown() async throws {
        // A gated render left holding would poll for the life of the process.
        transport?.rendersReleased = true
        mirror.teardown()
        mirror = nil
        streamManager = nil
        transport = nil
        message = nil
        center = nil
        try await super.tearDown()
    }

    /// The mirror observes on the main actor and sends from a `Task`, so the effect is not visible
    /// on the next line. Polls rather than sleeping a fixed interval.
    @discardableResult
    private func waitForRenders(toReach target: Int, timeout: TimeInterval = 3) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if transport.renders >= target { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return transport.renders
    }

    @discardableResult
    private func waitForSends(toReach target: Int, timeout: TimeInterval = 3) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if transport.chunkedSends >= target { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return transport.chunkedSends
    }

    /// Drives a stream to completion with a body, exactly as a finishing run does. Content is set
    /// FIRST, while still streaming, so the response branch never observes an empty body — that is
    /// a different bug and this test isolates the claim.
    private func completeStream(withText text: String) {
        completeStream(with: .plainText(text))
    }

    private func completeStream(with content: MessageContent) {
        message.content = content
        message.isStreaming = false
        message.agentState = .idle
    }

    // MARK: - Tests

    /// ⚠️ THE BUG. The claim was inserted BEFORE the send and never released, so a transport
    /// failure marked the response mirrored while nothing had been delivered. Every later
    /// observation pass was then suppressed by a claim for a send that never happened, and the
    /// agent's answer never reached the remote chat.
    ///
    /// Mutation that must turn this red: delete `mirroredOperations.remove(responseKey)` from the
    /// `catch` in `evaluateMessageState`.
    func testAFailedResponseSendReleasesItsClaimSoALaterPassRetries() async {
        completeStream(withText: "the answer")
        let afterFirst = await waitForSends(toReach: 1)
        XCTAssertEqual(afterFirst, 1, "the finishing stream must attempt one send")

        // Any further observed change is another pass. With the claim released, it must retry.
        message.content = .plainText("the answer, revised")
        let afterSecond = await waitForSends(toReach: 2)
        XCTAssertEqual(afterSecond, 2, """
            The first send FAILED, so nothing reached the remote chat — but the message was already \
            marked mirrored, so this pass was suppressed. Work must not be marked done before it is \
            done: the retry path believes the claim.
            """)
    }

    /// ⚠️ THE OVER-CORRECTION THIS FORBIDS. Releasing the claim unconditionally — or dropping it —
    /// would post the same answer to the remote chat on every observation pass. `observeMessage`
    /// re-arms tracking BEFORE awaiting the mirror, so overlapping passes are normal and the claim
    /// is the only thing preventing a duplicate.
    ///
    /// Mutation that must turn this red: remove the claim, or release it on the success path too.
    func testADeliveredResponseIsNeverPostedTwice() async {
        transport.shouldThrow = false

        completeStream(withText: "the answer")
        let afterFirst = await waitForSends(toReach: 1)
        XCTAssertEqual(afterFirst, 1)

        // Two more passes over a message whose response has already been delivered.
        message.content = .plainText("the answer, revised")
        message.agentState = .idle
        _ = await waitForSends(toReach: 2, timeout: 0.75)

        XCTAssertEqual(transport.chunkedSends, 1, """
            A response that was actually delivered must be claimed permanently. Two posts of the \
            same answer is what the send-once claim exists to prevent.
            """)
    }

    /// ⚠️ The emptiness check used to run AFTER the claim, so a final response observed while its
    /// body was still empty claimed the key and permanently suppressed the real text — and
    /// `content` is one of the properties this service observes, so that ordering is reachable.
    ///
    /// Mutation that must turn this red: move `guard !responseText.isEmpty` back below the claim.
    func testAnEmptyBodyDoesNotClaimTheMessageAgainstTheRealAnswer() async {
        transport.shouldThrow = false

        // Completion observed while the body is still empty — no send, and no claim.
        message.isStreaming = false
        message.agentState = .idle
        _ = await waitForSends(toReach: 1, timeout: 0.5)
        XCTAssertEqual(transport.chunkedSends, 0, "an empty response has nothing to send")

        // The body arrives a moment later.
        message.content = .plainText("the real answer")
        let afterBody = await waitForSends(toReach: 1)
        XCTAssertEqual(afterBody, 1, """
            The empty pass claimed the send-once key, so the answer that arrived immediately \
            afterwards was suppressed and the remote user got nothing.
            """)
    }

    // MARK: - What a finished run actually says

    /// ⚠️ THE BUG. The content switch ended in `default: responseText = "Response complete."`, and
    /// `MessageContent.error` fell into it — so a run that FAILED told the remote user it had
    /// completed. That is the one surface where the user cannot see the Mac's error card, so the
    /// success message was the only thing they had, and it was wrong.
    ///
    /// Mutation that must turn this red: put the `default:` arm back.
    func testAFailedRunIsNotReportedAsSuccess() async {
        transport.shouldThrow = false

        completeStream(with: .error(
            title: "Backend unavailable",
            details: "The provider returned HTTP 503 after 3 retries.",
            category: .providerTimeout,
            suggestion: "Check the backend profile and try again."
        ))
        _ = await waitForSends(toReach: 1)

        let sent = transport.lastSentText ?? ""
        XCTAssertFalse(sent.contains("Response complete."),
                       "A failed run reported success to the remote chat. Reported text: \(sent)")
        XCTAssertTrue(sent.contains("Backend unavailable"), "the failure's title must reach the user")
        XCTAssertTrue(sent.contains("HTTP 503"), "the details are what make the failure actionable")
        XCTAssertTrue(sent.contains("Check the backend profile"), "the suggestion must survive too")
    }

    /// ⚠️ THIS FIX CREATED A NEW EGRESS. Before it, error text never left the process — the remote
    /// user got the fixed string "Response complete.". Error details are exactly the content that
    /// carries absolute home paths, HTTP error bodies and env dumps, and they now travel to a
    /// third-party chat service, so they pass through `TelemetrySanitizer` on the way out.
    ///
    /// Mutation that must turn this red: drop the `TelemetrySanitizer.sanitize` calls.
    func testAFailedRunsDetailsAreSanitisedBeforeLeavingTheProcess() async {
        transport.shouldThrow = false

        completeStream(with: .error(
            title: "Request rejected",
            details: "POST failed for /Users/testuser/Documents/keys.txt using sk-ant-api03-DEADBEEFCAFE1234",
            category: .providerRateLimit,
            suggestion: nil
        ))
        _ = await waitForSends(toReach: 1)

        let sent = transport.lastSentText ?? ""
        XCTAssertFalse(sent.contains("sk-ant-api03-DEADBEEFCAFE1234"),
                       "An API key was transmitted verbatim to a third-party chat service. Sent: \(sent)")
        XCTAssertFalse(sent.contains("/Users/testuser"),
                       "An absolute home path — which carries the account name — was transmitted verbatim. Sent: \(sent)")
        XCTAssertTrue(sent.contains("Request rejected"),
                      "redaction must not swallow the failure itself: \(sent)")
    }

    /// A generated image cannot be sent — no transport implements attachments — but "Response
    /// complete." told the remote user there was a reply to read when there was nothing.
    ///
    /// Mutation that must turn this red: fold `.mediaArtifact` back into a shared success message.
    func testAMediaArtifactIsDescribedRatherThanReportedAsAPlainReply() async {
        transport.shouldThrow = false

        completeStream(with: .mediaArtifact(MediaArtifact(
            kind: .image,
            reference: .diskPath(URL(fileURLWithPath: "/tmp/chart.png")),
            mimeType: "image/png",
            label: "Generated chart"
        )))
        _ = await waitForSends(toReach: 1)

        let sent = transport.lastSentText ?? ""
        XCTAssertFalse(sent.contains("Response complete."), "an image is not a completed text reply")
        XCTAssertTrue(sent.contains("Generated chart"), "the remote user must learn what exists: \(sent)")
    }

    // MARK: - Unanswered-question reminder (D-23)

    private func parkApproval() -> UUID {
        let operationID = UUID()
        streamManager.interactionCenter = center
        center.enqueue(PendingHITL(
            id: operationID,
            origin: HITLOrigin(interface: .chat, conversationID: conversationID, title: "Run a tool"),
            kind: .toolConfirmation(PendingToolConfirmation(id: operationID, toolName: "write_file", params: "{}"))
        ))
        return operationID
    }

    /// Mutation that must turn this red: stop calling `scheduleReminder` after the prompt is posted.
    func testAnUnansweredRemoteQuestionGetsOneReminder() async {
        transport.shouldThrow = false
        mirror.remoteReminderDelay = .milliseconds(100)
        _ = parkApproval()
        message.content = .plainText("working")
        let renders = await waitForRenders(toReach: 2)

        XCTAssertEqual(renders, 2, "the prompt, then one reminder")
        guard case .notice(let notice)? = transport.views.last else {
            return XCTFail("the second render must be a notice: \(transport.views)")
        }
        XCTAssertTrue(notice.body.contains("Still waiting for your approval"), notice.body)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.renders, 2, "ONE reminder, not a repeating nag")
    }

    /// Mutation that must turn this red: drop the still-pending check in the reminder task.
    func testAnAnsweredQuestionGetsNoReminder() async {
        transport.shouldThrow = false
        mirror.remoteReminderDelay = .milliseconds(200)
        let operationID = parkApproval()
        message.content = .plainText("working")
        _ = await waitForRenders(toReach: 1)
        center.resolve(operationID: operationID)
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(transport.renders, 1, "an answered question must not be reminded: \(transport.views)")
    }

    // MARK: - Who answered the prompt

    /// Mirrors a HITL prompt so the observers have a message to edit, then reports a resolution
    /// with the given source and outcome and returns what the remote message was rewritten to.
    private func resolvedPromptText(
        source: MessageSource?,
        outcome: String,
        approved: Bool = true
    ) async -> String? {
        let operationID = UUID()
        streamManager.interactionCenter = center
        center.enqueue(PendingHITL(
            id: operationID,
            origin: HITLOrigin(interface: .chat, conversationID: conversationID, title: "Run a tool"),
            kind: .toolConfirmation(PendingToolConfirmation(
                id: operationID, toolName: "write_file", params: "{}"
            ))
        ))

        // A pass over the message mirrors the pending prompt and stores its remote message id.
        message.content = .plainText("working")
        _ = await waitForRenders(toReach: 1)

        var userInfo: [String: Any] = [
            HITLResolvedKey.operationID: operationID,
            HITLResolvedKey.conversationID: conversationID!,
            HITLResolvedKey.approved: approved,
            HITLResolvedKey.outcome: outcome,
        ]
        if let source { userInfo[HITLResolvedKey.source] = source.rawValue }
        NotificationCenter.default.post(name: .hitlPermissionResolved, object: nil, userInfo: userInfo)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if transport.lastEditedText != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return transport.lastEditedText
    }

    /// ⚠️ THE BUG. These observers fire on a GLOBAL notification, so they ran for every resolution
    /// no matter where it happened — and the text was the literal "(from Mac)". A user who tapped
    /// Approve on Telegram was told, on Telegram, that the Mac had answered.
    ///
    /// Mutation that must turn this red: hard-code "(from Mac)" again, or stop reading
    /// `HITLResolvedKey.source`.
    func testATelegramApprovalIsNotAttributedToTheMac() async {
        transport.shouldThrow = false
        let text = await resolvedPromptText(source: .telegram, outcome: "approved")

        XCTAssertNotNil(text, "the prompt must be edited in place when it resolves")
        XCTAssertFalse(text?.contains("from the Mac") ?? true,
                       "answered on Telegram, reported as the Mac: \(text ?? "nil")")
        XCTAssertTrue(text?.contains("from this chat") ?? false,
                      "a resolution from this very channel should say so: \(text ?? "nil")")
    }

    /// The cross-surface case the old copy could not express at all: answered on the Mac, reported
    /// on Telegram. This is the ONLY case the hard-coded string ever got right.
    func testAMacApprovalIsAttributedToTheMac() async {
        transport.shouldThrow = false
        let text = await resolvedPromptText(source: .localUI, outcome: "approved")
        XCTAssertTrue(text?.contains("from the Mac") ?? false, "got: \(text ?? "nil")")
    }

    /// ⚠️ A CANCEL IS NOT A DENIAL, AND NO ONE MADE IT. `drainOperation` resolves a torn-down
    /// permission with `approved: false` and no source, so a stopped run used to render as
    /// "❌ Tool denied (from Mac)" — a decision nobody took, credited to a surface nobody used.
    ///
    /// Mutation that must turn this red: drop the `outcome == "cancelled"` branch.
    func testAStoppedRunIsNotReportedAsAHumanDenial() async {
        transport.shouldThrow = false
        let text = await resolvedPromptText(source: nil, outcome: "cancelled", approved: false)

        XCTAssertNotNil(text)
        XCTAssertFalse(text?.contains("denied") ?? true,
                       "a cancelled run is not a denial: \(text ?? "nil")")
        XCTAssertFalse(text?.contains("from the Mac") ?? true,
                       "nobody answered, so nothing may be attributed: \(text ?? "nil")")
        XCTAssertTrue(text?.contains("cancelled") ?? false, "got: \(text ?? "nil")")
    }

    // MARK: - Slice 4: which clarification is being answered

    private func park(_ label: String) -> UUID {
        let operationID = UUID()
        center.enqueue(PendingHITL(
            id: operationID,
            origin: HITLOrigin(interface: .chat, conversationID: conversationID, title: label),
            kind: .clarification(PendingClarification(id: operationID, question: label))
        ))
        return operationID
    }

    /// ⚠️ THE CASE THAT WAS PREVIOUSLY UNANSWERABLE. Correlation used to be derived from the
    /// provider's single conversation cursor and then resolved to the OLDEST pending clarification
    /// in it — so with two parked at once (routine for a fan-out workflow, which parks one per
    /// node) every answer resolved the first, and the second could never be answered at all.
    /// A reply names its message; this maps that message back to its own operation.
    ///
    /// Mutation that must turn this red: make `operationID(forRemoteMessageID:)` return the first
    /// entry regardless of the id.
    func testEachParkedClarificationIsAddressableByItsOwnMessage() async {
        transport.shouldThrow = false
        streamManager.interactionCenter = center

        let first = park("Which file?")
        let second = park("Which branch?")

        message.content = .plainText("working")
        _ = await waitForRenders(toReach: 2)

        // Both prompts were posted, each with its own remote message id.
        let firstMessage = await MainActor.run { mirror.operationID(forRemoteMessageID: "remote-msg-1") }
        let secondMessage = await MainActor.run { mirror.operationID(forRemoteMessageID: "remote-msg-2") }

        XCTAssertNotNil(firstMessage)
        XCTAssertNotNil(secondMessage)
        XCTAssertNotEqual(firstMessage, secondMessage, """
            Two parked clarifications resolved to the same operation, which is the collision this \
            correlation exists to remove.
            """)
        XCTAssertEqual(Set([firstMessage, secondMessage].compactMap { $0 }), Set([first, second]))
    }

    /// Mutation that must turn this red: have the lookup fall back to any pending operation instead
    /// of returning nil.
    func testAReplyToSomethingElseCorrelatesToNothing() async {
        transport.shouldThrow = false
        streamManager.interactionCenter = center
        _ = park("Which file?")

        message.content = .plainText("working")
        _ = await waitForRenders(toReach: 1)

        let unrelated = await MainActor.run { mirror.operationID(forRemoteMessageID: "some-other-message") }
        XCTAssertNil(unrelated, """
            A reply to an unrelated message must correlate to nothing. Guessing here would resolve \
            a parked clarification with text the user never intended as its answer.
            """)
    }

    // MARK: - A resolution that lands while its prompt is still being posted

    /// Parks a tool confirmation, holds its post open, and resolves it from Telegram inside the
    /// post. Returns the operation id once the post has been released and an edit observed.
    private func resolveWhilePosting() async -> UUID {
        transport.shouldThrow = false
        transport.gateRenders = true
        streamManager.interactionCenter = center

        let operationID = UUID()
        center.enqueue(PendingHITL(
            id: operationID,
            origin: HITLOrigin(interface: .chat, conversationID: conversationID, title: "Run a tool"),
            kind: .toolConfirmation(PendingToolConfirmation(
                id: operationID, toolName: "write_file", params: "{}"
            ))
        ))

        message.content = .plainText("working")
        _ = await waitForRenders(toReach: 1)
        XCTAssertNil(mirror.operationID(forRemoteMessageID: "remote-msg-1"),
                     "precondition: the post is held open, so no message id is recorded yet")

        // The user DENIES on Telegram while the prompt is still being posted.
        NotificationCenter.default.post(name: .hitlPermissionResolved, object: nil, userInfo: [
            HITLResolvedKey.operationID: operationID,
            HITLResolvedKey.conversationID: conversationID!,
            HITLResolvedKey.approved: false,
            HITLResolvedKey.outcome: "denied",
            HITLResolvedKey.source: MessageSource.telegram.rawValue,
        ])
        // Let the resolution reach the mirror before the post is allowed to complete.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(transport.lastEditedText, "nothing is posted yet, so there is nothing to edit")

        transport.rendersReleased = true
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, transport.lastEditedText == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return operationID
    }

    /// ⚠️ The mid-post prompt used to be rewritten as "✅ Already answered on another surface." —
    /// a ✅ on a DENIAL, attributed to "another surface" when it was answered from this very chat.
    ///
    /// Mutation that must turn this red: stop consuming `resolutionsDuringRender` in the render
    /// window (the interaction-center fallback then writes the generic text).
    func testAPromptAnsweredWhileStillPostingShowsTheRealOutcome() async {
        _ = await resolveWhilePosting()

        let text = transport.lastEditedText
        XCTAssertNotNil(text, "the prompt must be rewritten — otherwise its buttons stay live on a decided prompt")
        XCTAssertTrue(text?.contains("denied") ?? false,
                      "a denial must read as a denial, not a generic ✅: \(text ?? "nil")")
        XCTAssertFalse(text?.contains("another surface") ?? true,
                       "it was answered from this chat, not another surface: \(text ?? "nil")")
    }

    /// The claim must be released on this path, or the operation stays marked as mirrored and a
    /// later park of the same id is silently never shown remotely.
    ///
    /// Mutation that must turn this red: drop `mirroredOperations.remove(pending.id)` from the
    /// parked-verdict branch of the render window.
    func testAPromptAnsweredWhileStillPostingReleasesItsClaim() async {
        let operationID = await resolveWhilePosting()
        XCTAssertNotNil(transport.lastEditedText, "precondition: the mid-post resolution was applied")

        // Probed by re-parking: `ActiveStreamManager` already removed the item from the centre, and
        // the mirror skips any id still claimed — so only a released claim lets this render again.
        transport.gateRenders = false
        center.enqueue(PendingHITL(
            id: operationID,
            origin: HITLOrigin(interface: .chat, conversationID: conversationID, title: "Run a tool"),
            kind: .toolConfirmation(PendingToolConfirmation(
                id: operationID, toolName: "write_file", params: "{}"
            ))
        ))
        message.content = .plainText("working again")
        let renders = await waitForRenders(toReach: 2)
        XCTAssertEqual(renders, 2, "the mid-post resolution never released its claim, so this operation can never be mirrored again")
    }
}
