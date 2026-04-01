//
//  BackendProfileStoreTests.swift
//  DevgenticTests
//
//  Created on 26/03/26.
//
//  Tests BackendProfile round-trip persistence via SwiftData (in-memory container).
//  Validates create, read, update, delete, ProfileDetails encode/decode,
//  schema versioning, and store-level validation.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class BackendProfileStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    /// Creates a minimal valid Tool for testing.
    private func makeTool(name: String, enabled: Bool = true, confirm: Bool = true) -> Tool {
        Tool(
            name: name,
            description: "Test tool: \(name)",
            isEnabled: enabled,
            requiresConfirmation: confirm,
            sourceId: UUID(),
            parameters: ToolParameters(type: "object", properties: [:], required: [])
        )
    }

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: BackendProfile.self, configurations: config)
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    // MARK: - Insert & Fetch

    func testInsertAndFetchBotProfile() throws {
        let profile = BackendProfile(
            displayName: "Test Bot",
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                instructions: "Be helpful."
            ))
        )
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.displayName, "Test Bot")
        XCTAssertEqual(fetched.first?.profileType, .bot)

        if case .bot(let config) = fetched.first?.details {
            XCTAssertEqual(config.llmConfig.modelName, "llama3")
            XCTAssertEqual(config.instructions, "Be helpful.")
        } else {
            XCTFail("Expected bot details")
        }
    }

    func testInsertAndFetchAgentProfile() throws {
        let tools = [makeTool(name: "bash")]
        let profile = BackendProfile(
            displayName: "Test Agent",
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-3", apiKey: "sk-test"),
                architecture: .planAndExecute,
                tools: tools,
                description: "A test agent",
                instructions: "Follow the plan.",
                knowledgeSources: nil
            ))
        )
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.profileType, .agent)

        if case .agent(let config) = fetched.first?.details {
            XCTAssertEqual(config.architecture, .planAndExecute)
            XCTAssertEqual(config.tools.count, 1)
            XCTAssertEqual(config.tools.first?.name, "bash")
            XCTAssertEqual(config.description, "A test agent")
            XCTAssertEqual(config.llmConfig.apiKey, "sk-test")
        } else {
            XCTFail("Expected agent details")
        }
    }

    func testInsertAndFetchImageGenProfile() throws {
        let profile = BackendProfile(
            displayName: "Image Gen",
            details: .imageGen(ImageGenConfig(
                llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "dall-e-3", apiKey: "sk-img"),
                negativePrompt: "blurry",
                defaultAspectRatio: .landscape
            ))
        )
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>())
        XCTAssertEqual(fetched.count, 1)

        if case .imageGen(let config) = fetched.first?.details {
            XCTAssertEqual(config.negativePrompt, "blurry")
            XCTAssertEqual(config.defaultAspectRatio, .landscape)
        } else {
            XCTFail("Expected imageGen details")
        }
    }

    func testInsertAndFetchWorkflowProfile() throws {
        let agentIDs = [UUID(), UUID(), UUID()]
        let profile = BackendProfile(
            displayName: "My Workflow",
            details: .workflow(WorkflowConfig(agentProfileIDs: agentIDs))
        )
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.profileType, .workflow)

        if case .workflow(let config) = fetched.first?.details {
            XCTAssertEqual(config.agentProfileIDs, agentIDs)
        } else {
            XCTFail("Expected workflow details")
        }
    }

    // MARK: - Denormalized Columns

    func testDenormalizedProviderAndModelColumns() throws {
        let profile = BackendProfile(
            displayName: "Bot",
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-3.5-sonnet")
            ))
        )
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>()).first!
        XCTAssertEqual(fetched.providerRaw, ApiProvider.anthropic.rawValue)
        XCTAssertEqual(fetched.modelNameRaw, "claude-3.5-sonnet")
    }

    func testDenormalizedColumnsUpdateOnDetailsChange() throws {
        let profile = BackendProfile(
            displayName: "Bot",
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")
            ))
        )
        context.insert(profile)
        try context.save()

        // Change provider and model
        profile.details = .bot(BotConfig(
            llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "gpt-4o")
        ))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>()).first!
        XCTAssertEqual(fetched.providerRaw, ApiProvider.openAI.rawValue)
        XCTAssertEqual(fetched.modelNameRaw, "gpt-4o")
    }

    func testWorkflowDenormalizedColumnsAreEmpty() throws {
        let profile = BackendProfile(
            displayName: "Workflow",
            details: .workflow(WorkflowConfig(agentProfileIDs: [UUID()]))
        )
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>()).first!
        XCTAssertEqual(fetched.providerRaw, "")
        XCTAssertEqual(fetched.modelNameRaw, "")
    }

    // MARK: - Update

    func testUpdateProfileDisplayName() throws {
        let profile = BackendProfile(
            displayName: "Original",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        context.insert(profile)
        try context.save()

        profile.displayName = "Updated"
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>())
        XCTAssertEqual(fetched.first?.displayName, "Updated")
    }

    func testUpdateProfileDetails() throws {
        let profile = BackendProfile(
            displayName: "Bot",
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                instructions: "V1"
            ))
        )
        context.insert(profile)
        try context.save()

        profile.details = .bot(BotConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            instructions: "V2"
        ))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>())
        if case .bot(let config) = fetched.first?.details {
            XCTAssertEqual(config.instructions, "V2")
        } else {
            XCTFail("Expected bot details")
        }
    }

    // MARK: - Delete

    func testDeleteProfile() throws {
        let profile = BackendProfile(
            displayName: "ToDelete",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        context.insert(profile)
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BackendProfile>()), 1)

        context.delete(profile)
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BackendProfile>()), 0)
    }

    // MARK: - Fetch by ID

    func testFetchByPredicate() throws {
        let target = BackendProfile(
            displayName: "Target",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        let other = BackendProfile(
            displayName: "Other",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "mistral")))
        )
        context.insert(target)
        context.insert(other)
        try context.save()

        let targetID = target.id
        let predicate = #Predicate<BackendProfile> { $0.id == targetID }
        var descriptor = FetchDescriptor<BackendProfile>(predicate: predicate)
        descriptor.fetchLimit = 1
        let results = try context.fetch(descriptor)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.displayName, "Target")
    }

    // MARK: - Snapshot Round-Trip

    func testSnapshotRoundTrip() throws {
        let profile = BackendProfile(
            displayName: "Snapshot Test",
            lastSelected: Date(),
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .google, modelName: "gemini-pro", apiKey: "AIza-test"),
                architecture: .reflexion,
                tools: [makeTool(name: "web_search", confirm: false)],
                description: "Research agent",
                instructions: "Search thoroughly."
            ))
        )
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<BackendProfile>()).first!
        let snapshot = fetched.snapshot()

        XCTAssertEqual(snapshot.id, profile.id)
        XCTAssertEqual(snapshot.displayName, "Snapshot Test")
        XCTAssertEqual(snapshot.profileType, .agent)

        if case .agent(let config) = snapshot.details {
            XCTAssertEqual(config.architecture, .reflexion)
            XCTAssertEqual(config.tools.first?.name, "web_search")
            XCTAssertEqual(config.description, "Research agent")
        } else {
            XCTFail("Expected agent details in snapshot")
        }
    }

    // MARK: - ProfileDetails Encode/Decode Fidelity

    func testProfileDetailsEncodeDecode() throws {
        let cases: [(String, ProfileDetails)] = [
            ("bot", .bot(BotConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
                instructions: "Be concise."
            ))),
            ("agent", .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-3"),
                architecture: .supervisor,
                tools: [makeTool(name: "bash")]
            ))),
            ("workflow", .workflow(WorkflowConfig(agentProfileIDs: [UUID(), UUID()]))),
            ("imageGen", .imageGen(ImageGenConfig(
                llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "dall-e-3"),
                negativePrompt: "ugly",
                defaultAspectRatio: .portrait
            )))
        ]

        for (label, details) in cases {
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(details)
            let decoded = try decoder.decode(ProfileDetails.self, from: data)

            switch (details, decoded) {
            case (.bot, .bot), (.agent, .agent), (.workflow, .workflow), (.imageGen, .imageGen):
                break
            default:
                XCTFail("Round-trip type mismatch for \(label): original=\(details), decoded=\(decoded)")
            }
        }
    }

    // MARK: - Schema Version Stamping

    func testEncodedProfileDetailsContainsSchemaVersion() throws {
        let details = ProfileDetails.bot(BotConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")
        ))
        let data = try JSONEncoder().encode(details)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["schemaVersion"], "Encoded ProfileDetails should contain schemaVersion")
        XCTAssertEqual(json?["schemaVersion"] as? Int, ProfileSchemaVersion.current.rawValue)
    }

    // MARK: - Migration Pipeline

    func testMigratorStampsVersionOnLegacyData() throws {
        // Simulate legacy data (no schemaVersion)
        let legacyJSON: [String: Any] = [
            "profileType": "Bot",
            "llmConfig": [
                "apiProvider": "Ollama (Local)",
                "modelName": "llama3"
            ]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let migrated = ProfileMigrator.migrateIfNeeded(legacyData)
        let migratedJSON = try JSONSerialization.jsonObject(with: migrated) as? [String: Any]

        XCTAssertEqual(migratedJSON?["schemaVersion"] as? Int, 1,
                        "Migrator should stamp schemaVersion=1 on legacy data")
    }

    func testMigratorPreservesCurrentVersionData() throws {
        // Data already at current version should pass through unchanged
        let details = ProfileDetails.bot(BotConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")
        ))
        let data = try JSONEncoder().encode(details)
        let migrated = ProfileMigrator.migrateIfNeeded(data)
        let decoded = try JSONDecoder().decode(ProfileDetails.self, from: migrated)

        if case .bot(let config) = decoded {
            XCTAssertEqual(config.llmConfig.modelName, "llama3")
        } else {
            XCTFail("Expected bot details after migration passthrough")
        }
    }

    // MARK: - Store-Level Strict Validation

    func testInsertWithEmptyModelSucceeds() throws {
        // New profiles use lenient validation — empty model is allowed
        let store = BackendProfileStore.shared
        store.configureContainer(container)

        let snapshot = BackendProfileSnapshot(
            displayName: "New Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "")))
        )
        XCTAssertNoThrow(try store.saveProfile(snapshot), "Insert with empty model should succeed (lenient)")
    }

    func testUpdateWithEmptyModelFailsStrictValidation() throws {
        // First insert (lenient)
        let store = BackendProfileStore.shared
        store.configureContainer(container)

        let snapshot = BackendProfileSnapshot(
            id: UUID(),
            displayName: "Strict Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        try store.saveProfile(snapshot)

        // Now update with empty model (strict) — should fail
        let updated = BackendProfileSnapshot(
            id: snapshot.id,
            displayName: "Strict Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "")))
        )
        XCTAssertThrowsError(try store.saveProfile(updated)) { error in
            guard case ProfileStoreError.validationFailed(let errors) = error else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(errors.contains(where: { $0.field == "modelName" }),
                           "Strict update should reject empty model name")
        }
    }

    func testUpdateWithMissingCloudApiKeyFailsStrictValidation() throws {
        let store = BackendProfileStore.shared
        store.configureContainer(container)

        // Insert with a valid local profile first
        let snapshot = BackendProfileSnapshot(
            id: UUID(),
            displayName: "Cloud Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
        )
        try store.saveProfile(snapshot)

        // Update to cloud provider without API key
        let updated = BackendProfileSnapshot(
            id: snapshot.id,
            displayName: "Cloud Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "gpt-4")))
        )
        XCTAssertThrowsError(try store.saveProfile(updated)) { error in
            guard case ProfileStoreError.validationFailed(let errors) = error else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(errors.contains(where: { $0.field == "apiKey" }),
                           "Strict update should reject missing API key for cloud provider")
        }
    }

    // MARK: - Export Envelope

    func testExportEnvelopeRoundTrip() throws {
        let profiles = [
            BackendProfileSnapshot(
                displayName: "Bot A",
                details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3")))
            )
        ]
        let envelope = ProfileExportEnvelope(
            formatVersion: ProfileExportEnvelope.currentFormatVersion,
            exportedAt: Date(),
            appVersion: "99.0",
            profiles: profiles
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProfileExportEnvelope.self, from: data)

        XCTAssertEqual(decoded.formatVersion, ProfileExportEnvelope.currentFormatVersion)
        XCTAssertEqual(decoded.appVersion, "99.0")
        XCTAssertEqual(decoded.profiles.count, 1)
        XCTAssertEqual(decoded.profiles.first?.displayName, "Bot A")
    }
}
