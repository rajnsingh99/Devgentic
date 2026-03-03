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

    private var diffResults: [DiffResult] {
        return DiffUtility.generateDiff(original: originalCode, modified: modifiedCode)
    }

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
                        .font(.system(size: 11, design: .monospaced))
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
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(contentColor(for: result.type))
                            .frame(width: 20, alignment: .center)
                            .padding(.vertical, 3)

                        // Code Content
                        Text(result.line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(contentColor(for: result.type))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            .padding(.trailing, 8)
                    }
                    .background(rowBackgroundColor(for: result.type))
                }
            }
        }
        .background(theme.textBackground)
    }

    // MARK: - Styling Helpers

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
