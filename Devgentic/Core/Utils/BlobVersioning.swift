// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BlobVersioning.swift
//  Devgentic
//
//  Created on 05/08/26.
//
//  Version discriminators for the JSON blob columns (SWIFTDATA_GAP_REGISTER.md G19).
//
//  WHY THIS EXISTS
//  ───────────────
//  Most of this app's rich state is a JSON blob inside a `Data`/`String` column, invisible to
//  SwiftData. When the shape of one changes there are then TWO shapes on disk and no label saying
//  which is which, so the reader has to guess:
//
//      if let modern = try? decode(New.self, from: data) { … }
//      else if let legacy = try? decode(Old.self, from: data) { … }
//
//  ⚠️ The danger is not that guessing is ugly — it is that a guess can SUCCEED AND BE WRONG. JSON
//  decoding is forgiving: an older blob frequently decodes cleanly into a newer shape with fields
//  silently missing or defaulted. No error, no log, just a profile that loads fine having quietly
//  lost its settings. That is the same silent-degradation class as G12/G13.
//
//  `configData` carries its own inline key (`ProfileBlobGate`); this file gives every other blob
//  column a discriminator too, so none of them has to guess.
//
//  ⚠️ NO LEGACY SHAPES (2026-10-03 history reset, pre-release): every reader accepts only the
//  stamped/enveloped shape. A blob from before versioning is a decode failure, not a fallback.
//
//  TWO MECHANISMS, CHOSEN BY ROOT SHAPE — not interchangeable:
//
//  A. INLINE KEY (`stamped` / `version`) — for object-rooted blobs whose keys are DEVELOPER-defined.
//     Purely additive: the blob keeps its shape and gains one key, so an older build still reads it
//     (JSONDecoder ignores unknown keys). Applies to contentData, agentResponseData, tokenUsageData,
//     layoutData, mcpConfigData, parametersData.
//
//  B. ENVELOPE (`VersionedBlob`) — for ARRAY-rooted blobs, and for object-rooted blobs whose keys are
//     USER-controlled. An array has no place to put a sibling key. And `variablesData` is
//     `[String: String]` of workflow variable NAMES — an inline key there would collide with a user
//     variable actually called "schemaVersion". Applies to timelineEventsData, variablesData,
//     attachedFileURLsJSON.
//
//  ⚠️ WHY NOT JUST ADD `var schemaVersion: Int` TO EACH TYPE — the obvious move, and it is the G13
//  trap. Swift's synthesized `init(from:)` calls `decode(_:forKey:)` for every non-optional stored
//  property EVEN WHEN IT HAS A DEFAULT, so adding the property would make every already-persisted
//  blob throw `keyNotFound` — the precise failure this whole effort exists to prevent. Stamping at
//  the JSON level (what `ProfileBlobGate` does with `json["schemaVersion"]`) touches no
//  type's Codable conformance.
//

import Foundation

// MARK: - Mechanism A: inline key

enum BlobVersioning {

    /// The key stamped into object-rooted blobs. Matches the name `ProfileBlobGate` reads on
    /// `configData`, so the app has ONE spelling of this concept rather than two.
    static let versionKey = "schemaVersion"

    /// Reads the version stamped into a blob, or nil when it carries none. Deliberately tolerant of
    /// any root shape — an array simply has no version, which is the truth.
    static func version(of data: Data) -> Int? {
        struct Probe: Decodable { let schemaVersion: Int? }
        return (try? JSONDecoder().decode(Probe.self, from: data))?.schemaVersion
    }

    /// Returns `data` with a version key inserted, WITHOUT re-encoding the payload.
    ///
    /// ⚠️ Byte-level insertion, deliberately. The obvious implementation — deserialize with
    /// `JSONSerialization`, add the key, re-serialize — is LOSSY ON DOUBLES: its writer does not
    /// round-trip every floating-point value, so blobs carrying `TimeInterval`s (node timeouts, run
    /// durations, canvas coordinates) would drift a little on every save. Splicing the key in after
    /// the opening brace leaves every other byte exactly as the encoder produced it.
    ///
    /// IDEMPOTENT: stamping an already-stamped blob replaces the value rather than producing a
    /// duplicate key. This matters because `MessageContent.unknown` preserves an unrecognised
    /// payload VERBATIM — including a version key it did not write — and re-emits it on the next
    /// save.
    ///
    /// Non-object roots are returned unchanged: an array cannot carry a sibling key, and silently
    /// corrupting it would be far worse than leaving it unstamped. Use `VersionedBlob` for those.
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

    /// Decodes the envelope. Returns nil when the bytes are not one — a genuine decode failure the
    /// caller must treat as unreadable rather than as "empty". A bare, unwrapped payload is NOT
    /// accepted: that shape predates versioning and is no longer read (2026-10-03 reset).
    static func decode(from data: Data, decoder: JSONDecoder = JSONDecoder())
        -> (payload: Payload, version: Int)? {
        guard let wrapped = try? decoder.decode(VersionedBlob<Payload>.self, from: data) else { return nil }
        return (wrapped.payload, wrapped.schemaVersion)
    }
}
