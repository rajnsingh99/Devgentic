//
//  ProfileValidatorTests.swift
//  DevgenticTests
//
//  Created on 26/03/26.
//
//  Unit tests for ProfileValidator — validates BackendProfileSnapshot before save.
//

import XCTest
@testable import devgentic

final class ProfileValidatorTests: XCTestCase {

    // MARK: - Display Name Validation (always enforced, even in lenient mode)

    func testEmptyNameFails() {
        let profile = makeBot(name: "", modelName: "llama3", provider: .ollama)
        let errors = ProfileValidator.validate(profile)
        XCTAssertTrue(errors.contains(where: { $0.field == "displayName" }),
                       "Expected validation error for empty display name")
    }

    func testWhitespaceOnlyNameFails() {
        let profile = makeBot(name: "   ", modelName: "llama3", provider: .ollama)
        let errors = ProfileValidator.validate(profile)
        XCTAssertTrue(errors.contains(where: { $0.field == "displayName" }))
    }

    func testValidNamePasses() {
        let profile = makeBot(name: "My Bot", modelName: "llama3", provider: .ollama)
        let errors = ProfileValidator.validate(profile)
        XCTAssertFalse(errors.contains(where: { $0.field == "displayName" }))
    }

    func testNameExceedingMaxLengthFails() {
        let longName = String(repeating: "A", count: ProfileValidationLimits.maxDisplayNameLength + 1)
        let profile = makeBot(name: longName, modelName: "llama3", provider: .ollama)
        let errors = ProfileValidator.validate(profile)
        XCTAssertTrue(errors.contains(where: { $0.field == "displayName" && $0.message.contains("characters") }),
                       "Expected validation error for name exceeding max length")
    }

    func testNameAtMaxLengthPasses() {
        let maxName = String(repeating: "A", count: ProfileValidationLimits.maxDisplayNameLength)
        let profile = makeBot(name: maxName, modelName: "llama3", provider: .ollama)
        let errors = ProfileValidator.validate(profile)
        XCTAssertFalse(errors.contains(where: { $0.field == "displayName" && $0.message.contains("characters") }))
    }

    // MARK: - Model Name Validation (strict mode only)

    func testEmptyModelNameFailsInStrictMode() {
        let profile = makeBot(name: "Bot", modelName: "", provider: .ollama)
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.contains(where: { $0.field == "modelName" }),
                       "Expected validation error for empty model name in strict mode")
    }

    func testEmptyModelNamePassesInLenientMode() {
        let profile = makeBot(name: "Bot", modelName: "", provider: .ollama)
        let errors = ProfileValidator.validate(profile)
        XCTAssertFalse(errors.contains(where: { $0.field == "modelName" }),
                        "Empty model name should pass in lenient mode (initial creation)")
    }

    func testValidModelNamePasses() {
        let profile = makeBot(name: "Bot", modelName: "llama3:8b", provider: .ollama)
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertFalse(errors.contains(where: { $0.field == "modelName" }))
    }

    // MARK: - API Key Validation (strict mode only — Cloud Providers)

    func testMissingApiKeyForOpenAIFailsInStrictMode() {
        let profile = makeBot(name: "Bot", modelName: "gpt-4", provider: .openAI, apiKey: nil)
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.contains(where: { $0.field == "apiKey" }),
                       "Expected validation error for missing OpenAI API key in strict mode")
    }

    func testMissingApiKeyForAnthropicFailsInStrictMode() {
        let profile = makeBot(name: "Bot", modelName: "claude-3", provider: .anthropic, apiKey: nil)
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.contains(where: { $0.field == "apiKey" }))
    }

    func testMissingApiKeyForGoogleFailsInStrictMode() {
        let profile = makeBot(name: "Bot", modelName: "gemini-pro", provider: .google, apiKey: nil)
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.contains(where: { $0.field == "apiKey" }))
    }

    func testEmptyApiKeyForCloudProviderFailsInStrictMode() {
        let profile = makeBot(name: "Bot", modelName: "gpt-4", provider: .openAI, apiKey: "  ")
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.contains(where: { $0.field == "apiKey" }),
                       "Whitespace-only API key should fail validation in strict mode")
    }

    func testMissingApiKeyPassesInLenientMode() {
        let profile = makeBot(name: "Bot", modelName: "gpt-4", provider: .openAI, apiKey: nil)
        let errors = ProfileValidator.validate(profile)
        XCTAssertFalse(errors.contains(where: { $0.field == "apiKey" }),
                        "Missing API key should pass in lenient mode (initial creation)")
    }

    func testValidApiKeyForCloudProviderPasses() {
        let profile = makeBot(name: "Bot", modelName: "gpt-4", provider: .openAI, apiKey: "sk-abc123")
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertFalse(errors.contains(where: { $0.field == "apiKey" }))
    }

    func testOllamaWithoutApiKeyPasses() {
        let profile = makeBot(name: "Bot", modelName: "llama3", provider: .ollama, apiKey: nil)
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertFalse(errors.contains(where: { $0.field == "apiKey" }),
                        "Local providers should not require API keys")
    }

    func testMLXWithoutApiKeyPasses() {
        let profile = makeBot(name: "Bot", modelName: "phi-3", provider: .mlx, apiKey: nil)
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertFalse(errors.contains(where: { $0.field == "apiKey" }))
    }

    // MARK: - Base URL Validation (strict mode only)

    func testInvalidBaseURLFailsInStrictMode() {
        let profile = makeBot(name: "Bot", modelName: "llama3", provider: .ollama, baseURL: "ht tp://invalid url with spaces")
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.contains(where: { $0.field == "baseURL" }),
                       "Invalid base URL should fail validation in strict mode")
    }

    func testValidBaseURLPasses() {
        let profile = makeBot(name: "Bot", modelName: "llama3", provider: .ollama, baseURL: "http://localhost:11434")
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertFalse(errors.contains(where: { $0.field == "baseURL" }))
    }

    func testEmptyBaseURLPasses() {
        let profile = makeBot(name: "Bot", modelName: "llama3", provider: .ollama, baseURL: nil)
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertFalse(errors.contains(where: { $0.field == "baseURL" }),
                        "Nil base URL should pass (default endpoint used)")
    }

    func testHTTPSBaseURLPasses() {
        let profile = makeBot(name: "Bot", modelName: "llama3", provider: .ollama, baseURL: "https://api.example.com")
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertFalse(errors.contains(where: { $0.field == "baseURL" }))
    }

    func testFTPBaseURLFailsInStrictMode() {
        let profile = makeBot(name: "Bot", modelName: "llama3", provider: .ollama, baseURL: "ftp://files.example.com")
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.contains(where: { $0.field == "baseURL" && $0.message.contains("http") }),
                       "Non-http(s) scheme should fail validation in strict mode")
    }

    func testFileSchemeBaseURLFailsInStrictMode() {
        let profile = makeBot(name: "Bot", modelName: "llama3", provider: .ollama, baseURL: "file:///etc/passwd")
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.contains(where: { $0.field == "baseURL" && $0.message.contains("http") }))
    }

    // MARK: - Instructions Validation (always enforced)

    func testInstructionsWithinLimitPasses() {
        let instructions = String(repeating: "a", count: 1000)
        let config = BotConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            instructions: instructions
        )
        let profile = BackendProfileSnapshot(displayName: "Bot", details: .bot(config))
        let errors = ProfileValidator.validate(profile)
        XCTAssertFalse(errors.contains(where: { $0.field == "instructions" }))
    }

    func testInstructionsExceedingLimitFails() {
        let instructions = String(repeating: "a", count: ProfileValidationLimits.maxInstructionsLength + 1)
        let config = BotConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3"),
            instructions: instructions
        )
        let profile = BackendProfileSnapshot(displayName: "Bot", details: .bot(config))
        let errors = ProfileValidator.validate(profile)
        XCTAssertTrue(errors.contains(where: { $0.field == "instructions" }),
                       "Instructions exceeding limit should fail validation")
    }

    // MARK: - Agent Profile Validation

    func testValidAgentProfilePasses() {
        let config = AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3", baseURL: "http://localhost:11434"),
            architecture: .reAct,
            tools: []
        )
        let profile = BackendProfileSnapshot(displayName: "Agent", details: .agent(config))
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.isEmpty, "Valid agent profile should pass: \(errors)")
    }

    // MARK: - Workflow Validation (strict mode only)

    func testEmptyWorkflowFailsInStrictMode() {
        let config = WorkflowConfig(agentProfileIDs: [])
        let profile = BackendProfileSnapshot(displayName: "Workflow", details: .workflow(config))
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.contains(where: { $0.field == "workflow" }),
                       "Empty workflow should fail validation in strict mode")
    }

    func testEmptyWorkflowPassesInLenientMode() {
        let config = WorkflowConfig(agentProfileIDs: [])
        let profile = BackendProfileSnapshot(displayName: "Workflow", details: .workflow(config))
        let errors = ProfileValidator.validate(profile)
        XCTAssertFalse(errors.contains(where: { $0.field == "workflow" }),
                        "Empty workflow should pass in lenient mode (initial creation)")
    }

    func testWorkflowWithAgentsPasses() {
        let config = WorkflowConfig(agentProfileIDs: [UUID(), UUID()])
        let profile = BackendProfileSnapshot(displayName: "Workflow", details: .workflow(config))
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertFalse(errors.contains(where: { $0.field == "workflow" }))
    }

    // MARK: - Fully Valid Profile

    func testFullyValidBotProfileReturnsNoErrors() {
        let profile = makeBot(name: "My Bot", modelName: "llama3:8b", provider: .ollama, baseURL: "http://localhost:11434")
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertTrue(errors.isEmpty, "Fully valid bot profile should have zero errors, got: \(errors.map(\.message))")
    }

    // MARK: - Multiple Errors (strict mode)

    func testMultipleErrorsReturnedAtOnce() {
        let profile = makeBot(name: "", modelName: "", provider: .openAI, apiKey: nil)
        let errors = ProfileValidator.validate(profile, strict: true)
        XCTAssertGreaterThanOrEqual(errors.count, 3,
                                     "Expected at least 3 errors (name, model, apiKey)")
    }

    // MARK: - Helpers

    private func makeBot(
        name: String,
        modelName: String,
        provider: ApiProvider,
        apiKey: String? = nil,
        baseURL: String? = nil
    ) -> BackendProfileSnapshot {
        let llmConfig = ProviderConfig(
            apiProvider: provider,
            modelName: modelName,
            apiKey: apiKey,
            baseURL: baseURL
        )
        return BackendProfileSnapshot(
            displayName: name,
            details: .bot(BotConfig(llmConfig: llmConfig))
        )
    }
}
