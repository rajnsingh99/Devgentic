//
//  CodeDiffView.swift
//  Devgentic
//
//  Created by Raj Singh on 08/08/25.
//
//  MODERNIZED: GitHub-style Unified Diff with line numbers and distinct gutters.
//  THEME: Migrated to centralized AppTheme via @Environment(\.appTheme).

import SwiftUI

struct CodeDiffView: View {
    let originalCode: String
    let modifiedCode: String
    @Environment(\.appTheme) private var theme

    /// Cached diff, computed ONCE per content change in `.task` (off the main thread) —
    /// NOT recomputed in `body`. `DiffUtility` allocates an O(n·m) table and does O(n·m)
    /// comparisons, and `DiffResult.id` is a fresh UUID per row, so the old compute-in-body
    /// both stalled on large files and forced the LazyVStack to rebuild every row on each
    /// pass. Caching keeps the rows (and their ids) stable across renders.
    @State private var diffResults: [DiffResult] = []
    @State private var isComputingDiff = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diffResults) { result in
                    HStack(alignment: .top, spacing: 0) {
                        // Line Numbers Gutter
                        HStack(spacing: 8) {
                            Text(formatLineNumber(result.originalLineNumber))
                                .foregroundColor(lineNumberColor(for: result.type))
                            Text(formatLineNumber(result.modifiedLineNumber))
                                .foregroundColor(lineNumberColor(for: result.type))
                        }
                        .font(.system(size: 11, design: .monospaced)) // Fixed size: monospaced
                        .frame(width: 70, alignment: .trailing)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(gutterColor(for: result.type))

                        // Vertical Divider
                        Rectangle()
                            .fill(borderColor(for: result.type))
                            .frame(width: 1)

                        // Marker (+/-)
                        Text(prefix(for: result.type))
                            .font(.system(size: 11, weight: .bold, design: .monospaced)) // Fixed size: monospaced
                            .foregroundColor(contentColor(for: result.type))
                            .frame(width: 20, alignment: .center)
                            .padding(.vertical, 3)

                        // Code Content
                        Text(result.line)
                            .font(.system(size: 12, design: .monospaced)) // Fixed size: monospaced
                            .foregroundColor(contentColor(for: result.type))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .padding(.trailing, 8)
                    }
                    .background(rowBackgroundColor(for: result.type))
                    // Add/delete were encoded by color only — announce the change kind
                    // so VoiceOver / color-blind users can tell added from removed lines.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel(for: result))
                }
            }
        }
        .background(theme.textBackground)
        .overlay {
            if isComputingDiff && diffResults.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: DiffInput(original: originalCode, modified: modifiedCode)) {
            isComputingDiff = true
            let orig = originalCode
            let mod = modifiedCode
            let results = await Task.detached(priority: .userInitiated) {
                DiffUtility.generateDiff(original: orig, modified: mod)
            }.value
            guard !Task.isCancelled else { return }
            diffResults = results
            isComputingDiff = false
        }
    }

    // MARK: - Styling Helpers

    private func accessibilityLabel(for result: DiffResult) -> String {
        let kind: String
        switch result.type {
        case .added:     kind = String(localized: "Added line")
        case .deleted:   kind = String(localized: "Removed line")
        case .unchanged: kind = String(localized: "Unchanged line")
        }
        return "\(kind): \(result.line)"
    }

    private func formatLineNumber(_ number: Int?) -> String {
        guard let number = number else { return "    " }
        return String(format: "%4d", number)
    }

    private func rowBackgroundColor(for type: LineChangeType) -> Color {
        switch type {
        case .added: return theme.successColor.opacity(0.1)
        case .deleted: return theme.errorColor.opacity(0.1)
        case .unchanged: return Color.clear
        }
    }

    private func gutterColor(for type: LineChangeType) -> Color {
        switch type {
        case .added: return theme.successColor.opacity(0.05)
        case .deleted: return theme.errorColor.opacity(0.05)
        case .unchanged: return theme.controlBackground
        }
    }

    private func borderColor(for type: LineChangeType) -> Color {
        return theme.dividerColor
    }

    private func prefix(for type: LineChangeType) -> String {
        switch type {
        case .added: return "+"
        case .deleted: return "-"
        case .unchanged: return ""
        }
    }

    private func lineNumberColor(for type: LineChangeType) -> Color {
        return theme.secondaryText.opacity(0.6)
    }

    private func contentColor(for type: LineChangeType) -> Color {
        switch type {
        case .added: return theme.successColor.opacity(0.8) // Readable green text
        case .deleted: return theme.errorColor.opacity(0.8)   // Readable red text
        case .unchanged: return theme.primaryText.opacity(0.9)
        }
    }
}

/// `.task(id:)` key for the diff: recompute only when the compared text actually changes.
/// Comparing the two strings each body pass is O(n) — far cheaper than the O(n·m) diff it
/// gates, and it stops a theme/hover-driven re-render from re-diffing.
private struct DiffInput: Equatable {
    let original: String
    let modified: String
}
