//
//  ConversationExporter.swift
//  Devgentic
//
//  P1: Export conversation to Markdown.
//

import Foundation
import AppKit
import os

private let logger = DGLogger(category: "ConversationExporter")

struct ConversationExporter {

    /// A fence long enough to contain `content`.
    ///
    /// CommonMark closes a fenced block at the first run of backticks at least as long as the
    /// opening fence, so a hardcoded ``` is broken by any content that contains one — the
    /// remainder of that block then renders as document structure. This is reachable on the
    /// ordinary `.codeBlock` path (an agent answer about markdown, or any nested fence), not
    /// only in the file-embedding branch.
    private static func fence(for content: String) -> String {
        var longestRun = 0, currentRun = 0
        for character in content {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: max(3, longestRun + 1))
    }

    /// Exports a conversation's messages to a Markdown string.
    /// - Parameter includeFileContent: When true, embeds extracted document content inline (up to 10K chars per file).
    /// - Parameter isTruncated: true when the caller's fetch hit its cap, so older turns are
    ///   missing. Stated in the document — an export that silently begins partway through
    ///   misrepresents the conversation exactly like a dropped turn does. Deliberately a flag
    ///   and not a total: the caller knows it was capped, not how many messages exist.
    static func toMarkdown(title: String, messages: [ChatMessage], includeFileContent: Bool = false,
                           isTruncated: Bool = false) async -> String {
        var lines: [String] = []

        lines.append("# \(title)")
        lines.append("")
        if isTruncated {
            lines.append("> ⚠️ This export contains only the most recent \(messages.count) messages of this conversation. Earlier turns exceeded the export limit and are not included.")
            lines.append("")
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        // Messages arrive newest-first; reverse for chronological order
        let chronological = messages.reversed()

        for message in chronological {
            let timestamp = dateFormatter.string(from: message.timestamp)
            let role = message.sender == .user ? "You" : "Agent"

            lines.append("## \(role) — \(timestamp)")
            lines.append("")

            // Attached files
            if let files = message.attachedTextFiles, !files.isEmpty {
                for file in files {
                    lines.append("> Attached: `\(file.name)`")
                }
                lines.append("")

                // Optionally embed extracted content
                if includeFileContent {
                    let registry = DocumentExtractionRegistry.shared
                    for file in files {
                        if registry.canExtract(from: file.url) {
                            do {
                                let result = try await registry.extract(from: file.url, maxSize: 10_000)
                                let fence = Self.fence(for: result.text)
                                lines.append("<details>")
                                lines.append("<summary>Content of \(file.name)</summary>")
                                lines.append("")
                                lines.append(fence)
                                lines.append(result.text)
                                lines.append(fence)
                                lines.append("</details>")
                                lines.append("")
                            } catch {
                                logger.warning("Failed to extract content from \(file.name) during export: \(error.localizedDescription)")
                                lines.append("> ⚠️ Could not extract content from `\(file.name)`")
                                lines.append("")
                            }
                        }
                    }
                }
            }

            // Content
            switch message.sender == .agent ? (message.currentAgentContent ?? message.content) : message.content {
            case .plainText(let text):
                lines.append(text)

            case .markdownText(let text):
                lines.append(text)

            case .codeBlock(let language, let code):
                let fence = Self.fence(for: code)
                lines.append("\(fence)\(language ?? "")")
                lines.append(code)
                lines.append(fence)

            case .error(let errorTitle, let details, _, let suggestion):
                lines.append("> **Error**: \(errorTitle ?? "Unknown") — \(details)")
                if let suggestion, !suggestion.isEmpty {
                    lines.append("> 💡 \(suggestion)")
                }

            case .mediaArtifact(let artifact):
                lines.append("*[Media: \(artifact.label ?? artifact.kind.rawValue)]*")

            case .checkpoint(let summary):
                lines.append("---\n**History Checkpoint**\n\(summary)\n---")

            case .unknown(let type, _):
                // Marked, not silently dropped: an export that quietly omits a turn misrepresents
                // the conversation. The payload is not printed — it is raw JSON, not prose.
                lines.append("*[Content from a newer version of Devgentic (\(type)) — not shown]*")
            }

            lines.append("")
            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Presents an NSSavePanel and writes the Markdown export to disk.
    @MainActor
    static func exportToFile(title: String, messages: [ChatMessage], includeFileContent: Bool = false,
                            isTruncated: Bool = false) async {
        let markdown = await toMarkdown(title: title, messages: messages,
                                        includeFileContent: includeFileContent,
                                        isTruncated: isTruncated)

        let savePanel = NSSavePanel()
        savePanel.title = String(localized: "Export Conversation")
        savePanel.nameFieldStringValue = sanitizeFilename(title) + ".md"
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                logger.info("Exported conversation to \(url.path)")
            } catch {
                logger.error("Failed to export conversation: \(error.localizedDescription)")
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Export Failed")
                    alert.informativeText = String(localized: "Could not save the conversation: \(error.localizedDescription)")
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            }
        }
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
        return String(cleaned.prefix(80))
    }
}
