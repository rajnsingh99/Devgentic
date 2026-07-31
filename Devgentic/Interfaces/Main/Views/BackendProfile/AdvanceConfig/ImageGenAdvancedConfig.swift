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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Quality (all providers)
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
