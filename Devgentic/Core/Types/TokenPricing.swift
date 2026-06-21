//
//  TokenPricing.swift
//  Devgentic
//
//  Approximate list prices for per-trace cost rollup (observability D1). USD per 1M
//  tokens, matched by substring against the model name. These are a deliberately plain,
//  hand-maintained table — NOT fetched — so EDIT them as provider pricing changes. Local
//  models (MLX/Ollama) and any unmatched model return nil (no cost attributed).
//

import Foundation

enum TokenPricing {
    /// (model-name substring, input $/1M, output $/1M). First match wins, so order
    /// most-specific entries first.
    private static let table: [(match: String, inputPerM: Double, outputPerM: Double)] = [
        ("claude-opus",       15.0, 75.0),
        ("claude-3-opus",     15.0, 75.0),
        ("claude-3-5-sonnet",  3.0, 15.0),
        ("claude-sonnet",      3.0, 15.0),
        ("claude-3-5-haiku",   0.80, 4.0),
        ("claude-haiku",       0.80, 4.0),
        ("gpt-4o-mini",        0.15, 0.60),
        ("gpt-4o",             2.50, 10.0),
        ("o1-mini",            1.10, 4.40),
        ("o1",                15.0, 60.0),
        ("gpt-4-turbo",       10.0, 30.0),
        ("gpt-4",             30.0, 60.0),
        ("gpt-3.5",            0.50, 1.50),
        ("gemini-1.5-pro",     1.25, 5.0),
        ("gemini-1.5-flash",   0.075, 0.30),
        ("gemini-2.0-flash",   0.10, 0.40),
        ("gemini-2",           0.10, 0.40),
    ]

    /// Estimated cost in USD for `usage` on `model`, or nil for local/unknown models.
    /// (Token *counts* may themselves be estimated — see `TokenUsage.isEstimated` — in
    /// which case the cost is only as good as that estimate; callers persist that flag.)
    static func estimatedCostUSD(model: String?, usage: TokenUsage) -> Double? {
        guard let model = model?.lowercased(),
              let row = table.first(where: { model.contains($0.match) }) else { return nil }
        return Double(usage.inputTokens) / 1_000_000 * row.inputPerM
             + Double(usage.outputTokens) / 1_000_000 * row.outputPerM
    }
}
