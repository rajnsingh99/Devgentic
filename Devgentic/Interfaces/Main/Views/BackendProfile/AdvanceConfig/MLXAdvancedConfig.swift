// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Logger for this file, so rewrites of persisted user settings are visible in a support log.
private let logger = DGLogger(category: "MLXAdvancedConfig")

/// Data model representing advanced MLX inference parameters
struct MLXAdvancedConfig: Codable, Equatable {
    var temperature: Double
    var topP: Double
    var repetitionPenalty: Double
    var repetitionContextSize: Int
    var maxTokens: Int

    init(temperature: Double, topP: Double, repetitionPenalty: Double, repetitionContextSize: Int = 20, maxTokens: Int) {
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.maxTokens = maxTokens
    }

    // Why: a throw is answered with nil and then `?? .default()`, so one absent key would silently replace the user's whole
    // advanced panel with defaults.
    /// Backward-compatible decoding: every field falls back to its default rather than throwing. A wrong-typed value also
    /// falls back to the documented default instead of being coerced.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.default()
        temperature = (try? container.decode(Double.self, forKey: .temperature)) ?? fallback.temperature
        topP = (try? container.decode(Double.self, forKey: .topP)) ?? fallback.topP
        repetitionPenalty = (try? container.decode(Double.self, forKey: .repetitionPenalty)) ?? fallback.repetitionPenalty
        repetitionContextSize = (try? container.decode(Int.self, forKey: .repetitionContextSize)) ?? 20
        maxTokens = (try? container.decode(Int.self, forKey: .maxTokens)) ?? fallback.maxTokens
    }

    /// Default values optimized for Agentic reasoning and structured outputs
    static func `default`() -> MLXAdvancedConfig {
        return MLXAdvancedConfig(
            temperature: 0.1,
            topP: 0.9,
            repetitionPenalty: 1.15,
            repetitionContextSize: 20,
            maxTokens: 2048
        )
    }

    /// Returns a config with repetition settings tuned to the model's tier and quantization: stronger penalties and
    /// larger windows for low-bit and small models. `profile` picks the ladder; the agent ladder is light because a tool
    /// loop must repeat identifiers verbatim and a strong penalty corrupts them.
    static func recommended(for metadata: ModelMetadata, profile: OllamaConfigDefaultProfile) -> MLXAdvancedConfig {
        let (penalty, contextSize) = profile == .agent
            ? agentRepetitionSettings(tier: metadata.tier)
            : optimalRepetitionSettings(tier: metadata.tier, quantization: metadata.quantization)
        return MLXAdvancedConfig(
            temperature: 0.1,
            topP: 0.9,
            repetitionPenalty: penalty,
            repetitionContextSize: contextSize,
            maxTokens: 2048
        )
    }

    /// Computes (repetitionPenalty, repetitionContextSize) from model characteristics. Low-bit quantization and small
    /// models loop more easily and get stronger penalties; larger windows catch longer loops.
    private static func optimalRepetitionSettings(
        tier: ModelTier,
        quantization: String?
    ) -> (penalty: Double, contextSize: Int) {
        let bits = parseBits(from: quantization)
        let isLowQuant = bits <= 4

        switch tier {
        case .tiny:
            return isLowQuant ? (1.30, 30) : (1.25, 25)
        case .small:
            return isLowQuant ? (1.25, 25) : (1.15, 20)
        case .medium:
            return isLowQuant ? (1.20, 30) : (1.15, 20)
        case .large:
            return isLowQuant ? (1.15, 25) : (1.10, 20)
        case .ultra:
            return (1.10, 20)
        }
    }

    /// The agent ladder: enough to discourage a stutter, too little to flip a confident token. The
    /// window stays at the chat ladder's 20–30 so the prompt cache's minimum suffix is unchanged.
    private static func agentRepetitionSettings(tier: ModelTier) -> (penalty: Double, contextSize: Int) {
        switch tier {
        case .tiny, .small:
            return (1.05, 30)
        case .medium, .large, .ultra:
            return (1.05, 20)
        }
    }

    /// Extracts the numeric bit-width from a quantization string like "3bit", "4bit", "Q4_K_M".
    /// Returns 16 (full precision) if the string is nil or unparseable.
    private static func parseBits(from quantization: String?) -> Int {
        guard let q = quantization?.lowercased() else { return 16 }
        // Match patterns: "3bit", "4bit", "q4_k_m", "q8_0", "2bit"
        if let match = q.range(of: #"(\d+)\s*bit"#, options: .regularExpression) {
            return Int(q[match].filter(\.isNumber)) ?? 16
        }
        if let match = q.range(of: #"q(\d+)"#, options: .regularExpression) {
            return Int(q[match].filter(\.isNumber)) ?? 16
        }
        return 16
    }
}

/// The UI component to edit the MLX advanced configuration. Integer bounds derive from the active model's
/// `ModelMetadata.contextWindow`; each field pairs a `TextField` with a `Stepper`, out-of-range typed values are
/// clamped on commit, and the active range is shown as a caption.
// MARK: - Parameter bounds (register A39)

extension MLXAdvancedConfig {

    /// Absolute floors. A value below these is not a tuning choice, it is a typo in the text field
    /// — the provider rejects or misbehaves on them — so these ARE clamped.
    static let maxTokensFloor = 256
    static let repetitionContextFloor = 10

    /// Upper bound for `maxTokens`: half the context window so the prompt has room, with a floor of 512. A static
    /// function so the derivation can be tested.
    static func maxTokensCap(forContextWindow contextWindow: Int) -> Int {
        max(512, contextWindow / 2)
    }

    /// Upper bound for `repetitionContextSize`: a quarter of the context window, capped near 2K where the sampler's scan
    /// cost outweighs the loop-suppression benefit.
    static func repetitionContextCap(forContextWindow contextWindow: Int) -> Int {
        max(64, min(contextWindow / 4, 2048))
    }
}

struct MLXSettingsView: View {
    @Binding var config: MLXAdvancedConfig

    /// Active model metadata that parameter bounds derive from. Nil when no model is selected or the model is unknown to
    /// the catalog; the view then falls back to a catalog lookup or a conservative 8K window.
    let modelMetadata: ModelMetadata?

    /// Active model name, a secondary fallback when `modelMetadata.contextWindow` is nil: looked up in
    /// `KnownModelContextWindows`. Nil when no model is selected.
    let modelName: String?

    /// Which ladder "Reset to Defaults" restores: the agent one unless hosted in a Bot config.
    var defaultProfile: OllamaConfigDefaultProfile = .agent

    @Environment(\.appTheme) private var theme

    /// Effective context window (tokens) for bound derivation, mirroring `AgentConnect`: `ModelMetadata.contextWindow`,
    /// else `KnownModelContextWindows.lookup(modelName)`, else 8192.
    private var contextWindow: Int {
        if let cw = modelMetadata?.contextWindow { return cw }
        if let name = modelName, let cw = KnownModelContextWindows.lookup(name) { return cw }
        return 8192
    }

    private var maxTokensCap: Int {
        MLXAdvancedConfig.maxTokensCap(forContextWindow: contextWindow)
    }

    private var repCtxCap: Int {
        MLXAdvancedConfig.repetitionContextCap(forContextWindow: contextWindow)
    }

    /// Suffix shown next to a range hint — surfaces the model context window
    /// when known so the user understands where the cap came from.
    private var modelContextSuffix: String {
        if let ctx = modelMetadata?.contextWindow {
            return " · model context: \(ctx) tokens"
        }
        if let name = modelName, let ctx = KnownModelContextWindows.lookup(name) {
            return " · model context: \(ctx) tokens (catalog)"
        }
        return ""
    }

    // MARK: - Bound enforcement (register A39)

    // Why: clamping the ceiling rewrote stored values when the editor opened with a smaller-context model, marking the
    // profile dirty and persisting the reduced number on the next Save.
    /// Clamps a value up to the absolute floor and does not clamp the ceiling.
    private func clampFloorOnly(_ value: inout Int, newValue: Int, floor: Int, field: String) {
        guard newValue < floor else { return }
        value = floor
        logger.notice(
            "[PROFILE] MLX advanced config '\(field)' was \(newValue), below the absolute floor "
            + "\(floor), and has been raised to it. CONSEQUENCE: values under the floor are "
            + "rejected by the sampler, so this is a typo repair — an over-cap value, by contrast, "
            + "is kept and surfaced as a warning rather than rewritten."
        )
    }

    /// Inline warning for a stored value above the model-derived cap. Mirrors the Ollama panel's
    /// `num_ctx` row so the two read the same way.
    @ViewBuilder
    private func overCapWarning(current: Int, cap: Int, what: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text("Current value \(current) exceeds this model's \(what) cap of \(cap). Your setting is kept — lower it if this model cannot handle it.")
                .font(theme.fontCaption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(theme.warningColor)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Temperature
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Sharpens or flattens the next-token distribution. 0.0 = pick the single most likely token (fully deterministic, best for structured tool calls). 0.5–0.7 = natural conversation. 1.0+ = creative/varied but less reliable. Above 1.5 is rarely useful.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.temperature, in: 0.0...2.0, step: 0.05)
                        .accessibilityLabel("Temperature")
                        .accessibilityValue(String(format: "%.2f", config.temperature))
                        .frame(width: 150)
                    Text("\(config.temperature, specifier: "%.2f")")
                        .font(theme.fontFootnote.monospacedDigit())
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Top P
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top P")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("After temperature, restricts sampling to the smallest set of tokens whose combined probability reaches this value (nucleus sampling). 1.0 = no filter. 0.9–0.95 = standard for chat. 0.7–0.85 = tighter; pairs with higher temperature to keep output coherent. Lower temperature usually beats lower Top P for structured output.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.topP, in: 0.0...1.0, step: 0.05)
                        .accessibilityLabel("Top P")
                        .accessibilityValue(String(format: "%.2f", config.topP))
                        .frame(width: 150)
                    Text("\(config.topP, specifier: "%.2f")")
                        .font(theme.fontFootnote.monospacedDigit())
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Repetition Penalty
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repetition Penalty")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Multiplier applied to the probability of recently-emitted tokens. 1.0 = off. 1.05–1.15 = mild (suits frontier models). 1.20–1.30 = strong, useful when small/Q4 models lock into identical tool-call patterns. Above 1.5 can make output incoherent.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.repetitionPenalty, in: 1.0...2.0, step: 0.05)
                        .accessibilityLabel("Repetition penalty")
                        .accessibilityValue(String(format: "%.2f", config.repetitionPenalty))
                        .frame(width: 150)
                    Text("\(config.repetitionPenalty, specifier: "%.2f")")
                        .font(theme.fontFootnote.monospacedDigit())
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Repetition Context Size — TextField + Stepper combo with model-derived cap
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repetition Context Size")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("How far back (in tokens) the repetition penalty looks. Larger windows catch longer-range loops at a small decode-speed cost. Chat models rarely need more than 64; small/Q4 local models prone to JSON-template loops benefit from values ≥200 because a single tool-call envelope is ~60 tokens.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Range: 10–\(repCtxCap)\(modelContextSuffix)")
                        .font(theme.fontCaption2).foregroundColor(theme.secondaryText.opacity(0.7))

                    if config.repetitionContextSize > repCtxCap {
                        overCapWarning(
                            current: config.repetitionContextSize,
                            cap: repCtxCap,
                            what: "repetition context"
                        )
                    }
                }
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    AdvancedConfigNumericField(
                        value: $config.repetitionContextSize,
                        width: 70,
                        accessibilityName: "Repetition context size"
                    )
                    Stepper("", value: $config.repetitionContextSize, in: 10...repCtxCap, step: 5)
                        .labelsHidden()
                        .accessibilityLabel("Repetition context size stepper")
                        .accessibilityValue("\(config.repetitionContextSize)")
                }
            }
            .onChange(of: config.repetitionContextSize) { _, newVal in
                clampFloorOnly(&config.repetitionContextSize,
                               newValue: newVal,
                               floor: MLXAdvancedConfig.repetitionContextFloor,
                               field: "repetitionContextSize")
            }

            Divider()

            // Max Tokens — TextField + Stepper combo with model-derived cap
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Tokens")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Cap on the length of a single model response. Higher values consume more of the context window — leave room for the prompt itself. A typical tool call needs 100–500 tokens; a multi-paragraph chat reply 500–2000; a long synthesis 2000+.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Range: 256–\(maxTokensCap)\(modelContextSuffix)")
                        .font(theme.fontCaption2).foregroundColor(theme.secondaryText.opacity(0.7))

                    if config.maxTokens > maxTokensCap {
                        overCapWarning(
                            current: config.maxTokens,
                            cap: maxTokensCap,
                            what: "max tokens"
                        )
                    }
                }
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    AdvancedConfigNumericField(
                        value: $config.maxTokens,
                        width: 80,
                        accessibilityName: "Max tokens"
                    )
                    Stepper("", value: $config.maxTokens, in: 256...maxTokensCap, step: 256)
                        .labelsHidden()
                        .accessibilityLabel("Max tokens stepper")
                        .accessibilityValue("\(config.maxTokens)")
                }
            }
            .onChange(of: config.maxTokens) { _, newVal in
                clampFloorOnly(&config.maxTokens,
                               newValue: newVal,
                               floor: MLXAdvancedConfig.maxTokensFloor,
                               field: "maxTokens")
            }

            HStack {
                Spacer()
                GlassActionButton(title: "Reset to Defaults", icon: "arrow.counterclockwise", isAccent: false) {
                    withAnimation {
                        // Prefers the model-aware recommendation when metadata is available; falls back to the generic default otherwise.
                        if let metadata = modelMetadata {
                            config = .recommended(for: metadata, profile: defaultProfile)
                        } else {
                            config = .default()
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}
