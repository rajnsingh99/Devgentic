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
                    profile.details = .bot(llmConfig: config, instructions: val.isEmpty ? nil : val)
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
                            .foregroundColor(theme.primaryText)
                        
                        Text("A straightforward LLM interface without agentic capabilities.")
                            .font(.subheadline)
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                }
                .padding()
                .background(theme.secondaryBackground)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.dividerColor, lineWidth: 1))
                
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
                                    supportsNativeTools: Binding(
                                        get: { providerConfig.wrappedValue.supportsNativeTools },
                                        set: { _ in } // Prevent MLX Model Picker from auto-enabling this setting
                                    )
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
            .padding(.bottom, 80) // Space for action bar
        }
        .background(theme.primaryBackground)
        .safeAreaInset(edge: .bottom) {
            actionButtons
                .padding()
                .background(theme.secondaryBackground)
                .overlay(Rectangle().frame(height: 1).foregroundColor(theme.dividerColor), alignment: .top)
        }
        .alert("Delete '\(profile.displayName)'?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                profileService.deleteProfile(withId: profile.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this bot? This action cannot be undone.")
        }
        .onAppear {
            initialProfileState = profile
            loadAdvancedConfigs()
        }
        .onChange(of: profile.id) { _ in
            initialProfileState = profile
            loadAdvancedConfigs()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _ in
            // Reset edit state when switching providers
            isEditingBaseURL = false
            loadAdvancedConfigs()
        }
        .onChange(of: localOllamaConfig) { _ in
            if providerConfig.wrappedValue.apiProvider == .ollama {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localOllamaConfig)
            }
        }
        .onChange(of: localGeminiConfig) { _ in
            if providerConfig.wrappedValue.apiProvider == .google {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localGeminiConfig)
            }
        }
    }
    
    // MARK: - Subviews & Helpers
    
    private var actionButtons: some View {
        HStack {
            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                Label("Delete Bot", systemImage: "trash")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isDeleteHovered ? Color.red.opacity(0.1) : Color.clear)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
            .scaleEffect(isDeleteHovered ? 1.02 : 1.0)
            .onHover { isDeleteHovered = $0 }
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDeleteHovered)
            
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isRevertHovered ? theme.surfaceOverlay : Color.clear)
                    .cornerRadius(8)
                    .onHover { isRevertHovered = $0 }
                    .scaleEffect(isRevertHovered ? 1.02 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isRevertHovered)
                    
                    Button {
                        profileService.saveProfile(profile)
                        initialProfileState = profile
                    } label: {
                        Text("Save Changes")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(theme.accentColor.opacity(isSaveHovered ? 0.9 : 1.0))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .shadow(color: theme.accentColor.opacity(isSaveHovered ? 0.3 : 0.0), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .onHover { isSaveHovered = $0 }
                    .scaleEffect(isSaveHovered ? 1.02 : 1.0)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isSaveHovered)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                Text("All changes saved")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }
        }
    }
    
    private var providerPicker: some View {
        Picker("", selection: Binding(
            get: { providerConfig.wrappedValue.apiProvider },
            set: { newValue in
                let oldValue = providerConfig.wrappedValue.apiProvider
                providerConfig.wrappedValue.apiProvider = newValue
                
                if newValue != oldValue {
                    if [.openAI, .google, .anthropic].contains(newValue) {
                        providerConfig.wrappedValue.supportsNativeTools = true
                    } else if newValue == .mlx {
                        // Default to false for MLX, user must opt-in manually to prevent unstable behavior
                        providerConfig.wrappedValue.supportsNativeTools = false
                    }
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
                    supportsNativeTools: providerConfig.supportsNativeTools,
                    baseURL: providerConfig.wrappedValue.baseURL ?? defaultBaseURL(for: .ollama),
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
