// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    /// [mm-3] One quoted line stating a run's verdict, with any reason flattened onto it.
    ///
    /// Deliberately NOT routed through `inlineArgument`: that caps at 80 characters and wraps in
    /// backticks, which would truncate a real error message and code-format prose. Only its
    /// newline flattening is reused, and for the same reason — a raw newline in provider text
    /// would end the block quote and drop the rest of the sentence out of it.
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
        // ⚠️ [mm-7] A LIST ITEM inside the quote. Consecutive `> Attached image:` lines are one
        // blockquote PARAGRAPH in CommonMark, so their newlines are softbreaks and N attachments
        // rendered run-together on a single wrapped line. `- ` makes each its own list item.
        return "> - Attached image: `\(image.name)` (\(kb) KB)"
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
    /// [mm-5] Attached TEXT files are embedded, bounded per file. The `includeFileContent` flag
    /// that used to gate this is gone: nothing in the app — production or test — ever passed it,
    /// so the whole branch was unreachable in every build, and the export of a turn built around
    /// an attached document carried the filename and none of the words the model was answering
    /// about. The branch was also mis-built. It re-read the file from DISK through
    /// `DocumentExtractionRegistry`, which registers only PDF/DOCX/XLSX/CSV/PPTX/RTF — so a
    /// `.txt`, `.md`, `.swift` or `.json` attachment fell through it with no line and no warning
    /// even with the flag on — and it could fail on a file since moved or deleted. What is
    /// embedded now is `AttachedTextFile.content`: the exact bytes that were sent to the model,
    /// already in memory, filled by `FileProcessorService.readFileContent` (which runs that same
    /// registry itself for the binary formats).
    /// - Parameter isTruncated: true when the caller's fetch hit its cap, so older turns are
    ///   missing. Stated in the document — an export that silently begins partway through
    ///   misrepresents the conversation exactly like a dropped turn does. Deliberately a flag
    ///   and not a total: the caller knows it was capped, not how many messages exist.
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

        // [CF-19] What this export deliberately does not embed — logged once at the end.
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
                    // [mm-7] List item for the same reason as `attachedImageLine` — consecutive
                    // quoted lines collapse into one paragraph.
                    lines.append("> - Attached: `\(file.name)`")
                }
                lines.append("")

                // [mm-5] The text the model actually received, folded so it does not drown the
                // conversation. Bounded per file because `AttachedTextFile.content` holds up to
                // 500 KB and a turn can carry several — the cap and its counter are what keep a
                // .md export from silently becoming multiple megabytes.
                for file in files where !file.content.isEmpty {
                    let body = String(file.content.prefix(Self.attachedFileContentLimit))
                    let omitted = file.content.count - body.count
                    if omitted > 0 {
                        truncatedFileCount += 1
                        omittedFileBytes += omitted
                    }
                    // ⚠️ `fence(for:)`, never a hard-coded ``` — a markdown or code attachment
                    // containing its own fence would otherwise end this block early and the rest
                    // of the file would render as document structure.
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

            // [mm-3] The run's terminal outcome, stated BEFORE the content.
            //
            // The bubble shows a `TerminalOutcomeChip` for any non-completed run; the export
            // said nothing, so an agent turn that streamed real prose and THEN failed or was
            // stopped exported exactly like one that answered normally. The demotion is
            // deliberate on screen (the partial answer is the useful half and the chip carries
            // the verdict) — but the export dropped the chip's half entirely.
            //
            // ⚠️ BEFORE the content, not after, for the reason the execution log above is also
            // first: the very failure being reported is the one most likely to have left the
            // prose ending in an UNCLOSED ``` fence, and a `> …` line appended after that lands
            // INSIDE the open code block and renders as literal text — invisible in precisely
            // the case it exists for.
            //
            // ⚠️ ONE quoted paragraph, never a quote plus a `> - ` list item: a reason that is
            // only whitespace would emit an EMPTY list item, and per CommonMark an empty list
            // item cannot interrupt a paragraph, so it would collapse into the line above and
            // render "Run outcome: Failed -". Trimmed and flattened onto the same line instead.
            let displayed = message.sender == .agent ? (message.currentAgentContent ?? message.content) : message.content
            if message.sender == .agent, !message.isStreaming, !Self.isErrorContent(displayed) {
                // Mirrors the bubble's own suppression (`!isErrorContent`): the `.error` arm
                // below already prints "**Error**: …", and two verdicts is noise.
                if let outcome = message.terminalOutcome, outcome != .completed {
                    lines.append(Self.outcomeLine(outcome.displayName, reason: message.terminalReason))
                    lines.append("")
                } else if message.terminalOutcome == nil, message.lifecycleState.isInterrupted {
                    // ⚠️ `isInterrupted` is `self != .final`, which is TRUE for a live
                    // `.streaming` row — the `!message.isStreaming` guard above is what makes
                    // this mean "cut off and never finished" rather than "in progress".
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
                // ⚠️ [mm-6] Emitted as SEPARATE lines with blank separators. As one joined string,
                // `summary` was followed immediately by `---`, which CommonMark reads as a SETEXT
                // HEADING UNDERLINE — so the whole checkpoint summary rendered as a giant H2
                // instead of a rule-delimited note. `HistoryCompactionService.callIC` trims the
                // summary and throws on empty, so it can never end in a newline of its own; the
                // blank line here is the only thing separating it from the closing rule.
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

        // [CF-19] Same doctrine as the `.unknown` arm: nothing leaves this export unaccounted
        // for. A "where is my screenshot in the export" report is answerable from this line.
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

    /// Presents an NSSavePanel, then loads and writes the Markdown export.
    ///
    /// [mm-4] Panel FIRST, `load` after. The messages used to be fetched — every attached
    /// image's external-storage bytes included, on the main actor — BEFORE the panel was
    /// constructed, so for a long image-heavy conversation nothing appeared for seconds: the
    /// window stopped redrawing, a live stream stalled, and the menu item looked like it had
    /// done nothing, so the user clicked again and queued a second full decode. Now the panel
    /// is on screen at once, a Cancel costs no fetch at all, and the load (already lighter,
    /// see `fetchMessagesForExport`) runs only once the user has committed to a file.
    ///
    /// `load` returns nil when there is nothing to export any more — the panel is modeless, so
    /// the conversation can be deleted while it is up. That used to write a header-only file and
    /// log it as a success; now it is reported as a failure and nothing is written.
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
