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

    // MARK: - Attachments and timeline [CF-19]
    //
    // `toMarkdown` read `attachedTextFiles` and the content enum and nothing else, so a turn that
    // was "here's a screenshot, what's wrong?" exported as the prompt alone, and an agent turn
    // that was all tool calls with no final prose exported as a heading over an empty section —
    // under the doctrine, stated on the `.unknown` arm below, that an export which quietly omits
    // something misrepresents the conversation. Both are now written; what is deliberately NOT
    // embedded (image bytes, reasoning text, events nested inside capability cards) is counted
    // and logged once per export.

    /// Tool rows written into one turn's execution log before the rest fold into "… and N more".
    /// Generous for a real run (a ReAct turn is capped at ~15 iterations, and a plan card's
    /// nested rows are summarised rather than listed), tight enough that a 500-event runaway
    /// timeline does not turn the export into a log dump.
    static let maxExportedToolRows = 50

    /// One `> Attached image:` line. Sized from the bytes actually held when present, falling
    /// back to the recorded `size` for a row whose bytes were not loaded. The bytes themselves
    /// are never embedded: a base64 data URI per screenshot would put megabytes into a text file.
    nonisolated static func attachedImageLine(for image: AttachedImageFile) -> String {
        let kb = Int((Double(max(0, imageByteCount(image))) / 1024).rounded(.up))
        return "> Attached image: `\(image.name)` (\(kb) KB)"
    }

    nonisolated static func imageByteCount(_ image: AttachedImageFile) -> Int {
        image.binaryData.isEmpty ? Int(image.size) : image.binaryData.count
    }

    /// What one export's execution logs deliberately left out, accumulated across messages so
    /// the omission is logged with counts rather than silently.
    struct TimelineOmissions {
        var reasoningRows = 0
        var nestedEvents = 0
        var foldedToolRows = 0
        var otherRows = 0

        var isEmpty: Bool {
            reasoningRows == 0 && nestedEvents == 0 && foldedToolRows == 0 && otherRows == 0
        }
    }

    /// The `<details>` block for an agent turn's timeline: one bounded line per top-level tool
    /// row, one line per capability card (with the count of what it holds), nothing for
    /// reasoning. Returns nil when no event earns a line (a reasoning-only timeline), so the
    /// caller writes no block; the skipped rows are still counted into `omissions`.
    nonisolated static func executionLogLines(for events: [TimelineEvent],
                                              omissions: inout TimelineOmissions) -> [String]? {
        var rows: [String] = []
        var toolCallCount = 0
        var folded = 0

        func appendRow(_ line: String) {
            if rows.count < maxExportedToolRows {
                rows.append(line)
            } else {
                folded += 1
            }
        }

        for event in events {
            switch event {
            case .toolExecution(let data):
                toolCallCount += 1
                appendRow(toolRowLine(for: data))

            case .mediaGeneration(_, let toolName, let artifact, let isComplete):
                toolCallCount += 1
                let label = artifact?.label ?? artifact?.kind.rawValue ?? "media"
                appendRow("- \(isComplete ? "✅" : "⏳") `\(toolName)` \(inlineArgument(label))")

            case .planExecution(let data):
                let nested = event.flattenedIncludingNested.dropFirst()
                let nestedTools = nested.filter { if case .toolExecution = $0 { return true }; return false }.count
                toolCallCount += nestedTools
                omissions.nestedEvents += nested.count
                var line = "- 📋 Plan & Execute: \(data.steps.count) step(s), \(data.completedCount) completed"
                if data.hasDegradedSteps { line += " (degraded)" }
                line += ", \(nestedTools) tool call(s) inside — not listed"
                rows.append(line)

            case .reflectionRun(let data):
                let nested = event.flattenedIncludingNested.dropFirst()
                let nestedTools = nested.filter { if case .toolExecution = $0 { return true }; return false }.count
                toolCallCount += nestedTools
                omissions.nestedEvents += nested.count
                let verdict = data.acceptedTrial.map { "accepted trial \($0)" } ?? "no accepted trial"
                rows.append("- 🔁 Reflexion: \(data.attempts.count) of \(data.maxTrials) trial(s), \(verdict), \(nestedTools) tool call(s) inside — not listed")

            case .thought, .reasoning:
                omissions.reasoningRows += 1

            case .capabilityMilestone, .warning, .unknown:
                omissions.otherRows += 1
            }
        }

        guard !rows.isEmpty else { return nil }

        if folded > 0 {
            omissions.foldedToolRows += folded
            rows.append("- … and \(folded) more tool call(s)")
        }

        var lines = ["<details>",
                     "<summary>Execution log (\(toolCallCount) tool call\(toolCallCount == 1 ? "" : "s"))</summary>",
                     ""]
        lines.append(contentsOf: rows)
        lines.append("")
        lines.append("</details>")
        return lines
    }

    /// `- ✅ \`read_file\` \`Foo.swift\` (120ms)` — outcome, tool name, the primary argument the
    /// timeline row itself shows, duration when measured, and the failure category on failure.
    nonisolated static func toolRowLine(for data: ToolExecutionData) -> String {
        var line = "- \(outcomeGlyph(for: data)) `\(data.name)`"
        let argument = ToolArgFormatter.primaryLabel(tool: data.name, params: data.params)
        if !argument.isEmpty {
            line += " " + inlineArgument(argument)
        }
        if let ms = data.durationMs {
            line += " (\(DurationFormat.milliseconds(ms)))"
        }
        // ⚠️ `isSuccess != true`, not `== false`: since CF-51 a user Stop settles the row with
        // `isSuccess` nil (a stop is not a tool failure) while still recording `.cancelled` in
        // `failureCategory`. Gating on `== false` silently dropped the cause from every exported
        // stopped row — the glyph stayed ⏹, so nothing looked broken.
        if data.isSuccess != true, let category = data.failureCategory {
            line += " — \(category.displayName)"
        }
        return line
    }

    /// ✅ succeeded · ❌ failed · ⏹ stopped (cancelled, declined, or closed without a verdict
    /// because the run was cut) · ⏳ still executing at export time.
    nonisolated static func outcomeGlyph(for data: ToolExecutionData) -> String {
        if data.isExecuting { return "⏳" }
        guard let success = data.isSuccess else { return "⏹" }
        if success { return "✅" }
        switch data.failureCategory {
        case .cancelled?, .userDenied?: return "⏹"
        default: return "❌"
        }
    }

    /// A one-line, bounded inline-code rendering of an argument. Newlines would break the
    /// list item; a backtick inside the argument would close the span, so such a value is
    /// written plain instead.
    nonisolated static func inlineArgument(_ raw: String) -> String {
        let flat = raw.replacingOccurrences(of: "\r", with: " ")
                      .replacingOccurrences(of: "\n", with: " ")
        let bounded = flat.count > 80 ? String(flat.prefix(79)) + "…" : flat
        return bounded.contains("`") ? bounded : "`\(bounded)`"
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

        // [CF-19] What this export deliberately does not embed — logged once at the end.
        var omissions = TimelineOmissions()
        var omittedImageCount = 0
        var omittedImageBytes = 0

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

            // Attached images [CF-19] — named and sized, never embedded (see `attachedImageLine`).
            // What a bare-text export hid was that an image was part of the question at all.
            if let images = message.attachedImageFiles, !images.isEmpty {
                for image in images {
                    lines.append(Self.attachedImageLine(for: image))
                    omittedImageCount += 1
                    omittedImageBytes += Self.imageByteCount(image)
                }
                lines.append("")
            }

            // Agent timeline [CF-19] — BEFORE the content switch, so an all-tool-calls turn with no
            // final prose exports as its execution log rather than as an empty heading.
            let timeline = message.timelineEvents
            if message.sender == .agent, !timeline.isEmpty,
               let log = Self.executionLogLines(for: timeline, omissions: &omissions) {
                lines.append(contentsOf: log)
                lines.append("")
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

        // [CF-19] Same doctrine as the `.unknown` arm: nothing leaves this export unaccounted
        // for. A "where is my screenshot in the export" report is answerable from this line.
        if omittedImageCount > 0 || !omissions.isEmpty {
            let conversation = messages.first.map { String($0.conversationId.uuidString.prefix(8)) } ?? "none"
            logger.info("[EXPORT] conversation \(conversation): \(messages.count) message(s) exported. Not embedded by design — \(omittedImageCount) attached image(s) (\(omittedImageBytes) bytes) listed by name and size only; \(omissions.reasoningRows) reasoning row(s) skipped; \(omissions.nestedEvents) event(s) inside capability cards summarised as counts; \(omissions.foldedToolRows) tool row(s) past the \(Self.maxExportedToolRows)-row cap folded into '… and N more'; \(omissions.otherRows) milestone/warning/unknown row(s) skipped.")
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
