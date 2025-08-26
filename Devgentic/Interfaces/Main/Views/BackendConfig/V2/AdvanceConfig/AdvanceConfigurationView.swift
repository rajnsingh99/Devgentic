//
//  AdvanceConfigurationView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//

import SwiftUI

/// A dynamic view that presents the appropriate UI for editing the advanced configuration
/// of a given provider model (`any Codable`).
struct AdvanceConfigurationView: View {
    @Binding var config: any Codable
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                Text(headerTitle)
                    .font(.title2).fontWeight(.bold)
            }
            .padding()
            
            Divider()

            // Dynamically present the correct settings view based on the config type.
            if config is GeminiAdvancedConfig {
                GeminiSettingsView(config: geminiBinding)
            } else if config is OllamaAdvancedConfig {
                OllamaSettingsView(config: ollamaBinding)
            } else {
                Text("Unsupported configuration type.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 450, idealWidth: 500, minHeight: 550)
        .background(.regularMaterial)
    }
    
    // MARK: - Computed Properties & Bindings
    
    /// Provides a dynamic title for the header based on the config type.
    private var headerTitle: String {
        if config is GeminiAdvancedConfig {
            return "Advanced Gemini Settings"
        } else if config is OllamaAdvancedConfig {
            return "Advanced Ollama Settings"
        }
        return "Advanced Settings"
    }
    
    /// Creates a strongly-typed binding to a `GeminiAdvancedConfig` model.
    private var geminiBinding: Binding<GeminiAdvancedConfig> {
        Binding<GeminiAdvancedConfig>(
            get: { config as! GeminiAdvancedConfig },
            set: { config = $0 }
        )
    }
    
    /// Creates a strongly-typed binding to an `OllamaAdvancedConfig` model.
    private var ollamaBinding: Binding<OllamaAdvancedConfig> {
        Binding<OllamaAdvancedConfig>(
            get: { config as! OllamaAdvancedConfig },
            set: { config = $0 }
        )
    }
}

// MARK: - Gemini-Specific Settings View
private struct GeminiSettingsView: View {
    @Binding var config: GeminiAdvancedConfig
    
    var body: some View {
        Form {
            Section(header: Text("Generation Settings").font(.headline)) {
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
            }
            
            Section(header: Text("Safety Settings").font(.headline)) {
                ForEach($config.safetySettings.toNonOptional(defaultValue: [])) { $setting in
                    Picker(setting.category.rawValue.replacingOccurrences(of: "HARM_CATEGORY_", with: ""), selection: $setting.threshold) {
                        ForEach(HarmBlockThreshold.allCases, id: \.self) { threshold in
                            Text(threshold.rawValue.replacingOccurrences(of: "BLOCK_", with: "")).tag(threshold)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ollama-Specific Settings View
private struct OllamaSettingsView: View {
    @Binding var config: OllamaAdvancedConfig
    
    var body: some View {
        Form {
            Section(header: Text("Generation Settings").font(.headline)) {
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
        .formStyle(.grouped)
    }
}


// MARK: - Binding Helper Extension
extension Binding {
    func toNonOptional<T>(defaultValue: T) -> Binding<T> where Value == T? {
        Binding<T>(
            get: { self.wrappedValue ?? defaultValue },
            set: { self.wrappedValue = $0 }
        )
    }
}

// MARK: - Preview Provider
struct AdvanceConfigurationView_Previews: PreviewProvider {
    
    struct PreviewContainer: View {
        @State var geminiConfig: any Codable = GeminiAdvancedConfig.default()
        @State var ollamaConfig: any Codable = OllamaAdvancedConfig.default()
        
        var body: some View {
            VStack {
                Text("Gemini Preview").font(.title)
                AdvanceConfigurationView(config: $geminiConfig)
                Divider()
                Text("Ollama Preview").font(.title)
                AdvanceConfigurationView(config: $ollamaConfig)
            }
        }
    }
    
    static var previews: some View {
        PreviewContainer()
    }
}
