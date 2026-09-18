// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AnthropicModelGeneration.swift
//  Devgentic
//
//  Created on 07/08/26.
//
//  Classifies an Anthropic model id into the request contract it accepts.
//
//  ⚠️ WHY THIS EXISTS. `ClaudeLLMProvider` used to build one request shape for every Claude model,
//  and that shape is now rejected by every current flagship:
//
//    • `thinking: {type: "enabled", budget_tokens: N}` returns 400 on Opus 4.7+ / Sonnet 5 /
//      Fable 5 / Mythos 5. `{type: "adaptive"}` replaced it, with depth controlled by
//      `output_config.effort` rather than a token count.
//    • `temperature` / `top_p` / `top_k` are REMOVED on those same models and return 400 —
//      not merely ignored, and not conditional on thinking being enabled.
//
//  Both remain valid on Opus 4.6 / Sonnet 4.6 and older, so this cannot be a flag day: the
//  provider has to emit whichever contract the *selected* model accepts. That decision is
//  isolated here so it is unit-testable without a network call, and so a future model only
//  needs a case added in one place.
//
//  ⚠️ An unrecognised id classifies as `.adaptive` (the newest contract) ON PURPOSE. Model ids
//  arrive from the live `/v1/models` listing, so the ids this table does not know are the ones
//  released after it was written — newer, not older. Guessing "new" degrades gracefully (a
//  genuinely ancient model simply loses thinking and sampling); guessing "old" hard-400s every
//  request to a model the user just picked from the app's own list.
//

import Foundation

/// The Anthropic request contract a given model accepts.
enum AnthropicModelGeneration: String, Sendable, Hashable {

    /// Opus 4.7+ / 4.8 / 5, Sonnet 5 — and any unrecognised id.
    /// Adaptive thinking only; `budget_tokens` and all sampling parameters return 400.
    /// Supports the full effort ladder including `xhigh`, and accepts an explicit
    /// `{"type": "disabled"}` to turn thinking off.
    case adaptive

    /// Fable 5 / Mythos 5. Identical to `.adaptive` in every respect but one, and that one is a
    /// hard 400 rather than a degraded response: **thinking is always on**, so an explicit
    /// `{"type": "disabled"}` is REJECTED at any effort. The parameter must be omitted, or sent
    /// as `{"type": "adaptive"}` — the API treats those two as equivalent.
    ///
    /// ⚠️ This case exists because the tier it was folded into is the one whose members mostly
    /// DO accept `disabled`. Classifying by tier and then testing the tier through its most
    /// permissive member is how the 400 got shipped: `{"type": "disabled"}` is legal on Opus 5
    /// and Sonnet 5 and illegal here, and nothing in the shared behaviour distinguishes them.
    case adaptiveAlwaysOn

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
        case .adaptive, .adaptiveAlwaysOn: return false
        case .adaptiveWithSampling, .legacyBudget: return true
        }
    }

    /// Whether thinking is expressed as `{type: "adaptive"}` (true) or the legacy
    /// `{type: "enabled", budget_tokens: N}` (false).
    var usesAdaptiveThinking: Bool {
        switch self {
        case .adaptive, .adaptiveWithSampling, .adaptiveAlwaysOn: return true
        case .legacyBudget: return false
        }
    }

    /// Whether the model accepts an explicit `thinking: {type: "disabled"}`.
    ///
    /// ⚠️ `false` means the key must be OMITTED, not that omitting it is merely tidier. Sending
    /// `disabled` to a model that removed it is a 400 on every request — and since
    /// `AnthropicAdvancedConfig.default()` ships `extendedThinking: false`, that is the shape a
    /// freshly created profile sends before the user has touched a single control.
    var acceptsDisabledThinking: Bool {
        switch self {
        case .adaptiveAlwaysOn: return false
        case .adaptive, .adaptiveWithSampling, .legacyBudget: return true
        }
    }

    /// Whether `output_config.effort` may be sent. It errors on Sonnet 4.5 / Haiku 4.5, and the
    /// legacy tier spans exactly the models where that is a risk, so the whole tier opts out.
    var acceptsEffort: Bool {
        switch self {
        case .adaptive, .adaptiveWithSampling, .adaptiveAlwaysOn: return true
        case .legacyBudget: return false
        }
    }

    /// The effort levels this generation accepts, lowest first.
    /// ⚠️ `xhigh` was introduced with Opus 4.7 — sending it to a 4.6 model is rejected.
    var supportedEffortLevels: [String] {
        switch self {
        case .adaptive, .adaptiveAlwaysOn: return ["low", "medium", "high", "xhigh", "max"]
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
        guard !normalized.isEmpty else { return .adaptive }

        // 2.x / 3.x families never had adaptive thinking or the effort parameter. These are
        // matched first because their version digits sit BEFORE the family token
        // (`claude-3-5-sonnet-…`), which the positional parse below would otherwise misread.
        if normalized.hasPrefix("claude-2")
            || normalized.contains("claude-3")
            || normalized.contains("instant") {
            return .legacyBudget
        }

        // Fable and Mythos are 5-tier by definition and carry no numeric version in the id.
        // ⚠️ NOT `.adaptive`: thinking is always on for these two and `{type: "disabled"}` is a
        // 400. Everything else about the contract is identical, which is exactly why folding them
        // in went unnoticed.
        if normalized.contains("fable") || normalized.contains("mythos") {
            return .adaptiveAlwaysOn
        }

        guard let version = parseVersion(normalized) else {
            // No recognisable family/version — treat as newest. See the header note on why
            // this direction is the safe one.
            return .adaptive
        }

        if version.major >= 5 { return .adaptive }
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

    /// Reads the version components that follow the family token.
    ///
    /// `claude-opus-4-8`            → (4, 8)
    /// `claude-opus-5`             → (5, 0)
    /// `claude-opus-4-5-20251101`  → (4, 5)   — the 8-digit date terminates the scan
    /// `claude-sonnet-4-20250514`  → (4, 0)
    ///
    /// ⚠️ A component longer than two digits is a DATE STAMP, not a version. Without that cut,
    /// `claude-opus-4-5-20251101` would parse a minor version of 20251101 and classify as
    /// adaptive — silently stripping the sampling parameters that model still accepts.
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
