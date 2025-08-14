//
//  MarkdownParser.swift
//  Devgentic
//
//  Created by Raj Singh on 20/07/25.
//


import Foundation
import SwiftUI

func preprocessMarkdownText(_ text: String) -> String {
    return text.replacingOccurrences(of: "<br>", with: "\n")
}

func parseMarkdown(_ markdown: String) -> [ContentBlock] {
    var blocks: [ContentBlock] = []
    let lines = markdown.components(separatedBy: .newlines)

    var currentParagraphLines: [String] = []
    var inCodeBlock = false
    var codeBlockLanguage: String = ""
    var codeBlockContentLines: [String] = []
    var pendingFileName: String? = nil
    
    var inTable = false
    var tableHeaders: [String] = []
    var tableRows: [[String]] = []


    func finalizeCurrentParagraph() {
        if !currentParagraphLines.isEmpty {
            let paragraphText = currentParagraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraphText.isEmpty {
                blocks.append(.paragraph(preprocessMarkdownText(paragraphText)))
            }
            currentParagraphLines.removeAll()
        }
    }

    func finalizeCodeBlock() {
        if inCodeBlock {
            let content = codeBlockContentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                blocks.append(.code(language: codeBlockLanguage, content: content, fileName: pendingFileName))
            }
            inCodeBlock = false
            codeBlockLanguage = ""
            codeBlockContentLines.removeAll()
            pendingFileName = nil
        }
    }
    
    func finalizeTable() {
        if !tableHeaders.isEmpty {
            blocks.append(.table(headers: tableHeaders, rows: tableRows))
        }
        inTable = false
        tableHeaders = []
        tableRows = []
    }

    for (index, line) in lines.enumerated() {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        
        // --- CHANGE START: Add Image Parsing ---
        // Check for Markdown image syntax: ![alt text](url)
        if let match = trimmedLine.firstMatch(of: /!\[(.*?)\]\((.*?)\)/) {
            finalizeCurrentParagraph() // Finalize any preceding text
            let altText = String(match.1)
            let url = String(match.2)
            blocks.append(.image(url: url, altText: altText))
            continue
        }
        // --- CHANGE END ---

        let fileMarkerRegex = #"---\s*Start of file:\s*(.*?)\s*---"#
        if let range = trimmedLine.range(of: fileMarkerRegex, options: .regularExpression) {
            if let match = trimmedLine.firstMatch(of: /---\s*Start of file:\s*(.*?)\s*---/) {
                 let fileName = String(match.1)
                 pendingFileName = fileName
                 finalizeCurrentParagraph()
                 continue
            }
        }
        
        if trimmedLine.contains("--- End of file:") {
            continue
        }

        // 1. Handle Code Blocks
        if trimmedLine.hasPrefix("```") {
            if inCodeBlock {
                finalizeCodeBlock()
            } else {
                finalizeCurrentParagraph()
                finalizeTable()
                inCodeBlock = true
                codeBlockLanguage = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            continue
        }

        if inCodeBlock {
            codeBlockContentLines.append(line)
            continue
        }
        
        // 2. Handle Tables
        let isTableLine = trimmedLine.hasPrefix("|") && trimmedLine.hasSuffix("|")
        let isTableSeparator = isTableLine && trimmedLine.contains("-") && trimmedLine.trimmingCharacters(in: .whitespaces).allSatisfy { "|- :".contains($0) }

        if isTableSeparator {
            // This is the separator line (e.g., |:---|:---|), just consume it.
            continue
        }
        
        if isTableLine {
            let components = trimmedLine.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map { preprocessMarkdownText(String($0).trimmingCharacters(in: .whitespaces)) }
            
            if !inTable {
                let nextIndex = index + 1
                if nextIndex < lines.count {
                    let nextLine = lines[nextIndex].trimmingCharacters(in: .whitespaces)
                    let isNextLineSeparator = nextLine.hasPrefix("|") && nextLine.contains("-") && nextLine.trimmingCharacters(in: .whitespaces).allSatisfy { "|- :".contains($0) }
                    
                    if isNextLineSeparator {
                        finalizeCurrentParagraph()
                        inTable = true
                        tableHeaders = components
                        continue
                    }
                }
            } else {
                let paddedRow = components + Array(repeating: "", count: max(0, tableHeaders.count - components.count))
                tableRows.append(Array(paddedRow.prefix(tableHeaders.count)))
                continue
            }
        } else if inTable {
            // This line is not part of the table, so finalize the table
            finalizeTable()
        }
        
        if trimmedLine.isEmpty {
            finalizeCurrentParagraph()
            continue
        }

        if trimmedLine == "---" || trimmedLine == "***" {
            finalizeCurrentParagraph()
            blocks.append(.horizontalRule)
            continue
        }

        if trimmedLine.hasPrefix("# ") {
            finalizeCurrentParagraph()
            blocks.append(.heading(level: 1, text: String(trimmedLine.dropFirst(2))))
            continue
        } else if trimmedLine.hasPrefix("## ") {
            finalizeCurrentParagraph()
            blocks.append(.heading(level: 2, text: String(trimmedLine.dropFirst(3))))
            continue
        } else if trimmedLine.hasPrefix("### ") {
            finalizeCurrentParagraph()
            blocks.append(.heading(level: 3, text: String(trimmedLine.dropFirst(4))))
            continue
        }

        if trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("+ ") {
            finalizeCurrentParagraph()
            let prefix = String(trimmedLine.prefix(2))
            let text = String(trimmedLine.dropFirst(2))
            blocks.append(.listItem(prefix: prefix, text: text, indentation: 0))
            continue
        }
        
        if let range = trimmedLine.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            finalizeCurrentParagraph()
            let prefix = String(trimmedLine[range])
            let text = String(trimmedLine[range.upperBound...])
            blocks.append(.listItem(prefix: prefix, text: text, indentation: 0))
            continue
        }

        currentParagraphLines.append(line)
    }

    finalizeCurrentParagraph()
    finalizeCodeBlock()
    finalizeTable()

    return blocks
}
