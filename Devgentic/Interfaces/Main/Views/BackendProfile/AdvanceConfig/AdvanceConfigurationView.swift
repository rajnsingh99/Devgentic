//
//  AdvanceConfigurationView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//

import SwiftUI

struct GeminiSettingsView: View {
    @Binding var config: GeminiAdvancedConfig
    
    var body: some View {
        Section(header: Text("Advanced Gemini Settings").font(.headline)) {
            VStack(alignment: .leading) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text("\(config.temperature ?? 0.0, specifier: "%.2f")")
                }
                Slider(value: $config.temperature.toNonOptional(defaultValue: 0.9), in: 0.0...1.0, step: 0.05)
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("Top P")
                    Spacer()
                    Text("\(config.topP ?? 0.0, specifier: "%.2f")")
                }
                Slider(value: $config.topP.toNonOptional(defaultValue: 1.0), in: 0.0...1.0, step: 0.05)
            }
            Stepper("Top K: \(config.topK ?? 1)", value: $config.topK.toNonOptional(defaultValue: 1), in: 1...100)
            Stepper("Max Output Tokens: \(config.maxOutputTokens ?? 2048)", value: $config.maxOutputTokens.toNonOptional(defaultValue: 2048), in: 256...8192, step: 256)
            
            // Sub-header for safety settings within the same section
            Text("Safety Settings").font(.subheadline).padding(.top)
            ForEach($config.safetySettings.toNonOptional(defaultValue: [])) { $setting in
                Picker(setting.category.rawValue.replacingOccurrences(of: "HARM_CATEGORY_", with: ""), selection: $setting.threshold) {
                    ForEach(HarmBlockThreshold.allCases, id: \.self) { threshold in
                        Text(threshold.rawValue.replacingOccurrences(of: "BLOCK_", with: "")).tag(threshold)
                    }
                }
            }
        }
    }
}

struct OllamaSettingsView: View {
    @Binding var config: OllamaAdvancedConfig
    
    var body: some View {
        Section(header: Text("Advanced Ollama Settings").font(.headline)) {
            VStack(alignment: .leading) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text("\(config.temperature ?? 0.0, specifier: "%.2f")")
                }
                Slider(value: $config.temperature.toNonOptional(defaultValue: 0.8), in: 0.0...2.0, step: 0.1)
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("Top P")
                    Spacer()
                    Text("\(config.topP ?? 0.0, specifier: "%.2f")")
                }
                Slider(value: $config.topP.toNonOptional(defaultValue: 0.9), in: 0.0...1.0, step: 0.05)
            }
            Stepper("Top K: \(config.topK ?? 40)", value: $config.topK.toNonOptional(defaultValue: 40), in: 1...100)
            Stepper("Context Window (num_ctx): \(config.numCtx ?? 2048)", value: $config.numCtx.toNonOptional(defaultValue: 2048), in: 256...8192, step: 256)
            TextField("Seed (Optional)", value: $config.seed, format: .number)
        }
    }
}


