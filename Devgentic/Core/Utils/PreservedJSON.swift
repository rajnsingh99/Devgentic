// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PreservedJSON.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// Decodes in a fixed arm order: bool, int, uint, double, string, array, object; the order is unambiguous and must
    /// not change. `uint` follows `int` so ordinary integers stay signed, and exists only for values above `Int64.max`.
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

    /// The single key of a one-key object, if that is what this is. Swift encodes an enum with associated values as
    /// `{"caseName": {payload}}`, so this recovers an unrecognised case name.
    var singleKeyEntry: (key: String, value: PreservedJSON)? {
        guard case .object(let members) = self, members.count == 1, let only = members.first else {
            return nil
        }
        return (only.key, only.value)
    }

    /// Sorted-key encoding, the only deterministic serialization of this value; not for persistence. Gives equality and
    /// hashing a stable form, since `JSONEncoder`'s default key order varies between runs.
    var canonicalData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// A UUID derived from the value itself, identical on every load. Prefers an `id` member that parses as a UUID,
    /// else derives one from a SHA-256 of the canonical bytes. Must never be `UUID()`, or `ForEach` churns on every
    /// reload.
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
