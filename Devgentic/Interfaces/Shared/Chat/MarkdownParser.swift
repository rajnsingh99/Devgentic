//
//  MarkdownParser.swift
//  Devgentic
//
//  Created by Raj Singh on 20/07/25.
//

import Foundation

// Represents a block of content, either a paragraph, code snippet, heading, or list item.
enum ContentBlock: Identifiable {
    var id: UUID { UUID() } // Provides a unique ID for ForEach in SwiftUI
    case paragraph(String)
    case code(language: String, content: String)
    case heading(level: Int, text: String) // New case for headings (e.g., #, ##, ###)
    case listItem(String) // New case for simple bullet list items (e.g., *, -)
}

// Parses a Markdown string into an array of ContentBlock items.
func parseMarkdown(_ markdown: String) -> [ContentBlock] {
    var blocks: [ContentBlock] = []
    // Split the markdown by code block delimiters "```"
    let components = markdown.components(separatedBy: "```")

    // Iterate through the components to identify paragraphs, code blocks, headings, and list items
    for (index, component) in components.enumerated() {
        if component.isEmpty { continue } // Skip empty components

        if index % 2 == 0 { // Even indices are typically regular text/paragraphs outside code blocks
            let lines = component.components(separatedBy: .newlines)
            var currentParagraphLines: [String] = []

            // Helper function to finalize the current paragraph block
            func finalizeCurrentParagraph() {
                if !currentParagraphLines.isEmpty {
                    // Join lines with newline to preserve internal line breaks for AttributedString
                    let paragraphText = currentParagraphLines.joined(separator: "\n")
                    blocks.append(.paragraph(paragraphText.trimmingCharacters(in: .whitespacesAndNewlines)))
                    currentParagraphLines.removeAll()
                }
            }

            for line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)

                if trimmedLine.isEmpty {
                    // If a blank line, finalize the current paragraph (if any) and move on
                    finalizeCurrentParagraph()
                    continue
                }

                // Check for headings (highest precedence)
                if trimmedLine.hasPrefix("### ") {
                    finalizeCurrentParagraph()
                    blocks.append(.heading(level: 3, text: String(trimmedLine.dropFirst(4))))
                    continue
                } else if trimmedLine.hasPrefix("## ") {
                    finalizeCurrentParagraph()
                    blocks.append(.heading(level: 2, text: String(trimmedLine.dropFirst(3))))
                    continue
                } else if trimmedLine.hasPrefix("# ") {
                    finalizeCurrentParagraph()
                    blocks.append(.heading(level: 1, text: String(trimmedLine.dropFirst(2))))
                    continue
                }

                // Check for list items (next precedence)
                // Supports bullet lists starting with '* ' or '- '
                if trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("- ") {
                    finalizeCurrentParagraph()
                    blocks.append(.listItem(String(trimmedLine.dropFirst(2))))
                    continue
                }

                // If none of the above, it's part of a paragraph
                currentParagraphLines.append(line)
            }

            // Add any remaining paragraph lines after the loop finishes
            finalizeCurrentParagraph()

        } else { // Odd indices are code blocks
            var lines = component.split(separator: "\n", maxSplits: 1).map(String.init)
            // The first line of a code block usually specifies the language
            let language = lines.removeFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            // The rest is the code content
            let content = lines.joined(separator: "\n")
            blocks.append(.code(language: language, content: content))
        }
    }
    return blocks
}
