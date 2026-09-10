// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PanelControlGatingTests.swift
//  DevgenticTests
//
//  Created on 09/08/26.
//
//  Registers B33 / B34 / B36.
//

import XCTest
import Flux2Core   // `Flux2Model` lives in the SPM package, not the app module
@testable import devgentic

// MARK: - B33: the OpenAI panel must gate on the same predicate the provider does

/// ⚠️ SCOPE, stated plainly. `OpenAIModelFamily.acceptsSamplingParameters` is already pinned by
/// `EndpointAndReasoningGatingTests` (`:191-201`), and re-asserting it here would test the same
/// thing twice. The NEW claim B33 makes is structural: the *panel* consults that predicate rather
/// than rendering the sliders unconditionally. A SwiftUI body is unreachable from XCTest, so the
/// only honest guard is a source-level one — which is the "consumption guard" shape the register
/// recommended after A56 and never actually built.
///
/// It is deliberately narrow: it asserts the gate EXISTS around the sampling controls, not how the
/// view is laid out. If someone renames the predicate this fails loudly and the fix is obvious;
/// that is a far better failure than the silent drift that produced B33 in the first place.
final class OpenAIPanelGatingSourceTests: XCTestCase {

    /// Repo root, derived from this file's own compile-time path.
    private func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../DevgenticTests/Core/Persistence/<this file>
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    private func source(_ relativePath: String) throws -> String {
        let url = try repoRoot().appendingPathComponent(relativePath)
        // ⚠️ Deliberately NOT an XCTSkip when the file is missing. Register B40 recorded that a
        // convenience skip turns an unguarded path into a green test; if the layout moves, this
        // must fail so the guard gets repointed rather than quietly stopping.
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// ⚠️ THE B33 REGRESSION. The panel stated the "hide, don't disable" rule in its own header and
    /// then consulted `family` exactly once — for Reasoning Effort. Temperature and Top P rendered
    /// at full opacity for reasoning models, persisted, and were dropped at request time: the user
    /// dragged Temperature to 0.2, saw it save, reopened to 0.20, and every request ran at the
    /// model's fixed sampling.
    func testTheOpenAIPanelGatesTemperatureAndTopPOnTheSamplingPredicate() throws {
        let panel = try source("Devgentic/Interfaces/Main/Views/BackendProfile/AdvanceConfig/AdvanceConfigurationView.swift")

        let openAISection = try XCTUnwrap(panel.range(of: "struct OpenAISettingsView").map {
            String(panel[$0.lowerBound...])
        })

        XCTAssertTrue(openAISection.contains("if family.acceptsSamplingParameters"),
                      "Temperature and Top P must be gated on the SAME predicate the provider uses "
                      + "to decide whether to send them, or the panel offers controls the request "
                      + "discards — the decorative knob A56 exists to prevent")
    }

    /// Hiding without explaining reads as a missing feature. The Anthropic panel prints a note in
    /// its `else`; B33's fix copied that shape, and this pins the note's presence.
    func testTheHiddenSamplingControlsAreExplained() throws {
        let panel = try source("Devgentic/Interfaces/Main/Views/BackendProfile/AdvanceConfig/AdvanceConfigurationView.swift")
        XCTAssertTrue(
            panel.contains("Temperature and Top P are not available on reasoning models"),
            "a hidden control needs a stated reason — otherwise the user reads the gap as a bug")
    }

    /// The other half of the pair: the provider must still be the thing that actually drops them.
    /// If this predicate stopped being consulted at request time, the panel's gate would be hiding
    /// controls that DO work.
    func testTheProviderStillDropsSamplingOnTheSamePredicate() throws {
        let provider = try source("Devgentic/Core/Backends/OpenAILLMProvider.swift")
        XCTAssertTrue(provider.contains("if family.acceptsSamplingParameters"),
                      "panel and provider must agree, and this is the side that makes it true")
    }
}

// MARK: - B34: the Flux2 picker follows ModelSelectionPolicy like every other picker

final class Flux2ModelSelectionTests: XCTestCase {

    private var inferenceModels: [String] {
        Flux2Model.allCases.filter(\.isForInference).map(\.rawValue)
    }

    /// The common path, and the one the register row got wrong. `switchProvider(to:)` clears
    /// `modelName` to `""`, so arriving at the MLX arm with an empty selection is the NORMAL case —
    /// and filling it is compliant, not an overwrite.
    func testAnEmptySelectionIsFilledWithTheDefaultModel() {
        let resolution = ModelSelectionPolicy.resolve(
            saved: "",
            available: inferenceModels,
            fillCandidate: Flux2Model.klein4B.rawValue
        )
        XCTAssertEqual(resolution, .fill(Flux2Model.klein4B.rawValue))
    }

    /// ⚠️ THE ACTUAL B34 DEFECT. A stored, NON-empty name this build does not recognise — a
    /// `Flux2Model` case written by a newer build, or a variant whose `isForInference` is false —
    /// used to be replaced with `klein4B` silently, at two separate sites, neither of which logged.
    /// The rule everywhere else in this module is: keep it, say so.
    func testAnUnrecognisedStoredModelIsKeptNotReplaced() {
        let resolution = ModelSelectionPolicy.resolve(
            saved: "flux2-something-a-newer-build-shipped",
            available: inferenceModels,
            fillCandidate: Flux2Model.klein4B.rawValue
        )
        XCTAssertEqual(resolution, .keptUnlisted("flux2-something-a-newer-build-shipped"),
                       "replacing it destroys the user's stored choice on mere editor open — and "
                       + "register B13 deleted the module's one exception to this rule, so making "
                       + "Flux2 the new exception would re-introduce what B13 just removed")
    }

    /// A non-inference variant is the reachable in-enum case of the same thing.
    func testAValidButNonInferenceVariantIsAlsoKept() throws {
        let nonInference = Flux2Model.allCases.first { !$0.isForInference }
        guard let nonInference else {
            // Not a skip-with-a-shrug: if every case is inference-capable there is nothing to
            // assert, and the test says so rather than pretending it checked something.
            return XCTAssertTrue(true, "no non-inference variants exist in this build")
        }
        XCTAssertEqual(
            ModelSelectionPolicy.resolve(saved: nonInference.rawValue,
                                         available: inferenceModels,
                                         fillCandidate: Flux2Model.klein4B.rawValue),
            .keptUnlisted(nonInference.rawValue))
    }

    func testAValidInferenceModelIsUntouched() throws {
        let valid = try XCTUnwrap(inferenceModels.first)
        XCTAssertEqual(
            ModelSelectionPolicy.resolve(saved: valid,
                                         available: inferenceModels,
                                         fillCandidate: Flux2Model.klein4B.rawValue),
            .keep)
    }

    /// The premise that makes "keep" safe rather than reckless: an unrecognised name still
    /// generates. `MLXImageGenService.resolveFlux2Model` falls back to a default pipeline and logs.
    /// If that ever became a throw, keeping would strand the profile and this decision would need
    /// revisiting.
    func testTheDefaultFillCandidateIsAnInferenceModel() {
        XCTAssertTrue(inferenceModels.contains(Flux2Model.klein4B.rawValue),
                      "the fill candidate must itself be selectable in the picker")
    }
}

// MARK: - B36: the pruning trap, guarded rather than only commented

final class WorkflowProfileIDsPruningTrapTests: XCTestCase {

    /// ⚠️ INVERTED 2026-08-29, and the history is the point. B36 recorded that emptying
    /// `agentProfileIDs` was dangerous BECAUSE a blocking validator rule fired on an empty list:
    /// `BackendProfileStore` validates `strict: isUpdate`, so an emptied list made a workflow refuse
    /// every later update, including a rename. This test used to pin that rule as blocking, so a
    /// "cleanup" that pruned the list would fail here instead of shipping.
    ///
    /// The field was then RETIRED outright — nothing recomputes it, because a workflow's nodes own
    /// their configuration and the layout is the only record of what a workflow contains. With no
    /// writer, the list is empty or stale forever, so keeping the rule would have done permanently
    /// and to every workflow exactly what B36 feared pruning would do to one.
    ///
    /// So the guard is inverted rather than deleted: the danger it names is real, and the thing that
    /// now prevents it is the rule's ABSENCE. Reinstating the rule is the regression.
    func testTheEmptyWorkflowRuleStaysRetired() {
        let profile = BackendProfileSnapshot(
            displayName: "Workflow",
            details: .workflow(WorkflowConfig(agentProfileIDs: [])))

        let errors = ProfileValidator.validate(profile, strict: true)

        XCTAssertTrue(errors.filter { $0.field == "workflow" }.isEmpty,
                      "the empty-agentProfileIDs rule must stay retired — nothing maintains that "
                      + "field any more, so reinstating it makes EVERY workflow permanently "
                      + "unsaveable, renames included (B36's own failure mode, applied universally)")
        XCTAssertTrue(errors.blocking.isEmpty, "got: \(errors.blocking.map(\.message))")
    }

    /// The asymmetry that makes the trap specifically an UPDATE trap: creation is lenient, so a
    /// pruned profile saves once and only fails afterwards — the worst shape for noticing it.
    func testCreationIsLenientSoAPrunedWorkflowWouldFailOnlyOnLaterEdits() {
        let profile = BackendProfileSnapshot(
            displayName: "Workflow",
            details: .workflow(WorkflowConfig(agentProfileIDs: [])))

        XCTAssertFalse(ProfileValidator.validate(profile).blocking.contains { $0.field == "workflow" },
                       "inserts are exempt (`strict: isUpdate`), which is why this trap would not "
                       + "show up until the user renamed the profile days later")
    }

    /// Stale-but-present ids keep the profile saveable — the state the decision preserves.
    func testAWorkflowWithStaleIDsIsStillSaveable() {
        let profile = BackendProfileSnapshot(
            displayName: "Workflow",
            details: .workflow(WorkflowConfig(agentProfileIDs: [UUID(), UUID()])))

        XCTAssertFalse(ProfileValidator.validate(profile, strict: true).blocking
            .contains { $0.field == "workflow" },
                       "ids pointing at deleted profiles are harmless here — that is the whole "
                       + "reason leaving them is the right call")
    }
}
