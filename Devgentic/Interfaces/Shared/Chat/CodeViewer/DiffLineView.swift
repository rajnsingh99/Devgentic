// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiffLineView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A diff row as attributed text, with the intra-line changed runs emphasized.
///
/// `DiffUtility.generateDiff` populates `segments` for modified line pairs; when it
/// didn't (pure add/delete, or refinement declined the pair) the whole line renders
/// plainly, which is the correct fallback.
func diffLineText(_ result: DiffResult, emphasisBackground: Color) -> Text {
    guard let segments = result.segments, segments.count > 1 else {
        return Text(result.line)
    }
    return segments.reduce(Text(verbatim: "")) { partial, segment in
        let piece = segment.isEmphasized
            ? Text(segment.text).bold()
            : Text(segment.text)
        return partial + piece
    }
}

/// One diff row with a `+` / `−` gutter and a tinted background.
struct DiffLineRow: View {
    let result: DiffResult
    @Environment(\.appTheme) private var theme

    var body: some View {
        let (bg, fg, sign): (Color, Color, String) = {
            switch result.type {
            case .added:     return (theme.successColor.opacity(0.14), theme.successColor, "+")
            case .deleted:   return (theme.errorColor.opacity(0.14), theme.errorColor, "−")
            case .unchanged: return (Color.clear, theme.tertiaryText, " ")
            }
        }()
        HStack(spacing: 4) {
            Text(verbatim: sign).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(fg).frame(width: 8)
            // Intra-line refinement: modified pairs highlight just the changed characters
            // instead of tinting the whole line.
            (result.line.isEmpty
                ? Text(verbatim: " ")
                : diffLineText(result, emphasisBackground: fg.opacity(0.24)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(result.type == .unchanged ? theme.secondaryText : fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 0.5)
        .background(bg)
        // The gutter sign read aloud is "minus" / "plus" — say what the row IS.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(result))
    }

    static func spokenLabel(_ result: DiffResult) -> String {
        let text = result.line.isEmpty ? String(localized: "blank line") : result.line
        switch result.type {
        case .added: return String(localized: "Added: \(text)")
        case .deleted: return String(localized: "Removed: \(text)")
        case .unchanged: return text
        }
    }
}

/// Rows capped at `lineCap`, with an "… N more lines" tail so a cut list never reads as whole.
/// No scroll container of its own — callers decide (the banner bounds its height; the Git panel
/// scrolls with its list).
struct DiffLinesList: View {
    let diff: [DiffResult]
    var lineCap: Int = 400
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.prefix(lineCap)) { result in
                DiffLineRow(result: result)
            }
            if diff.count > lineCap {
                Text("… \(diff.count - lineCap) more lines")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.vertical, 2)
            }
        }
    }
}
