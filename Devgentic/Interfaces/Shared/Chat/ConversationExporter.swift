// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationExporter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import AppKit
import os

private let logger = DGLogger(category: "ConversationExporter")

struct ConversationExporter {

    /// One quoted line stating a run's verdict, with any reason flattened onto a single line. Does not reuse
    /// `inlineArgument`, which truncates at 80 characters and code-formats prose; a raw newline would end the
    /// quote.
    nonisolated static func outcomeLine(_ verdict: String, reason: String?) -> String {
        let trimmed = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "> **Run outcome:** \(verdict)" }
        let flattened = trimmed
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "> **Run outcome:** \(verdict) — \(flattened)"
    }

    /// Whether this content is already an error card, i.e. already states its own verdict.
    nonisolated static func isErrorContent(_ content: MessageContent) -> Bool {
        if case .error = content { return true }
        return false
    }

    /// [mm-5] Per-file cap on embedded attachment text. Matches the `maxSize` the old (dead)
    /// extraction branch asked the registry for, so the bound is not a new number.
    static let attachedFileContentLimit = 10_000

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

    // MARK: - Attachments and timeline
    // Attachments and timeline are exported too; what is deliberately not embedded (image bytes, reasoning text, events
    // nested inside capability cards) is counted and logged once per export, so the export never quietly omits something.

    /// Tool rows written into one turn's execution log before the rest fold into "… and N more". Generous for a
    /// real run (a ReAct turn is capped at ~15 iterations) yet tight enough that a 500-event runaway stays
    /// readable.
    static let maxExportedToolRows = 50

    /// One `> Attached image:` line. Sized from the bytes actually held when present, falling
    /// back to the recorded `size` for a row whose bytes were not loaded. The bytes themselves
    /// are never embedded: a base64 data URI per screenshot would put megabytes into a text file.
    nonisolated static func attachedImageLine(for image: AttachedImageFile) -> String {
        let kb = Int((Double(max(0, imageByteCount(image))) / 1024).rounded(.up))
        // A list item inside the quote: consecutive `> Attached image:` lines are one blockquote paragraph in CommonMark and
        // would run together on one wrapped line; `- ` makes each its own item.
        return "> - Attached image: `\(image.name)` (\(kb) KB)"
    }

    nonisolated static func imageByteCount(_ image: AttachedImageFile) -> Int {
        image.binaryData.isEmpty ? Int(image.size) : image.binaryData.count
    }

    /// What one export's execution logs left out, accumulated across messages so the omission is logged with counts.
    struct TimelineOmissions {
        var reasoningRows = 0
        var nestedEvents = 0
        var foldedToolRows = 0
        var otherRows = 0

        var isEmpty: Bool {
            reasoningRows == 0 && nestedEvents == 0 && foldedToolRows == 0 && otherRows == 0
        }
    }

    /// The `<details>` block for an agent turn's timeline: one bounded line per top-level tool row, one per
    /// capability card (with the count of what it holds), nothing for reasoning. Returns nil when no event earns
    /// a line, so the caller writes no block; skipped rows are still counted into `omissions`.
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

            case .backgroundTask(let data):
                toolCallCount += 1
                // The command and how it ended, never the output: a background task's log lives in a temp file whose `logPath` is
                // meaningless on another machine, so it is omitted rather than exported as a dead path.
                let verdict: String
                switch data.status {
                case .running:     verdict = "⏳ still running"
                case .exited:      verdict = data.exitCode == 0 ? "✅ exit 0" : "⚠️ exit \(data.exitCode.map(String.init) ?? "?")"
                case .timedOut:    verdict = "⛔️ killed at its timeout"
                case .stopped:     verdict = "⛔️ stopped"
                case .interrupted: verdict = "⚠️ interrupted by app restart"
                }
                appendRow("- \(verdict) `background` \(inlineArgument(data.command))")

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
        // `isSuccess != true`, not `== false`: a user Stop settles the row with `isSuccess` nil while recording `.cancelled` in
        // `failureCategory`, so gating on `== false` would drop the cause from stopped rows.
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

    /// Exports a conversation's messages to a Markdown string; attached text files are embedded, bounded per file, from
    /// `AttachedTextFile.content` (the exact bytes sent to the model).
    /// - Parameter isTruncated: true when the caller's fetch hit its cap, so older turns are missing; stated in the document.
    static func toMarkdown(title: String, messages: [ChatMessage],
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

        // What this export deliberately does not embed, logged once at the end.
        var omissions = TimelineOmissions()
        var omittedImageCount = 0
        var omittedImageBytes = 0
        var truncatedFileCount = 0
        var omittedFileBytes = 0

        for message in chronological {
            let timestamp = dateFormatter.string(from: message.timestamp)
            let role = message.sender == .user ? "You" : "Agent"

            lines.append("## \(role) — \(timestamp)")
            lines.append("")

            // Attached files
            if let files = message.attachedTextFiles, !files.isEmpty {
                for file in files {
                    // List item for the same reason as `attachedImageLine`: consecutive quoted lines collapse into one paragraph.
                    // The delivery note says when the model got less than this file (cut to the injection budget, omitted, or path-only).
                    lines.append("> - Attached: `\(file.name)`" + (file.delivery?.note.map { " — \($0)" } ?? ""))
                }
                lines.append("")

                // The attached file's text, folded and bounded per file: `AttachedTextFile.content` holds up to 500 KB and a
                // turn can carry several, so the cap and its counter keep the export small.
                for file in files where !file.content.isEmpty {
                    let body = String(file.content.prefix(Self.attachedFileContentLimit))
                    let omitted = file.content.count - body.count
                    if omitted > 0 {
                        truncatedFileCount += 1
                        omittedFileBytes += omitted
                    }
                    // `fence(for:)`, never a hard-coded ```: an attachment containing its own fence would end this block early.
                    let fence = Self.fence(for: body)
                    lines.append("<details>")
                    lines.append("<summary>Content of \(file.name)\(omitted > 0 ? " — first \(Self.attachedFileContentLimit) characters of \(file.content.count)" : "")</summary>")
                    lines.append("")
                    lines.append(fence)
                    lines.append(body)
                    lines.append(fence)
                    lines.append("</details>")
                    lines.append("")
                }
            }

            // Attached images: named and sized, never embedded (see `attachedImageLine`), so the export shows an image
            // was part of the question.
            if let images = message.attachedImageFiles, !images.isEmpty {
                for image in images {
                    lines.append(Self.attachedImageLine(for: image))
                    omittedImageCount += 1
                    omittedImageBytes += Self.imageByteCount(image)
                }
                lines.append("")
            }

            // Agent timeline, before the content switch, so an all-tool-calls turn with no final prose exports as its execution log
            // rather than as an empty heading.
            let timeline = message.timelineEvents
            if message.sender == .agent, !timeline.isEmpty,
               let log = Self.executionLogLines(for: timeline, omissions: &omissions) {
                lines.append(contentsOf: log)
                lines.append("")
            }

            // Why: before the content: a failed run often ends in an unclosed ``` fence that would swallow a later `>
            // …` line; one quoted paragraph, since an empty list item cannot interrupt a paragraph
            // The run's terminal outcome, stated before the content, as the bubble's outcome chip does for a
            // non-completed run.
            let displayed = message.sender == .agent ? (message.currentAgentContent ?? message.content) : message.content
            if message.sender == .agent, !message.isStreaming, !Self.isErrorContent(displayed) {
                // Mirrors the bubble's own suppression (`!isErrorContent`): the `.error` arm
                // below already prints "**Error**: …", and two verdicts is noise.
                if let outcome = message.terminalOutcome, outcome != .completed {
                    lines.append(Self.outcomeLine(outcome.displayName, reason: message.terminalReason))
                    lines.append("")
                } else if message.terminalOutcome == nil, message.lifecycleState.isInterrupted {
                    // `isInterrupted` is `self != .final`, true for a live `.streaming` row too; the `!message.isStreaming` guard above
                    // makes this mean "cut off and never finished" rather than "in progress".
                    lines.append(Self.outcomeLine("Interrupted", reason: "this run was cut off and never finished"))
                    lines.append("")
                }
            }

            // Content
            switch displayed {
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
                // Separate lines with blank separators: otherwise `summary` is followed directly by `---`, which CommonMark
                // reads as a setext heading underline.
                lines.append("---")
                lines.append("")
                lines.append("**History Checkpoint**")
                lines.append("")
                lines.append(summary)
                lines.append("")
                lines.append("---")

            case .unknown(let type, _):
                // Marked, not silently dropped: an export that quietly omits a turn misrepresents
                // the conversation. The payload is not printed — it is raw JSON, not prose.
                lines.append("*[Content from a newer version of Devgentic (\(type)) — not shown]*")
            }

            lines.append("")
            lines.append("---")
            lines.append("")
        }

        // Same doctrine as the `.unknown` arm: nothing leaves this export unaccounted for, so a missing screenshot
        // is answerable from this line.
        if omittedImageCount > 0 || truncatedFileCount > 0 || !omissions.isEmpty {
            let conversation = messages.first.map { String($0.conversationId.uuidString.prefix(8)) } ?? "none"
            logger.info("[EXPORT] conversation \(conversation): \(messages.count) message(s) exported. Not embedded by design — \(omittedImageCount) attached image(s) (\(omittedImageBytes) bytes) listed by name and size only; \(omissions.reasoningRows) reasoning row(s) skipped; \(omissions.nestedEvents) event(s) inside capability cards summarised as counts; \(omissions.foldedToolRows) tool row(s) past the \(Self.maxExportedToolRows)-row cap folded into '… and N more'; \(omissions.otherRows) milestone/warning/unknown row(s) skipped; \(truncatedFileCount) attached text file(s) truncated at \(Self.attachedFileContentLimit) characters, dropping \(omittedFileBytes) character(s) — the document says so per file.")
        }

        return lines.joined(separator: "\n")
    }

    /// What the exporter is handed once — and only once — the user has picked a destination.
    typealias ExportSource = (messages: [ChatMessage], isTruncated: Bool)

    /// How the save panel is shown: production runs `NSSavePanel.begin`; tests substitute a
    /// presenter that answers immediately, which is what lets the ORDER (panel before fetch)
    /// be pinned without a window.
    typealias SavePanelPresenter = @MainActor (NSSavePanel, @escaping @MainActor (URL?) -> Void) -> Void

    /// How a failed export is told to the user: production runs a modal `NSAlert`; tests
    /// substitute a recorder (a modal alert would hang the test host).
    typealias FailureReporter = @MainActor (String) -> Void

    /// Presents an NSSavePanel, then loads and writes the Markdown export. The panel shows before `load` runs, so
    /// Cancel costs no fetch. `load` returns nil when nothing remains to export (the conversation can be deleted
    /// while the panel is up); that is reported as a failure.
    @MainActor
    static func exportToFile(title: String,
                             presentPanel: SavePanelPresenter = Self.presentSavePanel,
                             reportFailure: @escaping FailureReporter = Self.presentExportFailure,
                             load: @escaping @MainActor () async -> ExportSource?) {
        let savePanel = NSSavePanel()
        savePanel.title = String(localized: "Export Conversation")
        savePanel.nameFieldStringValue = sanitizeFilename(title) + ".md"
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true

        presentPanel(savePanel) { url in
            guard let url else {
                logger.info("[EXPORT] '\(title)' cancelled at the save panel — nothing was fetched or built.")
                return
            }
            Task { @MainActor in
                guard let source = await load() else {
                    logger.warning("[EXPORT] '\(title)' — the conversation was gone by the time the user chose \(url.lastPathComponent). CONSEQUENCE: nothing written; the user is told instead of receiving a header-only file logged as a success.")
                    reportFailure(String(localized: "The conversation no longer exists, so there is nothing to export."))
                    return
                }
                let markdown = await toMarkdown(title: title, messages: source.messages,
                                                isTruncated: source.isTruncated)
                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                    logger.info("Exported conversation to \(url.path)")
                } catch {
                    logger.error("Failed to export conversation: \(error.localizedDescription)")
                    reportFailure(String(localized: "Could not save the conversation: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// The production failure reporter: a modal alert.
    @MainActor
    static func presentExportFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Export Failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// The production presenter: `begin` returns immediately and reports the choice later.
    @MainActor
    static func presentSavePanel(_ panel: NSSavePanel, completion: @escaping @MainActor (URL?) -> Void) {
        panel.begin { response in
            let url = response == .OK ? panel.url : nil
            Task { @MainActor in completion(url) }
        }
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
        return String(cleaned.prefix(80))
    }
}
