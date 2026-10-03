// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileBlobHardeningTests.swift
//  DevgenticTests
//
//  Created on 04/08/26.
//
//  Guards the data-loss class that schema migration cannot see.
//
//  Everything rich in this app is persisted as an opaque JSON blob inside a `Data` column.
//  SwiftData's migration never looks inside one, so a change to a blob type's SHAPE is invisible
//  to every schema check: the store opens perfectly and the damage happens at read time — and
//  then at the next write, when the degraded value is persisted over the original.
//
//  These tests fail on the two specific mechanisms audited as critical:
//    G12 — an undecodable blob was replaced by a blank bot and then saved over the original.
//    G13 — Swift's SYNTHESIZED init(from:) throws keyNotFound for a non-optional property EVEN
//          WHEN IT HAS A DEFAULT, so adding one routine field broke every persisted profile.
//
//  See SWIFTDATA_GAP_REGISTER.md and SWIFTDATA_MIGRATION_PLAN.md.
//

import XCTest
import SwiftData
@testable import devgentic

final class ProfileBlobHardeningTests: XCTestCase {

    // MARK: - G13: synthesized Codable is intolerant of its own defaults

    /// The mechanism itself, pinned. If this ever starts passing with a synthesized decoder,
    /// Swift changed and the hand-written decoders below could be revisited.
    func testSynthesizedCodableThrowsForDefaultedNonOptionalProperty() throws {
        struct Synthesized: Codable {
            var name: String
            var addedLater: Bool = false   // has a default, yet is still required when decoding
        }

        let olderPayload = Data(#"{"name":"x"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(Synthesized.self, from: olderPayload)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("Expected .keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "addedLater",
                           "A default value did NOT rescue the decode — this is the G13 mechanism.")
        }
    }

    /// THE regression test for G13: a `Tool` blob written before a field existed must still
    /// decode. Simulated by decoding a payload that omits every defaulted key — exactly what a
    /// blob written by an older build looks like to a newer one.
    func testToolDecodesFromPayloadMissingEveryDefaultedField() throws {
        let sourceId = UUID()
        let payload = Data("""
        {
          "name": "read_file",
          "sourceId": "\(sourceId.uuidString)",
          "parameters": {}
        }
        """.utf8)

        let tool = try JSONDecoder().decode(Tool.self, from: payload)

        XCTAssertEqual(tool.name, "read_file")
        XCTAssertEqual(tool.sourceId, sourceId)
        XCTAssertEqual(tool.description, "")
        XCTAssertTrue(tool.isEnabled, "isEnabled must fall back to its default, not throw.")
        XCTAssertTrue(tool.requiresConfirmation, "requiresConfirmation must fall back to its default.")
        XCTAssertNil(tool.timeout)
        XCTAssertNil(tool.timeoutMessage)
        XCTAssertFalse(tool.isFavorite)
    }

    /// A genuinely corrupt blob must still fail. Tolerance is for MISSING OPTIONAL-ISH fields, not
    /// a licence to fabricate a tool out of nothing — otherwise real corruption gets laundered
    /// into junk data that looks legitimate.
    func testToolStillRejectsBlobMissingIdentifyingFields() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(Tool.self, from: Data(#"{"description":"orphan"}"#.utf8)),
            "A blob with no name/sourceId/parameters is corrupt and must not decode."
        )
    }

    func testSelfReflectionConfigDecodesFromEmptyObject() throws {
        let config = try JSONDecoder().decode(SelfReflectionConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.maxTrials, 3)
        XCTAssertNil(config.evaluatorProfileID)
    }

    func testKnowledgeSourceToleratesMissingIdAndType() throws {
        let source = try JSONDecoder().decode(
            KnowledgeSource.self, from: Data(#"{"location":"/tmp/notes.md"}"#.utf8)
        )
        XCTAssertEqual(source.location, "/tmp/notes.md")
        XCTAssertEqual(source.type, .file)
    }

    func testKnowledgeSourceStillRejectsMissingLocation() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(KnowledgeSource.self, from: Data(#"{"type":"File"}"#.utf8))
        )
    }

    /// Round-trip: the hand-written decoders must stay compatible with the SYNTHESIZED encoders.
    /// A decoder that reads a shape the encoder never writes is worse than no decoder at all.
    func testToolRoundTripsThroughItsOwnEncoder() throws {
        let original = Tool(
            name: "grep", description: "search", isEnabled: false, requiresConfirmation: false,
            sourceId: UUID(),
            parameters: ToolParameters(type: "object", properties: [:], required: []),
            timeout: 12, timeoutMessage: "slow",
            isFavorite: true
        )
        let decoded = try JSONDecoder().decode(Tool.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    // MARK: - G12: a read failure must never become a write failure

    /// A blob shape this build cannot decode — what an already-persisted profile looks like to a
    /// build whose `ProfileDetails` graph has changed underneath it.
    private static let unreadableBlob = Data(#"{"kind":"agent","payloadFromTheFuture":true}"#.utf8)

    /// Persists a profile carrying `unreadableBlob`, then returns it **re-materialized in a fresh
    /// context**.
    ///
    /// ⚠️ The fresh context is essential, not incidental. `BackendProfile` caches the decoded
    /// value in a `@Transient` set by `init`, so an instance created in-process never re-decodes
    /// and would report itself perfectly healthy. Only a fresh materialization — i.e. an app
    /// launch reading an existing store — exercises the decode path this whole class is about.
    private func makeProfileWithUnreadableBlob(
        in container: ModelContainer
    ) throws -> (profile: BackendProfile, context: ModelContext) {
        let seedContext = ModelContext(container)
        let profile = BackendProfile(
            displayName: "Corrupted",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        seedContext.insert(profile)
        profile.configData = Self.unreadableBlob
        try seedContext.save()

        let freshContext = ModelContext(container)
        let reloaded = try XCTUnwrap(
            try freshContext.fetch(FetchDescriptor<BackendProfile>()).first,
            "Seeded profile did not come back from the store."
        )
        return (reloaded, freshContext)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// The core guarantee. An undecodable blob is presented as a placeholder, but the stored bytes
    /// must survive an opportunistic save — the kind `ToolLibraryContainerView`, `CodeSessionManager`
    /// and `MLXContextWindowHealer` all perform without the user editing anything.
    func testOpportunisticSaveDoesNotOverwriteUnreadableBlob() throws {
        let container = try makeInMemoryContainer()
        let (profile, context) = try makeProfileWithUnreadableBlob(in: container)

        XCTAssertTrue(profile.hasUnreadableConfiguration,
                      "Profile should report its configuration as unreadable.")

        // The opportunistic save: read `details` (getting the placeholder) and write it straight
        // back, which is precisely what `BackendProfileStore.saveProfile` does via `snapshot()`.
        let placeholder = profile.details
        profile.details = placeholder
        try context.save()

        XCTAssertEqual(profile.configData, Self.unreadableBlob,
                       """
                       The unreadable blob was OVERWRITTEN by the placeholder. This is G12: the
                       user's model choice, API key, instructions and enabled-tool list are now
                       permanently gone.
                       """)
    }

    /// The other half: a real user edit must still be able to replace an unreadable blob, or a
    /// corrupted profile would be permanently unfixable from the UI.
    func testDeliberateEditReplacesUnreadableBlob() throws {
        let container = try makeInMemoryContainer()
        let (profile, context) = try makeProfileWithUnreadableBlob(in: container)
        XCTAssertTrue(profile.hasUnreadableConfiguration)

        let repaired = ProfileDetails.bot(
            BotConfig(llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "gpt-4o"))
        )
        profile.details = repaired
        try context.save()

        XCTAssertFalse(profile.hasUnreadableConfiguration, "Flag should clear after a real edit.")
        XCTAssertEqual(profile.details, repaired)
        XCTAssertNotEqual(profile.configData, Self.unreadableBlob, "A real edit must be persisted.")
        XCTAssertEqual(profile.providerRaw, ApiProvider.openAI.rawValue,
                       "Denormalized columns must resync on repair.")
        XCTAssertEqual(profile.modelNameRaw, "gpt-4o")
    }

    /// A profile whose blob decodes normally must be entirely unaffected by the guard — the fix
    /// must not make ordinary saves no-ops.
    func testHealthyProfileStillSavesNormally() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let profile = BackendProfile(
            displayName: "Healthy",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        context.insert(profile)
        try context.save()
        XCTAssertFalse(profile.hasUnreadableConfiguration)

        let updated = ProfileDetails.bot(
            BotConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude"))
        )
        profile.details = updated
        try context.save()

        XCTAssertEqual(profile.details, updated)
        XCTAssertEqual(profile.providerRaw, ApiProvider.anthropic.rawValue)
        XCTAssertEqual(profile.modelNameRaw, "claude")
    }

    /// A healthy profile re-read from the store must also stay healthy — proving the guard keys
    /// off an actual decode failure and not merely off "was this instance freshly fetched".
    func testHealthyProfileSurvivesReMaterialization() throws {
        let container = try makeInMemoryContainer()
        let details = ProfileDetails.bot(
            BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"))
        )

        let seedContext = ModelContext(container)
        seedContext.insert(BackendProfile(displayName: "Healthy", details: details))
        try seedContext.save()

        let freshContext = ModelContext(container)
        let reloaded = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<BackendProfile>()).first)

        XCTAssertFalse(reloaded.hasUnreadableConfiguration)
        XCTAssertEqual(reloaded.details, details)
    }

    // MARK: - Hand-written codecs must cover EVERY field of the type they flatten

    /// ⚠️ THE GENERAL GUARD for `.workflow`. `ProfileDetails` hand-writes each arm instead of
    /// delegating to the payload's synthesized `Codable`, and its `.workflow` arm writes NO payload
    /// fields because `WorkflowConfig` has none. A field added to `WorkflowConfig` would compile,
    /// pass every other test, and silently not persist — `nodeTimeoutEnabled` was lost exactly that
    /// way once. This fails the moment the struct gains a stored property.
    func testWorkflowConfigHasNoStoredFieldsTheCodecWouldDrop() throws {
        XCTAssertTrue(Mirror(reflecting: WorkflowConfig()).children.isEmpty,
                      """
                      WorkflowConfig gained a stored field. Add it to CodingKeys, encode(to:) AND                       init(from:) in ProfileDetails (BackendProfile.swift), then replace this test                       with a round-trip that sets every field.
                      """)
        let data = try JSONEncoder().encode(ProfileDetails.workflow(WorkflowConfig()))
        guard case .workflow = try JSONDecoder().decode(ProfileDetails.self, from: data) else {
            return XCTFail("Expected .workflow")
        }
    }

    /// ⚠️ `.agent` and `.code` carry the SAME `AgentConfig` but have SEPARATE encode/decode arms, so
    /// they can drift — and they had. The `.code` arm dropped `description`, `knowledgeSources`,
    /// `retryPolicy`, `errorRecovery`, `resilienceOverrides` and `skillConfig`, while its own comment
    /// claimed it decoded "identically to .agent plus projectPath".
    ///
    /// ⚠️ Scope, stated honestly: today the loss is MASKED. `AgentConnect` reads resilience under
    /// `if case .agent(…) = profile.details` (AgentConnect.swift:425) and sends `.code` down an
    /// `else` that hardcodes `ErrorRecovery()`, so the dropped value is not consulted for code
    /// profiles. This test guards the trap rather than a live symptom: the moment that guard is
    /// widened to include `.code`, or a Code-mode settings UI exposes the policy, the loss becomes
    /// real — and by then the cause would be several commits away from the symptom.
    func testCodeProfileRoundTripsEverySettingAgentDoes() throws {
        let config = AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5"),
            tools: [],
            description: "code session",
            instructions: "be careful",
            knowledgeSources: [KnowledgeSource(type: .file, location: "/tmp/notes.md")],
            maxIterations: 20,
            executionTimeout: 300,
            retryPolicy: RetryPolicy(maxRetries: 3, backoffStrategy: .exponential),
            errorRecovery: ErrorRecovery(onToolFailure: .fallbackPrompt,
                                        onIterationExhaustion: .synthesizeBestEffort),
            capabilities: AgentCapabilities(),
            historyStrategy: .pointer,
            projectPath: "/tmp/project"
        )

        let data = try JSONEncoder().encode(ProfileDetails.code(config))
        guard case .code(let out) = try JSONDecoder().decode(ProfileDetails.self, from: data) else {
            return XCTFail("Expected .code")
        }

        // The specific one that changes BEHAVIOUR, called out so a failure is self-explaining.
        XCTAssertEqual(out.errorRecovery?.onToolFailure, .fallbackPrompt,
                       "onToolFailure fell back to .abort — the stored profile no longer says what "
                       + "CodeSessionManager configured.")
        XCTAssertEqual(out.retryPolicy?.maxRetries, 3)
        XCTAssertEqual(out.knowledgeSources?.count, 1)
        XCTAssertEqual(out.description, "code session")
        XCTAssertEqual(out.projectPath, "/tmp/project", "projectPath is the one field .code adds.")

        XCTAssertEqual(out, config,
                       """
                       A .code profile lost a setting on round-trip. `.code` and `.agent` share \
                       AgentConfig but have separate encode/decode arms — keep them in lockstep.
                       """)
    }

    /// The `.agent` counterpart, so a drift in EITHER direction is caught.
    /// ⚠️ `projectPath` is deliberately excluded from `.agent` (it is code-mode-only metadata), so
    /// it is left nil here rather than asserted — that omission is intentional, not a bug.
    func testAgentProfileRoundTripsEverySetting() throws {
        let config = AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "gpt-5"),
            tools: [],
            description: "agent",
            instructions: "instructions",
            knowledgeSources: [KnowledgeSource(type: .file, location: "/tmp/kb.md")],
            maxIterations: 12,
            executionTimeout: 120,
            retryPolicy: RetryPolicy(maxRetries: 5, backoffStrategy: .fixed),
            errorRecovery: ErrorRecovery(onToolFailure: .fallbackPrompt,
                                        onIterationExhaustion: .synthesizeBestEffort),
            capabilities: AgentCapabilities(),
            historyStrategy: .pointer
        )

        let data = try JSONEncoder().encode(ProfileDetails.agent(config))
        guard case .agent(let out) = try JSONDecoder().decode(ProfileDetails.self, from: data) else {
            return XCTFail("Expected .agent")
        }
        XCTAssertEqual(out, config, "An AgentConfig field did not survive the .agent arm.")
    }

    /// `.bot` and `.imageGen` complete the set, so every arm of the hand-written codec is pinned.
    func testBotAndImageGenRoundTripEverySetting() throws {
        let bot = BotConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            instructions: "be brief",
            knowledgeSources: [KnowledgeSource(type: .file, location: "/tmp/a.md")]
        )
        let botData = try JSONEncoder().encode(ProfileDetails.bot(bot))
        guard case .bot(let botOut) = try JSONDecoder().decode(ProfileDetails.self, from: botData) else {
            return XCTFail("Expected .bot")
        }
        XCTAssertEqual(botOut, bot)

        let image = ImageGenConfig(
            llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "gpt-image-1"),
            negativePrompt: "blurry",
            defaultAspectRatio: .square,
            advancedSettings: ["steps": .number(30)]
        )
        let imageData = try JSONEncoder().encode(ProfileDetails.imageGen(image))
        guard case .imageGen(let imageOut) = try JSONDecoder().decode(ProfileDetails.self, from: imageData) else {
            return XCTFail("Expected .imageGen")
        }
        XCTAssertEqual(imageOut, image)
    }
}
