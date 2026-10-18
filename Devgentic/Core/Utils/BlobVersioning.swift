// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BlobVersioning.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Mechanism A: inline key

/// Version discriminators for the JSON blob columns, so readers never have to guess a blob's shape.
/// Object-rooted blobs carry an inline key; array-rooted or user-keyed blobs use the `VersionedBlob` envelope.
enum BlobVersioning {

    /// The key stamped into object-rooted blobs. Matches the name `ProfileBlobGate` reads on
    /// `configData`, so the app has ONE spelling of this concept rather than two.
    static let versionKey = "schemaVersion"

    /// Reads the version stamped into a blob, or nil when it carries none.
    /// Tolerant of any root shape; an array simply has no version.
    static func version(of data: Data) -> Int? {
        struct Probe: Decodable { let schemaVersion: Int? }
        return (try? JSONDecoder().decode(Probe.self, from: data))?.schemaVersion
    }

    // Why: re-serializing via `JSONSerialization` is lossy on doubles and drifts TimeIntervals on every save
    /// Returns `data` with a version key inserted by byte splice, without re-encoding the payload.
    /// Idempotent: an already-stamped blob has its value replaced. Non-object roots are returned unchanged.
    static func stamped(_ data: Data, version: Int) -> Data {
        guard let opening = firstNonWhitespaceByte(in: data), opening == UInt8(ascii: "{") else {
            return data  // array or scalar root — mechanism B's job
        }
        if let existing = self.version(of: data) {
            guard existing != version else { return data }
            return restamped(data, from: existing, to: version)
        }

        guard let braceIndex = data.firstIndex(of: UInt8(ascii: "{")) else { return data }
        let afterBrace = data.index(after: braceIndex)

        // `{}` has no members, so the injected pair must NOT be followed by a comma.
        let remainderIsEmptyObject = data[afterBrace...]
            .drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
            .first == UInt8(ascii: "}")

        let injection = remainderIsEmptyObject
            ? #""\#(versionKey)":\#(version)"#
            : #""\#(versionKey)":\#(version),"#

        var out = Data(data[...braceIndex])
        out.append(contentsOf: Array(injection.utf8))
        out.append(contentsOf: data[afterBrace...])
        return out
    }

    /// Replaces an existing version value. Falls back to the original bytes if the rewrite cannot be
    /// done safely — a diagnostic aid must never be the reason a blob becomes unreadable.
    private static func restamped(_ data: Data, from old: Int, to new: Int) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        // Match the key with optional whitespace, as an encoder may or may not pretty-print.
        guard let range = text.range(
            of: #""\#(versionKey)"\s*:\s*\#(old)"#, options: .regularExpression
        ) else { return data }
        return Data(text.replacingCharacters(in: range, with: #""\#(versionKey)":\#(new)"#).utf8)
    }

    private static func firstNonWhitespaceByte(in data: Data) -> UInt8? {
        data.first { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
    }
}

// MARK: - Mechanism B: envelope

/// A versioned wrapper for blobs that cannot carry an inline key.
///
/// Use for ARRAY-rooted payloads, and for dictionaries whose keys come from the user.
struct VersionedBlob<Payload: Codable>: Codable {
    let schemaVersion: Int
    let payload: Payload

    init(schemaVersion: Int, payload: Payload) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    /// Decodes the envelope, or returns nil when the bytes are not one.
    /// Nil is a decode failure the caller must treat as unreadable, not empty; a bare unwrapped payload is not accepted.
    static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder())
        -> (payload: Payload, version: Int)? {
        guard let wrapped = try? decoder.decode(VersionedBlob<Payload>.self, from: data) else { return nil }
        return (wrapped.payload, wrapped.schemaVersion)
    }
}
