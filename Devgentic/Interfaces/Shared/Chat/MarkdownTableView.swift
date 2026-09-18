// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MarkdownTableView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/08/25.
//
//  REWRITTEN (2026-07-16) from `Grid` to measured fixed-width columns. Grid sized
//  cells at a different width than it laid them out (unlimited proposal inside the
//  horizontal ScrollView vs the 400pt cap), and the cells' `fixedSize(vertical:)`
//  text then drew at its true height anyway — bleeding across neighbouring rows in
//  both directions (center-anchored overflow). Column widths are now measured
//  up-front (single-line NSAttributedString measurement, clamped to [min, max]),
//  so wrap heights are deterministic and each row is simply a top-aligned HStack
//  that grows to its tallest cell. Row backgrounds/hover are per-ROW, so stripes
//  always cover every wrapped line.
//

import SwiftUI
import os

private let logger = DGLogger(category: "MarkdownTableView")

/// The strings VoiceOver speaks for a table.
///
/// Pulled out of the views because it's pure logic with real edge cases (empty cells,
/// unnamed columns, pluralisation) and because a SwiftUI accessibility label cannot be
/// read back from a hosted view in a test — the a11y tree is built lazily when a real
/// assistive client attaches. Testing these functions is the only way to pin the contract.
/// [mc-13] One table's last width measurement, keyed by a hash of the cells it measured.
private final class ColumnWidthCache {
    var entry: (key: Int, widths: [CGFloat])?
}

enum TableSpeech {

    /// Spoken on landing, before navigating in. Without it a table was indistinguishable
    /// from loose prose: you'd hear cell values with no clue they were tabular, how many
    /// there were, or where the table ended.
    static func tableSummary(rowCount: Int, columnCount: Int, headers: [String], truncatedTo limit: Int?) -> String {
        let shape = "Table, \(rowCount) \(rowCount == 1 ? "row" : "rows"), "
            + "\(columnCount) \(columnCount == 1 ? "column" : "columns")"
        let named = headers.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var summary = named.isEmpty ? shape : "\(shape). Columns: \(named.joined(separator: ", "))"
        if let limit, rowCount > limit {
            summary += ". Showing first \(limit)"
        }
        return summary
    }

    /// A data cell. The column name comes first because the value alone means nothing —
    /// "42" or "failed" only says something once you know which column it sits in.
    ///
    /// `value` must be the RENDERED text, not the markdown source: VoiceOver should read
    /// "done", not "asterisk asterisk done".
    static func cellLabel(value: String, header: String) -> String {
        let spoken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty cell must SAY it's empty — silence is indistinguishable from a bug.
        let body = spoken.isEmpty ? String(localized: "empty") : spoken
        let column = header.trimmingCharacters(in: .whitespacesAndNewlines)
        return column.isEmpty ? body : "\(column), \(body)"
    }

    static func headerCellLabel(value: String) -> String {
        let spoken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return spoken.isEmpty ? String(localized: "Unnamed column") : String(localized: "\(spoken), column header")
    }

    static func rowLabel(index: Int, of total: Int) -> String {
        String(localized: "Row \(index + 1) of \(total)")
    }

    /// [mc-10] What a CELL speaks, header or data. The one entry point the table's two
    /// `accessibilityLabel`s call, so "what production speaks" and "what the tests pin" are
    /// the same function rather than two implementations that drifted (the private twin this
    /// replaced did not trim the header before testing it for emptiness, so a whitespace-only
    /// header spoke "   , 42" on screen and "42" in the suite).
    static func label(value: String, header: String, isHeader: Bool) -> String {
        isHeader ? headerCellLabel(value: value) : cellLabel(value: value, header: header)
    }

    /// The header row's own label. Deliberately its own constant rather than a case of
    /// `rowLabel(index:of:)` — "Column headers" is a different sentence, not row zero, and
    /// `rowLabel` cannot express it. [mc-10] It was an inline literal at the call site, which
    /// is precisely how the view and this enum drifted apart in the first place.
    static let headerRowLabel = String(localized: "Column headers")
}

/// Serialises a parsed table back to GitHub-Flavored Markdown.
///
/// The previous inline version produced markdown that didn't re-parse as the same table:
/// it never escaped `|` (so one pipe in a cell silently split it into two), it sized the
/// separator row from `headers.count` while data rows used their own length (ragged input
/// → mismatched separator → not a table at all downstream), and it dropped column
/// alignment. Extracted so the round trip can actually be tested.
enum TableMarkdown {

    static func serialize(
        headers: [String],
        rows: [[String]],
        alignments: [ContentBlock.ColumnAlignment] = []
    ) -> String {
        // ONE column count for every row including the separator. GFM requires the
        // separator to match the header exactly, and a row that's longer than the header
        // is otherwise emitted with cells no separator accounts for.
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return "" }

        let headerRow = line(padding(headers, to: columnCount))
        let separatorRow = line((0..<columnCount).map { column in
            separator(for: column < alignments.count ? alignments[column] : .leading)
        }, escape: false)
        let dataRows = rows.map { line(padding($0, to: columnCount)) }

        return ([headerRow, separatorRow] + dataRows).joined(separator: "\n")
    }

    private static func padding(_ cells: [String], to count: Int) -> [String] {
        cells.count >= count
            ? Array(cells.prefix(count))
            : cells + Array(repeating: "", count: count - cells.count)
    }

    private static func line(_ cells: [String], escape: Bool = true) -> String {
        "| " + cells.map { escape ? escapeCell($0) : $0 }.joined(separator: " | ") + " |"
    }

    /// A literal `|` must be escaped or it reads as a column boundary, and a newline ends
    /// the row — GFM's only in-cell line break is `<br>`.
    static func escapeCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func separator(for alignment: ContentBlock.ColumnAlignment) -> String {
        switch alignment {
        case .leading:  return "---"
        case .center:   return ":---:"
        case .trailing: return "---:"
        }
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    /// Per-column `:--` / `:-:` / `--:` alignment, parallel to `headers`. Short or empty
    /// falls back to leading, which is what GFM renders for an unspecified column.
    var alignments: [ContentBlock.ColumnAlignment] = []
    /// Cell text size. Tables read best a step below body prose (GitHub/Notion
    /// convention) — ContentBlockView passes `chatFontSize - 2`.
    var cellFontSize: CGFloat = 13

    private func alignment(for column: Int) -> ContentBlock.ColumnAlignment {
        column < alignments.count ? alignments[column] : .leading
    }

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // NB: row hover state deliberately does NOT live here. It used to (`hoveredRowIndex`),
    // which meant every mouse move between rows re-ran THIS view's `body` — and `body`
    // measures every visible cell (see `columnWidths`). Each row now owns its own hover
    // flag, so hovering re-renders one row instead of re-measuring the whole table.
    // Fixing the spurious invalidation beats caching around it — and [mc-13] the cache that
    // replaced it is keyed on the CONTENT it measures, not on first appearance, which is the
    // difference between the two: the 2026-07-16 crash came from a key that could not notice
    // the table had grown.

    /// Maximum rows rendered before showing "Show all" button.
    /// Prevents rendering 100+ rows on initial layout.
    private static let initialRowLimit = 50
    @State private var isExpanded: Bool = false

    /// [mc-13] Content-keyed memo for `columnWidths`. A CLASS so that writing it from `body`
    /// publishes nothing (a `@State` value write during a view update is the mutation SwiftUI
    /// warns about); `@State` so that it lives and dies with this view rather than accumulating
    /// in a process-lifetime static across a session full of tables.
    @State private var widthCache = ColumnWidthCache()

    private static let minColumnWidth: CGFloat = 60
    private static let maxColumnWidth: CGFloat = 400
    private static let cellHorizontalPadding: CGFloat = 8
    private static let cellVerticalPadding: CGFloat = 6

    /// The rows actually rendered — capped unless expanded.
    private var visibleRows: ArraySlice<[String]> {
        if isExpanded || rows.count <= Self.initialRowLimit {
            return rows[...]
        }
        return rows[..<Self.initialRowLimit]
    }

    /// One column per header; ragged LLM output is normalized — a row's extra
    /// cells beyond the widest known column count are dropped (GFM behaviour),
    /// missing cells render empty.
    private var columnCount: Int {
        max(headers.count, visibleRows.map(\.count).max() ?? 0)
    }

    /// Single-line ideal width per column over the VISIBLE cells, clamped to
    /// [min, max] + padding. Measuring the raw markdown source slightly
    /// over-estimates rendered width (syntax characters) — the safe direction.
    ///
    /// [mc-13] Memoized on a hash of everything it reads — the visible cells, the headers, the
    /// column count and the font size — so a `body` pass that changes none of them reuses the
    /// answer instead of rebuilding an `NSAttributedString` per cell. The previous comment here
    /// claimed the opposite twice over: that a cache "goes stale under a streaming table's
    /// stable identity" (true only of the 2026-07-16 cache, which was keyed at first APPEARANCE
    /// — a content-keyed one cannot go stale, because the key changes with the content), and
    /// that `body` "only re-runs when the content actually changes", which is not a guarantee
    /// SwiftUI makes: an ancestor invalidation, a theme change or a font-size change re-runs it
    /// with identical cells, and each of those paid a full re-measure.
    ///
    /// The cache lives in a REFERENCE box held by `@State`, not in `@State` directly: `body`
    /// reads this, and publishing a `@State` write during a view update is the mutation SwiftUI
    /// warns about. The box dies with the view, so nothing accumulates across a session.
    ///
    /// ⚠️ The 2026-07-16 crash is separately defended now — `TableRowView` reads
    /// `column < widths.count ? widths[column] : 60` — so a short array renders a fallback
    /// width rather than trapping. That guard, not this cache's shape, is what makes the
    /// failure mode survivable; do not remove it on the strength of this comment.
    private var columnWidths: [CGFloat] {
        let count = columnCount
        guard count > 0 else { return [] }

        let key = Self.widthKey(fontSize: cellFontSize, columnCount: count, headers: headers, rows: visibleRows)
        if let cached = widthCache.entry, cached.key == key { return cached.widths }

        let font = NSFont.systemFont(ofSize: cellFontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: cellFontSize)

        func measure(_ text: String, bold: Bool) -> CGFloat {
            NSAttributedString(
                string: text,
                attributes: [.font: bold ? boldFont : font]
            ).size().width
        }

        let widths: [CGFloat] = (0..<count).map { column in
            var ideal: CGFloat = 0
            if column < headers.count {
                ideal = measure(headers[column], bold: true)
            }
            for row in visibleRows where column < row.count {
                ideal = max(ideal, measure(row[column], bold: false))
            }
            // Slack for bold/inline-code runs the plain measurement underestimates.
            let text = min(Self.maxColumnWidth, max(Self.minColumnWidth, ideal.rounded(.up) + 10))
            return text + Self.cellHorizontalPadding * 2
        }
        widthCache.entry = (key, widths)
        return widths
    }

    /// [mc-13] Everything `columnWidths` reads, hashed. THE property that makes the memo safe:
    /// the 2026-07-16 cache keyed on first appearance, so a streaming table that grew kept the
    /// widths it was measured at — and the row array outgrew them. Anything that can change a
    /// measured width must be in here.
    nonisolated static func widthKey(fontSize: CGFloat, columnCount: Int, headers: [String],
                                     rows: some Sequence<[String]>) -> Int {
        var hasher = Hasher()
        hasher.combine(fontSize)
        hasher.combine(columnCount)
        hasher.combine(headers)
        for row in rows { hasher.combine(row) }
        return hasher.finalize()
    }

    var body: some View {
        let widths = columnWidths

        ScrollView(.horizontal, showsIndicators: true) {
            // Lazy so an expanded 500-row table materialises its rows on demand rather than
            // all at once. NB the dominant cost is `columnWidths`, which measures the row DATA
            // (not the views) and so isn't affected by laziness — [mc-13] it is memoized on the
            // content it measures instead, which is what keeps a re-run that changed nothing
            // (an ancestor invalidation, a hover elsewhere, a theme change) from re-measuring
            // every cell. A real content change still re-measures, which is correct.
            LazyVStack(alignment: .leading, spacing: 0) {
                // MARK: - Header Row
                TableRowView(
                    cells: paddedHeaders,
                    headers: paddedHeaders,
                    alignments: (0..<columnCount).map(alignment(for:)),
                    widths: widths,
                    columnCount: columnCount,
                    cellFontSize: cellFontSize,
                    isHeader: true,
                    isOddRow: false,
                    rowLabel: TableSpeech.headerRowLabel
                )
                .background(theme.secondaryText.opacity(0.1))

                Divider()

                // MARK: - Data Rows (virtualized via visibleRows)
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { rowIndex, row in
                    TableRowView(
                        cells: row,
                        headers: paddedHeaders,
                        alignments: (0..<columnCount).map(alignment(for:)),
                        widths: widths,
                        columnCount: columnCount,
                        cellFontSize: cellFontSize,
                        isHeader: false,
                        isOddRow: rowIndex % 2 != 0,
                        rowLabel: TableSpeech.rowLabel(index: rowIndex, of: rows.count)
                    )

                    if rowIndex < visibleRows.count - 1 {
                        Divider()
                    }
                }

                // MARK: - Expand / Collapse Row
                // Expanding used to be one-way: a 500-row table you opened by accident
                // stayed 500 rows tall for the rest of the conversation, with no way back.
                if rows.count > Self.initialRowLimit {
                    Divider()
                    Button {
                        withAnimation(reduceMotion ? nil : .default) { isExpanded.toggle() }
                    } label: {
                        Text(isExpanded
                             ? "Show first \(Self.initialRowLimit) rows"
                             : "Show all \(rows.count) rows (\(rows.count - Self.initialRowLimit) more)")
                            .font(.caption)
                            .foregroundColor(theme.accentColor)
                            .frame(width: max(widths.reduce(0, +), 200), alignment: .center)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded
                                        ? "Collapse to the first \(Self.initialRowLimit) rows"
                                        : "Show all \(rows.count) table rows")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                    .stroke(theme.dividerColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusSmall))
            .padding(.bottom, theme.spacingMedium)
            // A container, NOT `.combine`: combining would flatten the whole table into one
            // run-on utterance. `.contain` keeps rows and cells individually navigable and
            // gives VoiceOver the shape of the thing before you walk into it.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tableSummary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Global Table Actions
        .contextMenu {
            Button {
                copyTableAsMarkdown()
            } label: {
                Label("Copy Table (Markdown)", systemImage: "tablecells")
            }
        }
    }

    /// Headers padded up to `columnCount` so ragged input still yields a full grid.
    private var paddedHeaders: [String] {
        headers + Array(repeating: "", count: max(0, columnCount - headers.count))
    }

    private var tableSummary: String {
        TableSpeech.tableSummary(
            rowCount: rows.count,
            columnCount: columnCount,
            headers: headers,
            truncatedTo: isExpanded ? nil : Self.initialRowLimit
        )
    }

    private func copyTableAsMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            TableMarkdown.serialize(headers: headers, rows: rows, alignments: alignments),
            forType: .string
        )
    }
}

/// One table row: top-aligned fixed-width cells. Row height = tallest cell, by plain
/// HStack layout — no grid sizing pass to disagree with.
///
/// Owns its OWN hover state. That's the point: hover used to live on `MarkdownTableView`,
/// so moving the mouse between rows re-ran the parent's `body` — which re-measures every
/// visible cell. Now a hover repaints one row and the parent never hears about it.
private struct TableRowView: View {
    let cells: [String]
    /// The column headers, so each cell can say which column it belongs to. A cell value
    /// read on its own ("42", "failed") is meaningless without its column.
    let headers: [String]
    /// Resolved per-column alignment, already defaulted — index-parallel to the columns.
    let alignments: [ContentBlock.ColumnAlignment]
    let widths: [CGFloat]
    let columnCount: Int
    let cellFontSize: CGFloat
    let isHeader: Bool
    /// Drives the zebra stripe; the row doesn't need to know its index.
    let isOddRow: Bool
    /// Spoken position ("Row 3 of 12"). Sighted users get this from the stripes and layout.
    let rowLabel: String

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { column in
                TableCellView(
                    content: column < cells.count ? cells[column] : "",
                    header: isHeader ? "" : (column < headers.count ? headers[column] : ""),
                    isHeader: isHeader,
                    fontSize: cellFontSize,
                    alignment: column < alignments.count ? alignments[column] : .leading
                )
                .equatable()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(
                    width: column < widths.count ? widths[column] : 60,
                    alignment: (column < alignments.count ? alignments[column] : .leading).frameAlignment
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(background)
        // Header rows aren't interactive, so don't track hover for them.
        .onHover { hovering in
            guard !isHeader else { return }
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rowLabel)
    }

    private var background: Color {
        if isHovered { return theme.secondaryText.opacity(0.1) }
        return isOddRow ? theme.secondaryText.opacity(0.03) : Color.clear
    }
}

/// Equatable so `.equatable()` at the call sites skips re-invoking `body` (and the
/// markdown parse inside it) for cells whose content hasn't changed. Deliberately
/// STATELESS: cell caches derived from init parameters go stale when a streaming
/// table grows under a stable identity.
private struct TableCellView: View, Equatable {
    let content: String
    /// This cell's column name, "" for a header cell (which IS the name).
    let header: String
    let isHeader: Bool
    let fontSize: CGFloat
    /// `--:` on a numeric column is a real instruction from the author; we parsed it and
    /// then rendered everything leading regardless.
    let alignment: ContentBlock.ColumnAlignment
    @Environment(\.appTheme) private var theme

    static func == (lhs: TableCellView, rhs: TableCellView) -> Bool {
        lhs.content == rhs.content && lhs.header == rhs.header
            && lhs.isHeader == rhs.isHeader && lhs.fontSize == rhs.fontSize
            && lhs.alignment == rhs.alignment
    }

    private var imageURL: URL? {
        guard content.hasPrefix("http"), let url = URL(string: content),
              ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }

    var body: some View {
        Group {
            if let url = imageURL {
                imageCell(url)
            } else {
                textCell
            }
        }
        // Cell-specific Actions
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            } label: {
                Label("Copy Cell", systemImage: "doc.on.doc")
            }
        }
    }

    /// The one place cell markdown is parsed. The spoken label reuses THIS parse rather
    /// than re-deriving it — VoiceOver must read "done", not "asterisk asterisk done".
    private var textCell: some View {
        let attributed = (try? AttributedString(markdown: content)) ?? AttributedString(content)
        return Text(attributed)
            .font(.system(size: fontSize, weight: isHeader ? .bold : .regular))
            .foregroundColor(theme.primaryText)
            .multilineTextAlignment(alignment.textAlignment)
            .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TableSpeech.label(value: String(attributed.characters), header: header, isHeader: isHeader))
            .accessibilityAddTraits(isHeader ? .isHeader : [])
    }

    private func imageCell(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable()
                     .aspectRatio(contentMode: .fit)
                     .frame(maxHeight: 150)
                     .clipShape(RoundedRectangle(cornerRadius: 4))
                     .accessibilityAddTraits(.isImage)
            case .failure(let error):
                Image(systemName: "photo.fill")
                    .font(.largeTitle)
                    .foregroundColor(theme.secondaryText)
                    .onAppear {
                        logger.error("Failed to load image from URL \(url.absoluteString): \(error.localizedDescription)")
                    }
            case .empty:
                ProgressView()
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxHeight: 150)
        .help(url.absoluteString)
        .accessibilityElement(children: .ignore)
        // The filename is the only description a bare image URL in a cell carries.
        .accessibilityLabel(TableSpeech.label(value: "Image, \(url.lastPathComponent)", header: header, isHeader: isHeader))
    }

    // [mc-10] The spoken label is `TableSpeech.label(value:header:isHeader:)`, called directly
    // at both `accessibilityLabel` sites above. There used to be a private re-implementation
    // here — four English literals and a subtly different empty-header test — which is what
    // production actually spoke while every assertion in `ChatAccessibilitySemanticsTests`
    // pinned the unused `TableSpeech` copy, localized entries and all.
}
