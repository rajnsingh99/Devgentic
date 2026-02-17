//
//  BotConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//  Updated on 04/02/26 for Modern Dashboard UI.
//  Updated on 16/02/26 to add API Key visibility toggle and persistent model display.
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
    
    // Local state for editing advanced configurations
    @State private var localOllamaConfig: OllamaAdvancedConfig = .default()
    @State private var localGeminiConfig: GeminiAdvancedConfig = .default()
    
    // UI State for API Key Visibility
    @State private var isApiKeyVisible: Bool = false
    
    // MARK: - Computed Bindings
    
    private var providerConfig: Binding<ProviderConfig> {
        Binding<ProviderConfig>(
            get: {
                switch profile.details {
                case .bot(let llmConfig): return llmConfig
                case .agent(let llmConfig, _, _, _, _, _): return llmConfig
                case .workflow: return ProviderConfig(apiProvider: .ollama, modelName: "")
                }
            },
            set: { newConfig in
                switch profile.details {
                case .bot:
                    profile.details = .bot(llmConfig: newConfig)
                case .agent(_, let architecture, let tools, let description, let instructions, let knowledgeSources):
                    profile.details = .agent(
                        llmConfig: newConfig,
                        architecture: architecture,
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
        ScrollView {
            VStack(spacing: 24) {
                
                // 1. Identity Header
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "cpu.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .foregroundColor(.blue) // Bot specific color
                        
                    VStack(alignment: .leading) {
                        TextField("Bot Name", text: $profile.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .textFieldStyle(.plain)
                        
                        Text("A straightforward LLM interface without agentic capabilities.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.1), lineWidth: 1))
                
                // 2. Inference Engine (Provider)
                ModernSection(title: "Inference Engine", icon: "server.rack") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("LLM Provider")
                                .fontWeight(.medium)
                            Text("The underlying model powering this bot.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        providerPicker
                            .labelsHidden()
                            .frame(width: 200)
                    }
                    
                    Divider()
                    
                    // Dynamic Fields
                    VStack(alignment: .leading, spacing: 12) {
                        switch providerConfig.wrappedValue.apiProvider {
                        case .ollama:
                            ollamaFields
                        case .mlx:
                            Text("Model Selection")
                                .fontWeight(.medium)
                                .font(.subheadline)
                            MLXModelPickerView(selectedModel: providerConfig.modelName)
                        default:
                            remoteFields
                        }
                    }
                }
                
                // 3. Advanced Configuration
                ModernSection(title: "Advanced Configuration", icon: "gearshape.2.fill") {
                   advancedSettingsView
                }
            }
            .padding()
            .padding(.bottom, 80) // Space for action bar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            actionButtons
                .padding()
                .background(.regularMaterial)
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.secondary.opacity(0.1)), alignment: .top)
        }
        .onAppear {
            initialProfileState = profile
            loadAdvancedConfigs()
        }
        .onChange(of: profile.id) {
            initialProfileState = profile
            loadAdvancedConfigs()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) {
            loadAdvancedConfigs()
        }
        .onChange(of: localOllamaConfig) {
            if providerConfig.wrappedValue.apiProvider == .ollama {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localOllamaConfig)
            }
        }
        .onChange(of: localGeminiConfig) {
            if providerConfig.wrappedValue.apiProvider == .google {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localGeminiConfig)
            }
        }
    }
    
    // MARK: - Subviews & Helpers
    
    private var actionButtons: some View {
        HStack {
            Button(role: .destructive) {
                profileService.deleteProfile(withId: profile.id)
            } label: {
                Label("Delete Bot", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            
            Spacer()
            
            if hasChanges {
                HStack(spacing: 12) {
                    Button("Revert") {
                        if let initialState = initialProfileState {
                            profile = initialState
                            loadAdvancedConfigs()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Button("Save Changes") {
                        profileService.saveProfile(profile)
                        initialProfileState = profile
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                Text("All changes saved")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            TextField("Base URL", text: providerConfig.baseURL.toNonOptional(defaultValue: "http://localhost:11434"))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            // Standard Bot view does NOT filter models.
            OllamaModelPickerView(
                selectedModel: providerConfig.modelName,
                baseURL: providerConfig.wrappedValue.baseURL ?? "",
                filterForTools: false
            )
        }
    }
    
    @ViewBuilder
    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            // API Key Input with Visibility Toggle
            ZStack(alignment: .trailing) {
                Group {
                    if isApiKeyVisible {
                        TextField("API Key", text: providerConfig.apiKey.toNonOptional(defaultValue: ""))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Key", text: providerConfig.apiKey.toNonOptional(defaultValue: ""))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                Button(action: { isApiKeyVisible.toggle() }) {
                    Image(systemName: isApiKeyVisible ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help(isApiKeyVisible ? "Hide API Key" : "Show API Key")
            }

            if providerConfig.wrappedValue.apiProvider == .google {
                VStack(alignment: .leading, spacing: 8) {
                    // The Picker: Useful when it loads, but might be hidden initially
                    GeminiModelPickerView(
                        selectedModel: providerConfig.modelName,
                        apiKey: providerConfig.wrappedValue.apiKey ?? ""
                    )
                    
                    // The Manual Field: Ensures the saved model is ALWAYS visible and editable
                    HStack {
                        Text("Model:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        TextField("e.g. gemini-1.5-pro", text: providerConfig.modelName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } else {
                TextField("Model Name", text: providerConfig.modelName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
    
    @ViewBuilder
    private var advancedSettingsView: some View {
        switch providerConfig.wrappedValue.apiProvider {
        case .ollama:
            OllamaSettingsView(config: $localOllamaConfig)
        case .google:
            GeminiSettingsView(config: $localGeminiConfig)
        case .openAI, .anthropic, .mlx:
            Text("No advanced settings available for \(providerConfig.wrappedValue.apiProvider.rawValue).")
                .foregroundColor(.secondary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
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
}

// MARK: - Reusable Card Component
// (Duplicated here to ensure file self-containment if AgentConfigDetailView is not visible)
fileprivate struct ModernSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 4)
            
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
        }
    }
}
