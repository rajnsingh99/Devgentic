//
//  CodeSnippetExtractor.swift
//  Devgentic
//
//  Created by Raj Singh on 09/08/25.
//

import SwiftUI
import os

private let logger = DGLogger(category: "CodeSnippetExtractor")

struct CodeSnippet: Identifiable, Hashable {
    let id = UUID()
    let language: String?
    let code: String
    
    var sourceMessageID: UUID?
    var sourceFileID: UUID?

    func hash(into hasher: inout Hasher) {
        hasher.combine(language)
        hasher.combine(code)
        hasher.combine(sourceMessageID)
        hasher.combine(sourceFileID)
    }

    static func == (lhs: CodeSnippet, rhs: CodeSnippet) -> Bool {
        return lhs.language == rhs.language &&
               lhs.code == rhs.code &&
               lhs.sourceMessageID == rhs.sourceMessageID &&
               lhs.sourceFileID == rhs.sourceFileID
    }
}

extension CodeSnippet {
    /// Builds a snippet from a code block's payload. Every site that feeds
    /// `openMessageInCodeViewer` must come through here: it finds the clicked snippet with
    /// `firstIndex(of:)`, and `==` above compares CONTENT, not `id` (a fresh UUID per
    /// extraction, which could never match). So a click site that normalises differently
    /// from the extractor by so much as cmark's trailing newline makes the lookup miss, and
    /// the viewer opens snippet 0 instead of the one the user clicked.
    init(codeBlock language: String?, content: String) {
        self.init(language: Self.normalizedLanguage(language), code: Self.normalizedCode(content))
    }

    /// Do these denote the same code block?
    ///
    /// Deliberately NOT `==`: the viewer stamps `sourceMessageID`/`sourceFileID` onto a
    /// snippet only AFTER resolving its `--- Start of file ---` name against the user's
    /// attached files, and a click site holds just the rendered block, so it cannot know
    /// either. `==` compares them, so using it to locate the clicked snippet would miss on
    /// every successfully LINKED block and fall back to snippet 0.
    func denotesSameBlock(as other: CodeSnippet) -> Bool {
        language == other.language && code == other.code
    }

    /// The snippet form of a code block's content: what `CodeBlockView` already shows
    /// (it strips the phantom trailing line for display) rather than cmark's raw text.
    static func normalizedCode(_ content: String) -> String {
        content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A missing info string reaches us as either `nil` or `""` depending on the path;
    /// both mean "no language".
    static func normalizedLanguage(_ language: String?) -> String? {
        guard let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Lines as the user sees them — over normalised content, so a block never reports the
    /// phantom trailing line cmark appends.
    static func lineCount(codeBlockContent content: String) -> Int {
        let code = normalizedCode(content)
        return code.isEmpty ? 0 : code.components(separatedBy: .newlines).count
    }

    var lineCount: Int { code.isEmpty ? 0 : code.components(separatedBy: .newlines).count }

    /// Long enough to collapse into a card that opens the viewer.
    ///
    /// The renderer asks this of raw block content before a snippet exists (a
    /// `@ViewBuilder` can't hold a local); `openMessageInCodeViewer` asks it of the snippet
    /// when picking `largeSnippets`. Both must count the same normalised lines, or a block
    /// can render a card that the viewer's filter then excludes — leaving the user's click
    /// to open some other snippet, with no way to reach the one they clicked.
    var isLarge: Bool { lineCount > ChatUIConstants.codeBlockLineLimit }

    static func isLarge(codeBlockContent content: String) -> Bool {
        lineCount(codeBlockContent: content) > ChatUIConstants.codeBlockLineLimit
    }
}

struct CodeSnippetExtractor {
    struct ExtractedInfo {
        let language: String?
        let code: String
        let potentialFileName: String?
    }
    
    /// Pulls every fenced code block out of a message, in document order.
    ///
    /// Derived from the shared CommonMark AST (`parseMarkdown`) rather than a bespoke
    /// fence regex. The regex this replaced —
    ///
    ///     ```(?:(\w+)\n)?([\s\S]*?)```
    ///
    /// — had three confirmed corruptions: `(\w+)` couldn't match a non-word info string
    /// (`c++`, `objective-c`, `c#`) and, being OPTIONAL, silently skipped instead of
    /// failing, so the info string was swallowed into the CODE BODY the user saw and
    /// copied; a trailing space after the language did the same; and the file marker
    /// only matched with exactly one newline before the fence, so the blank line LLMs
    /// normally emit left `potentialFileName` nil and broke source-file linking.
    ///
    /// Deriving from the AST also means the viewer sees exactly what the bubble renders
    /// (same parser, same filename-marker handling), and picks up fences nested inside
    /// list items — which LLMs produce constantly.
    static func extract(from markdown: String) -> [ExtractedInfo] {
        var results: [ExtractedInfo] = []

        func walk(_ blocks: [ContentBlock]) {
            for block in blocks {
                switch block.type {
                case .code(let language, let content, let fileName):
                    let code = CodeSnippet.normalizedCode(content)
                    guard !code.isEmpty else { continue }
                    results.append(ExtractedInfo(
                        language: CodeSnippet.normalizedLanguage(language),
                        code: code,
                        potentialFileName: fileName
                    ))

                // Containers own child blocks — a fence inside a numbered step is still
                // a code block the user should be able to open.
                case .listItem(_, let children, _), .blockquote(let children):
                    walk(children)

                default:
                    break
                }
            }
        }

        walk(parseMarkdown(markdown))
        logger.debug("CodeSnippetExtractor found \(results.count) code block(s).")
        return results
    }
}
