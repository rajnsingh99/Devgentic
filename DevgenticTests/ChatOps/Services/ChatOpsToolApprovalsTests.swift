// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsToolApprovalsTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ChatOpsToolApprovalsGrantTests: XCTestCase {

    private func makeApprovals() -> SessionToolApprovals {
        let suite = UserDefaults(suiteName: "ChatOpsToolApprovalsTests.\(UUID().uuidString)")!
        return SessionToolApprovals(defaults: suite)
    }

    private func run<T>(as origin: MessageSource, _ body: () async -> T) async -> T {
        await WorkflowRunAttendance.$origin.withValue(origin) { await body() }
    }

    /// ⚠️ THE REGRESSION, in one test: a voice grant, a remote run.
    func testAOrbGrantIsNotServedToAChatOpsRun() async {
        let approvals = makeApprovals()
        let conversation = UUID()
        await approvals.setAutonomous(true, conversationID: conversation, origin: .orb)

        let leaked = await run(as: .telegram) {
            await approvals.isAllowed(toolName: "execute_shell", conversationID: conversation)
        }

        XCTAssertFalse(leaked, """
            A blanket approval chosen by VOICE was served to a run started from Telegram. \
            `execute_shell` then runs with no prompt anywhere — the banner is skipped, so no \
            PendingHITL exists and the mirror has nothing to post either.
            """)
    }

    /// …and the converse, which the per-platform setting now makes reachable.
    func testAChatOpsGrantIsNotServedToAOrbRun() async {
        let approvals = makeApprovals()
        let conversation = UUID()
        await approvals.setAutonomous(true, conversationID: conversation, origin: .telegram)

        let leaked = await run(as: .orb) {
            await approvals.isAllowed(toolName: "execute_shell", conversationID: conversation)
        }
        XCTAssertFalse(leaked, "a grant made for a chat platform must not authorise a spoken run")
    }

    /// One platform's grant must not serve another's — three bridges can share a conversation.
    func testOneProvidersGrantDoesNotServeAnother() async {
        let approvals = makeApprovals()
        let conversation = UUID()
        await approvals.setAutonomous(true, conversationID: conversation, origin: .telegram)

        for other in [MessageSource.discord, .slack] {
            let leaked = await run(as: other) {
                await approvals.isAllowed(toolName: "execute_shell", conversationID: conversation)
            }
            XCTAssertFalse(leaked, "a Telegram grant was served to a \(other.rawValue) run")
        }
    }

    /// ⚠️ `.localUI` is "not attributed". A run whose origin nobody stamped must get the least
    /// privilege, never a grant made elsewhere.
    func testAnUnattributedRunGetsNoGrant() async {
        let approvals = makeApprovals()
        let conversation = UUID()
        await approvals.setAutonomous(true, conversationID: conversation, origin: .telegram)

        let leaked = await run(as: .localUI) {
            await approvals.isAllowed(toolName: "execute_shell", conversationID: conversation)
        }
        XCTAssertFalse(leaked)
    }

    /// The grant must still WORK for the surface that made it, or the fix has just deleted a feature.
    func testTheGrantStillServesItsOwnSurface() async {
        let approvals = makeApprovals()
        let conversation = UUID()
        await approvals.setAutonomous(true, conversationID: conversation, origin: .telegram)

        let allowed = await run(as: .telegram) {
            await approvals.isAllowed(toolName: "execute_shell", conversationID: conversation)
        }
        XCTAssertTrue(allowed, "Autonomous must still approve for the platform it was chosen on")
    }

    /// Deleting a conversation drops every surface's claim on it.
    func testClearingAConversationDropsEverySurfacesGrant() async {
        let approvals = makeApprovals()
        let conversation = UUID()
        await approvals.setAutonomous(true, conversationID: conversation, origin: .telegram)
        await approvals.setAutonomous(true, conversationID: conversation, origin: .orb)

        await approvals.clear(conversationID: conversation)

        for origin in [MessageSource.telegram, .orb] {
            let allowed = await run(as: origin) {
                await approvals.isAllowed(toolName: "read_file", conversationID: conversation)
            }
            XCTAssertFalse(allowed, "\(origin.rawValue)'s grant outlived the conversation")
        }
    }
}

// MARK: - The setting

@MainActor
final class ChatOpsToolApprovalsSettingTests: XCTestCase {

    private let config = ChatOpsConfigManager.shared

    /// ⚠️ The safe default is the one that stops and shows you the arguments.
    func testDefaultIsAskNotAutonomous() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: ChatOpsConfigManager.telegramToolApprovalsKey)
        defer { defaults.set(saved, forKey: ChatOpsConfigManager.telegramToolApprovalsKey) }

        defaults.removeObject(forKey: ChatOpsConfigManager.telegramToolApprovalsKey)
        XCTAssertEqual(config.toolApprovals(for: .telegram), .ask)
        XCTAssertFalse(config.toolApprovals(for: .telegram).isAutonomous)
    }

    /// ⚠️⚠️ THE TIER IS RE-CHECKED OUTSIDE THE UI. The picker is revealed only at `.full`, but the
    /// stored value survives a later drop to Standard — so a user who granted Autonomous and then
    /// tightened the tier would still be running unattended if the gate read the setting alone.
    func testAutonomousIsInertBelowFullAccess() {
        let savedTier = config.securityTier(for: .telegram)
        let savedApprovals = config.toolApprovals(for: .telegram)
        defer {
            config.setSecurityTier(savedTier, for: .telegram)
            config.setToolApprovals(savedApprovals, for: .telegram)
        }

        config.setToolApprovals(.autonomous, for: .telegram)

        config.setSecurityTier(.full, for: .telegram)
        XCTAssertTrue(config.isAutonomous(for: .telegram), "precondition: Full Access honours it")

        for tier in [ChatOpsSecurityTier.standard, .readOnly] {
            config.setSecurityTier(tier, for: .telegram)
            XCTAssertFalse(config.isAutonomous(for: .telegram), """
                Autonomous is still in force at the \(tier.rawValue) tier. Hiding the picker only \
                stops the user CHOOSING it; the stored value is still there, so the gate has to \
                re-check the tier or tightening it silently changes nothing.
                """)
        }
    }

    /// Per platform — a private DM and a shared channel must be able to differ.
    func testEachPlatformHoldsItsOwnApprovalsSetting() {
        let saved = (config.toolApprovals(for: .telegram),
                     config.toolApprovals(for: .discord),
                     config.toolApprovals(for: .slack))
        defer {
            config.setToolApprovals(saved.0, for: .telegram)
            config.setToolApprovals(saved.1, for: .discord)
            config.setToolApprovals(saved.2, for: .slack)
        }

        config.setToolApprovals(.autonomous, for: .telegram)
        config.setToolApprovals(.ask, for: .discord)
        config.setToolApprovals(.ask, for: .slack)

        XCTAssertEqual(config.toolApprovals(for: .telegram), .autonomous)
        XCTAssertEqual(config.toolApprovals(for: .discord), .ask, "setting Telegram moved Discord")
        XCTAssertEqual(config.toolApprovals(for: .slack), .ask)
    }

    // MARK: - Wiring

    /// ⚠️⚠️ NO REMOTE VERB MAY SET THIS. A command that grants its own sender unattended shell is a
    /// privilege escalation, not a setting. This is the one assertion that stops it being added by
    /// someone who does not know that.
    func testTheApprovalsSettingIsUnreachableFromAnyRemoteCommand() throws {
        for path in ["Devgentic/ChatOps/Models/ChatOpsCommand.swift",
                     "Devgentic/ChatOps/Models/ChatOpsVerbTable.swift",
                     "Devgentic/ChatOps/Services/ChatOpsCommandService.swift"] {
            let source = try ChatOpsSecurityTierMatrixTests.readSource(path)
            for writer in ["setToolApprovals", "toolApprovals =", "setAutonomous"] {
                XCTAssertFalse(source.contains(writer), """
                    \(path) can write the tool-approvals policy, which means a REMOTE MESSAGE can. \
                    Autonomous must be chosen from the Mac's Settings pane and nowhere else — a \
                    command that grants its own sender unattended shell is a privilege escalation.
                    """)
            }
        }
    }

    /// The policy must be re-applied per turn, or a stale grant outlives the setting that made it.
    func testThePolicyIsAppliedOnEveryRemoteTurn() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/Interfaces/Main/MessagingCoordinator.swift")
        XCTAssertTrue(source.contains("ChatOpsConfigManager.shared.isAutonomous(for: provider)"), """
            `submitRemoteMessage` no longer applies the ChatOps approvals policy, so a remote run \
            inherits whatever grant another surface last wrote for that conversation.
            """)
        XCTAssertTrue(source.contains("origin: source"),
                      "the grant is no longer keyed to the remote surface that made it")
    }

    /// The picker must be gated on the tier in the UI as well, or Autonomous is offered from a
    /// channel that is not even trusted to approve tools.
    func testThePickerIsRevealedOnlyAtFullAccess() throws {
        let view = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Settings/ChatOpsSettingsView.swift")
        XCTAssertTrue(view.contains("if config.securityTier(for: provider) == .full {"),
                      "the Tool Approvals row is no longer gated on Full Access")
        XCTAssertTrue(view.contains("config.setToolApprovals($0, for: provider)"),
                      "the picker no longer writes the per-platform setting")
    }
}
