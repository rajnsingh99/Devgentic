//
//  AdvanceConfigurationView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//  Updated on 28/02/26 to adopt Modern UI Layout and alignment.
//

import SwiftUI

struct GeminiSettingsView: View {
    @Binding var config: GeminiAdvancedConfig
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            // Temperature
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature").fontWeight(.medium)
                    Text("Controls the randomness of the generated response.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.temperature.toNonOptional(defaultValue: 0.9), in: 0.0...1.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(config.temperature ?? 0.9, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            
            Divider()
            
            // Top P
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top P").fontWeight(.medium)
                    Text("Cumulative probability of tokens to consider.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.topP.toNonOptional(defaultValue: 1.0), in: 0.0...1.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(config.topP ?? 1.0, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            
            Divider()
            
            // Top K
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top K").fontWeight(.medium)
                    Text("Maximum number of tokens to consider.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    Text("\(config.topK ?? 1)").monospacedDigit()
                    Stepper("", value: $config.topK.toNonOptional(defaultValue: 1), in: 1...100).labelsHidden()
                }
            }
            
            Divider()
            
            // Max Output Tokens
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Output Tokens").fontWeight(.medium)
                    Text("Maximum length of the generated response.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    Text("\(config.maxOutputTokens ?? 2048)").monospacedDigit()
                    Stepper("", value: $config.maxOutputTokens.toNonOptional(defaultValue: 2048), in: 256...8192, step: 256).labelsHidden()
                }
            }
            
            Divider()
            
            // Safety Settings Header
            Text("Safety Settings")
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.top, 8)
            
            ForEach($config.safetySettings.toNonOptional(defaultValue: GeminiAdvancedConfig.default().safetySettings ?? [])) { $setting in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatCategory(setting.category.rawValue))
                            .fontWeight(.medium)
                    }
                    
                    Spacer(minLength: 16)
                    
                    Picker("", selection: $setting.threshold) {
                        ForEach(HarmBlockThreshold.allCases, id: \.self) { threshold in
                            Text(formatThreshold(threshold.rawValue)).tag(threshold)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
            }
        }
    }
    
    // Formatting Helpers for Gemini Safety Labels
    private func formatCategory(_ raw: String) -> String {
        raw.replacingOccurrences(of: "HARM_CATEGORY_", with: "")
           .replacingOccurrences(of: "_", with: " ")
           .capitalized
    }

    private func formatThreshold(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "BLOCK_", with: "")
                      .replacingOccurrences(of: "_", with: " ")
                      .capitalized
        return text == "None" ? "Block None" : text
    }
}

struct OllamaSettingsView: View {
    @Binding var config: OllamaAdvancedConfig
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            // Temperature
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Temperature").fontWeight(.medium)
                    Text("Controls the randomness of the generated response.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.temperature.toNonOptional(defaultValue: 0.8), in: 0.0...2.0, step: 0.1)
                        .frame(width: 150)
                    Text("\(config.temperature ?? 0.8, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            
            Divider()
            
            // Top P
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top P").fontWeight(.medium)
                    Text("Cumulative probability of tokens to consider.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.topP.toNonOptional(defaultValue: 0.9), in: 0.0...1.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(config.topP ?? 0.9, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            
            Divider()
            
            // Top K
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top K").fontWeight(.medium)
                    Text("Maximum number of tokens to consider.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    Text("\(config.topK ?? 40)").monospacedDigit()
                    Stepper("", value: $config.topK.toNonOptional(defaultValue: 40), in: 1...100).labelsHidden()
                }
            }
            
            Divider()
            
            // Context Window
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context Window").fontWeight(.medium)
                    Text("Number of tokens the model can remember (num_ctx).").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    Text("\(config.numCtx ?? 2048)").monospacedDigit()
                    Stepper("", value: $config.numCtx.toNonOptional(defaultValue: 2048), in: 256...8192, step: 256).labelsHidden()
                }
            }
            
            Divider()
            
            // Seed
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fixed Seed").fontWeight(.medium)
                    Text("Set a specific seed for reproducible outputs.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                TextField("Optional", value: $config.seed, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }
            
            Divider()
            
            // Repeat Penalty
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repeat Penalty").fontWeight(.medium)
                    Text("Prevents the model from repeating the same tokens.").font(.caption).foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                HStack {
                    Slider(value: $config.repeatPenalty.toNonOptional(defaultValue: 1.1), in: 1.0...2.0, step: 0.05)
                        .frame(width: 150)
                    Text("\(config.repeatPenalty ?? 1.1, specifier: "%.2f")")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            
            Divider()
            
            // Apply Optimal Button
            HStack {
                Spacer()
                Menu {
                    ForEach(OllamaAdvancedConfig.ModelTier.allCases) { tier in
                        Button(tier.rawValue) {
                            config = OllamaAdvancedConfig.preset(for: tier)
                        }
                    }
                } label: {
                    Label("Apply Optimal", systemImage: "sparkles")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.accentColor.opacity(0.1))
                        .foregroundColor(theme.accentColor)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
    }
}
