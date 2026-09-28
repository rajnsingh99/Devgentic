// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsHostSeamTests.swift
//  DevgenticTests
//
//  C0 of the ChatOps remote-interface plan: the host seam, before any command uses it.
//
//  ⚠️ WHAT CAN AND CANNOT BE TESTED HERE, STATED PLAINLY. Constructing a `MainApplicationViewModel`
//  runs `ChatOpsCoordinator.bootstrap()` and opens real network listeners, so no test may build
//  one — which means the real conformance's BEHAVIOUR is unreachable from a unit test by
//  construction. Three things are still checkable, and they are the three that would actually
//  regress:
//
//    1. That the real view model still satisfies both protocols — a compile-time fact, asserted
//       without instantiating anything.
//    2. That the protocols are satisfiable by something that is NOT the view model. This is the
//       entire purpose of the seam; if a future member can only be answered by the god object,
//       the fake below stops compiling and the seam has quietly stopped being one.
//    3. That `cancelRun`'s [WF-SE10] step ordering survives, by reading the source. The ordering
//       is the only real logic in the conformance and it is exactly the kind a later edit
//       "tidies" into a bug.
//
//  ⚠️ The source scans below regex over the JOINED body, never line by line. A line-filtered scan
//  in this repo has already let a multi-line mutation walk straight past it.
//

import XCTest
@testable import devgentic

final class ChatOpsHostSeamTests: XCTestCase {

    // MARK: - 1. The real conformance still exists

    /// Fails at BUILD time if either conformance is removed from
    /// `MainApplicationViewModel+ChatOps.swift`.
    ///
    /// Mutation that must turn this red: delete `: RemoteRunControlling` (or
    /// `: RemoteConversationCommanding`) from the extension.
    ///
    /// ⚠️ Metatypes only — nothing is constructed, so no listener is opened.
    @MainActor
    func testTheRealViewModelSatisfiesBothHalvesOfTheSeam() {
        let runControl: any RemoteRunControlling.Type = MainApplicationViewModel.self
        let commanding: any RemoteConversationCommanding.Type = MainApplicationViewModel.self
        XCTAssertTrue(runControl is MainApplicationViewModel.Type)
        XCTAssertTrue(commanding is MainApplicationViewModel.Type)
    }

    // MARK: - 2. The seam is satisfiable without the god object

    /// The point of the seam. `FakeRemoteHost` conforms to both protocols and reaches no
    /// singleton, no store, no network and no view model.
    ///
    /// Mutation that must turn this red: add a member to either protocol that only
    /// `MainApplicationViewModel` can answer — the fake stops compiling, which is the signal that
    /// the seam has stopped being narrow enough to stand behind.
    @MainActor
    func testTheSeamIsSatisfiableWithNoViewModelAtAll() async {
        let host = FakeRemoteHost()
        let conversation = UUID()
        let clarification = UUID()

        // Run control.
        host.activeConversations = [conversation]
        host.pendingClarifications = [conversation: clarification]
        XCTAssertTrue(host.hasActiveRun(inConversation: conversation))
        XCTAssertEqual(host.pendingClarificationID(inConversation: conversation), clarification)
        XCTAssertNil(host.pendingClarificationID(inConversation: UUID()))

        let hadRun = await host.cancelRun(inConversation: conversation)
        XCTAssertTrue(hadRun, "cancelRun must report the activity it observed BEFORE cancelling")
        XCTAssertFalse(host.hasActiveRun(inConversation: conversation))

        let hadRunSecondTime = await host.cancelRun(inConversation: conversation)
        XCTAssertFalse(hadRunSecondTime, "a second cancel has no run left to report")

        // Conversation commanding.
        let profile = UUID()
        host.defaultProfileID = profile
        XCTAssertEqual(host.defaultProfileID, profile)

        host.focusConversationInMainWindow(conversation)
        XCTAssertEqual(host.focused, conversation)
    }

    // MARK: - 3. The [WF-SE10] ordering, read from source

    /// `cancelRun` must read activity FIRST, then cancel the stream, then clear parked
    /// suspensions. Reading after cancelling always reports `false`, so the bridges' reply text
    /// silently inverts; clearing suspensions before the stream cancel is the pre-[WF-SE10] shape
    /// that denied a parked HITL while the run kept executing.
    ///
    /// Mutations that must turn this red: swap the `hasActiveStream` read below the
    /// `cancelStreams` call; move the `ExecutionSuspensionService.cancel` above it.
    func testCancelRunReadsActivityBeforeCancellingAndClearsSuspensionsLast() throws {
        let source = try Self.readSource("Devgentic/Interfaces/Main/MainApplicationViewModel+ChatOps.swift")

        guard let bodyStart = source.range(of: "func cancelRun(inConversation") else {
            return XCTFail("cancelRun is gone from the ChatOps conformance")
        }
        // Joined body, not lines: the three steps are three separate statements.
        let body = String(source[bodyStart.upperBound...].prefix(700))

        guard let read = body.range(of: "hasActiveStream(inConversation:"),
              let cancelStream = body.range(of: "cancelStreams(forConversation:"),
              let clearParked = body.range(of: "ExecutionSuspensionService.shared.cancel(for:")
        else {
            return XCTFail("""
                cancelRun no longer performs all three [WF-SE10] steps. \
                Body scanned:\n\(body)
                """)
        }

        XCTAssertLessThan(read.lowerBound, cancelStream.lowerBound,
                          "activity must be READ before the cancel — cancelling destroys the evidence, "
                          + "so a read afterwards always reports false and the bridge's reply inverts")
        XCTAssertLessThan(cancelStream.lowerBound, clearParked.lowerBound,
                          "the stream cancel must precede clearing parked suspensions — the reverse is "
                          + "the pre-[WF-SE10] shape that denied a parked HITL while the run kept running")
    }

    // MARK: - 4. The seam stays narrow

    /// C0 exists because the first draft of this seam was a single seven-member protocol over one
    /// god object — three and a half times `MessageStreamStarting`, whose own file warns against
    /// exactly that. This test is the pressure that keeps the split meaningful.
    ///
    /// Mutation that must turn this red: add an eighth requirement, or merge the two protocols
    /// back into one.
    func testTheHostSeamStaysNarrowerThanTheGodObject() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Services/ChatOpsHosting.swift")

        let protocolCount = source.components(separatedBy: "\nprotocol ").count - 1
        XCTAssertEqual(protocolCount, 2, """
            The ChatOps host seam is deliberately TWO protocols answering two questions \
            (run control; conversation commanding). Merging them recreates the god-object \
            interface this split exists to avoid.
            """)

        // Protocol requirements are the only 4-space-indented func/var declarations in this file;
        // the conformance lives in a different file entirely.
        let requirements = source
            .components(separatedBy: "\n")
            .filter { line in
                line.hasPrefix("    func ") || line.hasPrefix("    var ")
            }
        // 9 since 2026-09-27: `pendingQuestionNoun` lets a refused remote prompt say WHAT the run
        // is waiting on (Timeout inventory D-23, owner decision). Deliberate, not drift.
        XCTAssertEqual(requirements.count, 9, """
            The seam has \(requirements.count) requirements, not 9: \
            \(requirements.map { $0.trimmingCharacters(in: .whitespaces) }).
            A new member is not automatically wrong — but it belongs to whichever QUESTION it \
            answers, and if it answers neither it needs its own narrow protocol rather than a \
            slot here. Update this number deliberately, with that decision recorded.

            History: 7 → 8 at slice 2, adding `bindProfile(_:toConversation:)` to
            `RemoteConversationCommanding`. It answers that protocol's question — aim a conversation
            at a profile — so it earned a slot rather than a new protocol.
            """)
    }

    // MARK: - Helpers

    private static func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)   // …/DevgenticTests/ChatOps/Services/<this>
            .deletingLastPathComponent()                 // …/ChatOps/Services
            .deletingLastPathComponent()                 // …/ChatOps
            .deletingLastPathComponent()                 // …/DevgenticTests
            .deletingLastPathComponent()                 // repo root
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) not reachable from \(repoRoot.path) — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Fake

/// Conforms to the whole seam while reaching nothing. Its existence is the assertion.
@MainActor
private final class FakeRemoteHost: RemoteRunControlling, RemoteConversationCommanding {

    var activeConversations: Set<UUID> = []
    var pendingClarifications: [UUID: UUID] = [:]
    var defaultProfileID: UUID?
    private(set) var focused: UUID?
    private(set) var submitted: [(prompt: String, conversation: UUID, source: MessageSource)] = []
    private(set) var created: [String] = []
    private(set) var bindings: [(profile: UUID, conversation: UUID)] = []

    func hasActiveRun(inConversation conversation: UUID) -> Bool {
        activeConversations.contains(conversation)
    }

    func pendingClarificationID(inConversation conversation: UUID) -> UUID? {
        pendingClarifications[conversation]
    }

    func pendingQuestionNoun(inConversation conversation: UUID) -> String? { nil }

    @discardableResult
    func cancelRun(inConversation conversation: UUID) async -> Bool {
        let had = activeConversations.contains(conversation)
        activeConversations.remove(conversation)
        pendingClarifications[conversation] = nil
        return had
    }

    func createConversation(profile: BackendProfileModel, title: String) -> UUID {
        created.append(title)
        return UUID()
    }

    func bindProfile(_ profile: UUID, toConversation conversation: UUID) {
        bindings.append((profile, conversation))
    }

    func focusConversationInMainWindow(_ conversation: UUID) {
        focused = conversation
    }

    func submitRemote(
        prompt: String,
        conversationID: UUID,
        source: MessageSource,
        config: BackendRequestConfig
    ) {
        submitted.append((prompt, conversationID, source))
    }
}
