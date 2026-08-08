//
//  PreservedJSON.swift
//  Devgentic
//
//  Created on 04/08/26.
//
//  Lossless carrier for a persisted value this build cannot model.
//
//  Shared by every blob that needs a forward-compatible catch-all: `TimelineEvent.unknown` and
//  `MessageContent.unknown`. Named for what it does, not for its first caller.
//
//  WHY NOT `JSONValue` (Core/Utils/JSONValue.swift): that type is shared with tool dispatch and
//  workflow JSON, and it has only `case number(Double)` — no integer arm. Measured 2026-08-04:
//  ordinary integers survive it fine (`{"durationMs":1500}` round-trips byte-identically, and Int
//  decoding still succeeds, so the commonly-repeated "integers come back as doubles" claim is
//  wrong), but a value above 2^53 does NOT: `9007199254740993` → `9007199254740992`, silently.
//  A carrier for payloads written by FUTURE builds cannot assume their integers stay small, and
//  widening the shared type would ripple through unrelated subsystems.
//
//  WHY NOT RAW BYTES: capturing the underlying bytes of the current sub-object mid-decode is not
//  reachable — swift-foundation's `JSONDecoderImpl` exposes no such accessor — and the out-of-band
//  routes are themselves lossy (`JSONSerialization` mangles doubles, e.g. `0.1` →
//  `0.10000000000000001`).
//
//  ⚠️ THE BAR IS SEMANTIC FIDELITY, NOT BYTE FIDELITY — and byte fidelity is unavailable anyway.
//  Swift's keyed containers are Dictionary-backed, so `JSONEncoder` emits keys in an order that
//  varies BETWEEN PROCESS RUNS for the very same value. Any test asserting on encoded bytes or on a
//  golden string is flaky by construction; compare parsed objects instead.
//
//  ⚠️ INVARIANT: no `Decimal` may appear inside a preserved payload. `JSONEncoder` writes a
//  Decimal's full significant digits, which this carrier would round through `Double`. Every other
//  number in this blob is written by `JSONEncoder` from a Swift scalar, and `JSONEncoder` refuses to
//  emit inf/nan, so `Int64 | UInt64 | Double` is provably sufficient for everything else. There is
//  no `Decimal` anywhere in `Devgentic/` as of 2026-08-04.
//

import Foundation
import CryptoKit

/// A JSON value preserved verbatim enough to re-emit without semantic loss.
indirect enum PreservedJSON: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([PreservedJSON])
    case object([String: PreservedJSON])

    /// ⚠️ ARM ORDER IS LOAD-BEARING: bool → int → uint → double → string → array → object.
    /// Verified unambiguous — `1` never decodes as `Bool`, `true` never as `Int64`, `-1` never as
    /// `UInt64`. `uint` sits after `int` so ordinary integers stay signed, and exists only to carry
    /// values above `Int64.max`, which would otherwise degrade through `Double`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int64.self) { self = .int(value); return }
        if let value = try? container.decode(UInt64.self) { self = .uint(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([PreservedJSON].self) { self = .array(value); return }
        if let value = try? container.decode([String: PreservedJSON].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Value is not representable as JSON."
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:          try container.encodeNil()
        case .bool(let v):   try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .uint(let v):   try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v):  try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// The single key of a one-key object, if that is what this is.
    ///
    /// Swift synthesizes an enum-with-associated-values as `{"caseName": {payload}}`, so this is how
    /// an unrecognised event's case name is recovered.
    var singleKeyEntry: (key: String, value: PreservedJSON)? {
        guard case .object(let members) = self, members.count == 1, let only = members.first else {
            return nil
        }
        return (only.key, only.value)
    }

    /// Sorted-key encoding — the only DETERMINISTIC serialization of this value.
    ///
    /// ⚠️ Not for persistence. `JSONEncoder`'s default key order comes from a `Dictionary` and
    /// varies between process runs, so this exists purely to give equality and hashing something
    /// stable to work on.
    var canonicalData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// A UUID derived from the value itself, so it is identical on every load.
    ///
    /// Prefers an `id` member that already parses as a UUID (future cases are overwhelmingly likely
    /// to carry one, matching every current case); otherwise derives one from a SHA-256 of the
    /// canonical bytes. ⚠️ Must never be `UUID()` — SwiftUI's `ForEach` keys off it, so a fresh
    /// identity per decode would churn the timeline on every reload.
    var stableIdentity: UUID {
        if case .object(let members) = self,
           case .string(let raw)? = members["id"],
           let parsed = UUID(uuidString: raw) {
            return parsed
        }
        var bytes = Array(SHA256.hash(data: canonicalData))
        bytes = Array(bytes.prefix(16))
        // Stamp RFC-4122 version 4 / variant bits so the value is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
                           bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12],
                           bytes[13], bytes[14], bytes[15]))
    }
}
