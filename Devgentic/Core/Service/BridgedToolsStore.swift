// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BridgedToolsStore.swift
//  Devgentic
//
//  Byte-stable tool schemas for the chat template, achieved by INSTANCE REUSE.
//
//  THE PROBLEM (device evidence, 2026-08-21). The same logical request rendered 837 → 841 → 839
//  prompt tokens across three consecutive "identical" attempts: the `<tools>` JSON block shuffled
//  its key order on every render. Consequences: the empty-response retry's "retrying the SAME
//  prompt unchanged" was false in bytes; the prompt prefix changed every iteration, so KV/prompt
//  caching could never reuse it; and two renders of one request were not comparable in logs.
//
//  WHY SORTING CANNOT FIX IT — measured, not assumed. Swift seeds `Dictionary` iteration order
//  PER INSTANCE (30 dictionaries built identically — same keys, same sorted insertion order, same
//  process, all kept alive — iterated in 30 DIFFERENT orders; a tight loop looks stable only
//  because freed storage addresses get reused). swift-jinja's `Value(any:)` builds its
//  OrderedDictionary by iterating whatever dictionary instance it is handed, and swift-transformers
//  offers no ordered type at the `tools:` boundary. So no construction discipline on a FRESH
//  dictionary can stabilize the rendered bytes.
//
//  WHAT THIS STORE ACTUALLY DELIVERS — corrected against device evidence (2026-08-21). Instance
//  reuse was built on the reasoning that a given instance's iteration order is fixed for its
//  lifetime, so handing the template the SAME instances would make renders byte-identical. The
//  device run after shipping DISPROVED the sufficiency of that: the `<tools>` key order still
//  shuffled between iterations. Mechanism, verified in the dependency source: swift-jinja's
//  `Value(any:)` (Value.swift:56) matches `case let dict as [String: Any?]` — a value-type-changing
//  cast that REBUILDS the dictionary into fresh storage at every nesting level, acquiring a new
//  per-instance seed on the way. Our instance identity dies at that cast, inside code the app
//  cannot reach. Byte-stable tool blocks therefore require an UPSTREAM fix (deterministic key
//  order in swift-jinja's dict conversion or its tojson), or the app rendering the tools section
//  itself as a string — both recorded as options, neither taken yet.
//
//  ✅ WORKAROUND IN PLACE (2026-10-06): the app runs with `SWIFT_DETERMINISTIC_HASHING=1`, which
//  makes every dictionary iterate identically and the rendered `<tools>` bytes stable (20 of 20
//  renders identical, vs 20 of 20 distinct without it). See `DeterministicHashing.swift`. The
//  root cause is in swift-jinja's `tojson` (`Value.encode`, `.object`), still unfixed upstream
//  as of 2.3.1.
//
//  The store is kept because it still provides: (1) `canonicalKey`, the content-identity primitive
//  any future fix needs; (2) one bridge instead of one per iteration; (3) the single seam where a
//  self-rendered tools string would be cached if that option is taken. Its tests pin what it DOES
//  guarantee — equal content returns identical instances from THIS seam — not the downstream
//  byte-stability the dependency currently denies.
//

import Foundation

/// Owned by the `MLXService` actor — NOT thread-safe on its own; all access is actor-serialized.
struct BridgedToolsStore {

    /// Content-keyed cache of bridged schema arrays. Value arrays hold the exact instances handed
    /// out before, which is the entire point — see the file header.
    private var cache: [String: [[String: any Sendable]]] = [:]

    /// Bounded so a long session cycling many profiles cannot grow this without limit. Schemas are
    /// a few KB each; 16 covers every realistic set of concurrently-active profiles. Overflow
    /// clears the whole cache rather than tracking LRU order — the cost of a miss is one re-bridge
    /// and a one-off byte change, not a correctness problem.
    private static let maxEntries = 16

    /// Canonical content key: sorted-keys JSON, which is byte-identical for equal content
    /// regardless of which dictionary instances carry it. Returns nil for non-JSON content
    /// (impossible for real tool schemas; callers then bridge uncached rather than crash).
    nonisolated static func canonicalKey(for tools: [[String: Any]]) -> String? {
        guard JSONSerialization.isValidJSONObject(tools),
              let data = try? JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns bridged, `Sendable` schema dictionaries for `tools`, reusing the previously
    /// handed-out instances whenever the CONTENT matches a cached entry.
    mutating func stableInstances(for tools: [[String: Any]]) -> [[String: any Sendable]] {
        guard let key = Self.canonicalKey(for: tools) else {
            // Un-keyable content: bridge fresh. Uncached means unstable bytes for this call —
            // acceptable for a case real schemas cannot reach, and never worth failing a run over.
            return tools.map { $0.mapValues { Self.bridgeToSendable($0) } }
        }
        if let cached = cache[key] { return cached }

        let bridged = tools.map { $0.mapValues { Self.bridgeToSendable($0) } }
        if cache.count >= Self.maxEntries { cache.removeAll(keepingCapacity: true) }
        cache[key] = bridged
        return bridged
    }

    /// Recursively projects a JSON-compatible `Any` into a concrete `Sendable` type.
    /// Tool schemas only contain JSON primitives (String/Int/Double/Bool/Array/Dict),
    /// all of which are Sendable. Anything else is stringified as a defensive fallback.
    ///
    /// No ordering discipline here ON PURPOSE: per-instance seeding makes any such discipline
    /// meaningless (see the file header). Stability comes from the cache above, never from how
    /// these dictionaries are built.
    nonisolated static func bridgeToSendable(_ value: Any) -> any Sendable {
        switch value {
        case let v as String: return v
        case let v as Bool: return v
        case let v as Int: return v
        case let v as Double: return v
        case let v as [Any]: return v.map { bridgeToSendable($0) }
        case let v as [String: Any]: return v.mapValues { bridgeToSendable($0) }
        case is NSNull: return NSNull()
        default: return String(describing: value)
        }
    }
}
