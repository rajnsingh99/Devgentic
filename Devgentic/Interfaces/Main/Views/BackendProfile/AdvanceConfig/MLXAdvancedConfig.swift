//
//  MLXAdvancedConfig.swift
//  Devgentic
//
//  Created for MLX Advanced Inference Configuration.
//

import SwiftUI

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

    /// Backward-compatible decoding: existing saved configs may lack `repetitionContextSize`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try container.decode(Double.self, forKey: .temperature)
        topP = try container.decode(Double.self, forKey: .topP)
        repetitionPenalty = try container.decode(Double.self, forKey: .repetitionPenalty)
        repetitionContextSize = try container.decodeIfPresent(Int.self, forKey: .repetitionContextSize) ?? 20
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
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
    static func recommended(for metadata: ModelMetadata) -> MLXAdvancedConfig {
        let (penalty, contextSize) = optimalRepetitionSettings(
            tier: metadata.tier,
            quantization: metadata.quantization
        )
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

    /// Upper bound for `maxTokens` — half the context window so the prompt
    /// itself has room. Floor at 512 to keep the field usable even with a
    /// pathologically tiny configured window.
    private var maxTokensCap: Int {
        max(512, contextWindow / 2)
    }

    /// Upper bound for `repetitionContextSize`. Beyond ~2K the sampler's scan
    /// cost outweighs the loop-suppression benefit, so we cap there even when
    /// the model could technically attend to more. Tied to a quarter of the
    /// context window so small-context models don't get a disproportionate cap.
    private var repCtxCap: Int {
        max(64, min(contextWindow / 4, 2048))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Temperature
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature").fontWeight(.medium)
                    Text("Sharpens or flattens the next-token distribution. 0.0 = pick the single most likely token (fully deterministic, best for structured tool calls). 0.5–0.7 = natural conversation. 1.0+ = creative/varied but less reliable. Above 1.5 is rarely useful.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.temperature, in: 0.0...2.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(config.temperature, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Top P
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top P").fontWeight(.medium)
                    Text("After temperature, restricts sampling to the smallest set of tokens whose combined probability reaches this value (nucleus sampling). 1.0 = no filter. 0.9–0.95 = standard for chat. 0.7–0.85 = tighter; pairs with higher temperature to keep output coherent. Lower temperature usually beats lower Top P for structured output.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.topP, in: 0.0...1.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(config.topP, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Repetition Penalty
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repetition Penalty").fontWeight(.medium)
                    Text("Multiplier applied to the probability of recently-emitted tokens. 1.0 = off. 1.05–1.15 = mild (suits frontier models). 1.20–1.30 = strong, useful when small/Q4 models lock into identical tool-call patterns. Above 1.5 can make output incoherent.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.repetitionPenalty, in: 1.0...2.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(config.repetitionPenalty, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            // Repetition Context Size — TextField + Stepper combo with model-derived cap
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repetition Context Size").fontWeight(.medium)
                    Text("How far back (in tokens) the repetition penalty looks. Larger windows catch longer-range loops at a small decode-speed cost. Chat models rarely need more than 64; small/Q4 local models prone to JSON-template loops benefit from values ≥200 because a single tool-call envelope is ~60 tokens.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Range: 10–\(repCtxCap)\(modelContextSuffix)")
                        .font(.caption2).foregroundColor(theme.secondaryText.opacity(0.7))
                }
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    AdvancedConfigNumericField(
                        value: $config.repetitionContextSize,
                        width: 70
                    )
                    Stepper("", value: $config.repetitionContextSize, in: 10...repCtxCap, step: 5)
                        .labelsHidden()
                }
            }
            .onChange(of: config.repetitionContextSize) { _, newVal in
                // Clamp values typed outside the bound via TextField. SwiftUI
                // commits on focus loss/Return, so this fires after the user
                // finishes typing, not on each keystroke.
                let clamped = max(10, min(newVal, repCtxCap))
                if clamped != newVal {
                    config.repetitionContextSize = clamped
                }
            }

            Divider()

            // Max Tokens — TextField + Stepper combo with model-derived cap
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Tokens").fontWeight(.medium)
                    Text("Cap on the length of a single model response. Higher values consume more of the context window — leave room for the prompt itself. A typical tool call needs 100–500 tokens; a multi-paragraph chat reply 500–2000; a long synthesis 2000+.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Range: 256–\(maxTokensCap)\(modelContextSuffix)")
                        .font(.caption2).foregroundColor(theme.secondaryText.opacity(0.7))
                }
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    AdvancedConfigNumericField(
                        value: $config.maxTokens,
                        width: 80
                    )
                    Stepper("", value: $config.maxTokens, in: 256...maxTokensCap, step: 256)
                        .labelsHidden()
                }
            }
            .onChange(of: config.maxTokens) { _, newVal in
                let clamped = max(256, min(newVal, maxTokensCap))
                if clamped != newVal {
                    config.maxTokens = clamped
                }
            }

            HStack {
                Spacer()
                Button {
                    withAnimation {
                        // Prefer the model-aware recommendation when metadata is
                        // available (e.g. tier-tuned repPenalty for Q4); fall back
                        // to the generic default otherwise.
                        if let metadata = modelMetadata {
                            config = .recommended(for: metadata)
                        } else {
                            config = .default()
                        }
                    }
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.accentColor.opacity(0.1))
                        .foregroundColor(theme.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
    }
}
