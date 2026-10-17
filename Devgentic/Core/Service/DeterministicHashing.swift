// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeterministicHashing.swift
//  Devgentic
//
//  Why the app runs with `SWIFT_DETERMINISTIC_HASHING=1`, and the launch check that says whether
//  this process actually got it.
//
//  THE PROBLEM (measured 2026-10-06). An MLX model's chat template renders every tool schema with
//  `{{ tool | tojson }}`. swift-jinja 2.3.1 encodes an object by copying it into a plain Swift
//  `[String: Value]` (Value.swift, `.object` in `encode(to:)`), and Swift seeds dictionary order
//  per INSTANCE. So the `<tools>` block came out in a different key order on every render: 20 of
//  20 renders of one request (real Qwen2.5-3B template, 70 tools) were distinct, token counts
//  drifted 9,512–9,676, and consecutive renders matched only up to token 1,636, the start of
//  `<tools>`. No prompt prefix past the system text could ever be reused across turns. Ordering
//  the input app-side cannot fix it — pre-ordered Jinja values still shuffled, because the
//  reorder happens inside `tojson`. See `BridgedToolsStore` for the earlier device evidence.
//
//  THE WORKAROUND. With `SWIFT_DETERMINISTIC_HASHING=1` the runtime drops the random seeds, so
//  dictionaries built from equal keys iterate identically: the same probe gave 1 distinct render
//  in 20, every variant. Swift reads the variable at process start, so it must be in the
//  environment BEFORE launch:
//    - `Info.plist` `LSEnvironment` — launches through LaunchServices (Finder, Dock, `open`, a
//      Sparkle relaunch).
//    - the shared scheme's Launch action — Xcode's Run starts the binary directly and ignores
//      `LSEnvironment`.
//  ⚠️ The test host is launched through LaunchServices, so it would inherit `LSEnvironment` too.
//  The scheme's Test action therefore sets the variable to "0" (measured: the runner's value wins,
//  and "0" restores random order). Tests keep seeing the library's own behaviour, so a probe of a
//  swift-jinja upgrade is not masked by the workaround, and order-dependent bugs stay visible.
//
//  ⚠️ THE COST. Process-wide: Swift's hash-flooding protection is off for every Set and
//  Dictionary in the app. The only untrusted input is ChatOps; accepted by the owner 2026-10-06.
//  The key order is now fixed but arbitrary — still not the insertion order the model was
//  trained on, only no longer different every turn.
//

import Foundation

private let logger = DGLogger(category: "DeterministicHashing")

enum DeterministicHashing {

    static let environmentKey = "SWIFT_DETERMINISTIC_HASHING"

    /// Whether dictionaries built from equal keys iterate in the same order in THIS process —
    /// the property the MLX `<tools>` render depends on.
    ///
    /// Measured rather than read from the environment: the variable can be present and still not
    /// apply (set too late, misspelled value, a future runtime that ignores it), and the render
    /// only cares about the behaviour.
    static func isInEffect() -> Bool {
        ordersAgree(sampleIterationOrders())
    }

    /// True when every sampled iteration order is the same.
    static func ordersAgree(_ orders: [[String]]) -> Bool {
        Set(orders).count <= 1
    }

    /// Builds `count` dictionaries from the same keys and returns each one's iteration order.
    ///
    /// ⚠️ All dictionaries are kept alive until every order has been read. Built and dropped one
    /// at a time, they tend to reuse the same freed storage address, which can make random
    /// per-instance seeds look stable (seen in the August measurement).
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
