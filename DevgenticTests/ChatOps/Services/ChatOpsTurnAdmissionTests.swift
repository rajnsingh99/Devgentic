// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsTurnAdmissionTests.swift
//  devgenticTests
//
//  BR-4. Nothing stopped a remote free-text message from starting a SECOND root run in a
//  conversation that was already streaming. The Mac composer has guarded this since it shipped
//  (`MessagingCoordinator.sendMessage` opens with `guard !chatHistoryViewModel.isSending`); the
//  remote path read neither `isSending` nor `hasActiveRun`.
//
//  ⚠️⚠️ WHY THIS FILE ASSERTS ON THE BRIDGES' SOURCE AS WELL AS ON THE POLICY. The finding's own
//  words: "a test of the policy alone cannot fail when the bridge does not call it." That is not
//  hypothetical here — `RemoteConversationCommanding.submitRemote` already existed as a seam and
//  all three bridges bypassed it, calling `vm.submitRemoteMessage` directly, which is exactly how
//  the gap survived. A green policy test over a bypassed policy is the failure mode this subsystem
//  has already shipped once (F2, 163 green tests over a feature that could not run).
//

import XCTest
@testable import devgentic

@MainActor
final class ChatOpsTurnAdmissionTests: XCTestCase {

    // MARK: - The policy

    func testAnIdleConversationAdmitsTheTurn() {
        XCTAssertEqual(RemoteTurnAdmission.decide(hasActiveRun: false), .admitted)
    }

    func testAStreamingConversationRefusesTheTurn() {
        guard case .refused(let message, let whenLost) = RemoteTurnAdmission.decide(hasActiveRun: true) else {
            return XCTFail("a conversation with a run already streaming must refuse a second turn")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("/cancel"),
                      "the refusal must tell the user how to get out of it, or it is a dead end")
        XCTAssertFalse(whenLost.isEmpty,
                       "a refusal that fails to send must have a consequence to log, per the logging standard")
    }

    // MARK: - The wiring: what actually reaches the host

    /// ⚠️ THE ASSERTION THE FINDING ASKS FOR — "submits twice and asserts one submit reached the
    /// fake host". The policy could be perfect and this would still fail if `submitTurn` consulted
    /// `runControl` and submitted anyway.
    func testASecondTurnWhileStreamingNeverReachesTheHost() {
        let h = Harness()
        let conversation = UUID()

        XCTAssertEqual(h.submit(conversation), .admitted)
        h.runControl.busy.insert(conversation)              // the first run is now streaming
        guard case .refused = h.submit(conversation) else {
            return XCTFail("the second turn must be refused while the first is streaming")
        }

        XCTAssertEqual(h.commanding.submitted.count, 1,
                       "two remote messages must produce ONE root run — two interleave their answers "
                       + "into the same chat, /cancel kills both while reporting one, and a "
                       + "clarification answer can resolve the wrong run's question")
        XCTAssertEqual(h.commanding.submitted.first?.prompt, "first")
    }

    /// A different conversation is not blocked by this one — the check is conversation-scoped, not
    /// app-global. (Using `streamingMessageID` here would refuse a remote user's first message
    /// because the LOCAL user happened to be running something else.)
    func testAStreamingConversationDoesNotBlockADifferentOne() {
        let h = Harness()
        let busy = UUID(), idle = UUID()
        h.runControl.busy.insert(busy)

        guard case .refused = h.submit(busy) else { return XCTFail("the busy conversation must refuse") }
        XCTAssertEqual(h.submit(idle), .admitted, "an idle conversation is unaffected by another's run")
        XCTAssertEqual(h.commanding.submitted.count, 1)
        XCTAssertEqual(h.commanding.submitted.first?.conversation, idle)
    }

    /// ⚠️ A REFUSAL MUST NOT ATTACH THE MIRROR. Registering a remote session for a turn that was
    /// never submitted points the mirror at a run started by someone else.
    func testARefusedTurnRegistersNoMirrorSession() {
        let h = Harness()
        let conversation = UUID()
        h.runControl.busy.insert(conversation)

        guard case .refused = h.submit(conversation) else { return XCTFail("expected a refusal") }
        XCTAssertEqual(h.log.effects, [], "nothing may happen on a refusal — no registration, no submit")
    }

    /// ⚠️ THE ORDERING, which is why admission, registration and submit are ONE method. The mirror
    /// must be attached before the first token streams, so registration precedes the submit.
    func testTheMirrorIsRegisteredBeforeTheTurnIsSubmitted() {
        let h = Harness()
        XCTAssertEqual(h.submit(UUID()), .admitted)
        XCTAssertEqual(h.log.effects, ["register", "submit"],
                       "registering after the submit races the mirror against the first streamed token")
    }

    /// ⚠️ [NEW-4] A TURN THAT CANNOT BE MIRRORED IS NOT SUBMITTED. Before this, `attachMirror` was
    /// `() -> Void` and every bridge's body was fully optional-chained, so a nil transport or mirror
    /// made it a no-op — and the turn was submitted anyway. The run then spent tokens on the Mac,
    /// possibly ran tools, and the remote user waited forever with nothing logged.
    func testATurnThatCannotBeMirroredIsRefusedAndNeverSubmitted() {
        let h = Harness()
        h.mirrorAvailable = false

        guard case .refused(let message, let whenLost) = h.submit(UUID()) else {
            return XCTFail("a turn whose answer cannot reach the user must be refused, not started")
        }
        XCTAssertEqual(h.commanding.submitted.count, 0,
                       "submitting anyway spends tokens and may run TOOLS for an answer nobody receives")
        XCTAssertEqual(h.log.effects, [], "and nothing may be registered either")
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(whenLost.isEmpty, "the refusal needs a consequence if it fails to send")
    }

    /// The mirror failure must be distinguishable from the busy refusal — they need different fixes.
    func testTheMirrorRefusalIsNotTheBusyRefusal() {
        let h = Harness()
        h.mirrorAvailable = false
        guard case .refused(let mirrorMessage, _) = h.submit(UUID()) else { return XCTFail("expected refusal") }

        guard case .refused(let busyMessage, _) = RemoteTurnAdmission.decide(hasActiveRun: true) else {
            return XCTFail("expected refusal")
        }
        XCTAssertNotEqual(mirrorMessage, busyMessage,
                          "\"still working\" tells a user to wait; a mirror failure tells them to retry")
    }

    // MARK: - The wiring: that the bridges actually go through it

    /// ⚠️ THE BYPASS GUARD. `submitRemote` was a seam the bridges did not use; nothing failed when
    /// they went around it. This reads the three real `handleFreeText` bodies and requires that the
    /// submit goes through `submitTurn` — so re-adding a direct `vm.submitRemoteMessage` call there
    /// turns this red rather than silently restoring the defect.
    func testAllThreeBridgesSubmitFreeTextThroughTheAdmissionPath() throws {
        for bridge in ["ChatOpsBridge", "DiscordChatOpsBridge", "SlackChatOpsBridge"] {
            let body = try Self.handleFreeTextBody(in: bridge)
            XCTAssertTrue(body.contains("submitTurn"),
                          "\(bridge).handleFreeText must submit through ChatOpsCommandService.submitTurn")
            XCTAssertFalse(body.contains("submitRemoteMessage"),
                           "\(bridge).handleFreeText calls the view model directly, bypassing the admission check")
            XCTAssertTrue(body.contains("case .refused"),
                          "\(bridge).handleFreeText must POST the refusal — a dropped prompt with no "
                          + "reply is the failure this path exists to avoid")
            // ⚠️ [NEW-3] A bare `else { return }` on the transport, placed before the admission call,
            // drops the prompt with no log, no reply and no decision. The transport must be resolved
            // INSIDE `attachMirror`, where a nil becomes a refusal the user is told about.
            XCTAssertFalse(body.contains("Transport else { return }"),
                           "\(bridge).handleFreeText guards the transport before submitTurn, so a nil "
                           + "transport is a silent drop rather than a refusal")
        }
    }

    // MARK: - Harness

    private final class EffectLog {
        private(set) var effects: [String] = []
        func record(_ effect: String) { effects.append(effect) }
    }

    private final class FakeRunControl: RemoteRunControlling {
        var busy: Set<UUID> = []
        func hasActiveRun(inConversation conversation: UUID) -> Bool { busy.contains(conversation) }
        func pendingClarificationID(inConversation conversation: UUID) -> UUID? { nil }
        @discardableResult
        func cancelRun(inConversation conversation: UUID) async -> Bool { busy.remove(conversation) != nil }
    }

    private final class FakeCommanding: RemoteConversationCommanding {
        let log: EffectLog
        var defaultProfileID: UUID?
        private(set) var submitted: [(prompt: String, conversation: UUID, source: MessageSource)] = []
        init(log: EffectLog) { self.log = log }

        func createConversation(profile: BackendProfileModel, title: String) -> UUID { UUID() }
        func bindProfile(_ profile: UUID, toConversation conversation: UUID) {}
        func focusConversationInMainWindow(_ conversation: UUID) {}
        func submitRemote(prompt: String, conversationID: UUID, source: MessageSource, config: BackendRequestConfig) {
            submitted.append((prompt, conversationID, source))
            log.record("submit")
        }
    }

    /// ⚠️ Never consulted on this path — `submitTurn` takes the resolved config from the bridge, so
    /// admission does not depend on the store being reachable. Present only to satisfy the init.
    private final class FakeConversations: ConversationReading {
        func conversationRows(limit: Int, offset: Int) throws -> [ConversationRow] { [] }
        func reusableEmptyConversationID(preferring preferred: UUID?) throws -> UUID? { nil }
        func searchConversations(matching query: String, limit: Int) throws -> ConversationSearchResult {
            ConversationSearchResult(rows: [], scanWasTruncated: false)
        }
        func recentMessages(inConversation conversationID: UUID, limit: Int) throws -> [ConversationMessageRow] { [] }
        func conversationRow(id: UUID) throws -> ConversationRow? { nil }
    }

    @MainActor
    private final class Harness {
        let log = EffectLog()
        let runControl = FakeRunControl()
        let commanding: FakeCommanding
        let service: ChatOpsCommandService
        /// ⚠️ [NEW-4] Stands for "the transport or the mirror was nil" — the case that used to be a
        /// silent no-op inside a `() -> Void` closure.
        var mirrorAvailable = true
        private var counter = 0

        init() {
            commanding = FakeCommanding(log: log)
            service = ChatOpsCommandService(
                provider: .telegram,
                runControl: runControl,
                commanding: commanding,
                conversations: FakeConversations(),
                profiles: EmptyProfiles()
            )
        }

        /// Submits a turn the way a bridge does, recording the registration in the same log as the
        /// submit so their ORDER is observable.
        @discardableResult
        func submit(_ conversation: UUID) -> RemoteTurnAdmission.Decision {
            counter += 1
            let prompt = counter == 1 ? "first" : "second"
            var config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude"))
            config.instructions = "be helpful"
            let profile = BackendProfileSnapshot(displayName: "P", details: .agent(config))
            return service.submitTurn(
                prompt: prompt,
                conversationID: conversation,
                source: .telegram,
                config: BackendRequestConfig(profile: profile),
                attachMirror: { [log, mirrorAvailable] in
                    guard mirrorAvailable else { return false }
                    log.record("register")
                    return true
                }
            )
        }
    }

    private final class EmptyProfiles: ChatOpsProfileReading {
        func sharedProfiles() -> [BackendProfileModel] { [] }
        func profile(id: UUID) -> BackendProfileModel? { nil }
    }

    // MARK: - Source access

    /// The `handleFreeText` body of one bridge, comments stripped.
    ///
    /// ⚠️ COMMENT-BLIND. A structural scan that counts commented-out code has produced a false
    /// verdict three times in this subsystem — including one where the doc comment above the method
    /// mentioned the very symbol being searched for.
    private static func handleFreeTextBody(in bridge: String) throws -> String {
        let source = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Services/\(bridge).swift")
        guard let start = source.range(of: "func handleFreeText(") else {
            XCTFail("\(bridge) no longer declares handleFreeText( — this test is blind")
            return ""
        }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else { return "" }

        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return String(source[open...])
    }
}
