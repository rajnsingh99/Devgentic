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

    /// Exports a conversation's messages to a Markdown string.
    /// - Parameter includeFileContent: When true, embeds extracted document content inline (up to 10K chars per file).
    static func toMarkdown(title: String, messages: [ChatMessage], includeFileContent: Bool = false) async -> String {
        var lines: [String] = []

        lines.append("# \(title)")
        lines.append("")

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
                                lines.append("<details>")
                                lines.append("<summary>Content of \(file.name)</summary>")
                                lines.append("")
                                lines.append("```")
                                lines.append(result.text)
                                lines.append("```")
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
                lines.append("```\(language ?? "")")
                lines.append(code)
                lines.append("```")

            case .error(let errorTitle, let details, _, let suggestion):
                lines.append("> **Error**: \(errorTitle ?? "Unknown") — \(details)")
                if let suggestion, !suggestion.isEmpty {
                    lines.append("> 💡 \(suggestion)")
                }

            case .image(_, let alt, _):
                lines.append("*[Image: \(alt ?? "generated image")]*")

            case .mediaArtifact(let artifact):
                lines.append("*[Media: \(artifact.label ?? artifact.kind.rawValue)]*")

            case .checkpoint(let summary):
                lines.append("---\n**History Checkpoint**\n\(summary)\n---")
            }

            lines.append("")
            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Presents an NSSavePanel and writes the Markdown export to disk.
    @MainActor
    static func exportToFile(title: String, messages: [ChatMessage], includeFileContent: Bool = false) async {
        let markdown = await toMarkdown(title: title, messages: messages, includeFileContent: includeFileContent)

        let savePanel = NSSavePanel()
        savePanel.title = "Export Conversation"
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
                    alert.messageText = "Export Failed"
                    alert.informativeText = "Could not save the conversation: \(error.localizedDescription)"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
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
