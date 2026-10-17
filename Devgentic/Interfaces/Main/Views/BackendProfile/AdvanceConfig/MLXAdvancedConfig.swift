// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXAdvancedConfig.swift
//  Devgentic
//
//  Created for MLX Advanced Inference Configuration.
//

import SwiftUI

/// ⚠️ register A39 — this file had no logger while silently rewriting persisted user settings,
/// so the rewrite was invisible in a support log as well as on screen.
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

    /// Backward-compatible decoding: EVERY field falls back to its default rather than throwing.
    ///
    /// ⚠️ This used to hard-`decode` four of the five fields, so a blob missing any one of them
    /// failed the whole decode. That is not a per-field loss: `BackendProfileService.decodeConfig`
    /// answers a throw with nil and `ProviderAdvancedConfigManager.load` answers nil with
    /// `?? .default()`, so ONE absent key silently replaced the user's entire advanced panel with
    /// app defaults — and the panel then presented those defaults as the user's own settings.
    ///
    /// The hazard is not hypothetical here: `repetitionContextSize` was already grandfathered in
    /// this way, which is proof that fields get added to this struct over time. The next one added
    /// would have reintroduced the same failure.
    ///
    /// `try?` per field also absorbs a wrong-typed value (the legacy number-saved-as-Bool shape the
    /// sibling configs repair explicitly). Falling back to the documented default is preferred over
    /// those siblings' `bool ? 1.0 : 0.0` coercion — a temperature of 1.0 invented from a `true` is
    /// a worse answer than the tuned default, and just as silent.
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

    /// Returns a config with repetition settings tuned to the model's tier and quantization.
    ///
    /// Lower quantization (fewer bits) and smaller models are more prone to degenerate
    /// repetition loops. This method applies stronger penalties and larger context windows
    /// for those cases, while keeping penalties light for high-precision large models.
    ///
    /// `profile` picks the ladder, as for Ollama (`OllamaConfigDefaultProfile.forProfileType`).
    /// The agent ladder is deliberately light: a tool loop has to repeat identifiers verbatim, and
    /// a strong penalty corrupts them. On the 2026-10-06 device run Qwen2.5-3B-4bit at 1.30 over
    /// 30 tokens wrote `DevgeticTestbed` three times, each right after the real path had appeared
    /// in the last 30 tokens, and one of them sent a read outside the project. The loops the strong
    /// ladder was there to break are caught on that path anyway: identical tool calls by the
    /// repeated-call guard, text loops by `StreamingCircuitBreaker`.
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

    /// Computes optimal (repetitionPenalty, repetitionContextSize) based on model characteristics.
    ///
    /// Heuristic rationale:
    /// - Low-bit quantization (2-4 bit) compresses weight resolution, making models more likely
    ///   to get stuck in local probability loops. Stronger penalties break these cycles.
    /// - Smaller models have less capacity to self-regulate, needing more aggressive intervention.
    /// - Larger context windows let the penalty consider more prior tokens, catching longer loops.
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

/// The UI component to edit the MLX advanced configuration.
///
/// Bounds for the integer fields (`repetitionContextSize`, `maxTokens`) are
/// derived from the active model's `ModelMetadata.contextWindow` instead of
/// being hardcoded. This way a profile bound to a 4K-context model gets a
/// tighter cap than one bound to a 128K-context model — without code changes
/// when new models are added.
///
/// Each integer field pairs a `TextField` (for direct entry — typing 256 takes
/// 3 keystrokes vs 47 stepper clicks at the old bounds) with a `Stepper` (for
/// fine adjustment). Values typed outside the model-derived range are silently
/// clamped on commit, with the active range surfaced as a caption underneath
/// the field so the user can see where the cap came from.
// MARK: - Parameter bounds (register A39)

extension MLXAdvancedConfig {

    /// Absolute floors. A value below these is not a tuning choice, it is a typo in the text field
    /// — the provider rejects or misbehaves on them — so these ARE clamped.
    static let maxTokensFloor = 256
    static let repetitionContextFloor = 10

    /// Upper bound for `maxTokens` — half the context window so the prompt itself has room.
    /// Floor at 512 to keep the field usable even with a pathologically tiny configured window.
    ///
    /// ⚠️ Extracted from `MLXSettingsView` so the derivation is assertable. It was a `private var`
    /// on the view, which meant the bounds that silently rewrote user settings could not be
    /// tested at all — the same reason `ModelSelectionPolicy` was lifted out of the pickers.
    static func maxTokensCap(forContextWindow contextWindow: Int) -> Int {
        max(512, contextWindow / 2)
    }

    /// Upper bound for `repetitionContextSize`. Beyond ~2K the sampler's scan cost outweighs the
    /// loop-suppression benefit, so we cap there even when the model could technically attend to
    /// more. Tied to a quarter of the context window so small-context models don't get a
    /// disproportionate cap.
    static func repetitionContextCap(forContextWindow contextWindow: Int) -> Int {
        max(64, min(contextWindow / 4, 2048))
    }
}

struct MLXSettingsView: View {
    @Binding var config: MLXAdvancedConfig

    /// Active model metadata used to derive parameter bounds. Nil when the
    /// profile has no model selected yet (or the model is unknown to the
    /// metadata catalog) — the view falls back to the catalog lookup or a
    /// conservative 8K window so the UI still functions.
    let modelMetadata: ModelMetadata?

    /// Active model name. Used as a secondary fallback when
    /// `modelMetadata.contextWindow` is nil — many profiles persist tier and
    /// quantization but not the context window itself, so we look it up in
    /// `KnownModelContextWindows` (the same catalog AgentConnect uses at
    /// runtime). Nil when no model is selected yet.
    let modelName: String?

    /// Which ladder "Reset to Defaults" restores: the agent one unless hosted in a Bot config.
    var defaultProfile: OllamaConfigDefaultProfile = .agent

    @Environment(\.appTheme) private var theme

    /// Effective context window (tokens) for bound derivation. Layered
    /// fallback that mirrors `AgentConnect.swift:124` so the UI ranges match
    /// the runtime memory-budget calculations:
    ///   1. `ModelMetadata.contextWindow` if captured during scan
    ///   2. `KnownModelContextWindows.lookup(modelName)` for known catalog entries
    ///   3. 8192 as a last-resort safe default
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

    /// Clamps a value up to the absolute floor, and **deliberately does not clamp the ceiling**.
    ///
    /// ⚠️ The upper bound used to be clamped here too, which silently destroyed tuning. The trigger
    /// was not what the register assumed — `.onChange` watches the VALUE, not the cap, so
    /// re-pointing the profile at a smaller-context model clamps nothing at that moment. It fired
    /// on the NEXT editor open, when `ProviderAdvancedConfigManager.load` assigns the stored value
    /// and the now-smaller cap rewrites it. And it did not stop at the panel: the write reaches
    /// `AdvancedConfigSyncModifier`, so the profile went dirty on mere open and the next Save
    /// persisted the reduced number. A user who tuned 8192 for a large-context model got 2048 back
    /// with no notice, no log, and no way to know it had happened.
    ///
    /// The Ollama panel already made the opposite call for `num_ctx` and says why: values over the
    /// model's window are surfaced as a warning "so the user can choose to keep their setting
    /// (e.g. switching models for comparison)". This now matches it. Nothing downstream depends on
    /// the clamp — `AgentConnect` hands the decoded blob straight to `MLXLLMProvider`, so an
    /// over-cap value was never being corrected at runtime anyway; it was only being corrected in
    /// the one place the user could still have fixed it themselves.
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
                        // Prefer the model-aware recommendation when metadata is
                        // available (e.g. tier-tuned repPenalty for Q4); fall back
                        // to the generic default otherwise.
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
