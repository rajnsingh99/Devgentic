//
//  MarkdownTableView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/08/25.
//
//  ENHANCED: Fixed layout overlapping using Grid, added horizontal scrolling, and text wrapping.

import SwiftUI
import os

private let logger = DGLogger(category: "MarkdownTableView")

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    @Environment(\.appTheme) private var theme
    @State private var hoveredRowIndex: Int? = nil

    /// Maximum rows rendered before showing "Show all" button.
    /// Prevents Grid from rendering 100+ rows on initial layout.
    private static let initialRowLimit = 50
    @State private var isExpanded: Bool = false

    /// The rows actually rendered — capped unless expanded.
    private var visibleRows: ArraySlice<[String]> {
        if isExpanded || rows.count <= Self.initialRowLimit {
            return rows[...]
        }
        return rows[..<Self.initialRowLimit]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                // MARK: - Header Row
                GridRow {
                    ForEach(headers.indices, id: \.self) { index in
                        TableCellView(content: headers[index], isHeader: true)
                            .background(theme.secondaryText.opacity(0.1))
                    }
                }

                // Header Divider
                Divider()
                    .gridCellColumns(headers.count)

                // MARK: - Data Rows (virtualized via visibleRows)
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(row.indices, id: \.self) { colIndex in
                            TableCellView(content: row[colIndex], isHeader: false)
                                .background(rowBackgroundColor(for: rowIndex))
                                .onHover { isHovering in
                                    if isHovering {
                                        hoveredRowIndex = rowIndex
                                    } else if hoveredRowIndex == rowIndex {
                                        hoveredRowIndex = nil
                                    }
                                }
                        }
                    }

                    // Row Divider (except after the last visible row)
                    if rowIndex < visibleRows.count - 1 {
                        Divider()
                            .gridCellColumns(headers.count)
                    }
                }

                // MARK: - "Show All" Row
                if !isExpanded && rows.count > Self.initialRowLimit {
                    GridRow {
                        Button(action: { withAnimation { isExpanded = true } }) {
                            Text("Show all \(rows.count) rows (\(rows.count - Self.initialRowLimit) more)")
                                .font(.caption)
                                .foregroundColor(theme.accentColor)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .gridCellColumns(headers.count)
                        .accessibilityLabel("Show all \(rows.count) table rows")
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                    .stroke(theme.dividerColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusSmall))
            .padding(.bottom, theme.spacingMedium)
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

    private func rowBackgroundColor(for rowIndex: Int) -> Color {
        if hoveredRowIndex == rowIndex {
            return theme.secondaryText.opacity(0.1)
        }
        return rowIndex % 2 == 0 ? Color.clear : theme.secondaryText.opacity(0.03)
    }

    private func copyTableAsMarkdown() {
        let headerRow = "| " + headers.joined(separator: " | ") + " |"
        let separatorRow = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
        let dataRows = rows.map { row in "| " + row.joined(separator: " | ") + " |" }.joined(separator: "\n")
        let markdown = "\(headerRow)\n\(separatorRow)\n\(dataRows)"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }
}

private struct TableCellView: View {
    let content: String
    let isHeader: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading) {
            if let url = URL(string: content), content.hasPrefix("http"), ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased()) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                             .aspectRatio(contentMode: .fit)
                             .frame(maxHeight: 150)
                             .clipShape(RoundedRectangle(cornerRadius: 4))
                    case .failure(let error):
                        Image(systemName: "photo.fill")
                            .font(.largeTitle)
                            .foregroundColor(theme.secondaryText)
                            .onAppear {
                                logger.error("Failed to load image from URL \(url.absoluteString): \(error.localizedDescription)")
                            }
                    case .empty:
                        ProgressView()
                            .frame(height: 50)
                    @unknown default:
                        EmptyView()
                    }
                }
                .help(url.absoluteString)
            } else {
                Text((try? AttributedString(markdown: content)) ?? AttributedString(content))
                    .font(isHeader ? theme.fontBody.weight(.bold) : theme.fontBody)
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    // CRITICAL: Max width triggers wrapping for long text,
                    // while min width prevents collapsing.
                    .frame(minWidth: 80, maxWidth: 400, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(theme.spacingSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
