//
//  BotConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//

import SwiftUI

struct BotConfigDetailView: View {
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
                case .agent(let llmConfig, _, _, _, _):
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
                case .agent(_, let tools, let description, let instructions, let knowledgeSources): // Preserve existing tools
                    profile.details = .agent(
                        llmConfig: newConfig,
                        tools: tools,
                        description: description,
                        instructions: instructions,
                        knowledgeSources: knowledgeSources
                    )
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
                .padding()
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

            // UPDATED: Standard Bot view does NOT filter models. Any model is fine.
            OllamaModelPickerView(
                selectedModel: providerConfig.modelName,
                baseURL: providerConfig.wrappedValue.baseURL ?? "",
                filterForTools: false
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
