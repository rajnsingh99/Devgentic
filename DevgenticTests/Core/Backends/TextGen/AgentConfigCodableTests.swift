// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AgentConfigCodableTests.swift
//  DevgenticTests
//
//  Codable roundtrip and backward compatibility tests for all
//  execution-related config types: RetryPolicy, ErrorRecovery,
//  AgentCapabilities, PlanningCapabilityConfig, SelfReflectionConfig,
//  AgentDelegationConfig, and supporting enums.
//

import XCTest
@testable import devgentic

final class AgentConfigCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - RetryPolicy

    func testRetryPolicy_CodableRoundtrip() throws {
        let original = RetryPolicy(maxRetries: 5, backoffStrategy: .fixed)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RetryPolicy.self, from: data)
        XCTAssertEqual(decoded.maxRetries, 5)
        XCTAssertEqual(decoded.backoffStrategy, .fixed)
    }

    func testRetryPolicy_DefaultValues_Roundtrip() throws {
        let original = RetryPolicy()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(RetryPolicy.self, from: data)
        XCTAssertEqual(decoded.maxRetries, 3)
        XCTAssertEqual(decoded.backoffStrategy, .exponential)
    }

    func testRetryPolicy_BackwardCompat_MissingFields_UsesDefaults() throws {
        // Empty JSON object — custom init(from:) should fallback to defaults
        let json = "{}".data(using: .utf8)!
        let decoded = try decoder.decode(RetryPolicy.self, from: json)
        XCTAssertEqual(decoded.maxRetries, 3, "Missing maxRetries should default to 3")
        XCTAssertEqual(decoded.backoffStrategy, .exponential, "Missing backoffStrategy should default to .exponential")
    }

    // MARK: - ErrorRecovery

    func testErrorRecovery_CodableRoundtrip() throws {
        let original = ErrorRecovery(onToolFailure: .skipAndContinue, onIterationExhaustion: .failHard)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ErrorRecovery.self, from: data)
        XCTAssertEqual(decoded.onToolFailure, .skipAndContinue)
        XCTAssertEqual(decoded.onIterationExhaustion, .failHard)
    }

    func testErrorRecovery_FallbackMessage_NilRoundtrip() throws {
        let original = ErrorRecovery(onToolFailure: .fallbackPrompt, fallbackMessage: nil)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ErrorRecovery.self, from: data)
        XCTAssertEqual(decoded.onToolFailure, .fallbackPrompt)
        XCTAssertNil(decoded.fallbackMessage, "nil fallbackMessage should decode as nil")
    }

    func testErrorRecovery_FallbackMessage_CustomRoundtrip() throws {
        let custom = "Stop using tools. Answer from context only."
        let original = ErrorRecovery(onToolFailure: .fallbackPrompt, fallbackMessage: custom)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ErrorRecovery.self, from: data)
        XCTAssertEqual(decoded.fallbackMessage, custom)
    }

    func testErrorRecovery_BackwardCompat_MissingFallbackMessage() throws {
        // Old profiles without fallbackMessage field
        let json = """
        {"onToolFailure":"fallbackPrompt","onIterationExhaustion":"synthesizeBestEffort"}
        """.data(using: .utf8)!
        let decoded = try decoder.decode(ErrorRecovery.self, from: json)
        XCTAssertEqual(decoded.onToolFailure, .fallbackPrompt)
        XCTAssertNil(decoded.fallbackMessage, "Missing field should decode as nil")
    }

    // MARK: - AgentCapabilities

    func testAgentCapabilities_CodableRoundtrip_AllEnabled() throws {
        let original = AgentCapabilities(
            planning: PlanningCapabilityConfig(),
            selfReflection: SelfReflectionConfig(),
            agentDelegation: AgentDelegationConfig()
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentCapabilities.self, from: data)
        XCTAssertNotNil(decoded.planning)
        XCTAssertNotNil(decoded.selfReflection)
        XCTAssertNotNil(decoded.agentDelegation)
    }

    func testAgentCapabilities_CodableRoundtrip_NoneEnabled() throws {
        let original = AgentCapabilities()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AgentCapabilities.self, from: data)
        XCTAssertNil(decoded.planning)
        XCTAssertNil(decoded.selfReflection)
        XCTAssertNil(decoded.agentDelegation)
    }

    // MARK: - PlanningCapabilityConfig

    func testPlanningCapabilityConfig_CodableRoundtrip() throws {
        let original = PlanningCapabilityConfig(
            maxSubtasks: 10,
            parallelSubtasks: true,
            subtaskToolFiltering: false,
            requiresPlanApproval: true
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PlanningCapabilityConfig.self, from: data)
        XCTAssertEqual(decoded.maxSubtasks, 10)
        XCTAssertEqual(decoded.parallelSubtasks, true)
        XCTAssertEqual(decoded.subtaskToolFiltering, false)
        XCTAssertEqual(decoded.requiresPlanApproval, true)
    }

    // MARK: - SelfReflectionConfig

    func testSelfReflectionConfig_CodableRoundtrip() throws {
        let uuid = UUID()
        let original = SelfReflectionConfig(maxTrials: 5, evaluatorProfileID: uuid)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SelfReflectionConfig.self, from: data)
        XCTAssertEqual(decoded.maxTrials, 5)
        XCTAssertEqual(decoded.evaluatorProfileID, uuid)
    }

    func testSelfReflectionConfig_EvaluatorProfileID_NilDoesNotCrash() throws {
        let original = SelfReflectionConfig(maxTrials: 3, evaluatorProfileID: nil)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SelfReflectionConfig.self, from: data)
        XCTAssertEqual(decoded.maxTrials, 3)
        XCTAssertNil(decoded.evaluatorProfileID)
    }

    func testSelfReflectionConfig_EvaluatorProfileID_PresentDecodesCorrectly() throws {
        let uuid = UUID()
        let original = SelfReflectionConfig(maxTrials: 2, evaluatorProfileID: uuid)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SelfReflectionConfig.self, from: data)
        XCTAssertEqual(decoded.evaluatorProfileID, uuid)
    }

    // MARK: - AgentDelegationConfig

    func testAgentDelegationConfig_BackwardCompat_MissingFields() throws {
        // Empty JSON — custom init(from:) should use defaults
        let json = "{}".data(using: .utf8)!
        let decoded = try decoder.decode(AgentDelegationConfig.self, from: json)
        XCTAssertEqual(decoded.maxConcurrentAgents, 3)
        XCTAssertEqual(decoded.maxIterationsPerAgent, 10)
    }

    // MARK: - Enum Roundtrips

    func testBackoffStrategy_AllCases_EncodeDecodeCorrectly() throws {
        for strategy in BackoffStrategy.allCases {
            let data = try encoder.encode(strategy)
            let decoded = try decoder.decode(BackoffStrategy.self, from: data)
            XCTAssertEqual(decoded, strategy, "BackoffStrategy.\(strategy) roundtrip failed")
        }
    }

    func testToolFailurePolicy_AllCases_EncodeDecodeCorrectly() throws {
        for policy in ToolFailurePolicy.allCases {
            let data = try encoder.encode(policy)
            let decoded = try decoder.decode(ToolFailurePolicy.self, from: data)
            XCTAssertEqual(decoded, policy, "ToolFailurePolicy.\(policy) roundtrip failed")
        }
    }

    func testExhaustionPolicy_AllCases_EncodeDecodeCorrectly() throws {
        for policy in ExhaustionPolicy.allCases {
            let data = try encoder.encode(policy)
            let decoded = try decoder.decode(ExhaustionPolicy.self, from: data)
            XCTAssertEqual(decoded, policy, "ExhaustionPolicy.\(policy) roundtrip failed")
        }
    }

    func testHistoryStrategy_AllCases_EncodeDecodeCorrectly() throws {
        for strategy in HistoryStrategy.allCases {
            let data = try encoder.encode(strategy)
            let decoded = try decoder.decode(HistoryStrategy.self, from: data)
            XCTAssertEqual(decoded, strategy, "HistoryStrategy.\(strategy) roundtrip failed")
        }
    }
}
