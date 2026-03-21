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

/// The UI component to edit the MLX advanced configuration
struct MLXSettingsView: View {
    @Binding var config: MLXAdvancedConfig
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            // Temperature
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.2f", config.temperature))
                        .monospacedDigit()
                        .foregroundColor(theme.secondaryText)
                }
                Slider(value: $config.temperature, in: 0.0...2.0, step: 0.05)
                    .tint(theme.accentColor)
                Text("Controls randomness. Lower values (0.0 - 0.2) are strongly recommended for structured Agent outputs.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            
            Divider()
            
            // Top P
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Top P (Nucleus Sampling)")
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.2f", config.topP))
                        .monospacedDigit()
                        .foregroundColor(theme.secondaryText)
                }
                Slider(value: $config.topP, in: 0.0...1.0, step: 0.05)
                    .tint(theme.accentColor)
                Text("Limits token selection to the highest probability mass.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            
            Divider()
            
            // Repetition Penalty
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Repetition Penalty")
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.2f", config.repetitionPenalty))
                        .monospacedDigit()
                        .foregroundColor(theme.secondaryText)
                }
                Slider(value: $config.repetitionPenalty, in: 1.0...2.0, step: 0.05)
                    .tint(theme.accentColor)
                Text("Penalizes repeating the same tokens. Helps prevent local models from getting stuck in infinite thought loops.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }

            Divider()

            // Repetition Context Size
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Repetition Context Size")
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(config.repetitionContextSize)")
                        .monospacedDigit()
                        .foregroundColor(theme.secondaryText)
                }
                Slider(value: Binding(get: {
                    Double(config.repetitionContextSize)
                }, set: {
                    config.repetitionContextSize = Int($0)
                }), in: 10...60, step: 5)
                .tint(theme.accentColor)
                Text("Number of recent tokens the repetition penalty considers. Larger values catch longer repetition loops.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }

            Divider()
            
            // Max Tokens
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max Tokens")
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(config.maxTokens)")
                        .monospacedDigit()
                        .foregroundColor(theme.secondaryText)
                }
                Slider(value: Binding(get: {
                    Double(config.maxTokens)
                }, set: {
                    config.maxTokens = Int($0)
                }), in: 256...8192, step: 256)
                .tint(theme.accentColor)
                Text("Maximum length of the generated response. Agents need higher limits to accommodate long internal monologues before returning an action.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            
            Button("Reset to Agent Defaults") {
                withAnimation {
                    config = .default()
                }
            }
            .font(.caption)
            .buttonStyle(.link)
            .padding(.top, 8)
        }
    }
}
