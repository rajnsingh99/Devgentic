// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageGenAdvancedConfig.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

// MARK: - Config Model

/// Provider-agnostic advanced configuration for image generation profiles.
/// Quality applies to all providers; steps and guidance are MLX-specific.
struct ImageGenAdvancedConfig: Codable, Equatable {
    var quality: ImageQuality
    var steps: Int?
    var guidance: Double?

    static func `default`() -> ImageGenAdvancedConfig {
        ImageGenAdvancedConfig(quality: .standard, steps: nil, guidance: nil)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case quality, steps, guidance
    }

    /// Memberwise initializer, required because the custom decoder below suppresses synthesis.
    init(quality: ImageQuality, steps: Int?, guidance: Double?) {
        self.quality = quality
        self.steps = steps
        self.guidance = guidance
    }

    // Why: a throw loses the user's whole panel (nil in `decodeConfig`, then the default), not one field.
    /// Tolerant decoding: a missing `quality` (an older blob) or an unrecognised `ImageQuality` raw value must not throw.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quality = (try? container.decode(ImageQuality.self, forKey: .quality)) ?? .standard
        steps = try? container.decodeIfPresent(Int.self, forKey: .steps)
        guidance = try? container.decodeIfPresent(Double.self, forKey: .guidance)
    }

    /// MLX defaults with explicit steps/guidance for Flux2 models.
    static func mlxDefault() -> ImageGenAdvancedConfig {
        ImageGenAdvancedConfig(quality: .standard, steps: 28, guidance: 3.5)
    }
}

// MARK: - Settings View

struct ImageGenSettingsView: View {
    @Binding var config: ImageGenAdvancedConfig
    let provider: ApiProvider
    @Environment(\.appTheme) private var theme

    // Why: gated, not mapped: inventing a quality mapping for APIs that document none would guess at behaviour.
    /// Whether the selected provider's service actually reads `options.quality`.
    /// Only OpenAI (the `quality` body parameter) and MLX (selects a Flux2 pipeline) consume it; Gemini and Ollama ignore it.
    private var providerHonoursQuality: Bool {
        provider == .openAI || provider == .mlx
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            if providerHonoursQuality {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quality")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("HD produces higher detail at the cost of speed.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }
                    Spacer(minLength: 16)
                    Picker("", selection: $config.quality) {
                        Text("Standard").tag(ImageQuality.standard)
                        Text("HD").tag(ImageQuality.hd)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                    .labelsHidden()
                    .accessibilityLabel("Image quality")
                    .accessibilityValue(config.quality == .hd ? "HD" : "Standard")
                }
            } else {
                // Hidden, not disabled: a greyed-out control still implies the value is stored and
                // honoured somewhere, and here it is neither.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(theme.secondaryText)
                        .accessibilityHidden(true)
                    Text("This provider has no quality setting — image detail is fixed by the model you select.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }
                .accessibilityElement(children: .combine)
            }

            // MLX-only: Steps & Guidance
            if provider == .mlx {
                Divider()

                // Steps
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Inference Steps")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text("\(stepsValue)")
                            .font(theme.fontFootnote.monospacedDigit())
                            .foregroundColor(theme.accentColor)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(config.steps ?? 28) },
                            set: { config.steps = Int($0) }
                        ),
                        in: 10...50,
                        step: 1
                    )

                    Text("More steps improve quality but increase generation time.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }

                // Guidance (CFG Scale)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Guidance Scale")
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        Text(String(format: "%.1f", config.guidance ?? 3.5))
                            .font(theme.fontFootnote.monospacedDigit())
                            .foregroundColor(theme.accentColor)
                    }

                    Slider(
                        value: Binding(
                            get: { config.guidance ?? 3.5 },
                            set: { config.guidance = $0 }
                        ),
                        in: 1.0...20.0,
                        step: 0.5
                    )

                    Text("Higher values follow the prompt more strictly; lower values are more creative.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }

                // Reset
                HStack {
                    Spacer()
                    GlassActionButton(title: "Reset to Defaults", icon: "arrow.counterclockwise", isAccent: false) {
                        config = .mlxDefault()
                    }
                }
            }
        }
    }

    private var stepsValue: Int {
        config.steps ?? 28
    }
}
