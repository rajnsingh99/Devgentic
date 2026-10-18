// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbApprovalPolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Decides what a spoken approval may authorize and produces the only token that can authorize one.
/// The voice channel is an allowlist: deny by default and admit one narrow shape, since speech recognition
/// mishears.
enum OrbApprovalPolicy {

    /// Proof that `isVoiceApprovable` said yes.
    /// The `private init` is the enforcement: `approveByVoice` takes only this, so no caller can approve by voice
    /// around the policy.
    struct VoiceApproval {
        let operationID: UUID
        let toolName: String
        /// What gets read back before the commit. Never the raw params blob.
        let spokenArguments: String

        fileprivate init(operationID: UUID, toolName: String, spokenArguments: String) {
            self.operationID = operationID
            self.toolName = toolName
            self.spokenArguments = spokenArguments
        }
    }

    enum Decision: Equatable {
        case voiceApprovable(operationID: UUID, toolName: String, spokenArguments: String)
        /// Spoken aloud so the user knows why they are being sent to the window.
        case screenOnly(reason: String)
    }

    // MARK: - The gate

    static func decision(for pending: PendingHITL) -> Decision {
        guard case .toolConfirmation(let confirmation) = pending.kind else {
            // Deliberate scope cut: a clarification answer steers a later tool call, a gate picks a port, and a plan review
            // covers unheard subtasks.
            return .screenOnly(reason: String(localized: "that one needs the main window"))
        }

        // `== .safe`, not `!= .destructive`: `classify` returns `.moderate` for unknown and MCP tools, so only `.safe` is
        // an allowlist.
        guard confirmation.risk == .safe else {
            return .screenOnly(reason: String(localized: "\(spokenToolName(confirmation.toolName)) can change things, so it needs the main window"))
        }

        // Compared as `!= true`: older persisted confirmations decode as nil. A server's self-reported risk is unverified
        // and a voice cannot flag it.
        guard confirmation.riskIsServerDeclared != true else {
            return .screenOnly(reason: String(localized: "that tool reports its own safety, so I'd rather you saw it"))
        }

        // Redundant with `classify`'s first line but asserted directly so a future re-tiering cannot reopen the hole.
        guard !ToolCapability.executesArbitraryCode(confirmation.toolName) else {
            return .screenOnly(reason: String(localized: "that one runs code, so it needs the main window"))
        }

        // A read-back you cannot produce is not a read-back.
        guard let spoken = spokenArguments(confirmation), !spoken.isEmpty else {
            return .screenOnly(reason: String(localized: "I can't read you what it would do, so it needs the main window"))
        }

        return .voiceApprovable(operationID: pending.id,
                                toolName: confirmation.toolName,
                                spokenArguments: spoken)
    }

    /// The token, produced only from an approving decision.
    static func token(for pending: PendingHITL) -> VoiceApproval? {
        guard case .voiceApprovable(let id, let name, let args) = decision(for: pending) else { return nil }
        return VoiceApproval(operationID: id, toolName: name, spokenArguments: args)
    }

    // MARK: - Read-back

    /// What the user hears before committing. Top-level scalars only: nested JSON read aloud is
    /// noise, and anything that needs nesting to explain itself is not a spoken decision.
    static func spokenArguments(_ confirmation: PendingToolConfirmation) -> String? {
        guard case .object(let fields)? = confirmation.arguments else { return nil }
        let parts: [String] = fields
            .sorted { $0.key < $1.key }
            .compactMap { key, value in
                guard let scalar = scalarDescription(value) else { return nil }
                return "\(spokenToolName(key)) \(scalar)"
            }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    private static func scalarDescription(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.contains("/"), !trimmed.contains(" ") {
                return spokenPath(trimmed)
            }
            // Truncation is admitted aloud; clipping at 80 characters silently would hide the tail of an argument.
            guard trimmed.count > 80 else { return trimmed }
            return String(trimmed.prefix(80)) + String(localized: "… and more")
        case .number(let n):
            // Whole numbers read better without a decimal tail: "line 12", not "line 12.0".
            return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b):  return b ? "yes" : "no"
        case .null, .array, .object:
            // Not readable aloud in a sentence. Its absence is what makes the read-back honest.
            return nil
        }
    }

    static func spokenToolName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    /// Speaks the whole path, abbreviating only the home directory.
    /// The read-back is the mitigation, so the directory must be spoken: `id_rsa` alone hides whether a path is a
    /// private key.
    static func spokenPath(_ path: String) -> String {
        var remainder = path
        var prefix = ""
        let home = NSHomeDirectory()
        if remainder == home {
            return String(localized: "your home folder")
        }
        if remainder.hasPrefix(home + "/") {
            prefix = String(localized: "home ")
            remainder = String(remainder.dropFirst(home.count + 1))
        }
        let components = remainder.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return prefix.isEmpty ? path : prefix }
        // "slash" between components: heard, a path with no separators is one long word.
        return prefix + components.joined(separator: " slash ")
    }
}

// MARK: - Spoken grammar

/// What the user said while an approval queue was being read to them.
/// Separate from `voiceCommand(in:)`, which is exact whole-utterance matching; these are parameterised ("approve
/// one and three").
enum OrbApprovalUtterance: Equatable {
    case approve([Int])
    case deny([Int])
    case denyAll
    case describe(Int)
    case openOnScreen
}

extension OrbApprovalPolicy {

    /// Builds the deny-all phrases from the user's own deny keywords. There is no "approve all": its blast radius is
    /// the whole queue.
    /// Deny-all is kept because it fails closed; only user-chosen keywords answer on this channel.
    static func denyAllPhrases(for denyKeywords: [String]) -> [String] {
        denyKeywords.flatMap { ["\($0) all", "\($0) everything"] }
    }

    /// Asking to see it is not a decision, so these stay fixed — they authorize nothing.
    static let screenPhrases = ["show me", "open it", "show it on screen", "let me see", "on screen"]

    /// Parses an utterance heard while the queue was open; nil means "not an approval command" and the caller treats it
    /// as an ordinary request.
    /// The verb must be a prefix, never a substring: "approve the change to the readme" is a sentence, not an approval.
    static func parseApprovalUtterance(
        _ text: String,
        queueSize: Int,
        // No default values: a defaulted keyword list would silently use "approve"/"deny"; requiring it makes divergence a
        // compile error.
        approveKeywords: [String],
        denyKeywords: [String]
    ) -> OrbApprovalUtterance? {
        // Uses the same normalization as the keywords so a word typed in Settings and one heard from the microphone
        // compare identically.
        let normalized = normalizeKeyword(text)
        guard !normalized.isEmpty, queueSize > 0 else { return nil }

        // Denial first, at every level: if a word reaches both lists, the safe reading of an ambiguous instruction is
        // "don't".
        if denyAllPhrases(for: denyKeywords).contains(normalized) { return .denyAll }
        if screenPhrases.contains(normalized) { return .openOnScreen }

        // "what's number two" / "what is two"
        for prefix in ["whats number ", "what is number ", "whats ", "what is ", "describe "] {
            if normalized.hasPrefix(prefix) {
                let rest = String(normalized.dropFirst(prefix.count))
                if let n = ordinals(in: rest, queueSize: queueSize).first { return .describe(n) }
                return nil
            }
        }

        // The verb is the user's own keyword, with denial matched before approval; a fixed verb list would be a second
        // vocabulary.
        if let numbers = ordinals(after: denyKeywords, in: normalized, queueSize: queueSize) {
            return .deny(numbers)
        }
        if let numbers = ordinals(after: approveKeywords, in: normalized, queueSize: queueSize) {
            return .approve(numbers)
        }
        return nil
    }

    /// Returns in-range positions named after any of `verbs` used as a prefix, or nil if no verb led.
    /// A verb that leads but names no valid position returns nil, so a half-heard "approve the" cannot become a commit.
    private static func ordinals(after verbs: [String], in normalized: String, queueSize: Int) -> [Int]? {
        for verb in verbs where normalized.hasPrefix(verb + " ") {
            let rest = String(normalized.dropFirst(verb.count + 1))
            let numbers = ordinals(in: rest, queueSize: queueSize)
            if !numbers.isEmpty { return numbers }
        }
        return nil
    }

    /// Returns 1-based positions named in `text`, in order, deduplicated and in range.
    /// Out-of-range positions are dropped, not clamped: "approve seven" with three pending must not become "approve
    /// three".
    static func ordinals(in text: String, queueSize: Int) -> [Int] {
        let words: [String: Int] = [
            "one": 1, "first": 1, "two": 2, "second": 2, "three": 3, "third": 3,
            "four": 4, "fourth": 4, "five": 5, "fifth": 5, "six": 6, "sixth": 6,
            "seven": 7, "seventh": 7, "eight": 8, "eighth": 8, "nine": 9, "ninth": 9,
            "ten": 10, "tenth": 10,
        ]
        var found: [Int] = []
        for token in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let piece = String(token)
            let value = words[piece] ?? Int(piece)
            guard let value, value >= 1, value <= queueSize, !found.contains(value) else { continue }
            found.append(value)
        }
        return found
    }

    /// The commit word is an exact, whole-utterance match.
    /// This is the second stage of a two-stage commit after the read-back; a substring match would let "don't approve
    /// that" approve it.
    static func isConfirmation(_ text: String, keywords: [String]) -> Bool {
        keywords.contains(normalizeKeyword(text))
    }

    static func isDenial(_ text: String, keywords: [String]) -> Bool {
        keywords.contains(normalizeKeyword(text))
    }

    /// Shared with the utterance parser so a keyword typed in Settings and a keyword heard from
    /// the microphone are compared the same way. Divergence here means a keyword that works in
    /// one place and silently never matches in the other.
    static func normalizeKeyword(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[.,!?'\u{2019}]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

// MARK: - User-defined keywords

/// The words that approve and deny, and the rules that keep a typo from breaking the channel.
/// Configurable because the commit word must be one the user says but does not use in ordinary speech; validated
/// because a one-letter or shared word is unsafe.
enum OrbApprovalKeywords {

    static let approveDefault = "approve"
    static let denyDefault = "deny"

    /// A single letter is not a keyword, since speech recognition emits stray one-letter tokens; two is the floor so
    /// "no" and "ok" work.
    static let minimumLength = 2

    /// Candidates tried in order when the approve list collides entirely with the deny list; the last is unusable as
    /// ordinary speech.
    static let fallbackApproveCandidates = ["approve", "confirm", "go ahead", "accept", "affirmative"]

    static func fallbackApproveKeyword(avoiding deny: [String]) -> String {
        fallbackApproveCandidates.first { !deny.contains($0) } ?? "orb approve"
    }

    enum Problem: Equatable {
        case allDropped(kept: String)
        case collided([String])
    }

    /// Turns what the user typed into the list used for matching.
    /// Comma-separated; every entry goes through the same normalization as the microphone path, so Settings shows
    /// exactly what matches.
    static func parse(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .split(separator: ",")
            .map { OrbApprovalPolicy.normalizeKeyword(String($0)) }
            .filter { $0.count >= minimumLength }
            .filter { seen.insert($0).inserted }
    }

    /// The lists actually used, with every failure mode resolved.
    /// A word in both lists resolves to deny; an empty approve list falls back to the default so voice approval is
    /// never armed but inert.
    static func resolve(approveRaw: String, denyRaw: String) -> (approve: [String], deny: [String], problems: [Problem]) {
        var problems: [Problem] = []

        var approve = parse(approveRaw)
        var deny = parse(denyRaw)

        if approve.isEmpty {
            approve = [approveDefault]
            if !approveRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append(.allDropped(kept: approveDefault))
            }
        }
        if deny.isEmpty {
            deny = [denyDefault]
            if !denyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append(.allDropped(kept: denyDefault))
            }
        }

        let collisions = approve.filter(deny.contains)
        if !collisions.isEmpty {
            approve.removeAll(where: collisions.contains)
            problems.append(.collided(collisions))
            if approve.isEmpty { approve = [approveDefault] }
            // If the default ITSELF was the collision, the deny list keeps it and approve needs
            // something else — otherwise resolving the collision would just recreate it.
            approve.removeAll(where: deny.contains)
            if approve.isEmpty {
                // Every fallback is re-checked against the deny list, so the spoken instruction never names a word that denies.
                approve = [fallbackApproveKeyword(avoiding: deny)]
            }
        }
        return (approve, deny, problems)
    }
}
