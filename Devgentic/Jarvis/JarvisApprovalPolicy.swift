// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisApprovalPolicy.swift
//  Devgentic
//
//  [Phase 6 · F2] Decides what a SPOKEN approval is allowed to authorize — and produces the only
//  token that can authorize one.
//
//  ⚠️⚠️ THE RULE THIS FILE EXISTS TO ENFORCE. Speech recognition mishears. A click carries the
//  arguments on screen, editable, with the user's eyes on them; a spoken "yes" carries none of
//  that and can be produced by a television. So the voice channel gets an ALLOWLIST, not a
//  blocklist: deny by default, and admit exactly one narrow shape.
//
//  ⚠️ THIS GATES A CHANNEL, NOT A TOOL. The standing project rule is that capability metadata may
//  label and group but must never gate an action or override a per-tool preference. Nothing here
//  does: every tool stays fully approvable on screen, with identical options. What is restricted
//  is one INPUT MODALITY that cannot show arguments or be re-read before it commits.
//
//  ⚠️ NOT A JUDGEMENT ABOUT AUTONOMOUS MODE. `JarvisToolApprovals.autonomous` is a deliberate
//  "approve everything in this conversation" switch, chosen from a typed settings picker, held in
//  memory only, conversation-scoped, and gated on a human being reachable. It legitimately
//  auto-approves `execute_shell` — that is the feature, confirmed by the project owner
//  2026-09-05. This policy is a DIFFERENT question: not "did the user opt into unattended
//  execution" but "can a microphone commit this one action right now". Do not merge them, and do
//  not weaken this file to match that one.
//

import Foundation

enum JarvisApprovalPolicy {

    /// Proof that `isVoiceApprovable` said yes.
    ///
    /// ⚠️ THE `private init` IS THE ENFORCEMENT. `approveByVoice` takes this and nothing else, so
    /// a future caller physically cannot approve by voice without going through the policy. A
    /// comment saying "check the risk first" stops working the moment someone adds a second call
    /// site; a type that cannot be constructed elsewhere does not.
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
            // ⚠️ Deliberate scope cut, not an oversight. A clarification ANSWER re-enters the
            // agent's context and steers a later tool call — an indirect authorization channel
            // with no read-back. A gate option picks a workflow output port. A plan review is
            // all-or-nothing over subtasks the user never heard.
            return .screenOnly(reason: String(localized: "that one needs the main window"))
        }

        // ⚠️ `== .safe`, NOT `!= .destructive`. `HITLRiskTier.classify` returns `.moderate` for its
        // `default` case, so EVERY unknown tool and every MCP tool lands in `.moderate` — a
        // `!= .destructive` gate would make an unknown third-party tool voice-approvable. `.safe`
        // is the only tier that is an explicit allowlist, which is the right shape for a channel
        // that mishears.
        guard confirmation.risk == .safe else {
            return .screenOnly(reason: String(localized: "\(spokenToolName(confirmation.toolName)) can change things, so it needs the main window"))
        }

        // ⚠️ Optional-compared to `true`: pre-SE3 persisted confirmations decode as nil, so
        // `== false` would wrongly exclude them. An MCP server's self-reported risk is an
        // unverified third-party claim; the banner is required to render "(server-declared)"
        // beside it, and a voice cannot render anything.
        guard confirmation.riskIsServerDeclared != true else {
            return .screenOnly(reason: String(localized: "that tool reports its own safety, so I'd rather you saw it"))
        }

        // Redundant today — `classify` escalates on its first line — but asserted directly so a
        // future re-tiering of `classify` cannot quietly reopen the hole. That capability set is
        // kept honest by a source-reading, build-failing test.
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
            // ⚠️ Truncation is ADMITTED. Silently clipping at 80 characters let the tail of an
            // argument — which is where a suffix or a query string lives — vanish without a sound.
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

    /// ⚠️⚠️ THE READ-BACK IS THE ENTIRE MITIGATION, AND IT USED TO DROP THE DIRECTORY.
    ///
    /// `scalarDescription` reduced every path to its last component, so
    /// `/Users/alice/.ssh/id_rsa` was read aloud as **"id_rsa"** — and `read_file` returns file
    /// CONTENTS. The directory is the part that distinguishes a harmless note from a private key,
    /// and it was the part being thrown away, in the one sentence that exists so the user can
    /// refuse. A shorter read-back is not worth a mitigation that cannot catch the case it is for.
    ///
    /// So: the whole path, spoken. Home is abbreviated because "slash Users slash raj" is on every
    /// single path and carries no information; nothing else is dropped.
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
///
/// ⚠️ SEPARATE FROM `voiceCommand(in:)` ON PURPOSE. That matcher is exact whole-utterance set
/// membership; these are parameterised ("approve one and three"). Bolting parameters onto it
/// would turn a set lookup into a parser and put every ordinary sentence at risk of being
/// swallowed as a command.
enum JarvisApprovalUtterance: Equatable {
    case approve([Int])
    case deny([Int])
    case denyAll
    case describe(Int)
    case openOnScreen
}

extension JarvisApprovalPolicy {

    /// ⚠️ NO "APPROVE ALL". "All" is exactly the word a television supplies, and its blast radius
    /// is the entire queue. Denying all is kept because it fails closed — the worst case of a
    /// misheard denial is that the user is asked again.
    ///
    /// ⚠️ DERIVED FROM THE USER'S OWN DENY KEYWORDS, not a fixed list. A keyword the user chose is
    /// the only word this channel should answer to; a second hardcoded vocabulary beside it is a
    /// word that commits an action they never configured.
    static func denyAllPhrases(for denyKeywords: [String]) -> [String] {
        denyKeywords.flatMap { ["\($0) all", "\($0) everything"] }
    }

    /// Asking to see it is not a decision, so these stay fixed — they authorize nothing.
    static let screenPhrases = ["show me", "open it", "show it on screen", "let me see", "on screen"]

    /// Parses an utterance heard while the queue was open. Nil means "not an approval command" —
    /// and the caller must then treat it as an ordinary request, never silently swallow it.
    ///
    /// ⚠️ THE VERB MUST BE A PREFIX, never a substring. "approve the change to the readme" is a
    /// sentence about approving, not an approval; matching it as a command would execute something
    /// the user was only talking about. The existing vocabulary makes the same choice and pins it
    /// with a test.
    static func parseApprovalUtterance(
        _ text: String,
        queueSize: Int,
        // ⚠️ NO DEFAULT VALUES, DELIBERATELY. A defaulted keyword list is a call site that compiles
        // while silently using "approve"/"deny" — which is precisely the divergence this parameter
        // was added to remove, reintroduced by omission. Making it required turns the safety
        // property into a compile error instead of something a test has to notice.
        approveKeywords: [String],
        denyKeywords: [String]
    ) -> JarvisApprovalUtterance? {
        // ⚠️ The SAME normalization the keywords go through, so a word typed in Settings and a word
        // heard from the microphone are compared identically. Divergence here produces a keyword
        // that looks right in the pane and silently never fires.
        let normalized = normalizeKeyword(text)
        guard !normalized.isEmpty, queueSize > 0 else { return nil }

        // ⚠️ DENIAL FIRST, at every level. If a word somehow reaches both lists, the safe reading of
        // an ambiguous instruction to run a tool is "don't".
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

        // ⚠️ THE VERB IS THE USER'S OWN KEYWORD, and denial is matched before approval.
        //
        // A fixed verb list here would be a second vocabulary beside the configurable one — so a
        // user who changed their commit word to keep it out of their ordinary speech (the entire
        // reason the setting exists) would find "approve one" still committing tools. The keyword
        // is the vocabulary; this grammar only adds a target to it.
        if let numbers = ordinals(after: denyKeywords, in: normalized, queueSize: queueSize) {
            return .deny(numbers)
        }
        if let numbers = ordinals(after: approveKeywords, in: normalized, queueSize: queueSize) {
            return .approve(numbers)
        }
        return nil
    }

    /// In-range positions named after any of `verbs` used as a PREFIX, or nil if no verb led.
    ///
    /// ⚠️ Prefix, never substring — "can you approve the change to the readme" is a sentence about
    /// approving, not an approval, and matching it would run something the user was only discussing.
    /// A verb that leads but names no valid position returns nil rather than an empty approval, so a
    /// half-heard "approve the—" cannot degrade into a commit.
    private static func ordinals(after verbs: [String], in normalized: String, queueSize: Int) -> [Int]? {
        for verb in verbs where normalized.hasPrefix(verb + " ") {
            let rest = String(normalized.dropFirst(verb.count + 1))
            let numbers = ordinals(in: rest, queueSize: queueSize)
            if !numbers.isEmpty { return numbers }
        }
        return nil
    }

    /// 1-based positions named in `text`, in order, deduplicated, and never out of range.
    ///
    /// Out-of-range is DROPPED rather than clamped: "approve seven" with three pending must not
    /// quietly become "approve three".
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

    /// ⚠️ THE COMMIT WORD IS AN EXACT, WHOLE-UTTERANCE MATCH.
    ///
    /// This is the second half of a two-stage commit: the tool and its arguments were just read
    /// back, and this is the word that actually authorizes. Treating "uh, sure, maybe" as consent
    /// is the whole failure mode of voice approval, so only an exact match counts — never a
    /// substring, or "don't approve that" would approve it.
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
///
/// ⚠️ WHY THESE ARE CONFIGURABLE AT ALL. The commit word has to be one the user will actually say
/// and one that does NOT occur in their ordinary speech near the microphone. Those pull in
/// opposite directions and the right answer is personal — "yes" is natural but is also the single
/// most common word in a conversation happening in the same room.
///
/// ⚠️ AND WHY THEY ARE VALIDATED. This is the one setting where a careless value has teeth: a
/// one-letter keyword false-fires constantly, and a word used for BOTH actions makes the outcome
/// a coin toss on a decision that runs a tool.
enum JarvisApprovalKeywords {

    static let approveDefault = "approve"
    static let denyDefault = "deny"

    /// ⚠️ A single letter is not a keyword — speech recognition emits stray one-letter tokens all
    /// the time, and any of them would be a commit. Two is the floor because "no" and "ok" are
    /// legitimate choices a user might reasonably want.
    static let minimumLength = 2

    /// Candidates tried in order when the user's approve list collides entirely with their deny
    /// list. The last one is deliberately unusable as ordinary speech: at that point every natural
    /// word has been claimed for denial, and a keyword nobody says by accident is the right
    /// outcome — the Settings readout shows what was chosen.
    static let fallbackApproveCandidates = ["approve", "confirm", "go ahead", "accept", "affirmative"]

    static func fallbackApproveKeyword(avoiding deny: [String]) -> String {
        fallbackApproveCandidates.first { !deny.contains($0) } ?? "jarvis approve"
    }

    enum Problem: Equatable {
        case allDropped(kept: String)
        case collided([String])
    }

    /// Turns what the user typed into the list actually used for matching.
    ///
    /// Comma-separated so several words can share one field. Every entry is normalized through the
    /// SAME function the microphone path uses, so what is shown in Settings is exactly what will
    /// match — anything else produces a keyword that looks right and never fires.
    static func parse(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .split(separator: ",")
            .map { JarvisApprovalPolicy.normalizeKeyword(String($0)) }
            .filter { $0.count >= minimumLength }
            .filter { seen.insert($0).inserted }
    }

    /// The lists actually used, with every failure mode resolved rather than left to the caller.
    ///
    /// ⚠️ COLLISIONS RESOLVE TO DENY. A word in both lists is ambiguous, and the safe reading of an
    /// ambiguous instruction to run a tool is "don't". Silently preferring approve would make a
    /// typo authorize things.
    ///
    /// ⚠️ AN EMPTY LIST FALLS BACK TO THE DEFAULT rather than staying empty. Empty approve keywords
    /// would mean nothing can ever be approved by voice — a feature that is on, armed, and inert,
    /// with no way to tell from the orb that a cleared text field is why.
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
                // ⚠️ EVERY fallback is re-checked. The old code substituted "confirm" without
                // testing it, so a deny list of "approve, confirm" produced overlapping lists —
                // and Jarvis then told the user to say a word that denies. Denial is checked
                // first, so it failed closed, but the spoken instruction was simply wrong.
                approve = [fallbackApproveKeyword(avoiding: deny)]
            }
        }
        return (approve, deny, problems)
    }
}
