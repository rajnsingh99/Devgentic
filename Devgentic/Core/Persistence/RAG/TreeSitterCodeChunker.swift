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
    
    /// Core code-aware chunking algorithm: determines safe semantic line breaks based on AST depth.
    private func splitByAST(rootNode: Node, code: String, languageName: String) -> [String] {
        let lines = code.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunkLines: [String] = []
        var currentSize = 0
        
        let langName = languageName.isEmpty ? "Code" : languageName
        let prefix = "[\(langName) Context]:\n"
        let prefixSize = prefix.count
        
        // Map line index to the minimum grammatical depth of a discrete node ending on that line.
        // A lower depth means it's structurally closer to the top level (e.g., class end vs internal statement end).
        var lineDepths: [Int: Int] = [:]
        
        func traverse(node: Node, depth: Int) {
            let endRow = Int(node.pointRange.upperBound.row)
            if endRow >= 0 && endRow < lines.count {
                if let existing = lineDepths[endRow] {
                    lineDepths[endRow] = min(existing, depth)
                } else {
                    lineDepths[endRow] = depth
                }
            }
            // Traverse all children to map their end rows
            for i in 0..<node.childCount {
                if let child = node.child(at: i) {
                    traverse(node: child, depth: depth + 1)
                }
            }
        }
        
        // Start traversal. Root starts at depth 0, top-level declarations are depth 1.
        traverse(node: rootNode, depth: 0)
        
        for (index, line) in lines.enumerated() {
            let lineSize = line.count + 1 // +1 for the newline character
            
            if prefixSize + currentSize + lineSize > maxChunkSize && !currentChunkLines.isEmpty {
                // Time to split currentChunkLines at the safest, highest-level structural boundary available.
                let startIndex = index - currentChunkLines.count
                
                var bestSplitOffset = -1
                var bestDepth = Int.max
                
                // Search the latter half of the accumulated lines for the shallowest structural exit point.
                let searchStartOffset = max(0, currentChunkLines.count / 2)
                
                for offset in searchStartOffset..<currentChunkLines.count {
                    let absoluteLine = startIndex + offset
                    if let depth = lineDepths[absoluteLine] {
                        if depth <= bestDepth {
                            bestDepth = depth
                            bestSplitOffset = offset
                        }
                    }
                }
                
                if bestSplitOffset != -1 && bestSplitOffset < currentChunkLines.count - 1 {
                    // Split at the discovered structural boundary
                    let chunkToKeep = Array(currentChunkLines[0...bestSplitOffset])
                    chunks.append(prefix + chunkToKeep.joined(separator: "\n"))
                    
                    // The remaineder forms the start of the next chunk.
                    // Keep 2 lines for overlap to maintain immediate local context.
                    let overlapStart = max(0, bestSplitOffset + 1 - 2)
                    let rest = Array(currentChunkLines[overlapStart..<currentChunkLines.count])
                    currentChunkLines = rest
                    currentSize = rest.reduce(0) { $0 + $1.count + 1 }
                } else {
                    // Fallback: No good structural boundary found in the second half (e.g., a massive array literal).
                    chunks.append(prefix + currentChunkLines.joined(separator: "\n"))
                    
                    let overlapLines = Array(currentChunkLines.suffix(2))
                    currentChunkLines = overlapLines
                    currentSize = overlapLines.reduce(0) { $0 + $1.count + 1 }
                }
            }
            
            currentChunkLines.append(line)
            currentSize += lineSize
        }
        
        if !currentChunkLines.isEmpty {
            chunks.append(prefix + currentChunkLines.joined(separator: "\n"))
        }

        // Filter out prefix-only chunks (empty code that became just "[lang Context]:\n")
        return chunks.filter { chunk in
            let stripped = chunk
                .replacingOccurrences(of: prefix, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !stripped.isEmpty
        }
    }

    /// Identical to original naive line-break method in SemanticChunker.
    private func fallbackChunkCode(_ code: String, language: String) -> [String] {
        let lines = code.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentChunkLines: [String] = []
        var currentSize = 0
        
        let langName = language.isEmpty ? "Code" : language
        let prefix = "[\(langName) Context]:\n"
        let prefixSize = prefix.count
        
        for line in lines {
            let lineSize = line.count + 1
            if prefixSize + currentSize + lineSize > maxChunkSize && !currentChunkLines.isEmpty {
                chunks.append(prefix + currentChunkLines.joined(separator: "\n"))
                let overlapLines = Array(currentChunkLines.suffix(2))
                currentChunkLines = overlapLines
                currentSize = overlapLines.reduce(0) { $0 + $1.count + 1 }
            }
            currentChunkLines.append(line)
            currentSize += lineSize
        }
        
        if !currentChunkLines.isEmpty {
            chunks.append(prefix + currentChunkLines.joined(separator: "\n"))
        }

        // Filter out prefix-only chunks (empty code that became just "[lang Context]:\n")
        return chunks.filter { chunk in
            let stripped = chunk
                .replacingOccurrences(of: prefix, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !stripped.isEmpty
        }
    }
}
