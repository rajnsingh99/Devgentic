//
//  ImageGenConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  Configuration detail view for Image Generator profiles.
//  Updated to adopt Modern Dashboard UI, Model Pickers, and dynamic capabilities.
//

import SwiftUI
import Flux2Core

struct ImageGenConfigDetailView: View {
    @Binding var profile: BackendProfileModel
    @EnvironmentObject var profileService: BackendProfileService
    @Environment(\.appTheme) private var theme

    // State to track unsaved changes
    @State private var initialProfileState: BackendProfileModel?
    private var hasChanges: Bool {
        profile != initialProfileState
    }

    // Guard flag: prevents onChange handlers from writing during initial load
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
                if case .imageGen(let llmConfig, _, _, _) = profile.details { return llmConfig }
                return ProviderConfig(apiProvider: .openAI, modelName: "dall-e-3")
            },
            set: { newConfig in
                if case .imageGen(_, let negativePrompt, let aspectRatio, let advancedSettings) = profile.details {
                    profile.details = .imageGen(
                        llmConfig: newConfig,
                        negativePrompt: negativePrompt,
                        defaultAspectRatio: aspectRatio,
                        advancedSettings: advancedSettings
                    )
                }
            }
        )
    }

    private var negativePromptBinding: Binding<String> {
        Binding<String>(
            get: {
                if case .imageGen(_, let negativePrompt, _, _) = profile.details { return negativePrompt ?? "" }
                return ""
            },
            set: { newValue in
                let val = String(newValue.prefix(2000))
                if case .imageGen(let config, _, let aspectRatio, let advancedSettings) = profile.details {
                    profile.details = .imageGen(
                        llmConfig: config,
                        negativePrompt: val.isEmpty ? nil : val,
                        defaultAspectRatio: aspectRatio,
                        advancedSettings: advancedSettings
                    )
                }
            }
        )
    }

    private var aspectRatioBinding: Binding<ImageAspectRatio> {
        Binding<ImageAspectRatio>(
            get: {
                if case .imageGen(_, _, let ratio, _) = profile.details { return ratio ?? .square }
                return .square
            },
            set: { newValue in
                if case .imageGen(let config, let negativePrompt, _, let advancedSettings) = profile.details {
                    profile.details = .imageGen(
                        llmConfig: config,
                        negativePrompt: negativePrompt,
                        defaultAspectRatio: newValue,
                        advancedSettings: advancedSettings
                    )
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

    // MARK: - Capability Analysis
    private var capability: ImageModalitySupport {
        ImageCapabilityAnalyzer.analyze(
            provider: providerConfig.wrappedValue.apiProvider,
            modelName: providerConfig.wrappedValue.modelName,
            modelMetadata: providerConfig.wrappedValue.modelMetadata
        )
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                
                // 1. Identity Header
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "paintbrush.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .foregroundColor(.orange)
                        
                    VStack(alignment: .leading) {
                        TextField("Profile Name", text: $profile.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .textFieldStyle(.plain)
                            .foregroundColor(theme.primaryText)
                        
                        Text("AI-powered image generation")
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
                            Text("Image Provider")
                                .fontWeight(.medium)
                            Text("The underlying engine generating the visuals.")
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
                            mlxFields
                        default:
                            remoteFields
                        }
                    }
                }
                
                // 3. Generation Defaults
                ModernSection(title: "Generation Defaults", icon: "slider.horizontal.3") {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Aspect Ratio")
                                .fontWeight(.medium)
                        }
                        
                        Spacer(minLength: 16)
                        
                        Picker("", selection: aspectRatioBinding) {
                            ForEach(ImageAspectRatio.allCases) { ratio in
                                Text(ratio.rawValue).tag(ratio)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 120)
                        .labelsHidden()
                    }
                    
                    // Aspect Ratio Preview
                    HStack {
                        Spacer()
                        let dims = aspectRatioBinding.wrappedValue.dimensions(baseSize: 80)
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(theme.secondaryText.opacity(0.5), lineWidth: 1)
                            .frame(width: CGFloat(dims.width), height: CGFloat(dims.height))
                            .overlay(
                                Text("\(aspectRatioBinding.wrappedValue.dimensions().width)x\(aspectRatioBinding.wrappedValue.dimensions().height)")
                                    .font(.system(size: 9))
                                    .foregroundColor(theme.secondaryText)
                            )
                        Spacer()
                    }
                    .padding(.top, 8)
                }

                // 4. Negative Prompt
                ModernSection(title: "Negative Prompt", icon: "xmark.circle") {
                    VStack(alignment: .leading, spacing: 8) {
                        if providerConfig.wrappedValue.apiProvider == .mlx {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text("Flux2 models don't have a native negative prompt parameter. This text is appended to your prompt as \"Avoid: …\" for soft guidance.")
                                    .font(.caption)
                                    .foregroundColor(theme.secondaryText)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(6)
                        } else {
                            Text("Describe what to avoid in generated images (e.g., blurry, bad anatomy).")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }

                        TextEditor(text: negativePromptBinding)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 80, maxHeight: 160)
                            .background(theme.secondaryBackground)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.dividerColor, lineWidth: 1)
                            )
                    }
                }

                // 5. Capability Badge
                ModernSection(title: "Model Capabilities", icon: "checkmark.shield") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 16) {
                            capabilityBadge(
                                label: "Text-to-Image",
                                supported: capability.supportsTextToImage
                            )
                            capabilityBadge(
                                label: "Image-to-Image",
                                supported: capability.supportsImageToImage
                            )
                        }

                        if let maxRes = capability.maxResolution {
                            Text("Max Resolution: \(maxRes.width)x\(maxRes.height)")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }
            }
            .padding()
            .padding(.bottom, 80) // Space for action bar
        }
        .background(theme.primaryBackground)
        .safeAreaInset(edge: .bottom) {
            actionBar
                .padding()
                .background(theme.secondaryBackground)
                .overlay(Rectangle().frame(height: 1).foregroundColor(theme.dividerColor), alignment: .top)
        }
        .onAppear {
            isLoadingAdvancedConfig = true
            isLoadingAdvancedConfig = false
            initialProfileState = profile
        }
        .onChange(of: profile.id) { _ in
            isLoadingAdvancedConfig = true
            isLoadingAdvancedConfig = false
            initialProfileState = profile
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _ in
            isEditingBaseURL = false
            // When switching to MLX, immediately correct any invalid model name
            if providerConfig.wrappedValue.apiProvider == .mlx {
                snapToValidFlux2Model()
            }
        }
    }

    // MARK: - Dynamic Inference Fields
    
    private var providerPicker: some View {
        Picker("", selection: providerConfig.apiProvider) {
            Text("OpenAI").tag(ApiProvider.openAI)
            Text("Google Gemini").tag(ApiProvider.google)
            Text("MLX (Apple Silicon)").tag(ApiProvider.mlx)
            Text("Ollama (Local)").tag(ApiProvider.ollama)
        }
    }
    
    private func defaultBaseURL(for provider: ApiProvider) -> String {
        switch provider {
        case .google: return "https://generativelanguage.googleapis.com/v1beta/"
        case .anthropic: return "https://api.anthropic.com/v1/"
        case .openAI: return "https://api.openai.com/v1/"
        case .ollama: return "http://localhost:11434"
        case .mlx: return "Local Engine"
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
    private var mlxFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection")
                        .fontWeight(.medium)
                    Text("Flux2 models run fully on-device via Apple Silicon.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
                Spacer(minLength: 16)
                Flux2ModelPickerView(selectedModel: providerConfig.modelName)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .onAppear { snapToValidFlux2Model() }
    }

    /// If the stored model name isn't a valid Flux2 inference model, reset to klein-4b.
    private func snapToValidFlux2Model() {
        let inferenceRawValues = Flux2Model.allCases
            .filter(\.isForInference)
            .map(\.rawValue)
        if !inferenceRawValues.contains(providerConfig.wrappedValue.modelName) {
            providerConfig.wrappedValue.modelName = Flux2Model.klein4B.rawValue
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
                
                // Directly embeds the Ollama Picker (Provides the Manager Store capability)
                OllamaModelPickerView(
                    selectedModel: providerConfig.modelName,
                    cognitiveCapability: .constant(.none),
                    modelDialect: .constant(.nativeJSON),
                    modelMetadata: Binding(
                        get: { providerConfig.wrappedValue.modelMetadata },
                        set: { providerConfig.wrappedValue.modelMetadata = $0 }
                    ),
                    baseURL: providerConfig.wrappedValue.baseURL ?? defaultBaseURL(for: .ollama),
                    filterForTools: false
                )
                .labelsHidden()
                .frame(maxWidth: 350, alignment: .trailing)
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
                        .frame(maxWidth: 350, alignment: .trailing)
                        
                    } else if providerConfig.wrappedValue.apiProvider == .openAI {
                        OpenAIModelPickerView(
                            selectedModel: providerConfig.modelName,
                            apiKey: currentApiKey
                        )
                        .labelsHidden()
                        .frame(maxWidth: 350, alignment: .trailing)
                    } else {
                        TextField("e.g. dall-e-3", text: providerConfig.modelName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 350)
                    }
                }
            }
        }
    }

    private func capabilityBadge(label: String, supported: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(supported ? .green : .red.opacity(0.6))
                .font(.system(size: 14))
            Text(label)
                .font(.caption)
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(supported ? Color.green.opacity(0.1) : Color.red.opacity(0.05))
        )
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            // Delete Button
            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                Label("Delete Profile", systemImage: "trash")
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
            .alert("Delete '\(profile.displayName)'?", isPresented: $showingDeleteAlert) {
                Button("Delete", role: .destructive) {
                    profileService.deleteProfile(withId: profile.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this profile? This action cannot be undone.")
            }

            Spacer()

            if hasChanges {
                HStack(spacing: 12) {
                    Button("Revert") {
                        if let initialState = initialProfileState {
                            profile = initialState
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
}

// MARK: - Flux2 Model Picker

/// A picker restricted to inference-capable Flux2 model variants.
/// Only shows `dev`, `klein-4b`, and `klein-9b` — base/training models are excluded.
private struct Flux2ModelPickerView: View {
    @Binding var selectedModel: String
    @Environment(\.appTheme) private var theme

    /// Inference-only Flux2 variants, ordered from lightest to heaviest.
    private let models: [Flux2Model] = Flux2Model.allCases.filter(\.isForInference)

    private var selectedFlux2Model: Flux2Model? {
        models.first { $0.rawValue == selectedModel }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker("Flux2 Model", selection: $selectedModel) {
                ForEach(models, id: \.rawValue) { model in
                    // macOS menu pickers only render simple Text — no HStack
                    Text("\(model.displayName)  (~\(model.estimatedVRAM) GB)")
                        .tag(model.rawValue)
                }
            }
            .pickerStyle(.menu)
            .onAppear {
                if !models.map(\.rawValue).contains(selectedModel) {
                    selectedModel = Flux2Model.klein4B.rawValue
                }
            }

            // VRAM / memory info for the currently selected model
            if let model = selectedFlux2Model {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10))
                    Text("~\(model.estimatedVRAM) GB unified memory required")
                        .font(.caption2)
                }
                .foregroundColor(model.estimatedVRAM >= 40 ? .orange : theme.secondaryText)
            }
        }
    }
}
