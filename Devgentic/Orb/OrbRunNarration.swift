// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbRunNarration.swift
//  Devgentic
//
//  [Phase 6 · F1] Turns a finished run into sentences a person can listen to.
//
//  Pure and static on purpose: every function here is a text transform over data the caller
//  already fetched. Speech phrasing is the part most likely to be wrong, and the part that costs
//  a device round-trip to check — so it is the part that must be testable without one.
//
//  ⚠️ WRITTEN FOR AN EAR, NOT AN EYE. The report view can show `/Users/alice/src/Config.swift` and a
//  reader skims it; spoken aloud that is eleven words of noise before the only one that matters.
//  Everything here trims to what carries meaning out loud, and says plainly when it cannot answer
//  rather than reading a data structure at someone.
//

import Foundation

enum OrbRunNarration {

    /// Spoken lists are capped hard. A screen can show thirty rows and the eye picks; an ear has
    /// to receive all thirty in order, and by the fourth the first is gone. Four then a count is
    /// the shape that stays useful — the detail is on screen, and this says so.
    static let spokenListCap = 4

    // MARK: - Verdict

    /// The one-sentence outcome, or an honest explanation of why there isn't one.
    ///
    /// ⚠️ Never speak `verdict.sentence` without checking `unavailability` first: an unavailable
    /// projection carries `RunReportVerdict(label: "", tone: .neutral, sentence: "")`, so speaking
    /// it speaks nothing at all and the turn ends in silence with no reason given.
    static func verdictSentence(_ projection: RunReportProjection) -> String {
        if let reason = unavailabilitySentence(projection.unavailability) { return reason }
        let sentence = projection.verdict.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else {
            return String(localized: "The run finished, but I don't have a summary of it.")
        }
        return sentence
    }

    /// Each cause gets its own sentence. They are four genuinely different situations, and
    /// "I can't tell you" for all four teaches the user the feature is broken.
    static func unavailabilitySentence(_ unavailability: RunReportUnavailability) -> String? {
        switch unavailability {
        case .none:
            return nil
        case .neverRecorded:
            return String(localized: "That run wasn't recorded, so there's nothing for me to look at.")
        case .purged:
            return String(localized: "That run's details have already been cleaned up — they're kept for thirty days.")
        case .storeUnavailable:
            return String(localized: "I can't open the diagnostics database, so I can't tell you what happened.")
        }
    }

    // MARK: - "What went wrong"

    static func problemSentence(_ projection: RunReportProjection) -> String {
        if let reason = unavailabilitySentence(projection.unavailability) { return reason }
        let problems = projection.groups.flatMap(\.rows).filter(\.isProblem)
        guard !problems.isEmpty else {
            return String(localized: "Nothing went wrong in that run.")
        }
        let lines = problems.prefix(spokenListCap).map { spokenProblem($0) }
        return sentence(
            leading: problems.count == 1
                ? String(localized: "One thing went wrong.")
                : String(localized: "\(problems.count) things went wrong."),
            items: Array(lines),
            omitted: problems.count - lines.count
        )
    }

    /// A problem row's title is already prose; `meta` carries the error category. Spoken, the
    /// category first is the useful half — "a timeout, calling read file" beats the reverse.
    static func spokenProblem(_ row: RunReportRow) -> String {
        // ⚠️ A FAILED TOOL ROW'S TITLE IS "name · <80 chars of raw JSON>". Speaking it verbatim
        // read absolute paths and punctuation aloud for twenty seconds — breaking this file's own
        // rule that a path is never spoken, in the one sentence the user asked for. The tool name
        // is the half that carries meaning; the arguments are on screen.
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = row.kind == .tool
            ? spokenToolName(String(title.split(separator: "·", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces))
            : title
        let meta = row.meta.trimmingCharacters(in: .whitespacesAndNewlines)

        // For a tool row `meta` is the bare word "failed", which reads better as a verb phrase.
        if row.kind == .tool, !headline.isEmpty {
            return meta.isEmpty
                ? clipForSpeech(String(localized: "\(headline) had a problem"))
                : clipForSpeech(String(localized: "\(headline) \(meta)"))
        }
        if meta.isEmpty { return clipForSpeech(headline) }
        if headline.isEmpty { return clipForSpeech(meta) }
        return clipForSpeech("\(headline) — \(meta)")
    }

    // MARK: - "What did you change"

    /// ⚠️ Sourced from the MESSAGE, not the projection. Tool rows in the report carry no arguments
    /// — `TraceRecorder.emitToolCall` has no production callers, so every tool row is built with
    /// `call: nil` — and a successful tool's recorded result is the literal string "success".
    /// The message timeline is the only place the real file-level change survives.
    static func changeSentence(effects: [ActionEffect], writeToolNames: [String]) -> String {
        // ⚠️ GROUPED BY PATH FIRST. `changes(in:)` yields one effect per file-mutating EXECUTION,
        // so an agent that edited Config.swift three times used to be announced as "I changed 3
        // files. Config.swift … Config.swift … Config.swift" — a false count and a stutter.
        let merged = mergedByPath(effects)
        if !merged.isEmpty {
            let lines = merged.prefix(spokenListCap).map(spokenEffect)
            return sentence(
                leading: merged.count == 1
                    ? String(localized: "I changed one file.")
                    : String(localized: "I changed \(merged.count) files."),
                items: Array(lines),
                omitted: merged.count - lines.count
            )
        }
        guard !writeToolNames.isEmpty else {
            return String(localized: "I didn't change anything in that run.")
        }
        // Honest fallback: we know something ran that CAN write, but not what it did. Saying so is
        // better than silence and far better than implying nothing changed.
        let names = Set(writeToolNames).sorted().prefix(spokenListCap).map(spokenToolName)
        return String(localized: "I ran \(names.joined(separator: ", ")), but I can't tell from here what changed. The details are in the chat window.")
    }

    /// One entry per PATH, line counts summed, first-touched order preserved — the order the
    /// agent worked in is the order that makes sense read aloud.
    static func mergedByPath(_ effects: [ActionEffect]) -> [ActionEffect] {
        var order: [String] = []
        var totals: [String: (added: Int, removed: Int)] = [:]
        for effect in effects {
            if totals[effect.path] == nil { order.append(effect.path) }
            let running = totals[effect.path] ?? (0, 0)
            totals[effect.path] = (running.added + effect.linesAdded, running.removed + effect.linesRemoved)
        }
        return order.map { path in
            let total = totals[path] ?? (0, 0)
            return ActionEffect(path: path, linesAdded: total.added, linesRemoved: total.removed,
                                diff: nil, isTruncated: false)
        }
    }

    static func spokenEffect(_ effect: ActionEffect) -> String {
        let name = effect.fileName
        switch (effect.linesAdded, effect.linesRemoved) {
        case (0, 0):
            return String(localized: "\(name), no line changes")
        case (let added, 0):
            return String(localized: "\(name), \(added) added")
        case (0, let removed):
            return String(localized: "\(name), \(removed) removed")
        case (let added, let removed):
            return String(localized: "\(name), \(added) added and \(removed) removed")
        }
    }

    /// `fs_smart_search` spoken verbatim is unintelligible. Underscores become spaces; nothing
    /// else is guessed at.
    static func spokenToolName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - "Read me the answer"

    static func answerSentence(_ projection: RunReportProjection) -> String? {
        if unavailabilitySentence(projection.unavailability) != nil { return nil }
        let answer = projection.groups
            .flatMap(\.rows)
            .first { $0.kind == .answer }
        guard let answer else { return nil }
        let text = answer.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Shaping

    /// Joins a lead-in and its items into something that survives being heard once.
    static func sentence(leading: String, items: [String], omitted: Int) -> String {
        guard !items.isEmpty else { return leading }
        var text = leading + " " + items.joined(separator: ". ")
        if omitted > 0 {
            text += String(localized: ". There are \(omitted) more in the chat window.")
        }
        return text
    }

    /// Long error strings are usually a stack trace or a wall of JSON. Past a sentence or so the
    /// listener has stopped following anyway, and the full text is on screen.
    static func clipForSpeech(_ text: String, limit: Int = 160) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        let cut = String(collapsed.prefix(limit))
        // Prefer a word boundary — a sentence sliced mid-word sounds like a fault.
        if let space = cut.lastIndex(of: " ") {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }
}
