// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AnthropicModelGeneration.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The Anthropic request contract a given model accepts.
enum AnthropicModelGeneration: String, Sendable, Hashable {

    /// Opus 4.7+ / 4.8 / 5, Sonnet 5, Haiku 5.5: adaptive thinking only; `budget_tokens` and sampling parameters return 400.
    /// Supports the full effort ladder including `xhigh`, and accepts `{"type": "disabled"}` (on Opus 5 / Haiku 5.5 only at
    /// effort `high` or below, so the disabled shape is sent with no effort; see `ClaudeLLMProvider`).
    case adaptive

    // Why: testing the tier through its most permissive member sends `disabled` to models that reject it (a 400)
    /// Fable 5 / Mythos 5 / Opus 5.5+, and any unrecognised id. Like `.adaptive`, but thinking is always on:
    /// `{"type": "disabled"}` is a 400 at any effort; omit the parameter or send `{"type": "adaptive"}`.
    /// Also the default for an unreadable id: it never sends `disabled` or `between_tools`, so it cannot 400.
    case adaptiveAlwaysOn

    // Why: `between_tools` takes no other field and is rejected at effort `xhigh`/`max`: send it bare, with no `output_config`
    /// Sonnet 5.5+. Like `.adaptive`, except thinking is turned off with `{"type": "between_tools"}`;
    /// `{"type": "disabled"}` returns 400.
    case adaptiveBetweenTools

    /// Opus 4.6 / Sonnet 4.6. Adaptive thinking is the recommended on-mode, `budget_tokens` is
    /// deprecated but still functional, and sampling parameters are still accepted.
    /// Supports effort, but `xhigh` arrived with Opus 4.7 — so the ladder stops at `max`.
    case adaptiveWithSampling

    /// Opus 4.5 and older, Sonnet 4.5/4.0, Haiku 4.5, every 3.x and 2.x.
    /// Thinking uses `{type: "enabled", budget_tokens: N}`; sampling parameters accepted;
    /// `output_config.effort` errors on Sonnet 4.5 / Haiku 4.5, so it is never sent.
    case legacyBudget

    // MARK: - Capability surface

    /// Whether `temperature` / `top_p` / `top_k` may appear in the request body at all.
    /// Sending them to a model that removed them is a 400 — it does not degrade to "ignored".
    var acceptsSamplingParams: Bool {
        switch self {
        case .adaptive, .adaptiveAlwaysOn, .adaptiveBetweenTools: return false
        case .adaptiveWithSampling, .legacyBudget: return true
        }
    }

    /// Whether thinking is expressed as `{type: "adaptive"}` (true) or the legacy
    /// `{type: "enabled", budget_tokens: N}` (false).
    var usesAdaptiveThinking: Bool {
        switch self {
        case .adaptive, .adaptiveWithSampling, .adaptiveAlwaysOn, .adaptiveBetweenTools: return true
        case .legacyBudget: return false
        }
    }

    /// How an adaptive-era request says "thinking off" — or that it cannot.
    enum ThinkingOffShape: Sendable, Equatable {
        /// `{"type": "disabled"}`.
        case disabled
        /// `{"type": "between_tools"}`, bare — no other thinking field, no effort.
        case betweenTools
        /// Thinking cannot be switched off; the `thinking` key must not carry an off value.
        case notOffered
    }

    // Why: `.notOffered` means the off value must be omitted: sending `disabled` to a model that removed it is a 400 on every
    // request, including a freshly created profile whose default is thinking off
    /// The thinking-off shape this generation accepts; read by both the request builder and the Advanced panel.
    var thinkingOffShape: ThinkingOffShape {
        switch self {
        case .adaptiveAlwaysOn: return .notOffered
        case .adaptiveBetweenTools: return .betweenTools
        case .adaptive, .adaptiveWithSampling, .legacyBudget: return .disabled
        }
    }

    /// Whether the user can switch thinking off on this model at all — the Advanced panel's toggle.
    var canTurnThinkingOff: Bool { thinkingOffShape != .notOffered }

    /// Whether the model accepts the literal `thinking: {type: "disabled"}`.
    var acceptsDisabledThinking: Bool { thinkingOffShape == .disabled }

    /// Whether `output_config.effort` may be sent. It errors on Sonnet 4.5 / Haiku 4.5, and the
    /// legacy tier spans exactly the models where that is a risk, so the whole tier opts out.
    var acceptsEffort: Bool {
        switch self {
        case .adaptive, .adaptiveWithSampling, .adaptiveAlwaysOn, .adaptiveBetweenTools: return true
        case .legacyBudget: return false
        }
    }

    /// The effort levels this generation accepts, lowest first; `xhigh` (from Opus 4.7) is rejected by 4.6 models.
    var supportedEffortLevels: [String] {
        switch self {
        case .adaptive, .adaptiveAlwaysOn, .adaptiveBetweenTools: return ["low", "medium", "high", "xhigh", "max"]
        case .adaptiveWithSampling: return ["low", "medium", "high", "max"]
        case .legacyBudget: return []
        }
    }

    // MARK: - Classification

    /// Classifies a model id. Accepts bare first-party ids (`claude-opus-4-8`), dated snapshots
    /// (`claude-opus-4-5-20251101`), Bedrock's `anthropic.`-prefixed form, and Vertex's `@`
    /// version separator.
    static func classify(modelName: String) -> AnthropicModelGeneration {
        let normalized = normalize(modelName)
        guard !normalized.isEmpty else { return .adaptiveAlwaysOn }

        // 2.x / 3.x families never had adaptive thinking or the effort parameter. Matched first because their version
        // digits precede the family token (`claude-3-5-sonnet-…`), which the positional parse below would misread.
        if normalized.hasPrefix("claude-2")
            || normalized.contains("claude-3")
            || normalized.contains("instant") {
            return .legacyBudget
        }

        // Fable and Mythos are 5-tier by definition and carry no numeric version in the id.
        // Not `.adaptive`: thinking is always on for these two and `{type: "disabled"}` is a 400.
        if normalized.contains("fable") || normalized.contains("mythos") {
            return .adaptiveAlwaysOn
        }

        guard let version = parseVersion(normalized) else {
            // No recognisable family/version — treat as newest, in the one adaptive shape that
            // cannot 400. See the header note and `.adaptiveAlwaysOn`.
            return .adaptiveAlwaysOn
        }

        if version.major >= 5 {
            // 5.5 split the 5 tier by family: Opus 5.5 cannot turn thinking off, Sonnet 5.5 uses `between_tools`, and
            // Opus 5 / Sonnet 5 / Haiku 5.5 still take `disabled`, so a rule on the version alone is wrong.
            let atLeast55 = version.major > 5 || version.minor >= 5
            switch (family(of: normalized), atLeast55) {
            case ("opus", true): return .adaptiveAlwaysOn
            case ("sonnet", true): return .adaptiveBetweenTools
            default: return .adaptive
            }
        }
        if version.major == 4 {
            if version.minor >= 7 { return .adaptive }
            if version.minor == 6 { return .adaptiveWithSampling }
            return .legacyBudget          // 4.5, 4.1, 4.0
        }
        return .legacyBudget
    }

    // MARK: - Parsing internals

    /// Lowercases, strips the Bedrock `anthropic.` provider prefix, and cuts Vertex's `@<date>`
    /// version suffix. Everything downstream assumes this normal form.
    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let atIndex = s.firstIndex(of: "@") { s = String(s[s.startIndex..<atIndex]) }
        if s.hasPrefix("anthropic.") { s = String(s.dropFirst("anthropic.".count)) }
        return s
    }

    /// The family token (`opus` / `sonnet` / `haiku`), or nil.
    private static func family(of normalized: String) -> String? {
        normalized.split(separator: "-").map(String.init).first { ["opus", "sonnet", "haiku"].contains($0) }
    }

    /// The effort the API applies when none is sent; Opus 5.5 and Haiku 5.5 default to `medium`, not `high`.
    static func defaultEffort(for modelName: String) -> String {
        let normalized = normalize(modelName)
        guard let version = parseVersion(normalized),
              version.major > 5 || (version.major == 5 && version.minor >= 5),
              let family = family(of: normalized), family == "opus" || family == "haiku" else { return "high" }
        return "medium"
    }

    // Why: a component longer than two digits is a date stamp; parsed as a minor version it would misclassify the model
    /// Reads the version components following the family token: `claude-opus-4-8` → (4, 8), `claude-opus-5` → (5, 0),
    /// `claude-opus-4-5-20251101` → (4, 5). A date stamp terminates the scan.
    private static func parseVersion(_ normalized: String) -> (major: Int, minor: Int)? {
        let families = ["opus", "sonnet", "haiku"]
        let parts = normalized.split(separator: "-").map(String.init)
        guard let familyIndex = parts.firstIndex(where: { families.contains($0) }) else {
            return nil
        }

        var digits: [Int] = []
        for part in parts.dropFirst(familyIndex + 1) {
            guard part.count <= 2, let value = Int(part) else { break }
            digits.append(value)
            if digits.count == 2 { break }
        }

        guard let major = digits.first else { return nil }
        return (major: major, minor: digits.count > 1 ? digits[1] : 0)
    }
}
