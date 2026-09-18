// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileDeletionCascadeTests.swift
//  DevgenticTests
//
//  Created on 08/08/26.
//
//  Register A30 — deleting a profile cascaded only to its own workflow layout, leaving scheduled
//  tasks and other workflows' nodes pointing at a dead ID.
//
//  ⚠️ Investigating the fix narrowed it. The WORKFLOW half turned out to be already covered:
//  `WorkflowValidator.validateProfileNode` reports an unresolvable profile as a blocking `.error`,
//  and `WorkflowExecutor` runs that same validation pre-flight and refuses to start — so every entry
//  point is gated, not just the canvas UI. Those tests are here because that behaviour is now
//  load-bearing for A30: if it ever regresses, deleting a profile silently breaks workflows again.
//
//  The genuinely uncovered half was the scheduler, which failed the task on every fire, forever.
//

import XCTest
@testable import devgentic

// MARK: - The workflow half was already handled — pin it

final class WorkflowProfileDeletionValidationTests: XCTestCase {

    private func profileNode(id: UUID = UUID(), profileID: UUID, task: String = "Do the thing") -> WorkflowNode {
        var node = WorkflowNode(id: id, profileID: profileID, position: .zero,
                                displayName: "Researcher", profileType: .agent)
        node.nodeConfig = WorkflowNodeConfig(taskDescription: task)
        return node
    }

    private func agent(id: UUID) -> BackendProfileModel {
        BackendProfileSnapshot(
            id: id,
            displayName: "Researcher",
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5"),
                tools: [])))
    }

    /// ⚠️ The behaviour A30's workflow half rests on. A node whose profile is gone is an ERROR, not
    /// a warning — errors block the run, warnings do not.
    func testADeletedProfileMakesItsNodeABlockingError() {
        let deletedID = UUID()
        let layout = WorkflowLayout(nodes: [profileNode(profileID: deletedID)], edges: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])
        let blocking = issues.filter { $0.severity == .error }

        XCTAssertEqual(blocking.count, 1,
                       "if this stops being an error, an unresolvable node silently breaks workflows")
    }

    /// ⚠️ The message must name an ACTIONABLE remedy, and the remedy changed on 2026-08-29. It used
    /// to read "Profile not found — it may have been deleted", which described a dead end: a node
    /// referenced a shared profile and nothing in the app could repoint it. A node's configuration
    /// is now its own, so the fix is in reach — hence "Delete it and add the node again".
    func testTheMessageNamesAFixTheUserCanPerform() throws {
        let layout = WorkflowLayout(nodes: [profileNode(profileID: UUID())], edges: [])

        let issue = try XCTUnwrap(
            WorkflowValidator.validate(layout: layout, profileMap: [:])
                .first { $0.severity == .error })

        XCTAssertTrue(issue.message.lowercased().contains("add the node again"),
                      "the message must tell the user what to DO, not just what is wrong — got: \(issue.message)")
    }

    /// A node whose profile still exists must NOT be flagged — otherwise the guard is noise and
    /// users learn to run past it.
    func testALiveProfileProducesNoProfileIssue() {
        let liveID = UUID()
        let layout = WorkflowLayout(nodes: [profileNode(profileID: liveID)], edges: [])

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [liveID: agent(id: liveID)])

        XCTAssertFalse(issues.contains { $0.message.contains("Profile not found") })
    }

    /// ⚠️ Why the fix does NOT clear the node's `profileID`: the issue names the node, which is only
    /// possible because the node still knows what it referenced. Clearing it would degrade the node
    /// to "nothing selected" and lose that.
    func testTheIssueIdentifiesWhichNodeBroke() throws {
        let nodeID = UUID()
        let layout = WorkflowLayout(nodes: [profileNode(id: nodeID, profileID: UUID())], edges: [])

        let issue = try XCTUnwrap(
            WorkflowValidator.validate(layout: layout, profileMap: [:])
                .first { $0.severity == .error })

        XCTAssertEqual(issue.nodeID, nodeID)
        XCTAssertEqual(issue.nodeName, "Researcher")
    }
}

// MARK: - The warning shown before the delete

@MainActor
final class ProfileDeletionWarningTests: XCTestCase {

    private func reference(_ kind: ProfileReference.Kind, _ name: String) -> ProfileReference {
        ProfileReference(id: UUID(), kind: kind, displayName: name)
    }

    // MARK: - B10: every delete entry point shows the same message

    private func profile(_ name: String) -> BackendProfileModel {
        BackendProfileSnapshot(
            displayName: name,
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
    }

    /// ⚠️ A30 built this message inline in the sidebar alert, so the three detail-view trash
    /// buttons kept saying only "This action cannot be undone" — and by A26's own note the
    /// sidebar hover-trash is the path the user is LEAST likely to use. The message is now one
    /// function; these pin what every caller therefore shows.
    func testTheDeletionMessageAlwaysNamesTheProfileAndIrreversibility() {
        let message = ProfileReferenceIndex.deletionMessage(
            for: profile("Research Agent"), in: [], tasksAreKnown: true)

        XCTAssertTrue(message.contains("Research Agent"), "the user must see WHICH profile")
        XCTAssertTrue(message.lowercased().contains("undone"))
    }

    /// ⚠️ register B24, fixed in the same extraction because B10 multiplies its blast radius by
    /// four. `scheduledTasks` is empty both when there are none and when the load failed at
    /// launch — so a confidently silent message would recreate the exact gap A30 was filed for.
    func testTheMessageAdmitsWhenScheduledTasksCouldNotBeChecked() {
        let unknown = ProfileReferenceIndex.deletionMessage(
            for: profile("Research Agent"), in: [], tasksAreKnown: false)
        XCTAssertTrue(unknown.lowercased().contains("could not be checked"),
                      "silence here reads as 'nothing uses this', which we do not know")

        let known = ProfileReferenceIndex.deletionMessage(
            for: profile("Research Agent"), in: [], tasksAreKnown: true)
        XCTAssertFalse(known.lowercased().contains("could not be checked"),
                       "and it must NOT hedge when the answer is actually known")
    }

    func testNoReferencesProducesNoWarning() {
        XCTAssertNil(ProfileReferenceIndex.deletionWarning(for: []))
    }

    /// ⚠️ The warning must state the OUTCOME, not just a count. "2 things use this" tells the user
    /// there is a consequence without telling them what it is — the same failure as the original
    /// "cannot be undone".
    func testAScheduledTaskWarningSaysItWillBeStoppedAndKept() throws {
        let warning = try XCTUnwrap(
            ProfileReferenceIndex.deletionWarning(for: [reference(.scheduledTask, "Nightly digest")]))

        XCTAssertTrue(warning.contains("Nightly digest"), "the user has to know WHICH task")
        XCTAssertTrue(warning.lowercased().contains("stopped"))
        XCTAssertTrue(warning.lowercased().contains("kept"),
                      "the task is disabled, not deleted — say so, or the user assumes the worst")
    }

    func testAWorkflowWarningSaysItWillRefuseToRun() throws {
        let warning = try XCTUnwrap(
            ProfileReferenceIndex.deletionWarning(for: [reference(.workflow, "Research pipeline")]))

        XCTAssertTrue(warning.contains("Research pipeline"))
        XCTAssertTrue(warning.lowercased().contains("refuse to run"))
    }

    func testBothKindsAreReportedSeparately() throws {
        let warning = try XCTUnwrap(ProfileReferenceIndex.deletionWarning(for: [
            reference(.scheduledTask, "Nightly digest"),
            reference(.workflow, "Research pipeline")
        ]))

        XCTAssertTrue(warning.contains("Nightly digest"))
        XCTAssertTrue(warning.contains("Research pipeline"))
    }

    /// One profile used by thirty tasks must not produce an unreadable dialog.
    func testALongReferenceListIsTruncated() throws {
        let many = (1...12).map { reference(.scheduledTask, "Task \($0)") }

        let warning = try XCTUnwrap(ProfileReferenceIndex.deletionWarning(for: many))

        XCTAssertTrue(warning.contains("Task 1"))
        XCTAssertFalse(warning.contains("Task 12"), "the tail is summarised, not listed")
        XCTAssertTrue(warning.contains("more"), "the count of what was elided must still be shown")
        XCTAssertTrue(warning.contains("12"), "and the true total must appear")
    }
}
