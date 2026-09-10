// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  CodeProfileConfigDeliveryTests.swift
//  DevgenticTests
//
//  Created on 09/08/26.
//
//  Registers B44 / B45 / B46 — the three "the fix landed on one site and left a sibling" findings.
//
//  ⚠️ The B44 half is the one that carries weight, and it is deliberately written against the
//  SHARED accessor rather than against `AgentConnect`. Register B37 recorded what happens
//  otherwise: `ExecutionTimeoutExtractionTests` grew a private copy of the production switch, so
//  reverting the production one left all five tests green. A test that re-implements the rule it is
//  guarding guards nothing. `ProfileDetails.agentConfig` is now the single definition, so asserting
//  on it is asserting on what ships.
//

import XCTest
@testable import devgentic

// MARK: - B44: `.code` carries an AgentConfig and must be treated as one

final class ProfileDetailsAgentConfigTests: XCTestCase {

    /// The values `CodeSessionManager` actually builds a session with. Kept in one place so a test
    /// below can assert the DIFFERENCE from the defaults, which is the whole finding.
    private func codeSessionConfig() -> AgentConfig {
        AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5"),
            tools: [],
            maxIterations: 20,
            executionTimeout: 300,
            retryPolicy: RetryPolicy(maxRetries: 3, backoffStrategy: .exponential),
            errorRecovery: ErrorRecovery(
                onToolFailure: .fallbackPrompt,
                onIterationExhaustion: .synthesizeBestEffort
            ),
            capabilities: AgentCapabilities(),
            historyStrategy: .pointer
        )
    }

    private func agentConfig() -> AgentConfig {
        AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5"),
            tools: [],
            executionTimeout: 120,
            errorRecovery: ErrorRecovery(onToolFailure: .skipAndContinue),
            capabilities: AgentCapabilities(),
            historyStrategy: .recentHistory
        )
    }

    // MARK: The accessor itself

    func testAgentAndCodeBothCarryTheirConfig() {
        XCTAssertNotNil(ProfileDetails.agent(agentConfig()).agentConfig)
        XCTAssertNotNil(ProfileDetails.code(codeSessionConfig()).agentConfig,
                        "`.code` reuses AgentConfig — treating it as configuration-less is B44")
    }

    func testTypesWithoutAnAgentConfigReturnNil() {
        let llm = ProviderConfig(apiProvider: .ollama, modelName: "llama3")
        XCTAssertNil(ProfileDetails.bot(BotConfig(llmConfig: llm)).agentConfig)
        XCTAssertNil(ProfileDetails.workflow(WorkflowConfig(agentProfileIDs: [])).agentConfig)
        XCTAssertNil(ProfileDetails.imageGen(ImageGenConfig(llmConfig: llm)).agentConfig)
    }

    // MARK: The derived settings — one test per value that was being dropped

    /// ⚠️ THE B44 REGRESSION, and the one with real user harm. `CodeSessionManager` configures
    /// `onToolFailure: .fallbackPrompt`; `ErrorRecovery()`'s default is `.abort`. `.code` fell into
    /// an `else` arm that substituted the default, so **every Code-mode tool failure aborted the
    /// run** instead of routing to the fallback prompt — silently, because an `else` logs nothing.
    func testCodeKeepsItsConfiguredToolFailurePolicy() {
        let details = ProfileDetails.code(codeSessionConfig())

        XCTAssertEqual(details.errorRecovery.onToolFailure, .fallbackPrompt)
        XCTAssertNotEqual(details.errorRecovery.onToolFailure, ErrorRecovery().onToolFailure,
                          "precondition: the configured value differs from the default, which is "
                          + "exactly why substituting the default was a defect and not a no-op")
    }

    /// The second live drop: Code sessions are built `.pointer` precisely so history images are not
    /// resent, and the `else` arm handed them `.recentHistory`.
    func testCodeKeepsItsConfiguredHistoryStrategy() {
        XCTAssertEqual(ProfileDetails.code(codeSessionConfig()).historyStrategy, .pointer)
        XCTAssertNotEqual(ProfileDetails.code(codeSessionConfig()).historyStrategy, .recentHistory)
    }

    /// Register A7's original finding, now derived from the shared accessor rather than restated.
    func testCodeKeepsItsExecutionTimeout() {
        XCTAssertEqual(ProfileDetails.code(codeSessionConfig()).executionTimeout, 300)
        XCTAssertEqual(ProfileDetails.agent(agentConfig()).executionTimeout, 120)
    }

    func testCodeKeepsItsRetryPolicy() {
        XCTAssertEqual(ProfileDetails.code(codeSessionConfig()).retryPolicy.maxRetries, 3)
    }

    /// ⚠️ The fallbacks must still apply to an agent profile that simply has not set the field —
    /// "unset on a profile that HAS an AgentConfig" and "this type has no AgentConfig" are
    /// different questions, and collapsing them is what the old `else` arm did.
    func testUnsetFieldsOnAnAgentStillFallBackToDefaults() {
        let bare = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                               tools: [], capabilities: AgentCapabilities())
        let details = ProfileDetails.agent(bare)

        XCTAssertEqual(details.errorRecovery.onToolFailure, ErrorRecovery().onToolFailure)
        XCTAssertEqual(details.historyStrategy, .recentHistory)
        XCTAssertNil(details.executionTimeout)
        XCTAssertNil(details.resilienceOverrides)
    }

    /// Non-agent types keep the defaults they always had — the fix must not change bot behaviour.
    func testNonAgentTypesStillGetTheDefaults() {
        let details = ProfileDetails.bot(BotConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))

        XCTAssertEqual(details.errorRecovery.onToolFailure, ErrorRecovery().onToolFailure)
        XCTAssertEqual(details.historyStrategy, .recentHistory)
        XCTAssertNil(details.executionTimeout)
        XCTAssertNil(details.agentCapabilities)
    }
}

// MARK: - B45: opening an ImageGen profile must not write to the draft

@MainActor
final class ImageGenAdvancedConfigBaselineTests: XCTestCase {

    private var service: BackendProfileService!

    override func setUp() {
        super.setUp()
        service = BackendProfileService(store: NoopStore())
    }

    private final class NoopStore: BackendProfileStoreProtocol {
        func fetchProfiles() throws -> [BackendProfileSnapshot] { [] }
        func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? { nil }
        func saveProfile(_ snapshot: BackendProfileSnapshot,
                         callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] { [] }
        func deleteProfile(withId id: UUID) throws {}
    }

    /// ⚠️ SCOPE, stated plainly. `ImageGenConfigDetailView`'s `.task` → `.onChange` wiring is a
    /// SwiftUI body and is not reachable from XCTest. What IS assertable is the PREMISE the fix
    /// rests on: that `encode(load(...))` is stable, so the baseline recorded at load compares
    /// equal to the encode performed on the deferred `.onChange` pass. If that premise failed, the
    /// guard would fail open and write on every profile open — which is the defect itself.
    func testEncodingAFreshlyLoadedDefaultMatchesItsOwnBaseline() {
        let loaded = service.decodeConfig(from: nil, as: ImageGenAdvancedConfig.self)
            ?? ImageGenAdvancedConfig.default()
        let baseline = service.encodeConfig(from: ImageGenAdvancedConfig.default())

        XCTAssertEqual(service.encodeConfig(from: loaded), baseline,
                       "a profile with no stored advanced config must produce the baseline it was "
                       + "loaded from — otherwise opening it writes, and the buffer goes dirty")
    }

    /// The MLX arm is the one that actually differed: `.mlxDefault()` is loaded over a `.default()`
    /// `@State` seed, so `localAdvancedConfig` genuinely CHANGES on open and `.onChange` genuinely
    /// fires. Only the baseline comparison stops it writing.
    func testTheMLXDefaultDiffersFromThePlainDefaultAndStillMatchesItsBaseline() {
        let mlx = ImageGenAdvancedConfig.mlxDefault()
        let plain = ImageGenAdvancedConfig.default()
        XCTAssertNotEqual(service.encodeConfig(from: mlx), service.encodeConfig(from: plain),
                          "precondition: if these were equal, `.onChange` would never fire on an "
                          + "MLX open and the phantom-dirty half of B45 could not happen")

        let loaded = service.decodeConfig(from: nil, as: ImageGenAdvancedConfig.self) ?? mlx
        XCTAssertEqual(service.encodeConfig(from: loaded), service.encodeConfig(from: mlx))
    }

    /// ⚠️ THE HALF WITH DATA LOSS — and it is **not** the shape B45 was originally filed as.
    ///
    /// I filed it as "an undecodable blob returns nil, `?? defaultConfig` substitutes app defaults,
    /// and the write puts those defaults into the draft". This test's first assertion disproved
    /// that: register A69 gave `ImageGenAdvancedConfig` a tolerant per-field decoder, so any
    /// well-formed JSON object decodes — the `?? defaultConfig` arm is effectively unreachable now.
    ///
    /// The live defect is the A69 interaction instead, and it costs more. A blob carrying anything
    /// the struct cannot model — a `steps` written as a string by another build, an unrecognised
    /// quality tier, a key added by a NEWER build — decodes LOSSILY, and the unguarded write-back
    /// then persisted that lossy version over the stored blob on mere open. Opening a profile to
    /// look at it silently normalised away every value this build could not parse. Same shape as
    /// register B26: A69 made a decoder tolerant, and a downstream consumer's assumption about what
    /// nil meant quietly stopped holding.
    func testALossilyDecodedBlobIsNotWrittenBackOverTheStoredOne() {
        let stored: [String: JSONValue] = [
            "quality": .string("standard"),
            "steps": .string("28"),          // wrong type — tolerated, and dropped
            "futureKey": .number(7),         // written by a newer build — not modelled at all
        ]

        let decoded = service.decodeConfig(from: stored, as: ImageGenAdvancedConfig.self)
        XCTAssertNotNil(decoded, "A69's tolerant decoder means this does NOT fail — that is the point")
        XCTAssertNil(decoded?.steps, "the mistyped value is dropped, i.e. the decode is lossy")

        let reEncoded = service.encodeConfig(from: decoded!)
        XCTAssertNotEqual(reEncoded, stored,
                          "precondition: writing this back would LOSE `futureKey` and `steps` — "
                          + "which is exactly what opening the profile used to do")

        // The fix: the baseline recorded at load is this same re-encode, so the deferred
        // `.onChange` compares equal and writes nothing.
        XCTAssertEqual(service.encodeConfig(from: decoded!), reEncoded,
                       "the baseline must match what a no-op open would produce, or the stored "
                       + "blob is overwritten with a lossy copy of itself")
    }

    /// A real edit must still write — a guard that suppresses everything is not a fix.
    func testAGenuineEditDiffersFromTheBaseline() {
        var edited = ImageGenAdvancedConfig.default()
        edited.steps = (edited.steps ?? 0) + 7

        XCTAssertNotEqual(service.encodeConfig(from: edited),
                          service.encodeConfig(from: ImageGenAdvancedConfig.default()))
    }
}

// MARK: - B46: the exit flush actually reaches the floating editor

@MainActor
final class PendingPromptFlushTests: XCTestCase {

    private final class NoopStore: BackendProfileStoreProtocol {
        func fetchProfiles() throws -> [BackendProfileSnapshot] { [] }
        func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? { nil }
        func saveProfile(_ snapshot: BackendProfileSnapshot,
                         callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] { [] }
        func deleteProfile(withId id: UUID) throws {}
    }

    /// The hook fires. Trivial on its own — it earns its place because the DEFECT was that nothing
    /// called `flushPendingEditorText` at a navigation exit, so the hook was correct and unreached.
    func testFlushInvokesTheRegisteredCommitHook() {
        let service = BackendProfileService(store: NoopStore())
        var commits = 0
        service.commitPendingPromptEdits = { commits += 1 }

        service.flushPendingEditorText()

        XCTAssertEqual(commits, 1)
    }

    /// ⚠️ THE ORDERING THAT MATTERS. A flush must make pending text VISIBLE to the dirty check that
    /// follows it — that is the whole reason the call has to come first. Here the hook writes into
    /// the draft exactly as the real editor's commit does, and the buffer is clean until it runs.
    func testFlushMakesPendingTextVisibleToTheDirtyCheck() {
        let service = BackendProfileService(store: NoopStore())
        let profile = BackendProfileSnapshot(
            displayName: "Agent",
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                tools: [], instructions: "old", capabilities: AgentCapabilities())))
        service.editBuffer = ProfileEditBuffer(profile: profile)

        XCTAssertFalse(service.hasUnsavedEditorChanges,
                       "precondition: the buffer is clean while the text sits in the editor's @State")

        service.commitPendingPromptEdits = { [weak service] in
            guard let buffer = service?.editBuffer,
                  case .agent(var config) = buffer.draft.details else { return }
            config.instructions = "two thousand characters the user just typed"
            buffer.draft.details = .agent(config)
        }
        service.flushPendingEditorText()

        XCTAssertTrue(service.hasUnsavedEditorChanges,
                      "after the flush the exit guard must see the work — reading the dirty state "
                      + "BEFORE the flush is what let a back tap discard it with no prompt")
    }

    /// No editor on screen means no hook, and flushing must be a harmless no-op — it is now called
    /// from three editors and the sidebar, most of which register nothing.
    func testFlushIsSafeWithNoRegisteredHook() {
        let service = BackendProfileService(store: NoopStore())
        service.flushPendingEditorText()
        XCTAssertFalse(service.hasUnsavedEditorChanges)
    }
}
