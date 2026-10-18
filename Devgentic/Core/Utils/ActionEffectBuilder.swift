// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ActionEffectBuilder.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Turns a completed file-mutating tool execution into the compact record of what it changed, for episodic memory.
/// One builder serves the timeline row and the agent's memory, so they cannot disagree about what a write did.
extension ActionEffect {

    /// Derives the effect of a tool call, or nil when there is nothing to record.
    /// Built on `TimelineFileViewerAction.resolve`, which owns append mode, edit tools and both path spellings.
    /// `.recordFragment` lets an append with no snapshot still be recorded, which the timeline chip would not show.
    static func from(toolExecution data: ToolExecutionData) -> ActionEffect? {
        guard let action = TimelineFileViewerAction.resolve(data: data, missingBaseline: .recordFragment) else {
            return nil
        }

        // Reads change nothing. `.fromDisk` rows are reads by construction.
        guard action.isWrite, let after = action.inlineContent else { return nil }

        guard let before = action.preWriteContent else {
            // The write happened but there is no baseline to diff: record the fact and the file, so the agent can re-read it.
            effectLogger.info("[EFFECT] '\(data.name)' → \(action.fileName): no pre-write snapshot, recording the write without a diff (the file was unreadable or over the snapshot cap at capture).")
            return ActionEffect(
                path: action.filePath,
                linesAdded: after.components(separatedBy: .newlines).count,
                linesRemoved: 0,
                diff: nil,
                isTruncated: false,
                // Taken even with no diff: the retrieval promise is what goes stale, and a
                // bodyless effect still advertises the file as the agent left it.
                fingerprint: .of(after)
            )
        }

        // One line-level pass feeds both the counts and the diff text; this runs on the main actor, so a second pass would
        // block it.
        let rows = DiffUtility.lineLevelDiff(original: before, modified: after)
        let counts = DiffUtility.changeCounts(rows: rows)
        guard counts.added > 0 || counts.deleted > 0 else {
            // A byte-identical rewrite is not a change. Recording it would teach the agent
            // it had edited something when it hadn't.
            effectLogger.debug("[EFFECT] '\(data.name)' → \(action.fileName): content identical, no effect recorded.")
            return nil
        }

        let (diff, truncated) = changedLines(rows: rows)
        if truncated {
            effectLogger.info("[EFFECT] '\(data.name)' → \(action.fileName): diff exceeded \(ActionEffect.diffCharacterLimit) chars and was truncated for memory — the model is told so via truncated=\"true\"; the full change is still on the timeline row.")
        }
        return ActionEffect(
            path: action.filePath,
            linesAdded: counts.added,
            linesRemoved: counts.deleted,
            diff: diff,
            isTruncated: truncated,
            // Fingerprint from `after`, already in memory: no syscall on the main actor; the render-time comparison does the I/O.
            fingerprint: .of(after)
        )
    }

    /// The changed lines, `+`/`-` prefixed, with two lines of surrounding context, capped.
    /// Context locates a hunk for reverting; takes the rows `from` already computed, so no second diff pass is needed.
    private static func changedLines(rows: [DiffResult]) -> (text: String, truncated: Bool) {
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
