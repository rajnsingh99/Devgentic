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

        XCTAssertTrue(blocking.contains { $0.message.contains("Profile not found") },
                      "if this stops being an error, deleting a profile silently breaks workflows")
    }

    /// The message has to point at deletion — "Profile not found" alone reads like a bug in the app.
    func testTheMessageSaysItMayHaveBeenDeleted() throws {
        let layout = WorkflowLayout(nodes: [profileNode(profileID: UUID())], edges: [])

        let issue = try XCTUnwrap(
            WorkflowValidator.validate(layout: layout, profileMap: [:])
                .first { $0.message.contains("Profile not found") })

        XCTAssertTrue(issue.message.lowercased().contains("deleted"))
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
                .first { $0.message.contains("Profile not found") })

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
