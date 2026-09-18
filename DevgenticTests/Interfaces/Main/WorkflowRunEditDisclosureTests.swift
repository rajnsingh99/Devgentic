// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunEditDisclosureTests.swift
//  DevgenticTests
//
//  Register WF-CS4 — a run that executes the last-SAVED graph while the canvas holds unsaved edits
//  must SAY SO. The defect's own filed category is "ux-lie", and the lie is the silence, not the
//  behaviour: running the saved graph is documented, deliberate and stated in the in-canvas Guide.
//
//  ⚠️ EXACTLY WHAT THIS FILE COVERS, and what it provably does not.
//  COVERED: the pure decision (`WorkflowRunEditDisclosure.shouldDisclose`), and the wiring from the
//  real `WorkflowRunBootstrap.begin` entry point onto `WorkflowExecutionState` and through
//  `WorkflowRunDisplayData.from(live:)` — the exact chain the run header reads. `begin` is testable
//  only because it takes the narrow `WorkflowRunRegistry` protocol rather than a
//  `MainApplicationViewModel` (constructing one claims `HITLPresenter` globally).
//  NOT COVERED, deliberately and by construction:
//    • The RENDERING (`WorkflowExecutionTimelineView.unsavedEditsDisclosure`) is a SwiftUI
//      ViewBuilder and is unreachable from a unit test. It is pinned only by the flag on the display
//      data it reads, asserted below — the same disclosure `WorkflowCanvasStateLifetimeTests` makes.
//    • PERSISTENCE. There is none: the disclosure is LIVE-ONLY by owner decision (2026-08-24).
//      `WorkflowRunRecord` is rebuilt field-by-field from promoted `WorkflowRunRecordSD` columns, so
//      carrying it would need a new column plus a `DevgenticSchemaV3` stage. `from(record:)`
//      therefore leaves the flag false, and `testHistoricalRunsDoNotDisclose` pins that as the
//      intended behaviour rather than leaving it to be discovered as a bug.
//    • ⚠️ THE TRANSITIVE-SET COMPUTATION INSIDE `begin`. The POLICY's handling of a nested set is
//      covered (`testDisclosesWhenANestedSubWorkflowsCanvasIsDirty`), but the line that BUILDS that
//      set — `Set([profile.id]).union(WorkflowLayoutStore.shared.resolveNestedLayouts(from:).keys)`
//      — is not: it needs real root + child layouts persisted to the shared store, which these
//      registry-only tests deliberately avoid. Stated rather than implied: a mutation collapsing
//      that union back to the root id alone would NOT be caught here. `resolveNestedLayouts` itself
//      is exercised by the workflow integration suite and by canvas validation.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowRunEditDisclosureTests: XCTestCase {

    // MARK: - The pure decision

    func testDisclosesWhenThisRunsOwnCanvasIsDirty() {
        let profileID = UUID()
        XCTAssertTrue(WorkflowRunEditDisclosure.shouldDisclose(
            runProfileIDs: [profileID],
            unsavedCanvasProfileIDs: [profileID]))
    }

    func testStaysSilentWhenNothingIsDirty() {
        XCTAssertFalse(WorkflowRunEditDisclosure.shouldDisclose(
            runProfileIDs: [UUID()],
            unsavedCanvasProfileIDs: []))
    }

    /// ⚠️ THE ONE THAT KEEPS THE NOTICE CREDIBLE. Canvas states outlive their views, so at any
    /// moment several unrelated workflows can be dirty. Disclosing another workflow's dirt on THIS
    /// run would put a warning on a run it does not describe, and a notice that cries wolf is worse
    /// than no notice — it trains the user to dismiss the true one.
    func testAnUnrelatedWorkflowsDirtyCanvasIsNotThisRunsProblem() {
        XCTAssertFalse(WorkflowRunEditDisclosure.shouldDisclose(
            runProfileIDs: [UUID()],
            unsavedCanvasProfileIDs: [UUID(), UUID()]))
    }

    /// ⚠️ THE SUB-WORKFLOW CASE. A nested child loads its OWN layout from disk and never reaches
    /// `begin`, so a dirty CHILD canvas reproduces WF-CS4 one level down. Scoping the probe to the
    /// root profile alone — the first shape of this fix — was silent here.
    func testDisclosesWhenANestedSubWorkflowsCanvasIsDirty() {
        let root = UUID(), child = UUID()
        XCTAssertTrue(WorkflowRunEditDisclosure.shouldDisclose(
            runProfileIDs: [root, child],
            unsavedCanvasProfileIDs: [child]),
            "the child's stale graph is just as invisible to the user as the root's")
    }

    func testDisclosesWhenTheDirtyCanvasIsOneOfSeveral() {
        let profileID = UUID()
        XCTAssertTrue(WorkflowRunEditDisclosure.shouldDisclose(
            runProfileIDs: [profileID],
            unsavedCanvasProfileIDs: [UUID(), profileID, UUID()]))
    }

    /// The log line is what makes a support log answer "why didn't my edit run?" without the user
    /// having to reproduce it. `RunAdmissionPolicyTests` enforces the same standard on its refusals.
    func testLogReasonCarriesCorrelationIDsAndTheConsequence() {
        let runID = UUID(), profileID = UUID(), conversationID = UUID()
        let line = WorkflowRunEditDisclosure.logReason(
            runRecordID: runID, workflowProfileID: profileID,
            conversationID: conversationID, origin: "chatOps")

        XCTAssertTrue(line.contains("[WF_RUN]"), "bracket tag is how these are grepped")
        XCTAssertTrue(line.contains("CONSEQUENCE:"), "the standard requires the consequence, not just the fact")
        XCTAssertTrue(line.contains(runID.uuidString))
        XCTAssertTrue(line.contains(profileID.uuidString))
        XCTAssertTrue(line.contains(conversationID.uuidString))
        XCTAssertTrue(line.contains("chatOps"), "origin answers 'what started this?'")
    }

    /// The user-facing string is rendered verbatim in the run header and read verbatim by VoiceOver.
    ///
    /// ⚠️ Asserts the UUID SHAPE, not the presence of a hyphen. An earlier version of this test used
    /// `!text.contains("-")`, which is both vacuous (the signature takes no id, so none can reach it)
    /// and brittle (it outlaws ordinary hyphenated prose and em-dashes in the copy).
    func testUserFacingReasonIsActionableAndCarriesNoIdentifiers() {
        let text = WorkflowRunEditDisclosure.userFacingReason
        let uuidShape = try? NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        let hits = uuidShape?.numberOfMatches(
            in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
        XCTAssertEqual(hits, 0, "no identifier may leak into user-facing copy — got: \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("save"),
                      "must name the remedy, not just the symptom — got: \(text)")
    }

    // MARK: - The wiring, through the real `begin`

    private final class FakeRegistry: WorkflowRunRegistry {
        var workflowExecutionStates: [UUID: WorkflowExecutionState] = [:]
        var workflowRunHistory: [UUID: [WorkflowRunRecord]] = [:]
        var unsavedWorkflowCanvasProfileIDs: [UUID] = []
    }

    private func workflowProfile() -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            id: UUID(),
            displayName: "Nightly Report",
            details: .workflow(WorkflowConfig(agentProfileIDs: []))
        )
    }

    private func begin(
        profile: BackendProfileSnapshot,
        registry: FakeRegistry,
        origin: WorkflowRunOrigin = .chat
    ) -> WorkflowRunTicket? {
        WorkflowRunBootstrap.begin(
            config: BackendRequestConfig(profile: profile),
            conversationID: UUID(),
            userInput: "go",
            registry: registry,
            origin: origin
        )
    }

    func testBeginStampsTheDisclosureOnTheLiveState() throws {
        let profile = workflowProfile()
        let registry = FakeRegistry()
        registry.unsavedWorkflowCanvasProfileIDs = [profile.id]

        let ticket = try XCTUnwrap(begin(profile: profile, registry: registry))
        XCTAssertTrue(ticket.state.ranWithUnsavedCanvasEdits,
                      "the run header reads this — without it the run is silent while it runs")
        // [WF-LC2] `begin()` self-registers the ticket into `WorkflowRunTicket.activeTickets`
        // (a process-wide static). Left un-finalized, it would leak into every later test in this
        // process — including WorkflowRunBootstrapTests' exact-count WF-LC2 assertions, which is
        // exactly how adversarial review caught this.
        ticket.finalize()
    }

    /// The control. Without it the fix could be passing by disclosing on every run, which would be
    /// the same lie pointing the other way.
    func testBeginStaysSilentOnACleanCanvas() throws {
        let profile = workflowProfile()
        let registry = FakeRegistry()   // nothing dirty

        let ticket = try XCTUnwrap(begin(profile: profile, registry: registry))
        XCTAssertFalse(ticket.state.ranWithUnsavedCanvasEdits)
        ticket.finalize()   // [WF-LC2] see the note in the test above
    }

    /// ⚠️ The whole design rests on the two UNATTENDED origins behaving identically — they are why
    /// this discloses instead of prompting. A decision that varied by origin would mean a scheduled
    /// run silently kept the old behaviour.
    func testEveryRunOriginDisclosesEqually() throws {
        for origin in [WorkflowRunOrigin.chat, .scheduled, .chatOps, .regenerate, .quickAccess, .orb, .resume] {
            let profile = workflowProfile()
            let registry = FakeRegistry()
            registry.unsavedWorkflowCanvasProfileIDs = [profile.id]

            let ticket = try XCTUnwrap(begin(profile: profile, registry: registry, origin: origin))
            XCTAssertTrue(ticket.state.ranWithUnsavedCanvasEdits,
                          "origin \(origin.rawValue) must disclose like every other")
            ticket.finalize()   // [WF-LC2] 7 tickets this loop creates — see the note above
        }
    }

    /// A non-workflow profile produces no ticket at all — the disclosure must not change that.
    func testBotProfileStillProducesNoTicket() {
        let bot = BackendProfileSnapshot(
            id: UUID(),
            displayName: "Plain Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "test-model")))
        )
        let registry = FakeRegistry()
        registry.unsavedWorkflowCanvasProfileIDs = [bot.id]
        XCTAssertNil(begin(profile: bot, registry: registry))
    }

    // MARK: - The display projection the run header reads

    func testLiveDisplayDataCarriesTheDisclosure() {
        let state = WorkflowExecutionState()
        state.ranWithUnsavedCanvasEdits = true
        XCTAssertTrue(WorkflowRunDisplayData.from(live: state).ranWithUnsavedCanvasEdits)
    }

    func testLiveDisplayDataStaysSilentByDefault() {
        XCTAssertFalse(WorkflowRunDisplayData.from(live: WorkflowExecutionState()).ranWithUnsavedCanvasEdits)
    }

    /// ⚠️ PINS THE LIVE-ONLY SCOPE AS INTENDED BEHAVIOUR, not as an undiscovered bug. The persisted
    /// record has no column for this (see the file header), so a historical run cannot disclose. If
    /// someone later adds the column + schema stage, THIS is the test that should flip — and its
    /// failure is the reminder to split the copy, whose present-tense "save the canvas and run
    /// again" reads wrong on a run that finished days ago.
    func testHistoricalRunsDoNotDisclose() {
        let d = WorkflowRunDisplayData.from(record: WorkflowRunRecord(
            id: UUID(), conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "wf", timestamp: Date(), userInput: "go",
            nodeResults: [], finalOutput: "", variables: [:],
            status: .completed, duration: 1, error: nil
        ))
        XCTAssertFalse(d.ranWithUnsavedCanvasEdits,
                       "live-only by design — see the header; do not 'fix' this without the schema work")
    }
}
