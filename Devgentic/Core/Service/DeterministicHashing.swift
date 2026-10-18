// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeterministicHashing.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "DeterministicHashing")

/// Reports whether `SWIFT_DETERMINISTIC_HASHING` took effect, so dictionaries built from equal keys iterate identically.
/// MLX chat templates render tool schemas through `tojson`; random key order would reshuffle `<tools>` every render.
/// The variable must be set before launch (`LSEnvironment`, Run scheme); the test scheme sets it to 0.
enum DeterministicHashing {

    static let environmentKey = "SWIFT_DETERMINISTIC_HASHING"

    // Why: measured, not read from the environment: the variable can be present and still not apply (set too late, bad
    // value).
    /// Whether dictionaries built from equal keys iterate in the same order in this process; the MLX `<tools>` render depends
    /// on it.
    static func isInEffect() -> Bool {
        ordersAgree(sampleIterationOrders())
    }

    /// True when every sampled iteration order is the same.
    static func ordersAgree(_ orders: [[String]]) -> Bool {
        Set(orders).count <= 1
    }

    // Why: keep all dictionaries alive until every order is read: dropped ones reuse freed storage, so random seeds look
    // stable.
    /// Builds `count` dictionaries from the same keys and returns each one's iteration order.
    static func sampleIterationOrders(count: Int = 8, keyCount: Int = 32) -> [[String]] {
        let keys = (0..<keyCount).map { "key\($0)" }
        let dictionaries: [[String: Int]] = (0..<count).map { _ in
            Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })
        }
        return dictionaries.map { Array($0.keys) }
    }

    /// One line at launch saying whether this process renders stable MLX prompts.
    static func logLaunchStatus() {
        let value = ProcessInfo.processInfo.environment[environmentKey]
        if isInEffect() {
            logger.info("[HASHING] Deterministic hashing is ON (\(environmentKey)=\(value ?? "unset")). CONSEQUENCE: identical MLX chat-template requests render byte-identical prompts, so a prompt prefix can be reused across turns.")
        } else {
            logger.warning("[HASHING] Deterministic hashing is OFF (\(environmentKey)=\(value ?? "unset")). This launch came neither through LaunchServices (Info.plist LSEnvironment) nor through the Xcode scheme's Run action. CONSEQUENCE: every MLX chat-template prompt renders its <tools> block in a new key order each turn, so nothing after the system text can be reused and token counts drift between identical requests. Launch from Finder, the Dock or the Xcode scheme.")
        }
    }
}
