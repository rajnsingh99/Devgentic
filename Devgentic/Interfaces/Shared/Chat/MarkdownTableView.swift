//
//  MarkdownTableView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/08/25.
//
//  ENHANCED: Fixed layout overlapping using Grid, added horizontal scrolling, and text wrapping.

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MarkdownTableView")

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    @State private var hoveredRowIndex: Int? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                // MARK: - Header Row
                GridRow {
                    ForEach(headers.indices, id: \.self) { index in
                        TableCellView(content: headers[index], isHeader: true)
                            .background(Color.secondary.opacity(0.1))
                    }
                }

                // Header Divider
                Divider()
                    .gridCellColumns(headers.count)

                // MARK: - Data Rows
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(rows[rowIndex].indices, id: \.self) { colIndex in
                            TableCellView(content: rows[rowIndex][colIndex], isHeader: false)
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
                    
                    // Row Divider (except after the last row)
                    if rowIndex < rows.count - 1 {
                        Divider()
                            .gridCellColumns(headers.count)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: UITheme.CornerRadius.small)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: UITheme.CornerRadius.small))
            .padding(.bottom, UITheme.Spacing.medium)
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
            return Color.secondary.opacity(0.1)
        }
        return rowIndex % 2 == 0 ? Color.clear : Color.secondary.opacity(0.03)
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

    var body: some View {
        VStack(alignment: .leading) {
            if let url = URL(string: content), content.hasPrefix("http"), ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased()) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                             .aspectRatio(contentMode: .fit)
                             .frame(maxHeight: 150)
                             .cornerRadius(4)
                    case .failure(let error):
                        Image(systemName: "photo.fill")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
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
                Text(try! AttributedString(markdown: content))
                    .font(isHeader ? UITheme.Fonts.body.weight(.bold) : UITheme.Fonts.body)
                    .foregroundColor(UITheme.Colors.primaryText)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    // CRITICAL: Max width triggers wrapping for long text,
                    // while min width prevents collapsing.
                    .frame(minWidth: 80, maxWidth: 400, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(UITheme.Spacing.small)
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
