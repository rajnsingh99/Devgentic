//
//  MarkdownTableView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/08/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MarkdownTableView")

private struct CellHeightsPreferenceKey: PreferenceKey {
    typealias Value = [Int: CGFloat]

    static var defaultValue: Value = [:]

    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    @State private var rowHeights: [Int: CGFloat] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Row
            HeaderRowView(headers: headers, height: rowHeights[-1])
                .onPreferenceChange(CellHeightsPreferenceKey.self) { heights in
                    let maxHeight = heights.values.max() ?? 0
                    if rowHeights[-1] != maxHeight {
                        rowHeights[-1] = maxHeight
                    }
                }
                .background(Color.gray.opacity(0.1))

            Divider()

            // Data Rows
            ForEach(rows.indices, id: \.self) { rowIndex in
                DataRowView(
                    rowData: rows[rowIndex],
                    rowIndex: rowIndex,
                    height: rowHeights[rowIndex]
                )
                .onPreferenceChange(CellHeightsPreferenceKey.self) { heights in
                    let maxHeight = heights.values.max() ?? 0
                    if rowHeights[rowIndex] != maxHeight {
                        rowHeights[rowIndex] = maxHeight
                    }
                }
                
                if rowIndex < rows.count - 1 {
                    Divider()
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: UITheme.CornerRadius.small)
                .stroke(Color.gray.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: UITheme.CornerRadius.small))
        .padding(.bottom, UITheme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TableCellView: View {
    let content: String
    let isHeader: Bool
    let columnIndex: Int

    var body: some View {
        VStack {
            if let url = URL(string: content), content.hasPrefix("http"), ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased()) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                             .aspectRatio(contentMode: .fit)
                             .frame(maxHeight: 150) // Limit image height
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
            }
        }
        .padding(UITheme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CellHeightsPreferenceKey.self,
                    value: [columnIndex: geometry.size.height]
                )
            }
        )
    }
}

private struct HeaderRowView: View {
    let headers: [String]
    let height: CGFloat?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(headers.indices, id: \.self) { index in
                TableCellView(content: headers[index], isHeader: true, columnIndex: index)
                if index < headers.count - 1 {
                    Divider()
                }
            }
        }
        .frame(height: height)
    }
}

private struct DataRowView: View {
    let rowData: [String]
    let rowIndex: Int
    let height: CGFloat?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(rowData.indices, id: \.self) { colIndex in
                TableCellView(content: rowData[colIndex], isHeader: false, columnIndex: colIndex)
                if colIndex < rowData.count - 1 {
                    Divider()
                }
            }
        }
        .frame(height: height)
    }
}
