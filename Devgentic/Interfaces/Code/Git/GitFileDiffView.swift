// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitFileDiffView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// One expanded row's diff: loaded lazily on expand, reloaded on every published snapshot, and folded to the
/// changed lines plus context.
struct GitFileDiffView: View {
    let file: GitFileChange
    let filter: GitChangesFilter

    @Environment(GitChangesStore.self) private var store
    @Environment(\.appTheme) private var theme
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 14.0

    @State private var diff: GitFileDiff?

    /// Rendered rows at most — mirrors the approval banner's cap.
    private static let rowCap = 400

    /// Revision-keyed: a refresh reloads the diff even when the file's counts are unchanged.
    private var loadKey: String { "\(file.path)|\(filter.rawValue)|\(store.snapshotRevision)" }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.secondaryText.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: loadKey) {
                diff = await store.loadDiff(for: file, filter: filter)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch diff {
        case nil:
            ProgressView().controlSize(.small).scaleEffect(0.7).padding(8)
        case .binary:
            note(String(localized: "Binary file — no text diff."))
        case .tooLarge:
            note(String(localized: "Larger than 1 MB — diff skipped. Open the file to see it."))
        case .failed(let reason):
            note(String(localized: "Couldn't load the diff: \(reason)"), tint: theme.warningColor)
        case .lines(let rows):
            if !rows.contains(where: { $0.type != .unchanged }) {
                note(String(localized: "No content changes (mode or metadata only)."))
            } else {
                let display = GitDiffDisplayRow.collapse(rows)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(display.prefix(Self.rowCap)) { row in
                        switch row {
                        case .line(let result):
                            DiffLineRow(result: result)
                        case .gap(_, let hidden):
                            Text(hidden == 1
                                 ? String(localized: "⋯ 1 unchanged line")
                                 : String(localized: "⋯ \(hidden) unchanged lines"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.tertiaryText)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 2)
                        }
                    }
                    if display.count > Self.rowCap {
                        Text("… \(display.count - Self.rowCap) more lines")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func note(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: chatFontSize - 4))
            .foregroundStyle(tint ?? theme.tertiaryText)
            .padding(8)
    }
}
