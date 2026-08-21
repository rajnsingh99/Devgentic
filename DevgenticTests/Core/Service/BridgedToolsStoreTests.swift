//
//  BridgedToolsStoreTests.swift
//  DevgenticTests
//
//  Cover for the instance-stability cache behind the chat template's `<tools>` block.
//
//  ⚠️ SCOPE — read the store's file header before trusting these tests. They pin what the store
//  guarantees AT ITS OWN SEAM: equal content returns identical dictionary instances. They do NOT
//  claim the rendered prompt is byte-stable — device evidence showed swift-jinja's `Value(any:)`
//  rebuilds every dictionary via a value-type-changing cast (fresh storage, fresh per-instance
//  seed), so the `<tools>` block still shuffles downstream. Context: Swift dictionaries iterate in
//  per-INSTANCE order (measured: 30 identical builds kept alive → 30 distinct orders).
//

import XCTest
@testable import devgentic

final class BridgedToolsStoreTests: XCTestCase {

    /// A realistic OpenAI-style schema, decoded from JSON so the input dictionaries are
    /// Cocoa-backed — the same provenance as production (NativeJSONSchemaAdapter round-trips
    /// parameters through JSONSerialization).
    private func decodedTools(shuffle: Bool = false) -> [[String: Any]] {
        let a = #"{"type":"function","function":{"name":"execute_shell","description":"Runs a shell command.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"The command."}},"required":["command"]}}}"#
        let b = #"{"function":{"parameters":{"required":["command"],"properties":{"command":{"description":"The command.","type":"string"}},"type":"object"},"description":"Runs a shell command.","name":"execute_shell"},"type":"function"}"#
        let text = "[" + (shuffle ? b : a) + "]"
        return try! JSONSerialization.jsonObject(with: text.data(using: .utf8)!) as! [[String: Any]]
    }

    /// The order-signature Jinja actually consumes: every dictionary's key sequence, recursively.
    private func orderSignature(_ value: Any) -> String {
        switch value {
        case let dict as [String: any Sendable]:
            return "{" + dict.map { "\($0.key):\(orderSignature($0.value))" }.joined(separator: ",") + "}"
        case let dict as [String: Any]:
            return "{" + dict.map { "\($0.key):\(orderSignature($0.value))" }.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(orderSignature).joined(separator: ",") + "]"
        default:
            return "."
        }
    }

    // MARK: - THE stability property

    /// Equal content — even from freshly decoded, differently-ordered JSON text — must come back
    /// as the SAME instances, so every render of one tool set is byte-identical.
    func testEqualContentReturnsIdenticalInstanceOrder() {
        var store = BridgedToolsStore()
        let first = store.stableInstances(for: decodedTools())
        let second = store.stableInstances(for: decodedTools(shuffle: true))
        // Keep both alive simultaneously: per-instance ordering means two FRESH bridges would
        // disagree with near-certainty, so this equality holds only through the cache.
        XCTAssertEqual(orderSignature(first), orderSignature(second),
                       "equal schemas must reuse the cached instances — this is the whole fix")
    }

    func testRepeatedCallsStayStableAcrossMany() {
        var store = BridgedToolsStore()
        let signatures = Set((0..<20).map { _ in orderSignature(store.stableInstances(for: decodedTools())) })
        XCTAssertEqual(signatures.count, 1, "20 renders of one tool set must share one byte order")
    }

    // MARK: - Content keying

    func testCanonicalKeyIgnoresInstanceAndTextualOrder() {
        XCTAssertEqual(
            BridgedToolsStore.canonicalKey(for: decodedTools()),
            BridgedToolsStore.canonicalKey(for: decodedTools(shuffle: true)),
            "the key is CONTENT — textual key order in the source JSON must not matter"
        )
    }

    func testDifferentContentGetsDifferentKeyAndInstances() {
        var store = BridgedToolsStore()
        let other: [[String: Any]] = [["type": "function", "function": ["name": "ask_user"]]]
        XCTAssertNotEqual(BridgedToolsStore.canonicalKey(for: decodedTools()),
                          BridgedToolsStore.canonicalKey(for: other))
        // Both must round-trip content faithfully regardless of caching.
        let bridged = store.stableInstances(for: other)
        XCTAssertEqual((bridged.first?["function"] as? [String: any Sendable])?["name"] as? String, "ask_user")
    }

    /// Content must survive bridging byte-for-byte (canonical serialization compares equal) —
    /// the cache may never trade correctness for stability.
    func testBridgingPreservesContentExactly() {
        var store = BridgedToolsStore()
        let bridged = store.stableInstances(for: decodedTools())
        let a = try! JSONSerialization.data(withJSONObject: bridged, options: [.sortedKeys])
        let b = try! JSONSerialization.data(withJSONObject: decodedTools(), options: [.sortedKeys])
        XCTAssertEqual(a, b, "bridged schemas must carry identical content")
    }

    // MARK: - Bounds and degenerate input

    func testOverflowResetsButKeepsWorking() {
        var store = BridgedToolsStore()
        for i in 0..<40 {
            _ = store.stableInstances(for: [["type": "function", "n": i]])
        }
        // Past the cap the cache clears rather than growing without bound; behaviour must remain
        // correct (a later repeat is stable again from its first re-entry).
        let x = orderSignature(store.stableInstances(for: decodedTools()))
        let y = orderSignature(store.stableInstances(for: decodedTools()))
        XCTAssertEqual(x, y, "post-overflow entries must still be instance-stable")
    }

    func testNonJSONContentBridgesWithoutCrashing() {
        var store = BridgedToolsStore()
        let weird: [[String: Any]] = [["type": "function", "when": Date(timeIntervalSince1970: 0)]]
        XCTAssertNil(BridgedToolsStore.canonicalKey(for: weird), "un-keyable content must be detected, not crash")
        let bridged = store.stableInstances(for: weird)
        XCTAssertEqual(bridged.first?["type"] as? String, "function")
        XCTAssertNotNil(bridged.first?["when"], "defensive stringification must keep the value present")
    }
}
