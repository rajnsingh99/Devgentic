// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  TimelineRowDetail.swift
//  Devgentic
//
//  What a timeline tool row reveals when you expand it.
//
//  This exists as one named value rather than three inline conditions because that is
//  precisely how it broke. `ActionDetailView` gated its chevron and its tap target on
//  `data.output` while the body gated on `data.effect`, so a write row — which has BOTH —
//  rendered its diff unconditionally under a chevron that toggled a flag nothing read
//  (field-reported 2026-07-27). The mirror case is just as bad: an effect with no output
//  would render a diff with no chevron and no way to collapse it.
//
//  Every one of those three call sites now asks this type.
//

import Foundation

/// The one thing a tool row discloses, or `nil` when it has nothing to show.
enum TimelineRowDetail {
    /// A write's real output is WHAT IT WROTE. `"Successfully wrote to X"` only restates the
    /// row's own verb and path, so the diff takes its place — exactly as a read row shows
    /// the content it read.
    ///
    /// `note` carries the rare output that the diff CANNOT represent, and is nil for the
    /// common case. See `resolve`.
    case diff(ActionEffect, note: String?)
    /// Everything else discloses its raw tool output.
    case output(String)

    /// Precedence is deliberate: an effect with a diff wins over the output string, because
    /// that output is the redundant one.
    ///
    /// The exception is a PARTIAL failure. `edit_code_batch` writes the file when even one
    /// edit lands and returns `"Applied 1/3 edit(s) to X.\nErrors:\n…"`, which
    /// `isSemanticFailure` classifies as success — so the row gets a real diff, and letting
    /// the diff displace that output hid the only report of the two edits that did NOT apply.
    /// The discriminator is "the output is multi-line": every shipping success string is one
    /// line, and only a partial batch appends an error list. No tool-name list to keep in
    /// sync, no sniffing for the word "error".
    ///
    /// A no-op write (`effect.diff == nil`, 0/0) correctly falls through to `.output` — the
    /// row still has "Successfully wrote…" to show, and "No changes" is already on the chip.
    static func resolve(_ data: ToolExecutionData) -> TimelineRowDetail? {
        if let effect = data.effect, effect.diff != nil {
            let note = data.output
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.contains("\n") ? $0 : nil }
            return .diff(effect, note: note)
        }
        if let out = data.output, !out.isEmpty { return .output(out) }
        return nil
    }
}
