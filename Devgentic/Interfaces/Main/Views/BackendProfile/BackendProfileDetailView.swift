//
//  BackendProfileDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//  Updated on 27/08/25 to add a dynamic Ollama model picker.
//  Refactored on 27/08/25 to inline advanced settings and fix functionality.
//  Updated on 27/08/25 to add a dynamic Gemini model picker.
//  Fixed on 27/08/25 to properly manage advanced settings state.
//

import SwiftUI

/// A dynamic detail view capable of configuring the unified `BackendProfileModel`.
struct BackendProfileDetailView: View {
    @Binding var profile: BackendProfileModel
    @EnvironmentObject var profileService: BackendProfileService

    // MARK: - Body
    var body: some View {
        VStack {
            // Switch on the `details` enum to render the correct configuration UI.
            switch profile.details {
            case .bot:
                // The view for configuring Bot or Agent details.
                BotConfigDetailView(profile: $profile)
            case .agent:
                // Agent configuration can reuse the Bot view for LLM settings
                // and add its own section for tools.
                // For now, we'll just show the same view.
                BotConfigDetailView(profile: $profile)
            case .workflow:
                // Placeholder for the future Workflow configuration UI.
                placeholderView(for: .workflow)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// A helper function to create consistent placeholder views.
    @ViewBuilder
    private func placeholderView(for type: ProfileType) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer.fill")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("\(type.rawValue) configuration is not yet available.")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


// MARK: - Bot/Agent Configuration Subview
private struct BotConfigDetailView: View {
    @Binding var profile: BackendProfileModel
    @EnvironmentObject var profileService: BackendProfileService
    
    // State to track unsaved changes
    @State private var initialProfileState: BackendProfileModel?
    private var hasChanges: Bool {
        profile != initialProfileState
    }
    
    // Local state for editing advanced configurations. This prevents the UI from reverting.
    @State private var localOllamaConfig: OllamaAdvancedConfig = .default()
    @State private var localGeminiConfig: GeminiAdvancedConfig = .default()
    
    // MARK: - Computed Bindings
    
    /// Creates a binding to the `ProviderConfig` inside the `profile.details` enum.
    /// This is essential for allowing the form to modify the nested configuration.
    private var providerConfig: Binding<ProviderConfig> {
        Binding<ProviderConfig>(
            get: {
                switch profile.details {
                case .bot(let llmConfig):
                    return llmConfig
                case .agent(let llmConfig, _):
                    return llmConfig
                case .workflow:
                    // This case should not happen if the view is used correctly.
                    return ProviderConfig(apiProvider: .ollama, modelName: "")
                }
            },
            set: { newConfig in
                switch profile.details {
                case .bot:
                    profile.details = .bot(llmConfig: newConfig)
                case .agent(_, let tools): // Preserve existing tools
                    profile.details = .agent(llmConfig: newConfig, tools: tools)
                case .workflow:
                    break
                }
            }
        )
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(header: Text("General").font(.headline)) {
                    TextField("Display Name", text: $profile.displayName)
                }

                Section(header: Text("Provider Configuration").font(.headline)) {
                    providerPicker
                    
                    if providerConfig.wrappedValue.apiProvider == .ollama {
                        ollamaFields
                    } else {
                        remoteFields
                    }
                }
                
                // The advanced settings are now displayed inline.
                advancedSettingsView
                
                // TODO: Add a section for managing an Agent's tools when profileType is .agent
            }
            .formStyle(.grouped)
            
            Spacer()
            
            actionButtons
                .padding(.top)
        }
        .onAppear {
            // Store the initial state and load advanced settings when the view appears
            initialProfileState = profile
            loadAdvancedConfigs()
        }
        .onChange(of: profile.id) {
            // Update the state if the selected profile changes
            initialProfileState = profile
            loadAdvancedConfigs()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) {
             // When the provider is switched, reload the default config for the new provider
            loadAdvancedConfigs()
        }
        .onChange(of: localOllamaConfig) {
            // When local state changes, write it back to the main profile model
            if providerConfig.wrappedValue.apiProvider == .ollama {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localOllamaConfig)
            }
        }
        .onChange(of: localGeminiConfig) {
            // When local state changes, write it back to the main profile model
            if providerConfig.wrappedValue.apiProvider == .google {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localGeminiConfig)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Decodes the generic dictionary from the profile model into the specific local state variables.
    private func loadAdvancedConfigs() {
        switch providerConfig.wrappedValue.apiProvider {
        case .ollama:
            self.localOllamaConfig = profileService.decodeConfig(
                from: providerConfig.wrappedValue.advancedConfiguration,
                as: OllamaAdvancedConfig.self
            ) ?? .default()
        case .google:
            self.localGeminiConfig = profileService.decodeConfig(
                from: providerConfig.wrappedValue.advancedConfiguration,
                as: GeminiAdvancedConfig.self
            ) ?? .default()
        default:
            break
        }
    }
        
    // MARK: - UI Components
    
    private var actionButtons: some View {
        HStack {
            Button("Delete", role: .destructive) {
                profileService.deleteProfile(withId: profile.id)
            }
            
            Spacer()
            
            if hasChanges {
                Button("Revert") {
                    if let initialState = initialProfileState {
                        profile = initialState
                        // After reverting the profile, also revert the local advanced config state
                        loadAdvancedConfigs()
                    }
                }
                Button("Save") {
                    profileService.saveProfile(profile)
                    // Update the initial state to the new saved state
                    initialProfileState = profile
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
    
    private var providerPicker: some View {
        Picker("Provider", selection: providerConfig.apiProvider) {
            ForEach(ApiProvider.allCases) { provider in
                Text(provider.rawValue).tag(provider)
            }
        }
    }
    
    private var ollamaFields: some View {
        Group {
            TextField("Base URL", text: providerConfig.baseURL.toNonOptional(defaultValue: "http://localhost:11434"))
                .disableAutocorrection(true)

            OllamaModelPickerView(
                selectedModel: providerConfig.modelName,
                baseURL: providerConfig.wrappedValue.baseURL ?? ""
            )
        }
    }
    
    @ViewBuilder
    private var remoteFields: some View {
        SecureField("API Key", text: providerConfig.apiKey.toNonOptional(defaultValue: ""))

        switch providerConfig.wrappedValue.apiProvider {
        case .google:
            GeminiModelPickerView(
                selectedModel: providerConfig.modelName,
                apiKey: providerConfig.wrappedValue.apiKey ?? ""
            )
        default:
            TextField("Model Name", text: providerConfig.modelName)
        }
    }
    
    /// A dynamic view that renders the correct advanced settings based on the selected provider.
    @ViewBuilder
    private var advancedSettingsView: some View {
        switch providerConfig.wrappedValue.apiProvider {
        case .ollama:
            OllamaSettingsView(config: $localOllamaConfig)
            
        case .google:
            GeminiSettingsView(config: $localGeminiConfig)
            
        case .openAI, .anthropic:
            Section(header: Text("Advanced Settings").font(.headline)) {
                Text("Advanced settings for \(providerConfig.wrappedValue.apiProvider.rawValue) are not yet available.")
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Gemini Model Picker View
private struct GeminiModelPickerView: View {
    @Binding var selectedModel: String
    let apiKey: String
    
    @State private var models: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Verifying key...").foregroundColor(.secondary)
            } else if let errorMessage = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(errorMessage).foregroundColor(.secondary).font(.caption)
            } else if models.isEmpty {
                Text("Enter a valid API key to see models.").foregroundColor(.secondary).font(.caption)
            } else {
                Picker("Available Models", selection: $selectedModel) {
                    ForEach(models, id: \.self) { modelName in
                        Text(modelName).tag(modelName)
                    }
                }
            }
        }
        .onChange(of: apiKey) {
             // Debounce the API call slightly to avoid firing on every keystroke
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                await fetchModels()
            }
        }
    }
    
    private func fetchModels() async {
        guard !apiKey.isEmpty else {
            self.models = []
            self.errorMessage = nil
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let fetchedModels = try await GeminiService().verifyAndFetchModels(apiKey: apiKey)
            await MainActor.run {
                self.models = fetchedModels
                if !fetchedModels.contains(selectedModel), let firstModel = fetchedModels.first {
                    self.selectedModel = firstModel
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.models = []
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}


// MARK: - Ollama Model Picker View
private struct OllamaModelPickerView: View {
    @Binding var selectedModel: String
    let baseURL: String

    @State private var models: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        HStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading models...")
                    .foregroundColor(.secondary)
            } else if let errorMessage = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(errorMessage)
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else if models.isEmpty {
                 Text("No models found at this address.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                Picker("Available Models", selection: $selectedModel) {
                    ForEach(models, id: \.self) { modelName in
                        Text(modelName).tag(modelName)
                    }
                }
            }

            Spacer()

            Button(action: fetchModels) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh models")
            .disabled(isLoading)
        }
        .onAppear(perform: fetchModels)
        .onChange(of: baseURL) {
            fetchModels()
        }
    }

    private func fetchModels() {
        guard !baseURL.isEmpty, let _ = URL(string: baseURL) else {
            self.errorMessage = "Invalid URL format."
            self.models = []
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                // This assumes a helper struct `OllamaConnect` exists to perform the network call.
                // let fetchedModels = try await OllamaConnect.fetchLocalOllamaModels(baseURL: baseURL)
                
                // --- Placeholder for network call ---
                try? await Task.sleep(nanoseconds: 1_000_000_000) // Simulate network delay
                let fetchedModels = ["llama3:latest", "gemma:7b", "mistral:latest"]
                // --- End Placeholder ---

                await MainActor.run {
                    self.models = fetchedModels
                    if !fetchedModels.contains(selectedModel), let firstModel = fetchedModels.first {
                        self.selectedModel = firstModel
                    }
                }
            } catch {
                await MainActor.run {
                    self.models = []
                    self.errorMessage = "Connection failed. Check Base URL."
                }
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }
}

// MARK: - Provider-Specific Settings Views (Moved from AdvanceConfigurationView)

private struct GeminiSettingsView: View {
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

private struct OllamaSettingsView: View {
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


// MARK: - Preview Provider
struct BackendProfileDetailView_Previews: PreviewProvider {
    
    struct PreviewContainer: View {
        @State var botProfile = BackendProfileModel(
            displayName: "My Ollama Bot",
            details: .bot(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama3:latest", baseURL: "http://localhost:11434"))
        )
        
        var body: some View {
            BackendProfileDetailView(profile: $botProfile)
                .environmentObject(BackendProfileService())
                .frame(width: 600, height: 800)
        }
    }
    
    static var previews: some View {
        PreviewContainer()
    }
}

// MARK: - Helper Extensions

/// A helper extension to create a binding to a non-optional value from an optional one.
extension Binding {
    func toNonOptional<T>(defaultValue: T) -> Binding<T> where Value == T? {
        Binding<T>(
            get: { self.wrappedValue ?? defaultValue },
            set: { self.wrappedValue = $0 }
        )
    }
}
