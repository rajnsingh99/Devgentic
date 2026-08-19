//
//  ProfileEnumLocalizationTests.swift
//  DevgenticTests
//
//  Created on 08/08/26.
//
//  Register A63 — the Execution card's option labels and the file-context strategy labels were
//  `String` `displayName`s, so `Text(x.displayName)` bound to the non-localizing `StringProtocol`
//  overload and the String Catalog extractor never saw them. Section headers around them WERE
//  extracted, so a translated build would have rendered translated chrome over English options.
//
//  ⚠️ The real guard here is the COMPILER, not an assertion. `localizable(_:)` takes a
//  `LocalizedStringKey`, so retyping any of these properties back to `String` stops the file
//  compiling. That is deliberate: the sibling suite `MLXLocalizedTitleTests` records that its
//  first version asserted `XCTAssertNotNil` on a non-optional `LocalizedStringKey` — which can
//  never fail — and stayed green through the exact bug it existed to catch.
//

import XCTest
import SwiftUI
@testable import devgentic

final class ProfileEnumLocalizationTests: XCTestCase {

    /// Compile-time guard: a `String` return type cannot be passed here.
    private func localizable(_ key: LocalizedStringKey) -> LocalizedStringKey { key }

    private func assertDistinct(
        _ keys: [LocalizedStringKey], _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (i, a) in keys.enumerated() {
            for (j, b) in keys.enumerated() where j > i {
                XCTAssertNotEqual(a, b, "\(label): two cases share a label", file: file, line: line)
            }
        }
    }

    // MARK: - Every case is localizable and distinct

    func testErrorRecoveryPoliciesAreLocalizable() {
        XCTAssertEqual(ToolFailurePolicy.allCases.count, 3, "a case was added or removed")
        for policy in ToolFailurePolicy.allCases { _ = localizable(policy.localizedTitle) }
        assertDistinct(ToolFailurePolicy.allCases.map(\.localizedTitle), "ToolFailurePolicy")
    }

    func testExhaustionPoliciesAreLocalizable() {
        XCTAssertEqual(ExhaustionPolicy.allCases.count, 2, "a case was added or removed")
        for policy in ExhaustionPolicy.allCases { _ = localizable(policy.localizedTitle) }
        assertDistinct(ExhaustionPolicy.allCases.map(\.localizedTitle), "ExhaustionPolicy")
    }

    func testHistoryStrategiesAreLocalizableTitleAndDescription() {
        XCTAssertEqual(HistoryStrategy.allCases.count, 4, "a case was added or removed")
        for strategy in HistoryStrategy.allCases {
            _ = localizable(strategy.localizedTitle)
            _ = localizable(strategy.localizedDescription)
        }
        assertDistinct(HistoryStrategy.allCases.map(\.localizedTitle), "HistoryStrategy title")
        assertDistinct(HistoryStrategy.allCases.map(\.localizedDescription), "HistoryStrategy description")
    }

    func testFileContextStrategiesAreLocalizableTitleAndDescription() {
        XCTAssertEqual(FileContextStrategy.allCases.count, 3, "a case was added or removed")
        for strategy in FileContextStrategy.allCases {
            _ = localizable(strategy.localizedTitle)
            _ = localizable(strategy.localizedDescription)
        }
        assertDistinct(FileContextStrategy.allCases.map(\.localizedTitle), "FileContextStrategy title")
    }

    // MARK: - The persistence contract must stay separate

    /// ⚠️ THE ASSERTION THAT MAKES THE FIX SAFE. These `rawValue`s are the persisted and logged
    /// identifiers — `ErrorRecovery.init(from:)` decodes them, `TraceConfigSnapshot` records them,
    /// `BackendOrchestrationService` logs them. They must stay identifier-shaped and must never be
    /// "tidied" into display text, which is exactly the trap `ApiProvider` fell into (its rawValue
    /// is `"Ollama (Local)"`, and a test fixture hardcoding `"ollama"` silently broke because of
    /// it). Display text now lives only in `localizedTitle`.
    func testRawValuesRemainIdentifiersNotDisplayText() {
        let raws = ToolFailurePolicy.allCases.map(\.rawValue)
            + ExhaustionPolicy.allCases.map(\.rawValue)
            + HistoryStrategy.allCases.map(\.rawValue)
            + FileContextStrategy.allCases.map(\.rawValue)

        for raw in raws {
            XCTAssertFalse(raw.isEmpty)
            XCTAssertFalse(raw.contains(" "), "'\(raw)' looks like display text, not an identifier")
            XCTAssertFalse(raw.contains("&"), "'\(raw)' looks like display text, not an identifier")
            XCTAssertEqual(raw.first, raw.first?.lowercased().first,
                           "'\(raw)' is capitalised like a label")
        }
    }

    /// The persisted identifiers are the decode contract, so pin them literally. If one changes,
    /// every stored profile carrying the old value silently falls back to a default.
    func testPersistedIdentifiersAreUnchanged() {
        XCTAssertEqual(ToolFailurePolicy.abort.rawValue, "abort")
        XCTAssertEqual(ToolFailurePolicy.skipAndContinue.rawValue, "skipAndContinue")
        XCTAssertEqual(ToolFailurePolicy.fallbackPrompt.rawValue, "fallbackPrompt")
        XCTAssertEqual(ExhaustionPolicy.synthesizeBestEffort.rawValue, "synthesizeBestEffort")
        XCTAssertEqual(ExhaustionPolicy.failHard.rawValue, "failHard")
        XCTAssertEqual(HistoryStrategy.recentHistory.rawValue, "recentHistory")
        XCTAssertEqual(HistoryStrategy.hybrid.rawValue, "hybrid")
    }
}
