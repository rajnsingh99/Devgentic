//
//  BotConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//  Updated on 04/02/26 for Modern Dashboard UI.
//  Updated on 16/02/26 to add API Key visibility toggle and persistent model display.
//  Updated on 27/02/26 to refine Remote LLM UI and API Key gating.
//  Updated on 28/02/26 to add OpenAI dynamic model picker.
//  Updated on 28/02/26 to add editable Base URL endpoint field with default placeholders.
//  Updated on 28/02/26 to align inputs right matching Modern Settings UI.
//  Updated on 28/02/26 to fix MLX native tool toggle auto-enable bug.
//  Updated on 28/02/26 to fix model picker alignment and remove irrelevant Tool Toggle.
//

import SwiftUI

struct BotConfigDetailView: View {
    @Binding var profile: BackendProfileModel
    @EnvironmentObject var profileService: BackendProfileService
    @Environment(\.appTheme) private var theme
    
    // State to track unsaved changes
    @State private var initialProfileState: BackendProfileModel?
    private var hasChanges: Bool {
        profile != initialProfileState
    }
    
    // Local state for editing advanced configurations
    @State private var localOllamaConfig: OllamaAdvancedConfig = .default()
    @State private var localGeminiConfig: GeminiAdvancedConfig = .default()

    // Guard flag: prevents onChange(of: localOllamaConfig/localGeminiConfig) from writing
    // back to providerConfig during initial load, which would create phantom "unsaved changes".
    @State private var isLoadingAdvancedConfig = false
    
    // UI State for API Key Visibility and Endpoint Editing
    @State private var isApiKeyVisible: Bool = false
    @State private var isEditingBaseURL: Bool = false
    
    // Deletion State
    @State private var showingDeleteAlert = false
    
    // Button Hover States
    @State private var isDeleteHovered = false
    @State private var isRevertHovered = false
    @State private var isSaveHovered = false

    // MARK: - Computed Bindings
    
    private var providerConfig: Binding<ProviderConfig> {
        Binding<ProviderConfig>(
            get: {
                switch profile.details {
                case .bot(let llmConfig, _): return llmConfig
                case .agent(let llmConfig, _, _, _, _, _): return llmConfig
                case .imageGen(let llmConfig, _, _, _): return llmConfig
                case .workflow: return ProviderConfig(apiProvider: .ollama, modelName: "")
                }
            },
            set: { newConfig in
                switch profile.details {
                case .bot(_, let instructions):
                    profile.details = .bot(llmConfig: newConfig, instructions: instructions)
                case .agent(_, let architecture, let tools, let description, let instructions, let knowledgeSources):
                    profile.details = .agent(
                        llmConfig: newConfig,
                        architecture: architecture,
                        tools: tools,
                        description: description,
                        instructions: instructions,
                        knowledgeSources: knowledgeSources
                    )
                case .imageGen(_, let negativePrompt, let aspectRatio, let advancedSettings):
                    profile.details = .imageGen(llmConfig: newConfig, negativePrompt: negativePrompt, defaultAspectRatio: aspectRatio, advancedSettings: advancedSettings)
                case .workflow:
                    break
                }
            }
        )
    }
    
    private var baseURLBinding: Binding<String> {
        Binding<String>(
            get: { providerConfig.wrappedValue.baseURL ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                providerConfig.wrappedValue.baseURL = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private var instructionsBinding: Binding<String> {
        Binding<String>(
            get: {
                if case .bot(_, let instructions) = profile.details { return instructions ?? "" }
                return ""
            },
            set: { newValue in
                let val = String(newValue.prefix(5000))
                if case .bot(let config, _) = profile.details {
                    profile.details = .bot(llmConfig: config, instructions: val)
                }
            }
        )
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar {
                actionButtons
            }

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
                            .foregroundColor(theme.primaryText)
                        
                        Text("A straightforward LLM interface without agentic capabilities.")
                            .font(.subheadline)
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                }
                .padding(.bottom, 8)

                // 2. Inference Engine (Provider)
                ModernSection(title: "Inference Engine", icon: "server.rack") {
                    
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LLM Provider")
                                .fontWeight(.medium)
                            Text("The underlying model powering this bot.")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }
                        
                        Spacer(minLength: 16)
                        
                        providerPicker
                            .labelsHidden()
                            .fixedSize()
                    }
                    
                    Divider()
                    
                    // Dynamic Fields
                    VStack(alignment: .leading, spacing: 12) {
                        switch providerConfig.wrappedValue.apiProvider {
                        case .ollama:
                            ollamaFields
                        case .mlx:
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Model Selection")
                                        .fontWeight(.medium)
                                }
                                Spacer(minLength: 16)
                                MLXModelPickerView(
                                    selectedModel: providerConfig.modelName,
                                    cognitiveCapability: .constant(.none),
                                    modelDialect: .constant(.nativeJSON),
                                    modelMetadata: Binding(
                                        get: { providerConfig.wrappedValue.modelMetadata },
                                        set: { providerConfig.wrappedValue.modelMetadata = $0 }
                                    ),
                                    chatTemplateSource: Binding(
                                        get: { providerConfig.wrappedValue.chatTemplateSource },
                                        set: { providerConfig.wrappedValue.chatTemplateSource = $0 }
                                    ),
                                    stopSequences: Binding(
                                        get: { providerConfig.wrappedValue.stopSequences },
                                        set: { providerConfig.wrappedValue.stopSequences = $0 }
                                    ),
                                    profileID: profile.id
                                )
                                .labelsHidden()
                                .fixedSize()
                            }
                        default:
                            remoteFields
                        }
                    }
                }
                
                // 3. Persona & Behavior
                ModernSection(title: "Persona & Behavior", icon: "text.quote") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("System Instructions", systemImage: "text.quote")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(theme.secondaryText)

                            Spacer()

                            Button {
                                SimplePromptWindowManager.shared.showEditor(
                                    text: instructionsBinding,
                                    botName: profile.displayName,
                                    theme: theme
                                )
                            } label: {
                                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: instructionsBinding)
                                .font(.system(.body, design: .monospaced))
                                .disableAutocorrection(true)
                                .frame(minHeight: 120)
                                .padding(8)
                                .scrollContentBackground(.hidden)
                                .background(theme.textBackground)
                                .foregroundColor(theme.primaryText)
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.dividerColor, lineWidth: 1))
                                
                            if instructionsBinding.wrappedValue.isEmpty {
                                Text("Enter system instructions for your bot here...")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(theme.secondaryText.opacity(0.5))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }

                        Text("\(instructionsBinding.wrappedValue.count) characters · ~\(instructionsBinding.wrappedValue.count / 4) tokens")
                            .font(.caption2)
                            .foregroundColor(theme.secondaryText)
                    }
                }

                // 4. Advanced Configuration
                ModernSection(title: "Advanced Configuration", icon: "gearshape.2.fill") {
                   advancedSettingsView
                }
            }
            .padding()
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        } // end outer VStack
        .alert("Delete '\(profile.displayName)'?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                profileService.deleteProfile(withId: profile.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this bot? This action cannot be undone.")
        }
        .onAppear {
            // Load advanced configs FIRST (with guard flag on) so the onChange handlers
            // don't write back to providerConfig, then snapshot the initial state AFTER.
            isLoadingAdvancedConfig = true
            loadAdvancedConfigs()
            isLoadingAdvancedConfig = false

            initialProfileState = profile
        }
        .onChange(of: profile.id) { _ in
            isLoadingAdvancedConfig = true
            loadAdvancedConfigs()
            isLoadingAdvancedConfig = false

            initialProfileState = profile
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _ in
            // Reset edit state when switching providers
            isEditingBaseURL = false

            isLoadingAdvancedConfig = true
            loadAdvancedConfigs()
            isLoadingAdvancedConfig = false
        }
        .onChange(of: localOllamaConfig) { _ in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .ollama {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localOllamaConfig)
            }
        }
        .onChange(of: localGeminiConfig) { _ in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .google {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localGeminiConfig)
            }
        }
    }
    
    // MARK: - Subviews & Helpers
    
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if hasChanges {
                Button {
                    if let initialState = initialProfileState {
                        profile = initialState
                        loadAdvancedConfigs()
                    }
                } label: {
                    Text("Revert")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.surfaceOverlay))

                Button {
                    profileService.saveProfile(profile)
                    initialProfileState = profile
                } label: {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.accentColor))
            }

            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isDeleteHovered ? .white : .red.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isDeleteHovered ? Color.red : Color.red.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
            .onHover { isDeleteHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isDeleteHovered)
        }
    }
    
    private var providerPicker: some View {
        Picker("", selection: Binding(
            get: { providerConfig.wrappedValue.apiProvider },
            set: { newValue in
                let oldValue = providerConfig.wrappedValue.apiProvider
                providerConfig.wrappedValue.apiProvider = newValue
                
                if newValue != oldValue {
                    providerConfig.wrappedValue.cognitiveCapability = .none
                }
            }
        )) {
            ForEach(ApiProvider.allCases) { provider in
                Text(provider.rawValue).tag(provider)
            }
        }
    }
    
    private func defaultBaseURL(for provider: ApiProvider) -> String {
        switch provider {
        case .google: return "https://generativelanguage.googleapis.com/v1beta/"
        case .anthropic: return "https://api.anthropic.com/v1/"
        case .openAI: return "https://api.openai.com/v1/"
        case .ollama: return "http://localhost:11434"
        case .mlx: return "Local Engine"
        default: return ""
        }
    }
    
    @ViewBuilder
    private func endpointField(for provider: ApiProvider) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Endpoint")
                    .fontWeight(.medium)
                Text("Optional override for custom gateways.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
            
            Spacer(minLength: 16)
            
            HStack {
                if isEditingBaseURL || (providerConfig.wrappedValue.baseURL != nil && !providerConfig.wrappedValue.baseURL!.isEmpty) {
                    TextField(defaultBaseURL(for: provider), text: baseURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    
                    Button(action: {
                        // Clear the custom URL and exit edit mode
                        providerConfig.wrappedValue.baseURL = nil
                        isEditingBaseURL = false
                    }) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundColor(theme.secondaryText)
                            .help("Reset to Default")
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                } else {
                    Text(defaultBaseURL(for: provider))
                        .foregroundColor(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(theme.secondaryBackground.opacity(0.5))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.dividerColor, lineWidth: 1))
                    
                    Button("Edit") {
                        isEditingBaseURL = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: 350)
        }
    }
    
    @ViewBuilder
    private var ollamaFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            endpointField(for: providerConfig.wrappedValue.apiProvider)
            
            Divider()

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection")
                        .fontWeight(.medium)
                }
                Spacer(minLength: 16)
                // Standard Bot view does NOT filter models.
                OllamaModelPickerView(
                    selectedModel: providerConfig.modelName,
                    cognitiveCapability: .constant(.none),
                    modelDialect: .constant(.nativeJSON),
                    modelMetadata: Binding(
                        get: { providerConfig.wrappedValue.modelMetadata },
                        set: { providerConfig.wrappedValue.modelMetadata = $0 }
                    ),
                    baseURL: providerConfig.wrappedValue.baseURL ?? defaultBaseURL(for: .ollama),
                    profileID: profile.id,
                    filterForTools: false
                )
                .labelsHidden()
                .fixedSize()
            }
        }
    }
    
    @ViewBuilder
    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            
            // API Key Input
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").fontWeight(.medium)
                }
                
                Spacer(minLength: 16)
                
                ZStack(alignment: .trailing) {
                    Group {
                        if isApiKeyVisible {
                            TextField("Enter API Key", text: providerConfig.apiKey.toNonOptional(defaultValue: ""))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Enter API Key", text: providerConfig.apiKey.toNonOptional(defaultValue: ""))
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
                .frame(maxWidth: 350)
            }
            
            Divider()
            
            // Endpoint URL Selection / Override
            endpointField(for: providerConfig.wrappedValue.apiProvider)
            
            Divider()

            // Model Selection
            let currentApiKey = providerConfig.wrappedValue.apiKey ?? ""
            
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection").fontWeight(.medium)
                }
                
                Spacer(minLength: 16)
                
                if currentApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a valid API Key to select a model.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                } else {
                    if providerConfig.wrappedValue.apiProvider == .google {
                        GeminiModelPickerView(
                            selectedModel: providerConfig.modelName,
                            apiKey: currentApiKey
                        )
                        .labelsHidden()
                        .fixedSize()
                        
                    } else if providerConfig.wrappedValue.apiProvider == .anthropic {
                        AnthropicModelPickerView(
                            selectedModel: providerConfig.modelName,
                            apiKey: currentApiKey
                        )
                        .labelsHidden()
                        .fixedSize()
                        
                    } else if providerConfig.wrappedValue.apiProvider == .openAI {
                        OpenAIModelPickerView(
                            selectedModel: providerConfig.modelName,
                            apiKey: currentApiKey
                        )
                        .labelsHidden()
                        .fixedSize()
                        
                    } else {
                        // Fallback for other remote providers lacking a dynamic picker yet
                        TextField("e.g. gpt-4o", text: providerConfig.modelName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 350)
                    }
                }
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
                .foregroundColor(theme.secondaryText)
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
