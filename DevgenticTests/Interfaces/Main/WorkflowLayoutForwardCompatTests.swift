//
//  WorkflowLayoutForwardCompatTests.swift
//  DevgenticTests
//
//  Register WF-PE3 + WF-PE4 — the layout blob's decode resilience and its diagnostics.
//
//  Before this: five plain `String, Codable` enums in the blob had no unknown-rawValue handling,
//  so ONE value written by a newer build (read after a rollback — Sparkle self-distribution makes
//  that a real path) threw at decode, failed the node, failed the array, failed the WHOLE layout:
//  a 15-node graph unreadable and unsaveable over a single string, total-loss Discard the only
//  in-app escape. And when the failing element was a modern node's `kind`, the `try?` fallback
//  swallowed the real error and logged `keyNotFound(profileID)` — a key with nothing to do with
//  the failure.
//
//  The catch-alls are RAW-PRESERVING (`WorkflowRunRecord.RunStatus`'s established pattern): an
//  unknown value decodes to `.other(raw)` and re-encodes VERBATIM, so a round-trip through an
//  older build preserves the newer build's unknown enum VALUES verbatim.
//
//  ⚠️ THAT IS THE WHOLE GUARANTEE — it does NOT extend to unknown KEYS. Every Codable in
//  `WorkflowModels.swift` encodes a fixed `CodingKeys` set with no extras bag, so a FIELD added by
//  a newer build is dropped on decode and absent on re-encode. What protects an added field is
//  `WorkflowLayoutSD.layoutBlobVersion` and the WF-PE2 write refusal, not this file. See
//  `testUnknownKeysAreNotPreserved_soTheVersionStampIsTheOnlyProtection` at the bottom.
//
//  ⚠️ The round-trip halves of these
//  tests are the load-bearing ones: decode-without-throwing alone would also pass for a lossy
//  "map unknowns to a default" implementation, which is the exact defect class this forbids.
//

import XCTest
@testable import devgentic

final class WorkflowLayoutForwardCompatTests: XCTestCase {

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    // MARK: - The five enums decode unknowns and re-encode them verbatim

    func testUnknownConditionOpSurvivesTheRoundTrip() throws {
        let op = ConditionOp(rawValue: "fuzzyMatch")!
        XCTAssertEqual(op, .other("fuzzyMatch"))
        XCTAssertEqual(try roundTrip(op).rawValue, "fuzzyMatch",
                       "the unknown operator must re-encode VERBATIM — a default-mapping would destroy it")
    }

    func testUnknownConditionFieldSurvivesTheRoundTrip() throws {
        XCTAssertEqual(try roundTrip(ConditionField(rawValue: "nodeMetadata")!).rawValue, "nodeMetadata")
    }

    func testUnknownFailurePolicyAndJoinModeSurviveTheRoundTrip() throws {
        XCTAssertEqual(try roundTrip(NodeFailurePolicy(rawValue: "retryTwice")!).rawValue, "retryTwice")
        XCTAssertEqual(try roundTrip(JoinMode(rawValue: "quorum")!).rawValue, "quorum")
    }

    func testUnknownStickyColorSurvivesAndDrawsTheDefault() throws {
        let color = StickyNoteColor(rawValue: "teal")!
        XCTAssertEqual(try roundTrip(color).rawValue, "teal")
        XCTAssertEqual(color.swiftUIColor, StickyNoteColor.yellow.swiftUIColor,
                       "an unknown tint draws as the default — cosmetics must never brick a graph")
    }

    /// Pickers iterate `allCases`; offering "other" would let a user SELECT the unknown state.
    func testAllCasesExcludeTheCatchAll() {
        XCTAssertFalse(ConditionOp.allCases.contains(where: { if case .other = $0 { return true }; return false }))
        XCTAssertFalse(ConditionField.allCases.contains(where: { if case .other = $0 { return true }; return false }))
        XCTAssertFalse(NodeFailurePolicy.allCases.contains(where: { if case .other = $0 { return true }; return false }))
        XCTAssertFalse(JoinMode.allCases.contains(where: { if case .other = $0 { return true }; return false }))
        XCTAssertFalse(StickyNoteColor.allCases.contains(where: { if case .other = $0 { return true }; return false }))
    }

    // MARK: - The defect scenario end to end (WF-PE3's headline)

    /// A whole LAYOUT containing a rule with a newer-build operator must decode, keep working,
    /// and give the newer build back exactly the OPERATOR it wrote (see the WF-TS5 note in the
    /// header for what is NOT preserved).
    func testLayoutWithNewerBuildOperatorRoundTripsLosslessly() throws {
        // Simulate the newer build's blob: a valid layout whose JSON carries an unknown op.
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "Bug", field: .upstreamOutput, op: .contains, value: "bug"),
            ConditionRule(label: "Rest", field: .upstreamOutput, op: .isNotEmpty, value: "")
        ]
        let node = WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")
        let layout = WorkflowLayout(nodes: [node], edges: [], annotations: [])
        var json = String(data: try JSONEncoder().encode(layout), encoding: .utf8)!
        json = json.replacingOccurrences(of: "\"contains\"", with: "\"semanticMatch\"")

        // The rollback build decodes it — no throw, nothing lost.
        let decoded = try JSONDecoder().decode(WorkflowLayout.self, from: json.data(using: .utf8)!)
        guard case .condition(let decodedConfig) = decoded.nodes[0].kind else {
            return XCTFail("node kind lost")
        }
        XCTAssertEqual(decodedConfig.rules[0].op, .other("semanticMatch"))

        // …and a re-save on the rollback build hands the newer build its operator back.
        let resaved = try JSONDecoder().decode(WorkflowLayout.self, from: JSONEncoder().encode(decoded))
        guard case .condition(let resavedConfig) = resaved.nodes[0].kind else {
            return XCTFail("node kind lost on re-save")
        }
        XCTAssertEqual(resavedConfig.rules[0].op.rawValue, "semanticMatch",
                       "the older build must not launder the newer build's operator out of the blob")
    }

    /// The validator turns the inert rule into a visible, actionable error — the engine will never
    /// match it, and silence here would be a Router that quietly stopped routing.
    func testValidatorFlagsANewerBuildOperatorAsAnError() {
        var config = ConditionNodeConfig()
        config.rules = [
            ConditionRule(label: "A", field: .upstreamOutput, op: .other("semanticMatch"), value: "x"),
            ConditionRule(label: "B", field: .upstreamOutput, op: .isEmpty, value: "")
        ]
        let node = WorkflowNode(kind: .condition(config), position: .zero, displayName: "Router")
        let sink = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Sink")
        let layout = WorkflowLayout(
            nodes: [node, sink],
            edges: [WorkflowEdge(sourceNodeID: node.id, targetNodeID: sink.id, sourcePortLabel: "A")],
            annotations: []
        )

        let issues = WorkflowValidator.validate(layout: layout, profileMap: [:])

        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("newer version") },
                      "an un-evaluable rule must be a design-time error naming the remedy — got: \(issues.map(\.message))")
    }

    // MARK: - WF-PE4: the kind-decode diagnostic

    /// A MODERN non-profile node whose `kind` fails must surface the TRUE error — not
    /// `keyNotFound(profileID)`, a legacy key with nothing to do with the failure.
    func testUnknownKindOnAModernNodeThrowsTheRealError() {
        let json = """
        {"id":"\(UUID().uuidString)","kind":{"teleport":{}},"positionX":0,"positionY":0,"displayName":"Future Node"}
        """
        do {
            _ = try JSONDecoder().decode(WorkflowNode.self, from: json.data(using: .utf8)!)
            XCTFail("an unknown kind on a modern node must throw — silently guessing a kind would run the wrong graph")
        } catch {
            let description = String(describing: error)
            XCTAssertFalse(description.contains("profileID"),
                           "the diagnostic must name the real failure, not the absent legacy key — got: \(description)")
        }
    }

    /// A LEGACY node (no `kind`, `profileID` present) must still decode via the fallback.
    func testLegacyProfileNodeStillDecodes() throws {
        let pid = UUID()
        let json = """
        {"id":"\(UUID().uuidString)","profileID":"\(pid.uuidString)","profileType":"Bot","positionX":10,"positionY":20,"displayName":"Old Bot"}
        """
        let node = try JSONDecoder().decode(WorkflowNode.self, from: json.data(using: .utf8)!)
        guard case .profile(let decodedID, let type) = node.kind else {
            return XCTFail("legacy node did not reconstruct as a profile node")
        }
        XCTAssertEqual(decodedID, pid)
        XCTAssertEqual(type, .bot)
    }

    // MARK: - WF-TS5: the limit of this guarantee

    /// ⚠️ THIS TEST PINS A LIMITATION, NOT A GUARANTEE — and it is here so the file's own header
    /// cannot drift back into over-claiming. The catch-alls above preserve unknown enum VALUES;
    /// nothing preserves unknown KEYS. `WorkflowNode`, `WorkflowNodeConfig`, `ConditionNodeConfig`,
    /// `WorkflowEdge`, `StickyNote` and `WorkflowLayout` all encode a FIXED `CodingKeys` set, so a
    /// field added by a newer build is invisible to decode and absent from the re-encode.
    ///
    /// What actually protects the user is `WorkflowLayoutSD.layoutBlobVersion` + the write refusal
    /// (WF-PE2), pinned by
    /// `BlobWriteRefusalTests.testNewerVersionBlobKeepsAFutureFieldTheDecoderCannotSee`. That
    /// refusal is keyed on the STAMP, so ANY schema addition — including a purely additive optional
    /// field — MUST bump `layoutBlobVersion` or this drop happens for real.
    ///
    /// ⚠️ If you add an unknown-key sidecar to these Codables, DELETE this test and correct the
    /// header — its failure is good news, not a regression.
    func testUnknownKeysAreNotPreserved_soTheVersionStampIsTheOnlyProtection() throws {
        var node = WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: "Worker")
        node.nodeConfig = WorkflowNodeConfig(maxNodeRetries: 2)
        let encoded = try JSONEncoder().encode(WorkflowLayout(nodes: [node], edges: [], annotations: []))
        let fromTheFuture = String(data: encoded, encoding: .utf8)!
            .replacingOccurrences(of: "\"maxNodeRetries\":",
                                  with: "\"concurrencyLimit\":4,\"maxNodeRetries\":")

        let decoded = try JSONDecoder().decode(WorkflowLayout.self, from: Data(fromTheFuture.utf8))
        XCTAssertEqual(decoded.nodes[0].nodeConfig?.maxNodeRetries, 2,
                       "an unknown key must not break the decode — that is why the loss is silent")

        let reEncoded = String(data: try JSONEncoder().encode(decoded), encoding: .utf8)!
        XCTAssertFalse(reEncoded.contains("concurrencyLimit"),
                       "If this now PASSES a sidecar through, the guarantee has genuinely widened: "
                       + "delete this test and update the file header.")
    }
}
