// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  BinaryContentSniffer.swift
//  Devgentic
//
//  Whether a byte sequence plausibly IS text, asked before any lossy decode of it.
//

import Foundation

/// Guards the lossy-decode fallbacks that every text reader in the app eventually reaches for.
///
/// The hazard it exists for is specific and easy to reintroduce. ISO Latin-1 maps all 256 byte
/// values, so `String(data:encoding:.isoLatin1)` CANNOT return nil: it is not a decode attempt at
/// all, it is a reinterpretation that always succeeds. Used as a fallback without a guard it
/// converts "this file is not text" into a screenful of mojibake returned as the file's contents —
/// and a caller reasons over that as though it were real. `read_file` shipped exactly that for the
/// plain-text branch, and `CSVExtractor` rendered arbitrary binary as a *markdown table*, which
/// reads as structured data and is the more convincing lie of the two.
///
/// A rejected read is a fact the caller can act on. A confident wrong answer is not.
///
/// Only meaningful AFTER a strict decode has already failed — valid UTF-8 is text by definition
/// and must never be routed through here.
enum BinaryContentSniffer {

    /// Bytes examined. Bounded so the check costs the same on a 4 KB file and a 4 GB one; binary
    /// formats declare themselves in their header, so reading further buys nothing.
    static let sampleSize = 8_000

    /// Share of C0 control characters above which content is judged binary.
    ///
    /// Not zero: a stray control byte appears in legitimate text (terminal captures, old exports),
    /// and refusing those would be its own bug. Ten percent is far above what any text file
    /// reaches and far below what binary does — the distributions are not close, so the exact
    /// figure is not load-bearing.
    static let controlByteThreshold = 0.10

    /// Whether `data`'s leading bytes look like binary rather than text.
    ///
    /// Three rules, in order:
    ///
    /// 1. A leading Unicode BOM means text, and overrides everything below. It has to: UTF-16
    ///    encodes ASCII as alternating letter/NUL pairs, so rule 2 alone would refuse every UTF-16
    ///    file — the format a good deal of Windows tooling emits by default. A BOM is the file
    ///    stating its own encoding, which beats any heuristic that follows it.
    /// 2. A NUL byte means binary. This is the rule git uses, for the good reason that text
    ///    essentially never contains one and almost every binary format does.
    /// 3. A high share of C0 control characters means binary — catching formats that happen to
    ///    have no NUL early on.
    ///
    /// Deliberately does NOT count bytes above 0x7F. Those are exactly what Latin-1 and UTF-16
    /// text are made of, so counting them would refuse the files this guard exists to let through.
    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(sampleSize)
        guard !sample.isEmpty else { return false }

        let boms: [[UInt8]] = [
            [0xFF, 0xFE, 0x00, 0x00],   // UTF-32LE — tested before the UTF-16LE prefix it contains
            [0x00, 0x00, 0xFE, 0xFF],   // UTF-32BE
            [0xFF, 0xFE],               // UTF-16LE
            [0xFE, 0xFF],               // UTF-16BE
            [0xEF, 0xBB, 0xBF]          // UTF-8
        ]
        if boms.contains(where: { sample.starts(with: $0) }) { return false }

        if sample.contains(0) { return true }

        let control = sample.filter { byte in
            byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x0C
        }.count
        return Double(control) / Double(sample.count) > controlByteThreshold
    }

    /// Whether the file at `url` looks binary, reading only a bounded prefix.
    ///
    /// Returns false when the file cannot be opened: this is a guard on CONTENT, and an
    /// unreadable file is a different failure that its caller reports on its own terms. Answering
    /// "binary" here would mislabel a permissions problem.
    static func looksBinary(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let sample = try? handle.read(upToCount: sampleSize) else { return false }
        return looksBinary(sample)
    }
}
