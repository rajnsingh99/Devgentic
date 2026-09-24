// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbApprovalTests.swift
//  DevgenticTests
//
//  Phase 3. The safety-critical half of Orb: what it says when a run parks, and what
//  "Autonomous" actually grants. The rule these tests exist to defend is that an ASR transcript
//  must never be what authorizes code execution — so the spoken prompt must not carry the
//  arguments, and a blanket grant must inherit every restriction the per-tool grants have.
//

import XCTest
@testable import devgentic

// MARK: - What Orb says when a run parks

@MainActor
final class OrbApprovalPromptTests: XCTestCase {

    private func pending(_ kind: PendingInteraction) -> PendingHITL {
        PendingHITL(
            id: kind.id,
            origin: HITLOrigin(interface: .chat, conversationID: UUID(), title: "Permission required"),
            kind: kind
        )
    }

    func testToolConfirmationNamesTheToolInSpeakableForm() {
        let confirmation = PendingToolConfirmation(toolName: "fs_smart_search", params: "{}")
        let prompt = OrbSessionController.approvalPrompt(for: pending(.toolConfirmation(confirmation)))
        XCTAssertTrue(prompt.contains("fs smart search"),
                      "underscores must be spoken as spaces, not as the word 'underscore'")
        XCTAssertFalse(prompt.contains("fs_smart_search"))
    }

    func testThePromptNEVERCarriesTheArguments() {
        // ⚠️ THE safety assertion of Phase 3. The user must READ what they are approving; a
        // spoken paraphrase of a shell command is exactly how a misheard approval becomes an
        // executed one. Arguments belong on the banner, never in the utterance.
        let dangerous = "{\"command\":\"rm -rf /Users/alice/Documents\"}"
        let confirmation = PendingToolConfirmation(toolName: "execute_shell", params: dangerous)
        let prompt = OrbSessionController.approvalPrompt(for: pending(.toolConfirmation(confirmation)))
        XCTAssertFalse(prompt.contains("rm -rf"))
        XCTAssertFalse(prompt.contains("Documents"))
        XCTAssertTrue(prompt.lowercased().contains("on screen"),
                      "the prompt must send the user to the surface where the arguments are readable")
    }

    func testEveryInteractionKindGetsADistinctSpokenPrompt() {
        let prompts = [
            OrbSessionController.approvalPrompt(for: pending(.toolConfirmation(
                PendingToolConfirmation(toolName: "read_file", params: "{}")))),
            OrbSessionController.approvalPrompt(for: pending(.clarification(
                PendingClarification(question: "Which branch?")))),
            OrbSessionController.approvalPrompt(for: pending(.planReview(
                PendingPlanReview(subtasks: [])))),
            OrbSessionController.approvalPrompt(for: pending(.gate(
                PendingGate(id: UUID(), prompt: "Pick one", options: ["a", "b"], deadline: nil,
                            inputText: nil, highlights: [])))),
        ]
        XCTAssertEqual(Set(prompts).count, prompts.count, "a user must be able to tell the four apart by ear")
        for prompt in prompts { XCTAssertFalse(prompt.isEmpty) }
    }

    func testSpokenToolNameHandlesBothSeparators() {
        XCTAssertEqual(OrbSessionController.spokenToolName("execute_shell"), "execute shell")
        XCTAssertEqual(OrbSessionController.spokenToolName("web-search"), "web search")
        XCTAssertEqual(OrbSessionController.spokenToolName("plain"), "plain")
    }
}

// MARK: - Log legibility

@MainActor
final class OrbLogNamingTests: XCTestCase {

    func testEveryStageHasADistinctShortLogName() {
        // The log is the only debugging channel for an acoustic, unreproducible feature, so a
        // stage that logs the same string as another makes a trace unreadable.
        let stages: [OrbStage] = [
            .selectingProfile, .welcoming, .passiveListening, .commandCapture,
            .followUpWindow, .executing, .awaitingApproval, .announcing,
            .voiceUnavailable(reason: "anything"),
        ]
        let names = stages.map(OrbSessionController.name(of:))
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testVoiceUnavailableDoesNotInlineItsWholeSentence() {
        // `String(describing:)` would drag a full remediation paragraph into every log line.
        let name = OrbSessionController.name(of: .voiceUnavailable(
            reason: "The microphone opened but delivered no audio. Another app may be holding it."))
        XCTAssertEqual(name, "voiceUnavailable")
    }

    func testInteractionKindsHaveDistinctLogNames() {
        let kinds: [PendingInteraction] = [
            .toolConfirmation(PendingToolConfirmation(toolName: "t", params: "")),
            .clarification(PendingClarification(question: "q")),
            .planReview(PendingPlanReview(subtasks: [])),
            .gate(PendingGate(id: UUID(), prompt: "p", options: [], deadline: nil,
                              inputText: nil, highlights: [])),
        ]
        let names = kinds.map(OrbSessionController.kindName(of:))
        XCTAssertEqual(Set(names).count, names.count)
    }
}

// MARK: - Autonomous grants

final class OrbAutonomousApprovalTests: XCTestCase {

    private func makeApprovals() -> SessionToolApprovals {
        let suite = UserDefaults(suiteName: "OrbAutonomousApprovalTests.\(UUID().uuidString)")!
        return SessionToolApprovals(defaults: suite)
    }

    /// Runs `body` as a run STARTED BY ORB.
    ///
    /// ⚠️ The blanket grant is keyed on (conversation, origin) since 2026-09-11, so asking
    /// `isAllowed` outside a voice run correctly answers no. Without this the suite would be
    /// asserting `.localUI` behaviour while claiming to test Orb.
    private func asOrbRun<T>(_ body: () async -> T) async -> T {
        await WorkflowRunAttendance.$origin.withValue(.orb) { await body() }
    }

    func testAutonomousApprovesAToolThatWasNeverIndividuallyGranted() async {
        let approvals = makeApprovals()
        let conversation = UUID()
        // ⚠️ Run AS A VOICE RUN. The grant is keyed on (conversation, origin), so `isAllowed` must
        //   be asked in the same origin it was granted for — see `SessionToolApprovals.AutonomousGrant`.
        var allowed = await asOrbRun { await approvals.isAllowed(toolName: "execute_shell", conversationID: conversation) }
        XCTAssertFalse(allowed, "nothing is approved before the mode is set")

        await approvals.setAutonomous(true, conversationID: conversation, origin: .orb)
        allowed = await asOrbRun { await approvals.isAllowed(toolName: "execute_shell", conversationID: conversation) }
        XCTAssertTrue(allowed)
    }

    func testAutonomousIsScopedToItsOwnConversation() async {
        // A voice setting must never change the behaviour of a conversation the user is typing in.
        let approvals = makeApprovals()
        let voice = UUID(), typed = UUID()
        await approvals.setAutonomous(true, conversationID: voice, origin: .orb)
        let leaked = await asOrbRun { await approvals.isAllowed(toolName: "execute_shell", conversationID: typed) }
        XCTAssertFalse(leaked)
    }

    func testTurningItOffRevokesImmediately() async {
        let approvals = makeApprovals()
        let conversation = UUID()
        await approvals.setAutonomous(true, conversationID: conversation, origin: .orb)
        await approvals.setAutonomous(false, conversationID: conversation, origin: .orb)
        let allowed = await asOrbRun { await approvals.isAllowed(toolName: "read_file", conversationID: conversation) }
        XCTAssertFalse(allowed)
    }

    func testAutonomousDoesNotServeARunNobodyCanAnswer() async {
        // ⚠️ Inherited from `isAllowed`'s existing attendance gate, and the reason Autonomous is
        // implemented INSIDE this actor rather than as a bypass in ToolExecutionLoop: a blanket
        // grant given on a live voice session must not silently auto-approve a scheduled run.
        let approvals = makeApprovals()
        let conversation = UUID()
        await approvals.setAutonomous(true, conversationID: conversation, origin: .orb)

        let allowed = await WorkflowRunAttendance.$origin.withValue(.orb) {
            await WorkflowRunAttendance.$isAttended.withValue(false) {
                await WorkflowRunAttendance.$hasRemoteResponder.withValue(false) {
                    await approvals.isAllowed(toolName: "execute_shell", conversationID: conversation)
                }
            }
        }
        XCTAssertFalse(allowed, "an unattended run must not inherit a voice session's blanket grant")
    }

    func testClearingAConversationAlsoClearsItsBlanketGrant() async {
        let approvals = makeApprovals()
        let conversation = UUID()
        await approvals.setAutonomous(true, conversationID: conversation, origin: .orb)
        await approvals.clear(conversationID: conversation)
        let allowed = await asOrbRun { await approvals.isAllowed(toolName: "read_file", conversationID: conversation) }
        XCTAssertFalse(allowed)
    }
}

// MARK: - The setting

@MainActor
final class OrbToolApprovalSettingTests: XCTestCase {

    func testDefaultIsAskNotAutonomous() {
        // The safe default has to be the one that stops and shows you the arguments.
        let saved = TestHost.defaults.object(forKey: AppSettings.orbToolApprovalsKey)
        TestHost.defaults.removeObject(forKey: AppSettings.orbToolApprovalsKey)
        defer { if let saved { TestHost.defaults.set(saved, forKey: AppSettings.orbToolApprovalsKey) } }
        XCTAssertEqual(OrbConfigManager.shared.toolApprovals, .ask)
        XCTAssertFalse(OrbConfigManager.shared.toolApprovals.isAutonomous)
    }
}
