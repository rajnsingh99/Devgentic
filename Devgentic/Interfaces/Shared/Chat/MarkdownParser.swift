//
//  MarkdownParser.swift
//  Devgentic
//
//  Created by Raj Singh on 20/07/25.
//


import Foundation
import SwiftUI


enum ContentBlock: Identifiable, Equatable {
    var id: UUID { UUID() }
    case paragraph(String)
    case code(language: String, content: String)
    case heading(level: Int, text: String)
    case listItem(prefix: String, text: String, indentation: Int)
    case horizontalRule
}

func parseMarkdown(_ markdown: String) -> [ContentBlock] {
    var blocks: [ContentBlock] = []
    let lines = markdown.components(separatedBy: .newlines)

    var currentParagraphLines: [String] = []
    var inCodeBlock = false
    var codeBlockLanguage: String = ""
    var codeBlockContentLines: [String] = []

    func finalizeCurrentParagraph() {
        if !currentParagraphLines.isEmpty {
            let paragraphText = currentParagraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraphText.isEmpty {
                blocks.append(.paragraph(paragraphText))
            }
            currentParagraphLines.removeAll()
        }
    }

    func finalizeCodeBlock() {
        if inCodeBlock {
            // FIX: Trim the final joined content to remove leading/trailing whitespace and newlines.
            // This ensures consistency with other parsing methods (like regex) and makes
            // CodeSnippet equality checks reliable.
            let content = codeBlockContentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                blocks.append(.code(language: codeBlockLanguage, content: content))
            }
            inCodeBlock = false
            codeBlockLanguage = ""
            codeBlockContentLines.removeAll()
        }
    }

    for line in lines {
        let indentationWidth = line.prefix(while: { $0.isWhitespace }).count
        let indentationLevel = indentationWidth / 2
        
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)

        // 1. Handle Code Blocks
        if trimmedLine.hasPrefix("```") {
            if inCodeBlock {
                finalizeCodeBlock()
            } else {
                finalizeCurrentParagraph()
                inCodeBlock = true
                codeBlockLanguage = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            continue
        }

        if inCodeBlock {
            codeBlockContentLines.append(line)
            continue
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
            blocks.append(.listItem(prefix: prefix, text: text, indentation: indentationLevel))
            continue
        }
        
        if let range = trimmedLine.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            finalizeCurrentParagraph()
            let prefix = String(trimmedLine[range])
            let text = String(trimmedLine[range.upperBound...])
            blocks.append(.listItem(prefix: prefix, text: text, indentation: indentationLevel))
            continue
        }

        currentParagraphLines.append(line)
    }

    finalizeCurrentParagraph()
    finalizeCodeBlock()

    return blocks
}
