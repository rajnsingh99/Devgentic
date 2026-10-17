// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh

import Foundation
import SwiftTreeSitter
import CodeEditLanguages

/// A dedicated chunker that uses Tree-sitter AST to semantically split code blocks
/// at syntactically safe boundaries, instead of splitting purely by character count.
struct TreeSitterCodeChunker {
    
    let maxChunkSize: Int
    let overlap: Int
    
    init(maxChunkSize: Int = 512, overlap: Int = 50) {
        self.maxChunkSize = maxChunkSize
        self.overlap = overlap
    }
    
    /// Chunks code by preserving its syntactic topology.
    func chunk(code: String, languageName: String) -> [String] {
        let key = languageName.lowercased()
        
        // Map common markdown language identifiers to CodeEditLanguages supported IDs
        let languageFallbacks: [String: String] = [
            "sh": "bash", "zsh": "bash", "yml": "yaml",
            "md": "markdown", "c++": "cpp", "js": "javascript",
            "ts": "typescript", "tsx": "tsx"
        ]
        
        let resolvedKey = languageFallbacks[key] ?? key
        
        guard let codeLang = CodeLanguage.allLanguages.first(where: { $0.id.rawValue.lowercased() == resolvedKey }),
              let tsLanguage = codeLang.language else {
            return fallbackChunkCode(code, language: languageName)
        }
        
        return parseAndSplit(code: code, languageName: languageName, tsLanguage: tsLanguage)
    }
    
    private func parseAndSplit(code: String, languageName: String, tsLanguage: Language) -> [String] {
        let parser = Parser()
        do {
            try parser.setLanguage(tsLanguage)
        } catch {
            return fallbackChunkCode(code, language: languageName)
        }
        
        guard let tree = parser.parse(code), let rootNode = tree.rootNode else {
            return fallbackChunkCode(code, language: languageName)
        }
        
        return splitByAST(rootNode: rootNode, code: code, languageName: languageName)
    }
    
    /// Lines exactly as tree-sitter counts rows: `\r\n` is ONE break. `components(separatedBy:
    /// .newlines)` split it into two, so every line index after the first CRLF drifted from the AST
    /// rows the split points are looked up by (RAG-36).
    private static func lines(of code: String) -> [String] {
        code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// Core code-aware chunking algorithm: determines safe semantic line breaks based on AST depth.
    private func splitByAST(rootNode: Node, code: String, languageName: String) -> [String] {
        let lines = Self.lines(of: code)

        // Map line index to the minimum grammatical depth of a discrete node ending on that line.
        // A lower depth means it's structurally closer to the top level (e.g., class end vs internal statement end).
        var lineDepths: [Int: Int] = [:]
        
        // ⚠️ ITERATIVE, with an explicit stack (RAG-36). The recursive walk used one stack frame per
        // nesting level, and indexing runs on a background thread (512 KB stack): a deeply nested
        // file — a minified bundle, generated JSON thousands of levels deep — crashed the app. Visit
        // order does not matter: each row keeps the MINIMUM depth seen.
        // Root starts at depth 0, top-level declarations are depth 1.
        var stack: [(node: Node, depth: Int)] = [(rootNode, 0)]
        while let (node, depth) = stack.popLast() {
            let endRow = Int(node.pointRange.upperBound.row)
            if endRow >= 0 && endRow < lines.count {
                lineDepths[endRow] = min(lineDepths[endRow] ?? depth, depth)
            }
            for i in 0..<node.childCount {
                if let child = node.child(at: i) {
                    stack.append((child, depth + 1))
                }
            }
        }
        return pack(lines: lines, lineDepths: lineDepths, languageName: languageName)
    }

    /// No grammar for this language: the same packer, with no structural boundaries to prefer.
    private func fallbackChunkCode(_ code: String, language: String) -> [String] {
        pack(lines: Self.lines(of: code), lineDepths: [:], languageName: language)
    }

    /// Packs lines into chunks of at most `maxChunkSize` (prefix included), splitting at the
    /// shallowest AST boundary in the latter half of a full chunk and carrying 2 lines of overlap.
    ///
    /// ⚠️ INVARIANT: no chunk exceeds `maxChunkSize`. Two ways the old packers broke it:
    /// - A single line longer than a chunk was appended WHOLE — minified JS, one-line JSON, a log
    ///   line became one chunk of up to 500K chars with ~128 tokens embedded (RAG-23).
    /// - The 2-line overlap was carried forward without checking it still fit, so long lines were
    ///   emitted again as their own chunk, and chunks ran over by up to a line.
    private func pack(lines: [String], lineDepths: [Int: Int], languageName: String) -> [String] {
        let langName = languageName.isEmpty ? "Code" : languageName
        let prefix = "[\(langName) Context]:\n"
        // Characters of code a chunk can hold; each line costs its length + 1 (its newline).
        let budget = max(maxChunkSize - prefix.count, 8)

        var chunks: [String] = []
        var current: [String] = []          // contiguous lines ending just before `index`
        var currentSize = 0
        func size(_ lines: ArraySlice<String>) -> Int { lines.reduce(0) { $0 + $1.count + 1 } }

        for (index, line) in lines.enumerated() {
            let lineSize = line.count + 1

            if lineSize > budget {
                // A line no chunk can hold: close the open chunk, then cut the line into windows.
                if !current.isEmpty { chunks.append(prefix + current.joined(separator: "\n")) }
                current = []
                currentSize = 0
                chunks.append(contentsOf: Self.windows(of: line, size: budget - 1).map { prefix + $0 })
                continue
            }

            while currentSize + lineSize > budget, !current.isEmpty {
                // Split at the safest, highest-level structural boundary in the latter half.
                let startIndex = index - current.count
                var bestSplitOffset = -1
                var bestDepth = Int.max
                for offset in (current.count / 2)..<current.count {
                    if let depth = lineDepths[startIndex + offset], depth <= bestDepth {
                        bestDepth = depth
                        bestSplitOffset = offset
                    }
                }
                // No boundary (or only at the very end, e.g. a massive array literal): emit it all.
                let cut = (bestSplitOffset != -1 && bestSplitOffset < current.count - 1)
                    ? bestSplitOffset : current.count - 1
                chunks.append(prefix + current[0...cut].joined(separator: "\n"))

                // Keep 2 lines of overlap for local context — but only when they leave room for the
                // incoming line; otherwise carry just the lines not yet emitted.
                let withOverlap = current[max(0, cut + 1 - 2)...]
                let rest = size(withOverlap) + lineSize <= budget ? withOverlap : current[(cut + 1)...]
                current = Array(rest)
                currentSize = size(rest)
            }

            current.append(line)
            currentSize += lineSize
        }

        if !current.isEmpty {
            chunks.append(prefix + current.joined(separator: "\n"))
        }

        // Filter out prefix-only chunks (empty code that became just "[lang Context]:\n")
        return chunks.filter { chunk in
            !chunk.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Cuts one over-long line into windows of at most `size` characters, snapped back to
    /// whitespace when that keeps at least half a window. Linear: each step walks one window.
    private static func windows(of line: String, size: Int) -> [String] {
        var windows: [String] = []
        var start = line.startIndex
        while start < line.endIndex {
            guard let end = line.index(start, offsetBy: size, limitedBy: line.endIndex), end < line.endIndex else {
                windows.append(String(line[start...]))
                break
            }
            var cut = end
            if let space = line[start..<end].lastIndex(where: \.isWhitespace),
               line.distance(from: start, to: space) > size / 2 {
                cut = line.index(after: space)
            }
            windows.append(String(line[start..<cut]))
            start = cut
        }
        return windows
    }
}
