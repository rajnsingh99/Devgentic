//
//  BackendProfileDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
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
    
    // Local state for the view
    @State private var isShowingAdvancedConfig = false
    @State private var advancedConfig: any Codable = OllamaAdvancedConfig.default()
    
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
                    // Return a default/dummy config.
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
                    // Do nothing for workflow.
                    break
                }
            }
        )
    }

    // MARK: - Body
    var body: some View {
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
            
            // TODO: Add a section for managing an Agent's tools when profileType is .agent
            
            Section(header: Text("Advanced Settings").font(.headline)) {
                Button("Configure Advanced Settings") {
                    self.advancedConfig = profileService.getAdvancedConfig(for: profile)
                    isShowingAdvancedConfig = true
                }
            }
            
            Spacer()
            
            actionButtons
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingAdvancedConfig, onDismiss: {
            // Encode the edited config back into the profile's provider config.
            providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: advancedConfig)
        }) {
            AdvanceConfigurationView(config: $advancedConfig)
        }
    }
    
    // MARK: - UI Components
    
    private var actionButtons: some View {
        HStack {
            Button("Delete", role: .destructive) {
                profileService.deleteProfile(withId: profile.id)
            }
            Spacer()
            Button("Save") {
                profileService.saveProfile(profile)
            }
            .buttonStyle(.borderedProminent)
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
        TextField("Base URL", text: providerConfig.baseURL.toNonOptional(defaultValue: "http://localhost:11434"))
    }
    
    private var remoteFields: some View {
        SecureField("API Key", text: providerConfig.apiKey.toNonOptional(defaultValue: ""))
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
