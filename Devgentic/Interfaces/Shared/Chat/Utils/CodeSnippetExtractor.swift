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

struct CodeSnippetExtractor {
    struct ExtractedInfo {
        let language: String?
        let code: String
        let potentialFileName: String?
    }
    
    static func extract(from markdown: String) -> [ExtractedInfo] {
        var results: [ExtractedInfo] = []
        
        let fileBlockRegex = #"(?:--- Start of file:\s*(.*?) ---\n)?```(?:(\w+)\n)?([\s\S]*?)```"#

        do {
            let regex = try NSRegularExpression(pattern: fileBlockRegex, options: [])
            let nsrange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
            let matches = regex.matches(in: markdown, options: [], range: nsrange)

            logger.debug("CodeSnippetExtractor found \(matches.count) potential file/code blocks.")

            for match in matches {
                let fileNameRange = match.range(at: 1)
                let languageRange = match.range(at: 2)
                let codeRange = match.range(at: 3)

                guard codeRange.location != NSNotFound, let codeContentRange = Range(codeRange, in: markdown) else { continue }
                
                let code = String(markdown[codeContentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else { continue }

                let language = Range(languageRange, in: markdown).map { String(markdown[$0]) }
                let fileName = Range(fileNameRange, in: markdown).map { String(markdown[$0]).trimmingCharacters(in: .whitespaces) }
                
                results.append(ExtractedInfo(language: language, code: code, potentialFileName: fileName))
            }
        } catch {
            logger.error("Failed to create regex for code block extraction: \(error)")
        }
        
        return results
    }
}
