// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MarkdownTableView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "MarkdownTableView")

/// One table's last width measurement, keyed by a hash of the cells it measured.
private final class ColumnWidthCache {
    var entry: (key: Int, widths: [CGFloat])?
}

/// The strings VoiceOver speaks for a table.
/// Kept as pure logic so empty cells, unnamed columns and pluralisation can be tested without a hosted view.
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

    /// A data cell label. The column name comes first because the value alone means nothing.
    /// `value` must be the rendered text, not the markdown source, so VoiceOver reads "done" rather than the asterisks.
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

    /// Returns what a cell speaks, header or data. The single entry point both `accessibilityLabel`s call,
    /// so production speech and the tests exercise the same function.
    static func label(value: String, header: String, isHeader: Bool) -> String {
        isHeader ? headerCellLabel(value: value) : cellLabel(value: value, header: header)
    }

    /// The header row's own label; a separate constant because "Column headers" is a different sentence, not row zero.
    static let headerRowLabel = String(localized: "Column headers")
}

/// Serialises a parsed table back to GitHub-Flavored Markdown that re-parses as the same table.
/// Escapes `|` in cells, sizes the separator to the widest row, and keeps column alignment.
enum TableMarkdown {

    static func serialize(
        headers: [String],
        rows: [[String]],
        alignments: [ContentBlock.ColumnAlignment] = []
    ) -> String {
        // One column count for every row including the separator: GFM requires the separator to match the header,
        // and a longer row would otherwise emit cells no separator accounts for.
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

    // Row hover state lives in each row, not here: hover on this view re-ran `body`, which measures every visible cell.
    // Each row owns its hover flag, so hovering re-renders one row.

    /// Maximum rows rendered before showing "Show all" button.
    /// Prevents rendering 100+ rows on initial layout.
    private static let initialRowLimit = 50
    @State private var isExpanded: Bool = false

    /// Content-keyed memo for `columnWidths`. A class so writing it from `body` publishes nothing;
    /// `@State` so it lives and dies with this view.
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

    // Why: `TableRowView` falls back to a default width for a missing column; keep that guard, the memo does not replace it.
    /// Single-line ideal width per column over the visible cells, clamped to [min, max] plus padding.
    /// Memoized on a hash of the visible cells, headers, column count and font size, so repeated passes do not re-measure.
    /// Measures the raw markdown source, which slightly over-estimates rendered width (the safe direction).
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

    /// Hashes everything `columnWidths` reads: the visible cells, headers, column count and font size.
    /// Anything that can change a measured width must be in the key, or a growing streaming table keeps stale widths.
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
            // Lazy so an expanded long table materialises rows on demand. The dominant cost is `columnWidths`, which measures
            // row data and is memoized on its content, so a re-run that changed nothing does not re-measure.
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
            // A container, not `.combine`: combining would flatten the table into one utterance;
            // `.contain` keeps rows and cells individually navigable.
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

/// One table row: top-aligned fixed-width cells; row height is the tallest cell, by plain HStack layout.
/// Owns its own hover state, so hovering repaints one row without re-running the parent's `body`.
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

/// Equatable so `.equatable()` at the call sites skips `body` (and the markdown parse) for unchanged cells.
/// Stateless on purpose: caches derived from init parameters go stale when a streaming table grows in place.
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

}
