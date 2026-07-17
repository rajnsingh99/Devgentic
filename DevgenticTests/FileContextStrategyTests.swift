//
//  FileContextStrategyTests.swift
//  devgenticTests
//
//  Created on 11/07/26.
//
//  Covers the strategy resolution contract after the 2026-07 redesign:
//  contextualRAG is deprecated (decodable, never resolvable), bot is pinned
//  to directInjection, and resolve() heals persisted values a type can't honor.
//

import XCTest
@testable import devgentic

final class FileContextStrategyTests: XCTestCase {

    private let allTypes: [ProfileType] = [.bot, .agent, .workflow, .imageGen, .code]

    // MARK: - Smart Defaults

    func testDefaultStrategy_PerProfileType() {
        XCTAssertEqual(FileContextStrategy.defaultStrategy(for: .bot), .directInjection)
        XCTAssertEqual(FileContextStrategy.defaultStrategy(for: .agent), .directInjection)
        XCTAssertEqual(FileContextStrategy.defaultStrategy(for: .workflow), .directInjection)
        XCTAssertEqual(FileContextStrategy.defaultStrategy(for: .imageGen), .stateless)
        XCTAssertEqual(FileContextStrategy.defaultStrategy(for: .code), .stateless)
    }

    // MARK: - Availability

    func testAvailableStrategies_ContextualRAGAvailableToNoType() {
        for type in allTypes {
            XCTAssertFalse(
                FileContextStrategy.availableStrategies(for: type).contains(.contextualRAG),
                "contextualRAG is deprecated and must not be offered for \(type)"
            )
        }
    }

    func testAvailableStrategies_BotIsDirectInjectionOnly() {
        XCTAssertEqual(FileContextStrategy.availableStrategies(for: .bot), [.directInjection])
    }

    func testAvailableStrategies_AgentOffersDirectAndStateless() {
        XCTAssertEqual(
            FileContextStrategy.availableStrategies(for: .agent),
            [.directInjection, .stateless]
        )
    }

    func testAvailableStrategies_DefaultIsAlwaysAvailable() {
        for type in allTypes {
            XCTAssertTrue(
                FileContextStrategy.availableStrategies(for: type)
                    .contains(FileContextStrategy.defaultStrategy(for: type)),
                "default for \(type) must be offerable"
            )
        }
    }

    // MARK: - Resolution / healing

    func testResolve_NilFallsBackToDefault() {
        XCTAssertEqual(FileContextStrategy.resolve(nil, for: .bot), .directInjection)
        XCTAssertEqual(FileContextStrategy.resolve(nil, for: .agent), .directInjection)
        XCTAssertEqual(FileContextStrategy.resolve(nil, for: .code), .stateless)
    }

    func testResolve_ValidOverrideIsHonored() {
        XCTAssertEqual(FileContextStrategy.resolve(.stateless, for: .agent), .stateless)
        XCTAssertEqual(FileContextStrategy.resolve(.directInjection, for: .agent), .directInjection)
    }

    func testResolve_HealsLegacyContextualRAG() {
        // Pre-redesign bots defaulted to contextualRAG; persisted values must heal at read.
        XCTAssertEqual(FileContextStrategy.resolve(.contextualRAG, for: .bot), .directInjection)
        XCTAssertEqual(FileContextStrategy.resolve(.contextualRAG, for: .agent), .directInjection)
    }

    func testResolve_HealsStatelessOnBot() {
        // Bots run with no tools — a persisted stateless bot heals to directInjection.
        XCTAssertEqual(FileContextStrategy.resolve(.stateless, for: .bot), .directInjection)
    }

    func testResolve_NeverReturnsContextualRAG() {
        for type in allTypes {
            for override in FileContextStrategy.allCases {
                XCTAssertNotEqual(
                    FileContextStrategy.resolve(override, for: type), .contextualRAG,
                    "resolve must never return the deprecated case (type \(type), override \(override.rawValue))"
                )
            }
        }
    }

    // MARK: - Raw-value stability (persistence contract)

    func testRawValues_StableForPersistedProfiles() {
        XCTAssertEqual(FileContextStrategy.contextualRAG.rawValue, "contextual_rag")
        XCTAssertEqual(FileContextStrategy.directInjection.rawValue, "direct_injection")
        XCTAssertEqual(FileContextStrategy.stateless.rawValue, "stateless")
        XCTAssertEqual(FileContextStrategy(rawValue: "contextual_rag"), .contextualRAG)
    }
}
