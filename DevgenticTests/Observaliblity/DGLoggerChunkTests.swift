// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DGLoggerChunkTests.swift
//  DevgenticTests
//
//  Cover for `DGLogger.chunk`, the splitter behind the `[PROMPT-FULL]` / `[PROMPT-RENDERED]`
//  verbatim dumps.
//
//  ⚠️ WHY THIS IS WORTH TESTING AT ALL. These dumps exist because sizes-only logging cost this
//  project three wrong root causes in a row — the log kept reporting "system=1749 chars" while
//  everyone guessed at the contents. A splitter that drops the tail, or tears a multi-byte
//  character at a chunk seam, would put CORRUPTED evidence in front of the next investigation,
//  which is worse than no evidence: it still looks authoritative.
//

import XCTest
@testable import devgentic

final class DGLoggerChunkTests: XCTestCase {

    /// LOSSLESSNESS — the property that matters most. Reassembling the chunks must reproduce the
    /// input exactly, or the dump quietly misrepresents what the model read.
    func testChunksReassembleToTheOriginalExactly() {
        let body = String((0..<2500).map { _ in "abcdefghij".randomElement()! })
        for size in [1, 7, 800, 2499, 2500, 5000] {
            XCTAssertEqual(DGLogger.chunk(body, size: size).joined(), body,
                           "lossy at size \(size) — the dump would misrepresent the prompt")
        }
    }

    func testSplitsAtTheRequestedBoundary() {
        let parts = DGLogger.chunk(String(repeating: "x", count: 250), size: 100)
        XCTAssertEqual(parts.map(\.count), [100, 100, 50])
    }

    func testBodyShorterThanChunkSizeStaysOnePiece() {
        XCTAssertEqual(DGLogger.chunk("short", size: 800), ["short"])
    }

    /// ⚠️ THE MULTI-BYTE GUARANTEE. Prompts carry em dashes (this codebase's own section headers
    /// use them), non-Latin filenames and emoji in user queries. Splitting on UTF-8 bytes would
    /// emit replacement characters at every seam.
    func testMultiByteCharactersAreNeverSplit() {
        let body = "😀🇯🇵é—漢字" + String(repeating: "🙂", count: 50)
        let parts = DGLogger.chunk(body, size: 3)
        XCTAssertEqual(parts.joined(), body, "a grapheme was torn across a chunk boundary")
        XCTAssertFalse(parts.joined().contains("\u{FFFD}"), "replacement character introduced")
        for part in parts {
            XCTAssertLessThanOrEqual(part.count, 3, "chunk exceeded the requested character count")
        }
    }

    /// An empty prompt must be VISIBLE. Returning [] would render "0 chunk(s)" and read as
    /// "logging is broken" rather than "the prompt really was empty".
    func testEmptyBodyReportsItselfRatherThanVanishing() {
        XCTAssertEqual(DGLogger.chunk("", size: 800), ["<empty>"])
    }

    /// A corrupt or defaulted size must not divide by zero or spin forever.
    func testNonPositiveSizeDegradesToOneCharacterChunks() {
        for size in [0, -1, -9999] {
            XCTAssertEqual(DGLogger.chunk("abc", size: size), ["a", "b", "c"],
                           "size \(size) must be clamped, not fatal")
        }
    }

    /// The gate is what makes a verbatim dump defensible; absence of the key must mean OFF, so a
    /// normal build never emits prompt bodies.
    func testDeveloperModeGateDefaultsToOff() {
        let suite = "DGLoggerChunkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: AppSettings.developerModeKey),
                       "absent-means-false is what the dump gate relies on")
    }
}
