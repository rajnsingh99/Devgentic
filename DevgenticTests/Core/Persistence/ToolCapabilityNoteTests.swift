// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ToolCapabilityNoteTests.swift
//  devgenticTests
//
//  Covers G95: four model pickers had four different policies for one rule, because the helper that
//  was supposed to be the single source of truth was never adopted — and would have been the wrong
//  thing to adopt anyway, since `isModelDisabled` made a row "visible but not selectable", i.e. a
//  gate.
//
//  `toolCapabilityNote` replaces it. It can only ever produce a STRING, so a capability verdict can
//  no longer reach a picker as anything but text — the type signature is the guarantee, and these
//  tests pin the wording contract that makes the text worth reading.
//

import XCTest
@testable import devgentic

final class ToolCapabilityNoteTests: XCTestCase {

    private func note(
        _ capability: ModelCognitiveCapability,
        _ caveat: ToolSupportCaveat? = nil,
        _ profileType: ProfileType = .agent
    ) -> String? {
        ProfileCapabilityFilter.toolCapabilityNote(
            capability: capability,
            caveat: caveat,
            profileType: profileType
        )
    }

    // MARK: - Wording follows the CAVEAT, not the provider

    /// The whole reason the note takes a caveat: how much a `.none` verdict can be trusted varies
    /// *within* a provider. Ollama produces `.none` from the daemon's capability list (a protocol
    /// fact), from a reasoning-only name match, and from having no capabilities field at all.
    /// Per-provider copy would be wrong for two of those three.
    func testAuthoritativeDenialReadsAsFlatNotHedged() {
        XCTAssertEqual(note(.none, .serverRejectsTools), "🚫 No tools")
    }

    func testUnverifiableDenialIsHedged() {
        XCTAssertEqual(note(.none, .undetected), "⚠︎ Tools unconfirmed")
    }

    /// A caller with no caveat information at all — MLX's name heuristic, OpenRouter's `?? false`
    /// metadata — must get the hedge, never the flat claim.
    func testAbsentCaveatIsHedgedRatherThanAsserted() {
        XCTAssertEqual(note(.none, nil), "⚠︎ Tools unconfirmed")
    }

    func testReasoningFocusedIsNamedForWhatItIs() {
        XCTAssertEqual(note(.none, .reasoningFocused), "⚠️ Reasoning-focused")
    }

    /// A reasoning fine-tune that DOES have tool support is a reliability caveat, not a protocol
    /// one — the server accepts the tools param. It still earns a note.
    func testToolCapableReasoningModelStillGetsItsCaveat() {
        XCTAssertEqual(note(.parallelActions, .reasoningFocused), "⚠️ Reasoning-focused")
        XCTAssertEqual(note(.singleAction, .reasoningFocused), "⚠️ Reasoning-focused")
    }

    // MARK: - Silence when there is nothing to say

    func testAToolCapableModelGetsNoNote() {
        XCTAssertNil(note(.parallelActions))
        XCTAssertNil(note(.singleAction))
        XCTAssertNil(note(.parallelActions, .undetected))
    }

    /// A Bot never dispatches tools, so the note would be pure noise. This is why the helper keeps a
    /// profileType input rather than a capability-only signature.
    func testNonAgentProfilesNeverGetAToolNote() {
        for type in [ProfileType.bot, .imageGen, .workflow, .code] {
            XCTAssertNil(note(.none, .serverRejectsTools, type), "\(type.rawValue) should stay silent")
            XCTAssertNil(note(.none, nil, type), "\(type.rawValue) should stay silent")
        }
    }

    // MARK: - The property that makes this a fix rather than a refactor

    /// ⚠️ The point of G95: a capability verdict may LABEL, never GATE. `toolCapabilityNote` returns
    /// `String?` — there is no Bool for a caller to hang `.disabled(...)` on, and no filter
    /// predicate to drop a row with. If someone reintroduces a boolean here, this test is where the
    /// intent is written down: every verdict, for every profile type, resolves to text or silence.
    func testEveryVerdictResolvesToTextOrSilenceAndNothingElse() {
        let capabilities: [ModelCognitiveCapability] = [.none, .singleAction, .parallelActions]
        let caveats: [ToolSupportCaveat?] = [nil, .serverRejectsTools, .reasoningFocused, .undetected]

        for capability in capabilities {
            for caveat in caveats {
                let result = note(capability, caveat)
                if let result {
                    XCTAssertFalse(
                        result.trimmingCharacters(in: .whitespaces).isEmpty,
                        "A note must say something: \(capability)/\(String(describing: caveat))"
                    )
                }
                // No assertion needed on the nil branch — the absence of any other return type IS
                // the guarantee. This loop exists so the exhaustive sweep is on record.
            }
        }
    }

    /// Agent + `.none` always produces SOME note, whatever the caveat. A silent drop here would put
    /// the user back where G95 started: a model that cannot call tools, presented as if it could.
    func testAnAgentOnAToollessModelIsAlwaysTold() {
        for caveat in [nil, ToolSupportCaveat.serverRejectsTools, .reasoningFocused, .undetected] {
            XCTAssertNotNil(note(.none, caveat), "caveat \(String(describing: caveat)) must produce a note")
        }
    }
}
