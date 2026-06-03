//
//  DiffView.swift
//  Devgentic
//
//  Created by Raj Singh on 26/08/25.
//
//  Phase 3: Visual Diff Implementation using basic LCS (Longest Common Subsequence).
//  THEME: Migrated to centralized AppTheme via @Environment(\.appTheme).

import SwiftUI

/// A standalone view that compares two strings and visualizes additions/deletions.
struct DiffView: View {
    let original: String
    let modified: String
    let fileName: String?

    @State private var diffLines: [DiffLine] = []
    @State private var cachedSignature: Int?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(fileName ?? "Diff")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Spacer()
                HStack(spacing: 12) {
                    Label("Original", systemImage: "minus.circle.fill").foregroundColor(theme.errorColor.opacity(0.8))
                    Label("Modified", systemImage: "plus.circle.fill").foregroundColor(theme.successColor.opacity(0.8))
                }
                .font(.caption)
            }
            .padding()
            .background(theme.controlBackground)

            Divider()

            // Split View Area
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // Left: Original
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(diffLines) { line in
                                if line.type != .added {
                                    DiffLineRow(line: line, isLeft: true)
                                }
                            }
                        }
                    }
                    .frame(width: geometry.size.width / 2)
                    .background(theme.textBackground)

                    Divider()

                    // Right: Modified
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(diffLines) { line in
                                if line.type != .removed {
                                    DiffLineRow(line: line, isLeft: false)
                                }
                            }
                        }
                    }
                    .frame(width: geometry.size.width / 2)
                    .background(theme.textBackground)
                }
            }
        }
        .onAppear { computeDiffIfNeeded() }
        .onChange(of: original) { _, _ in computeDiffIfNeeded() }
        .onChange(of: modified) { _, _ in computeDiffIfNeeded() }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.dividerColor, lineWidth: 1))
    }

    private func computeDiffIfNeeded() {
        // Cheap O(n) hash skips the O(n*m) LCS recompute when inputs are unchanged.
        // Common when the view re-appears (e.g. user toggles diff view off/on)
        // or a parent re-renders without any input change.
        var hasher = Hasher()
        hasher.combine(original)
        hasher.combine(modified)
        let signature = hasher.finalize()

        guard cachedSignature != signature else { return }
        cachedSignature = signature

        let oldLines = original.components(separatedBy: .newlines)
        let newLines = modified.components(separatedBy: .newlines)
        self.diffLines = DiffEngine.computeDiff(oldLines: oldLines, newLines: newLines)
    }
}

// MARK: - Diff Row View
struct DiffLineRow: View {
    let line: DiffLine
    let isLeft: Bool // True for original (Left), False for modified (Right)
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Line Number
            Text("\(line.number)")
                .font(.system(size: 10, design: .monospaced)) // Fixed size: monospaced
                .foregroundColor(theme.secondaryText)
                .frame(width: 30, alignment: .trailing)
                .padding(.trailing, 8)
                .opacity(0.5)

            // Content
            Text(line.text.isEmpty ? " " : line.text) // Force height for empty lines
                .font(.system(size: 12, design: .monospaced)) // Fixed size: monospaced
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
        }
        .padding(.vertical, 2)
        .background(backgroundColor)
    }

    private var backgroundColor: Color {
        if isLeft {
            return line.type == .removed ? theme.errorColor.opacity(0.15) : Color.clear
        } else {
            return line.type == .added ? theme.successColor.opacity(0.15) : Color.clear
        }
    }
}

// MARK: - Diff Engine (Logic)
enum DiffType {
    case common
    case added
    case removed
}

struct DiffLine: Identifiable {
    let id = UUID()
    let text: String
    let type: DiffType
    let number: Int
}

class DiffEngine {
    static func computeDiff(oldLines: [String], newLines: [String]) -> [DiffLine] {
        let lcsMatrix = longestCommonSubsequence(oldLines, newLines)
        var _: [DiffLine] = []

        var i = oldLines.count
        var j = newLines.count

        var backtrack: [DiffLine] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldLines[i-1] == newLines[j-1] {
                backtrack.append(DiffLine(text: oldLines[i-1], type: .common, number: i)) // Use old line number
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || lcsMatrix[i][j-1] >= lcsMatrix[i-1][j]) {
                backtrack.append(DiffLine(text: newLines[j-1], type: .added, number: j))
                j -= 1
            } else if i > 0 && (j == 0 || lcsMatrix[i][j-1] < lcsMatrix[i-1][j]) {
                backtrack.append(DiffLine(text: oldLines[i-1], type: .removed, number: i))
                i -= 1
            }
        }

        return backtrack.reversed()
    }

    private static func longestCommonSubsequence(_ oldLines: [String], _ newLines: [String]) -> [[Int]] {
        let n = oldLines.count
        let m = newLines.count
        var matrix = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)

        for i in 1...n {
            for j in 1...m {
                if oldLines[i-1] == newLines[j-1] {
                    matrix[i][j] = matrix[i-1][j-1] + 1
                } else {
                    matrix[i][j] = max(matrix[i-1][j], matrix[i][j-1])
                }
            }
        }
        return matrix
    }
}
