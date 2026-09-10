// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ImageGenAdvancedConfig.swift
//  Devgentic
//
//  Created on 30/03/26.
//
//  Provider-agnostic advanced configuration for image generation profiles.
//  Quality applies to all providers; steps and guidance are MLX-specific.
//

import SwiftUI

// MARK: - Config Model

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

    /// Tolerant decoding — this was the only one of the six advanced-config structs with NO custom
    /// decoder at all, and the synthesized one threw on two reachable inputs.
    ///
    /// ⚠️ Both failures cost the user their WHOLE panel, not one field: a throw here becomes nil in
    /// `BackendProfileService.decodeConfig` and then `?? .default()` in the load path.
    ///   1. `quality` is non-optional, so any blob written before it existed failed outright.
    ///   2. An unrecognised `ImageQuality` raw value — a blob written by a NEWER build that added a
    ///      quality tier — took the whole config down. The app is unsandboxed and its store sits in
    ///      a shared directory, so running an earlier build against a newer store is reachable; the
    ///      profile blob's own `tooNew` refusal exists for exactly that case, and these inner
    ///      structs carry no version stamp of their own to lean on.
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

    /// Whether the selected provider's service actually READS `options.quality`.
    ///
    /// ⚠️ Verified by consumption, not by intent — the two that honour it are the only two that
    /// reference the field: `OpenAIImageGenService` sends it as the `quality` body parameter, and
    /// `MLXImageGenService` selects a different Flux2 pipeline from it.
    /// `GeminiImageGenService` and `OllamaImageGenService` accept `options` and never read a single
    /// field of it, so the picker was decorative for half the supported providers: a user switching
    /// to HD on a Gemini profile got byte-identical output while the caption promised "higher
    /// detail at the cost of speed".
    ///
    /// ⚠️ Gated rather than MAPPED on purpose. Inventing a mapping (sample count, a model variant)
    /// would be guessing at behaviour those APIs do not document — a control that does the wrong
    /// thing is not an improvement on one that does nothing. If Gemini or Ollama later expose a
    /// real quality knob, add the case here and to its service in the same change.
    private var providerHonoursQuality: Bool {
        provider == .openAI || provider == .mlx
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            if providerHonoursQuality {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quality")
                            .fontWeight(.medium)
                        Text("HD produces higher detail at the cost of speed.")
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
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
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
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
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(stepsValue)")
                            .font(.system(.body, design: .monospaced))
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
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }

                // Guidance (CFG Scale)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Guidance Scale")
                            .fontWeight(.medium)
                        Spacer()
                        Text(String(format: "%.1f", config.guidance ?? 3.5))
                            .font(.system(.body, design: .monospaced))
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
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
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
