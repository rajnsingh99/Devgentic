//
//  RawValueForwardCompatibilityTests.swift
//  DevgenticTests
//
//  Created on 04/08/26.
//
//  Guards the String-raw enums that a newer build can grow a case in.
//
//  ⚠️ THE NAIVE FIX HERE IS WORSE THAN DOING NOTHING. A "tolerant" decoder that falls back to some
//  EXISTING case would make the value render again — and then re-encode as the fallback, DESTROYING
//  the original rawValue. Since `TimelineEvent` gained its total catch-all, an unknown rawValue is
//  already survivable (the element is preserved verbatim as `.unknown`), so a lossy fallback would
//  trade preserved bytes for a pretty label. Every enum below therefore uses a hand-written
//  `RawRepresentable` with `case other(String)` that carries the value through.
//
//  Stdlib's `RawRepresentable where RawValue == String` conformances supply `Codable` and
//  `Equatable`, so the wire format is byte-identical to the previous `: String` form.
//

import XCTest
@testable import devgentic

final class RawValueForwardCompatibilityTests: XCTestCase {

    // MARK: - Round-trip preservation

    /// The property that matters: an unrecognised value survives decode → encode unchanged.
    private func assertPreserves<T: RawRepresentable & Codable & Equatable>(
        _ type: T.Type, unknownRaw: String, file: StaticString = #filePath, line: UInt = #line
    ) throws where T.RawValue == String {
        let blob = Data("\"\(unknownRaw)\"".utf8)
        let decoded = try JSONDecoder().decode(T.self, from: blob)
        XCTAssertEqual(decoded.rawValue, unknownRaw,
                       "\(T.self) lost the unrecognised rawValue on decode.", file: file, line: line)

        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(T.self, from: reencoded)
        XCTAssertEqual(roundTripped.rawValue, unknownRaw,
                       "\(T.self) did not re-emit the unrecognised rawValue.", file: file, line: line)
    }

    func testMediaKindPreservesAnUnknownRawValue() throws {
        try assertPreserves(MediaKind.self, unknownRaw: "hologram")
    }

    func testWarningCategoryPreservesAnUnknownRawValue() throws {
        try assertPreserves(WarningCategory.self, unknownRaw: "quotaExhausted")
    }

    func testCapabilityMilestoneKindPreservesAnUnknownRawValue() throws {
        try assertPreserves(CapabilityMilestoneKind.self, unknownRaw: "planApproved")
    }

    func testPlanStepStatusPreservesAnUnknownRawValue() throws {
        try assertPreserves(PlanStepStatus.self, unknownRaw: "awaitingInput")
    }

    func testReflectionAttemptStatusPreservesAnUnknownRawValue() throws {
        try assertPreserves(ReflectionAttemptStatus.self, unknownRaw: "deferred")
    }

    func testNodeStatusPreservesAnUnknownRawValue() throws {
        try assertPreserves(WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus.self,
                            unknownRaw: "retrying")
    }

    /// Known values must be untouched — the wire format cannot change for existing data.
    func testKnownRawValuesAreUnchanged() throws {
        XCTAssertEqual(try JSONEncoder().encode(MediaKind.image), Data("\"image\"".utf8))
        XCTAssertEqual(try JSONEncoder().encode(WarningCategory.retry), Data("\"retry\"".utf8))
        XCTAssertEqual(try JSONEncoder().encode(PlanStepStatus.completed), Data("\"completed\"".utf8))
        XCTAssertEqual(try JSONDecoder().decode(MediaKind.self, from: Data("\"audio\"".utf8)), .audio)
        XCTAssertEqual(try JSONDecoder().decode(PlanStepStatus.self, from: Data("\"failed\"".utf8)), .failed)
    }

    // MARK: - The reason MediaKind came first

    /// `MediaKind` rides `ChatMessageSD.contentData` via `MessageContent.mediaArtifact`, and THAT
    /// blob has no `.unknown` catch-all. Before hardening, one unrecognised kind threw, the whole
    /// message decoded to a Decode Error card, and the next save re-encoded that card over the
    /// original bytes — permanent loss, from a single new enum case.
    func testUnknownMediaKindDoesNotBreakMessageContentDecoding() throws {
        // Build a REAL artifact, encode it, then mutate ONLY the kind — hand-writing the JSON
        // produced a shape `MessageContent` rejected for unrelated reasons, which made the test
        // skip instead of assert.
        let real = MessageContent.mediaArtifact(
            MediaArtifact(kind: .image,
                          reference: .diskPath(URL(fileURLWithPath: "/tmp/x.png")),
                          mimeType: "image/png")
        )
        // `MessageContent` has a HAND-WRITTEN codec keyed on a `type` discriminator with the
        // payload under `artifact` — not the synthesized single-key shape.
        var tree = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(real)) as? [String: Any]
        )
        XCTAssertEqual(tree["type"] as? String, "mediaArtifact", "Fixture setup: unexpected discriminator.")
        var artifact = try XCTUnwrap(tree["artifact"] as? [String: Any],
                                     "Fixture setup: payload is not under `artifact`.")
        XCTAssertEqual(artifact["kind"] as? String, "image", "Fixture setup: unexpected artifact shape.")
        artifact["kind"] = "hologram"
        tree["artifact"] = artifact
        let blob = try JSONSerialization.data(withJSONObject: tree)

        // Before hardening this threw, the whole message became a Decode Error card, and the next
        // save re-encoded that card over the original bytes. `contentData` has NO catch-all.
        let content = try JSONDecoder().decode(MessageContent.self, from: blob)
        guard case .mediaArtifact(let decoded) = content else {
            return XCTFail("Expected .mediaArtifact, got \(content)")
        }
        XCTAssertEqual(decoded.kind.rawValue, "hologram",
                       "The unrecognised media kind was not preserved.")

        // And it must survive the way back out, or the next save still destroys it.
        let reencoded = try JSONEncoder().encode(content)
        let round = try JSONDecoder().decode(MessageContent.self, from: reencoded)
        guard case .mediaArtifact(let again) = round else { return XCTFail("round trip lost the case") }
        XCTAssertEqual(again.kind.rawValue, "hologram")
    }

    // MARK: - Predicates that must account for `.other`

    /// ⚠️ An unrecognised status must NOT be counted as completed — that would overstate what
    /// actually finished, the more misleading of the two possible errors.
    func testUnknownStepStatusIsNotCountedAsCompleted() {
        let run = PlanRunData(steps: [
            PlanStepData(id: "a", title: "A", status: .completed),
            PlanStepData(id: "b", title: "B", status: .other("awaitingInput")),
        ])
        XCTAssertEqual(run.completedCount, 1, "An unrecognised status was counted as completed.")
    }

    /// …but it IS a degradation signal: this build cannot verify the step succeeded, and the
    /// indicator exists to say "do not take this run's output at face value".
    func testUnknownStepStatusCountsAsDegraded() {
        let clean = PlanRunData(steps: [PlanStepData(id: "a", title: "A", status: .completed)])
        XCTAssertFalse(clean.hasDegradedSteps)

        let degraded = PlanRunData(steps: [
            PlanStepData(id: "a", title: "A", status: .completed),
            PlanStepData(id: "b", title: "B", status: .other("awaitingInput")),
        ])
        XCTAssertTrue(degraded.hasDegradedSteps,
                      "An unreadable step status rendered as a clean run.")
    }

    func testIsUnrecognisedOnlyTrueForOther() {
        XCTAssertTrue(PlanStepStatus.other("x").isUnrecognised)
        XCTAssertFalse(PlanStepStatus.completed.isUnrecognised)
        XCTAssertFalse(PlanStepStatus.failed.isUnrecognised)
    }

    /// `.other` is excluded from `allCases` by design — it is not a fixed member of the vocabulary.
    func testWarningCategoryAllCasesExcludesOther() {
        XCTAssertFalse(WarningCategory.allCases.contains { $0.isUnrecognisedCategory })
        XCTAssertEqual(WarningCategory.allCases.count, 9)
    }

    /// ⚠️ An unrecognised warning must not be promoted to the workflow surface — bubbling asserts
    /// "the whole run is at risk", which this build cannot know about a category it can't read.
    func testUnknownWarningCategoryDoesNotBubbleToWorkflowLevel() {
        XCTAssertFalse(WarningCategory.other("quotaExhausted").bubblesToWorkflowLevel)
        XCTAssertTrue(WarningCategory.circuitBreaker.bubblesToWorkflowLevel)
    }

    /// The display name falls back to the raw value — the only truthful label available.
    func testUnknownWarningCategoryDisplaysItsRawValue() {
        XCTAssertEqual(WarningCategory.other("quotaExhausted").displayName, "quotaExhausted")
    }

    // MARK: - G82: RunStatus, the sibling NodeStatus got and this did not

    /// ⚠️ THE defect: `WorkflowRunRecordSD.decodeRecord` resolved the status with
    /// `RunStatus(rawValue:) ?? .completed`. A run written by a NEWER build with a status this build
    /// cannot classify — very plausibly a FAILURE state — rendered as a green "Completed" with a
    /// checkmark, and the original rawValue was gone the next time the row was written.
    func testUnknownRunStatusIsPreservedNotReportedAsCompleted() throws {
        let status = try XCTUnwrap(WorkflowRunRecord.RunStatus(rawValue: "partiallyFailed"))

        XCTAssertEqual(status, .other("partiallyFailed"))
        XCTAssertNotEqual(status, .completed, "An unclassifiable run must never read as SUCCESS.")
        XCTAssertEqual(status.rawValue, "partiallyFailed", "The rawValue must survive verbatim.")
    }

    /// Byte-identical `Codable` — the whole point of hand-writing `RawRepresentable` rather than
    /// switching to an enum with an associated value, which would have changed the wire format.
    func testRunStatusCodableIsUnchangedForKnownCases() throws {
        for known: WorkflowRunRecord.RunStatus in [.running, .completed, .failed, .cancelled] {
            let data = try JSONEncoder().encode(known)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(known.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(WorkflowRunRecord.RunStatus.self, from: data), known)
        }
        let unknown = WorkflowRunRecord.RunStatus.other("partiallyFailed")
        let roundTripped = try JSONDecoder().decode(
            WorkflowRunRecord.RunStatus.self, from: try JSONEncoder().encode(unknown)
        )
        XCTAssertEqual(roundTripped, unknown)
    }

    /// The UI must not claim success either — a neutral icon and colour, never a checkmark.
    /// Moving the false claim from the decoder into the renderer would fix nothing.
    func testUnknownRunStatusRendersNeutrally() {
        let unknown = WorkflowRunRecord.RunStatus.other("partiallyFailed")
        XCTAssertNotEqual(unknown.icon, WorkflowRunRecord.RunStatus.completed.icon)
        XCTAssertEqual(unknown.icon, "questionmark.circle.fill")
        XCTAssertEqual(unknown.label, "Unknown")
    }

    /// ⚠️ `.other` is NOT settled: an unknown status may be a new in-flight state, and claiming it
    /// has finished is the same overreach as the old `?? .completed`.
    func testUnknownRunStatusIsNotTreatedAsSettled() {
        XCTAssertFalse(WorkflowRunRecord.RunStatus.other("queued").isSettled)
        XCTAssertFalse(WorkflowRunRecord.RunStatus.running.isSettled)
        for settled: WorkflowRunRecord.RunStatus in [.completed, .failed, .cancelled] {
            XCTAssertTrue(settled.isSettled)
        }
    }

    // MARK: - G85: ToolFailureCategory, the 7th String-raw enum in the same blob

    func testUnknownToolFailureCategoryIsPreserved() throws {
        let category = try XCTUnwrap(ToolFailureCategory(rawValue: "rateLimited"))
        XCTAssertEqual(category, .other("rateLimited"))
        XCTAssertEqual(category.rawValue, "rateLimited")
        XCTAssertEqual(category.displayName, "Unknown")
    }

    func testToolFailureCategoryCodableIsUnchangedForKnownCases() throws {
        for known in ToolFailureCategory.allCases {
            let data = try JSONEncoder().encode(known)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(known.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(ToolFailureCategory.self, from: data), known)
        }
    }

    /// ⚠️ `allCases` must be hand-written and must EXCLUDE `.other` — `CaseIterable` synthesis breaks
    /// once a case carries an associated value, and `.other` is unbounded so it cannot be enumerated.
    func testToolFailureCategoryAllCasesExcludesTheCatchAll() {
        XCTAssertEqual(ToolFailureCategory.allCases.count, 7)
        XCTAssertFalse(ToolFailureCategory.allCases.contains(.other("rateLimited")))
    }

    /// ⚠️ An unknown category must NOT produce a hard constraint. A hard constraint bans the tool
    /// outright, and a check that cannot answer must not block the action (§7 invariant 23): the cost
    /// of being wrong softly is one retry, the cost of being wrong hard is a capability the agent
    /// cannot use for the rest of the run.
    func testUnknownToolFailureCategoryDoesNotHardBanTheTool() {
        XCTAssertFalse(ToolFailureCategory.other("rateLimited").producesHardConstraint)
        XCTAssertTrue(ToolFailureCategory.userDenied.producesHardConstraint)
    }

    /// It still classifies as a failure — just a generic one, never a specific cause the telemetry
    /// would then group it under.
    func testUnknownToolFailureCategoryMapsToAGenericFailure() {
        XCTAssertEqual(ToolFailureCategory.other("rateLimited").actionStatus, .failed)
        XCTAssertEqual(ToolFailureCategory.other("rateLimited").agentErrorCategory, .toolSemanticFail)
        XCTAssertNotEqual(ToolFailureCategory.other("rateLimited").agentErrorCategory, .toolNotFound)
    }
}

private extension WarningCategory {
    var isUnrecognisedCategory: Bool {
        if case .other = self { return true }
        return false
    }
}
