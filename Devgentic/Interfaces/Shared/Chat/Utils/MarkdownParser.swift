//
//  MarkdownParser.swift
//  Devgentic
//
//  Created by Raj Singh on 20/07/25.
//

import Foundation
import SwiftUI
import Markdown

/// Step 3: Stream-Resilient Preprocessor
/// Automatically closes unmatched code blocks to ensure AST parsers (and our UI)
/// render them correctly while streaming, instead of falling back to raw paragraph text.
func preprocessStreamResilientMarkdown(_ text: String) -> String {
    var unclosedCodeBlock = false
    let lines = text.components(separatedBy: .newlines)
    
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A standard code block marker. We ignore inline backticks by checking the prefix.
        if trimmed.hasPrefix("```") {
            unclosedCodeBlock.toggle()
        }
    }
    
    // If we reach the end of the stream and a code block is still open, artificially close it.
    if unclosedCodeBlock {
        return text + "\n```\n"
    }
    return text
}

func preprocessMarkdownText(_ text: String) -> String {
    return text.replacingOccurrences(of: "<br>", with: "\n")
}

/// Step 4: swift-markdown AST Mapper
/// Replaces the legacy line-by-line regex parser with a true structural AST traversal.
func parseMarkdown(_ markdown: String) -> [ContentBlock] {
    // 1. Apply the stream-resilient preprocessor to ensure safe parsing
    let safeMarkdown = preprocessStreamResilientMarkdown(markdown)
    
    // 2. Generate AST using Apple's swift-markdown
    let document = Document(parsing: safeMarkdown)
    
    var blocks: [ContentBlock] = []
    var pendingFileName: String? = nil

    // Helper function to append blocks with stable structural identity
    func appendBlock(_ type: ContentBlock.BlockType) {
        blocks.append(ContentBlock(id: "block-\(blocks.count)", type: type))
    }

    // 3. Traverse the top-level AST nodes
    for child in document.children {
        // Format the entire block back to string for simple text nodes
        let text = child.format().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // --- Custom File Markers ---
        if let match = text.firstMatch(of: /---\s*Start of file:\s*(.*?)\s*---/) {
            pendingFileName = String(match.1)
            continue
        }
        if text.contains("--- End of file:") {
            pendingFileName = nil
            continue
        }
        
        // --- Image parsing ---
        // Standalone images are often wrapped inside a single Paragraph node
        if let paragraph = child as? Paragraph,
           paragraph.childCount == 1,
           let image = paragraph.child(at: 0) as? Markdown.Image {
            appendBlock(.image(url: image.source ?? "", altText: image.plainText))
            continue
        }
        
        // --- Standard AST Node Mapping ---
        if let paragraph = child as? Paragraph {
            appendBlock(.paragraph(preprocessMarkdownText(text)))
        }
        else if let codeBlock = child as? CodeBlock {
            appendBlock(.code(language: codeBlock.language ?? "", content: codeBlock.code, fileName: pendingFileName))
            pendingFileName = nil
        }
        else if let heading = child as? Heading {
            appendBlock(.heading(level: heading.level, text: heading.plainText))
        }
        else if let thematicBreak = child as? ThematicBreak {
            appendBlock(.horizontalRule)
        }
        else if let list = child as? UnorderedList {
            for item in list.listItems {
                // Join children formatting to keep inline styling (bold, italic, etc) intact
                let itemText = item.children.map { $0.format() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                appendBlock(.listItem(prefix: "•", text: preprocessMarkdownText(itemText), indentation: 0))
            }
        }
        else if let list = child as? OrderedList {
            for (i, item) in list.listItems.enumerated() {
                let index = list.startIndex + UInt(i)
                let itemText = item.children.map { $0.format() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                appendBlock(.listItem(prefix: "\(index).", text: preprocessMarkdownText(itemText), indentation: 0))
            }
        }
        else if let table = child as? Markdown.Table {
            let headers: [String] = table.head.cells.map { cell in
                cell.children.map { $0.format() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let rows: [[String]] = table.body.rows.map { row in
                row.cells.map { cell in
                    cell.children.map { $0.format() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            appendBlock(.table(headers: headers, rows: rows))
        }
        else {
            // Fallback for BlockQuotes, HTML blocks, or other unknown types
            appendBlock(.paragraph(preprocessMarkdownText(text)))
        }
    }
    
    return blocks
}
