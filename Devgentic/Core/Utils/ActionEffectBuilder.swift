//
//  ActionEffectBuilder.swift
//  Devgentic
//
//  Turns a completed file-mutating tool execution into the compact record of what it
//  changed, for episodic memory (and, once the timeline renders diffs itself, for the tool
//  row — same builder, so the row and the agent's memory can never disagree about what a
//  write did).
//
//  See `Docs/codeviewer-rescope-design.md` §5 and §12 D1.
//

import Foundation

extension ActionEffect {

    /// Derives the effect of a tool call, or nil when there is nothing to record.
    ///
    /// Deliberately built on `TimelineFileViewerAction.resolve` rather than re-reading the
    /// params here: that resolver already owns the awkward cases — append mode carries only
    /// the FRAGMENT in `content`, edit tools carry find/replace strings and get their post
    /// state from the executor's read-back, and both spellings of the path argument exist.
    /// Duplicating that logic would let the timeline chip and the agent's memory drift into
    /// describing the same write differently.
    /// `.recordFragment` is the one place memory deliberately diverges from the timeline
    /// chip. `resolve`'s default returns nil for an append with no snapshot — right for a
    /// chip, because opening the fragment as the file would lie. For memory it was the
    /// worst possible answer: `ActionEffect.from` exited at its FIRST guard, so no element
    /// was emitted at all and the `baseline="none"` hedge never applied to appends. The
    /// model read the silence as "nothing happened" — the exact amnesia this type exists
    /// to fix, reached by a different route (audited 2026-07-28).
    static func from(toolExecution data: ToolExecutionData) -> ActionEffect? {
        guard let action = TimelineFileViewerAction.resolve(data: data, missingBaseline: .recordFragment) else {
            return nil
        }

        // Reads change nothing. `.fromDisk` rows are reads by construction.
        guard action.isWrite, let after = action.inlineContent else { return nil }

        guard let before = action.preWriteContent else {
            // The write happened, but with no baseline the change itself can't be
            // described. Record the fact and the file — an agent that knows it wrote
            // `X.java` can at least re-read it; one told nothing assumes it did nothing.
            effectLogger.info("[EFFECT] '\(data.name)' → \(action.fileName): no pre-write snapshot, recording the write without a diff (the file was unreadable or over the snapshot cap at capture).")
            return ActionEffect(
                path: action.filePath,
                linesAdded: after.components(separatedBy: .newlines).count,
                linesRemoved: 0,
                diff: nil,
                isTruncated: false
            )
        }

        let counts = DiffUtility.changeCounts(original: before, modified: after)
        guard counts.added > 0 || counts.deleted > 0 else {
            // A byte-identical rewrite is not a change. Recording it would teach the agent
            // it had edited something when it hadn't.
            effectLogger.debug("[EFFECT] '\(data.name)' → \(action.fileName): content identical, no effect recorded.")
            return nil
        }

        let (diff, truncated) = changedLines(before: before, after: after)
        if truncated {
            effectLogger.info("[EFFECT] '\(data.name)' → \(action.fileName): diff exceeded \(ActionEffect.diffCharacterLimit) chars and was truncated for memory — the model is told so via truncated=\"true\"; the full change is still on the timeline row.")
        }
        return ActionEffect(
            path: action.filePath,
            linesAdded: counts.added,
            linesRemoved: counts.deleted,
            diff: diff,
            isTruncated: truncated
        )
    }

    /// The changed lines, `+`/`-` prefixed, with a little surrounding context — capped.
    ///
    /// Context matters for reverting: `- foo()` alone doesn't say WHERE, so the agent
    /// couldn't put it back. Two lines either side is enough to locate a hunk without
    /// carrying the file.
    private static func changedLines(before: String, after: String) -> (text: String, truncated: Bool) {
        let rows = DiffUtility.generateDiff(original: before, modified: after)
        let contextRadius = 2

        // Indices worth emitting: every change, plus a small window around each.
        var keep = Set<Int>()
        for (index, row) in rows.enumerated() where row.type != .unchanged {
            for offset in -contextRadius...contextRadius {
                let neighbour = index + offset
                if rows.indices.contains(neighbour) { keep.insert(neighbour) }
            }
        }

        var lines: [String] = []
        var lastEmitted: Int? = nil
        for index in keep.sorted() {
            // A gap between kept windows becomes an explicit elision, so the model doesn't
            // read two distant hunks as adjacent.
            if let last = lastEmitted, index > last + 1 { lines.append("…") }
            let row = rows[index]
            switch row.type {
            case .added:     lines.append("+\(row.line)")
            case .deleted:   lines.append("-\(row.line)")
            case .unchanged: lines.append(" \(row.line)")
            }
            lastEmitted = index
        }

        let text = lines.joined(separator: "\n")
        guard text.count > ActionEffect.diffCharacterLimit else { return (text, false) }
        let clipped = String(text.prefix(ActionEffect.diffCharacterLimit))
        return (clipped + "\n… (diff truncated)", true)
    }
}

private let effectLogger = DGLogger(category: "ActionEffect")
