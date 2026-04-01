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
//  Refactored on 27/03/26 to use ProfileEditBuffer (single source of truth for dirty tracking).
//

import SwiftUI
import UniformTypeIdentifiers

private let defaultBotPersona = """
You are a helpful, knowledgeable assistant.

## CORE BEHAVIORS
1. **Clarity**: Provide clear, well-structured responses.
2. **Accuracy**: Prioritize correctness. If uncertain, say so.
3. **Conciseness**: Be thorough but avoid unnecessary verbosity.
"""

struct BotConfigDetailView: View {
    @Bindable var editBuffer: ProfileEditBuffer
    var onDelete: ((UUID) -> Void)? = nil
    @EnvironmentObject var profileService: BackendProfileService
    @EnvironmentObject private var toastManager: ToastManager
    @Environment(\.appTheme) private var theme

    // Local state for editing advanced configurations
    @State private var localOllamaConfig: OllamaAdvancedConfig = .default()
    @State private var localGeminiConfig: GeminiAdvancedConfig = .default()
    @State private var localAnthropicConfig: AnthropicAdvancedConfig = .default()
    @State private var localOpenAIConfig: OpenAIAdvancedConfig = .default()
    @State private var localMlxConfig: MLXAdvancedConfig = .default()

    // Guard flag: prevents onChange(of: localOllamaConfig/localGeminiConfig) from writing
    // back to providerConfig during initial load.
    @State private var isLoadingAdvancedConfig = false

    // Deletion State
    @State private var showingDeleteAlert = false

    // File Importer State
    @State private var showingKnowledgeImporter = false

    // Button Hover States
    @State private var isDeleteHovered = false

    // MARK: - Convenience Accessors

    /// Shorthand for the draft being edited.
    private var profile: Binding<BackendProfileModel> {
        $editBuffer.draft
    }

    // MARK: - Computed Bindings

    private var providerConfig: Binding<ProviderConfig> {
        Binding<ProviderConfig>(
            get: {
                switch editBuffer.draft.details {
                case .bot(let config): return config.llmConfig
                case .agent(let config): return config.llmConfig
                case .imageGen(let config): return config.llmConfig
                case .workflow: return ProviderConfig(apiProvider: .ollama, modelName: "")
                }
            },
            set: { newConfig in
                switch editBuffer.draft.details {
                case .bot(var config):
                    config.llmConfig = newConfig
                    editBuffer.draft.details = .bot(config)
                case .agent(var config):
                    config.llmConfig = newConfig
                    editBuffer.draft.details = .agent(config)
                case .imageGen(var config):
                    config.llmConfig = newConfig
                    editBuffer.draft.details = .imageGen(config)
                case .workflow:
                    break
                }
            }
        )
    }

    private var instructionsBinding: Binding<String> {
        Binding<String>(
            get: {
                if case .bot(let config) = editBuffer.draft.details { return config.instructions ?? "" }
                return ""
            },
            set: { newValue in
                if case .bot(var config) = editBuffer.draft.details {
                    config.instructions = newValue
                    editBuffer.draft.details = .bot(config)
                }
            }
        )
    }

    private var knowledgeSourcesBinding: Binding<[KnowledgeSource]> {
        Binding<[KnowledgeSource]>(
            get: {
                if case .bot(let config) = editBuffer.draft.details { return config.knowledgeSources ?? [] }
                return []
            },
            set: { newValue in
                if case .bot(var config) = editBuffer.draft.details {
                    config.knowledgeSources = newValue.isEmpty ? nil : newValue
                    editBuffer.draft.details = .bot(config)
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
                VStack(spacing: 32) {

                    // 1. Identity Header
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "cpu.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .foregroundColor(.blue) // Bot specific color

                    VStack(alignment: .leading) {
                        TextField("Bot Name", text: profile.displayName)
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
                SettingsCard(title: "Inference Engine", icon: "server.rack", theme: theme) {
                    VStack(alignment: .leading, spacing: 16) {
                        ProviderConfigSection(
                            providerConfig: providerConfig,
                            profileID: editBuffer.draft.id,
                            profileType: .bot,
                            onProviderChanged: { _, newProvider in
                                providerConfig.wrappedValue.cognitiveCapability =
                                    ProfileCapabilityFilter.defaultCognitiveCapability(for: .bot, provider: newProvider)
                            }
                        )
                    }
                    .padding(16)
                }

                // 3. Persona & Behavior
                SettingsCard(title: "Persona & Behavior", icon: "text.quote", theme: theme) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("System Instructions")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(theme.secondaryText)

                            Spacer()

                            Button {
                                SimplePromptWindowManager.shared.showEditor(
                                    text: instructionsBinding,
                                    botName: editBuffer.draft.displayName,
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

                        let charCount = instructionsBinding.wrappedValue.count
                        let charLimit = ProfileValidationLimits.maxInstructionsLength
                        Text("\(charCount) characters · ~\(charCount / 4) tokens")
                            .font(.caption2)
                            .foregroundColor(
                                charCount > charLimit ? .red :
                                charCount > Int(Double(charLimit) * 0.9) ? .orange :
                                theme.secondaryText
                            )
                    }
                    .padding(16)
                }

                // 4. File Handling
                SettingsCard(title: "File Handling", icon: "doc.on.doc.fill", theme: theme) {
                  VStack(alignment: .leading, spacing: 16) {
                    FileContextStrategyPicker(
                        strategy: $editBuffer.draft.fileContextStrategy,
                        profileType: .bot
                    )

                    Divider()

                    // Knowledge Base
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Knowledge Base")
                                .fontWeight(.medium)
                            Text("Pre-configured reference documents")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }

                        Spacer(minLength: 16)

                        Button {
                            showingKnowledgeImporter = true
                        } label: {
                            Label("Add File", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fileImporter(
                            isPresented: $showingKnowledgeImporter,
                            allowedContentTypes: [.item],
                            allowsMultipleSelection: true
                        ) { result in
                            if case let .success(urls) = result {
                                for url in urls {
                                    let source = KnowledgeSource(type: .file, location: url.path)
                                    if !knowledgeSourcesBinding.wrappedValue.contains(where: { $0.location == source.location }) {
                                        knowledgeSourcesBinding.wrappedValue.append(source)
                                    }
                                }
                            }
                        }
                    }

                    if !knowledgeSourcesBinding.wrappedValue.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(knowledgeSourcesBinding.wrappedValue) { source in
                                HStack {
                                    Image(systemName: "doc.text.fill")
                                        .foregroundColor(source.exists ? .orange : .red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.fileName)
                                            .font(.callout)
                                            .lineLimit(1)
                                        if !source.exists {
                                            Text("File not found")
                                                .font(.caption2)
                                                .foregroundColor(.red)
                                        } else {
                                            Text(source.location)
                                                .font(.caption2)
                                                .foregroundColor(theme.secondaryText)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    Spacer()
                                    Button {
                                        knowledgeSourcesBinding.wrappedValue.removeAll { $0.id == source.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(theme.secondaryText)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(10)
                                .background(theme.secondaryBackground.opacity(0.5))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                    source.exists ? theme.dividerColor : Color.red.opacity(0.3), lineWidth: 1
                                ))
                            }
                        }
                    } else {
                        Text("No reference documents added.")
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                            .italic()
                    }
                  }
                  .padding(16)
                }

                // 5. Advanced Configuration
                SettingsCard(title: "Advanced Configuration", icon: "gearshape.2.fill", theme: theme) {
                    VStack(alignment: .leading, spacing: 16) {
                        advancedSettingsView
                    }
                    .padding(16)
                }
            }
            .padding(24)
            .padding(.bottom, 24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        } // end outer VStack
        .alert("Delete '\(editBuffer.draft.displayName)'?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                do {
                    try profileService.deleteProfile(withId: editBuffer.draft.id)
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this bot? This action cannot be undone.")
        }
        .task {
            // Auto-populate default instructions if nil (first time setup)
            if case .bot(var config) = editBuffer.draft.details, config.instructions == nil {
                config.instructions = defaultBotPersona
                editBuffer.draft.details = .bot(config)
                editBuffer.load(editBuffer.draft)
            }
            isLoadingAdvancedConfig = true
            loadAdvancedConfigs()
            isLoadingAdvancedConfig = false
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _, _ in
            isLoadingAdvancedConfig = true
            loadAdvancedConfigs()
            isLoadingAdvancedConfig = false
        }
        .onChange(of: localOllamaConfig) { _, _ in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .ollama {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localOllamaConfig)
            }
        }
        .onChange(of: localGeminiConfig) { _, _ in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .google {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localGeminiConfig)
            }
        }
        .onChange(of: localAnthropicConfig) { _, _ in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .anthropic {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localAnthropicConfig)
            }
        }
        .onChange(of: localOpenAIConfig) { _, _ in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .openAI {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localOpenAIConfig)
            }
        }
        .onChange(of: localMlxConfig) { _, _ in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .mlx {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localMlxConfig)
            }
        }
        .onChange(of: providerConfig.wrappedValue.modelName) { _, _ in
            if providerConfig.wrappedValue.apiProvider == .ollama {
                detectAndApplyOllamaBotPreset(for: providerConfig.wrappedValue.modelName)
            }
        }
    }

    // MARK: - Subviews & Helpers

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if editBuffer.isDirty {
                Button {
                    editBuffer.revert()
                    isLoadingAdvancedConfig = true
                    loadAdvancedConfigs()
                    isLoadingAdvancedConfig = false
                } label: {
                    Text("Revert")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Revert unsaved changes")
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.surfaceOverlay))

                Button {
                    do {
                        try profileService.saveProfile(editBuffer.draft)
                        editBuffer.markSaved()
                        toastManager.show("Profile saved", style: .success)
                    } catch {
                        toastManager.show(error.localizedDescription, style: .error)
                    }
                } label: {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Save profile changes")
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
            .accessibilityLabel("Delete this profile")
            .onHover { isDeleteHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isDeleteHovered)
        }
    }


    @ViewBuilder
    private var advancedSettingsView: some View {
        switch providerConfig.wrappedValue.apiProvider {
        case .ollama:
            OllamaSettingsView(config: $localOllamaConfig)
        case .google:
            GeminiSettingsView(config: $localGeminiConfig)
        case .anthropic:
            AnthropicSettingsView(config: $localAnthropicConfig)
        case .openAI:
            OpenAISettingsView(config: $localOpenAIConfig)
        case .mlx:
            MLXSettingsView(config: $localMlxConfig)
        }
    }

    private func detectAndApplyOllamaBotPreset(for modelName: String) {
        let name = modelName.lowercased()
        var tier: OllamaAdvancedConfig.ModelTier? = nil

        if name.contains("1b") || name.contains("3b") || name.contains("tiny") || name.contains("phi-3") {
            tier = .tiny
        } else if name.contains("7b") || name.contains("8b") || name.contains("14b") || name.contains("mistral") || name.contains("llama-3-8b") || name.contains("small") {
            tier = .smallMedium
        } else if name.contains("70b") || name.contains("72b") || name.contains("large") {
            tier = .large
        }

        if let tier = tier {
            localOllamaConfig = OllamaAdvancedConfig.botPreset(for: tier)
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
        case .anthropic:
            self.localAnthropicConfig = profileService.decodeConfig(
                from: providerConfig.wrappedValue.advancedConfiguration,
                as: AnthropicAdvancedConfig.self
            ) ?? .default()
        case .openAI:
            self.localOpenAIConfig = profileService.decodeConfig(
                from: providerConfig.wrappedValue.advancedConfiguration,
                as: OpenAIAdvancedConfig.self
            ) ?? .default()
        case .mlx:
            self.localMlxConfig = profileService.decodeConfig(
                from: providerConfig.wrappedValue.advancedConfiguration,
                as: MLXAdvancedConfig.self
            ) ?? {
                if let metadata = providerConfig.wrappedValue.modelMetadata {
                    return .recommended(for: metadata)
                }
                return .default()
            }()
        }
    }
}
