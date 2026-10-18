// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BridgedToolsStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Owned by the `MLXService` actor — NOT thread-safe on its own; all access is actor-serialized.
struct BridgedToolsStore {

    /// Content-keyed cache of bridged schema arrays. Value arrays hold the exact instances handed
    /// out before, which is the entire point — see the file header.
    private var cache: [String: [[String: any Sendable]]] = [:]

    /// Cache bound: schemas are a few KB each and 16 covers every realistic set of concurrently-active profiles.
    /// Overflow clears the whole cache instead of tracking LRU order; a miss costs one re-bridge and a one-off byte change.
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

    /// Returns bridged, `Sendable` schema dictionaries for `tools`, reusing the instances already handed out
    /// whenever the content matches a cached entry.
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

    // Why: no ordering discipline is applied here: per-instance hash seeding makes any such discipline meaningless,
    // so stability comes from the cache, never from how the dictionaries are built
    /// Recursively projects a JSON-compatible `Any` into a concrete `Sendable` type.
    /// Tool schemas contain only JSON primitives, arrays and dictionaries, all Sendable; anything else is stringified.
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
