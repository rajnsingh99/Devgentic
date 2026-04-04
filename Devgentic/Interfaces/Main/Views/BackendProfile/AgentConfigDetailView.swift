//
//  AgentConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//  Updated on 28/01/26 to support Agent Architecture selection.
//  Updated on 04/02/26 for Modern Dashboard UI.
//  Updated on 16/02/26 to add API Key visibility toggle and persistent model display.
//  Updated on 20/02/26 to add Detached Expandable Prompt Editor.
//  Updated on 27/02/26 to add explicit MLX Warning Banner.
//  Updated on 27/02/26 to refine Remote LLM UI and API Key gating.
//  Updated on 28/02/26 to add OpenAI dynamic model picker.
//  Updated on 28/02/26 to add editable Base URL endpoint field with default placeholders.
//  Updated on 28/02/26 to align inputs right matching Modern Settings UI.
//  Updated on 28/02/26 to fix MLX native tool toggle auto-enable bug.
//  Refactored on 27/03/26 to use ProfileEditBuffer (single source of truth for dirty tracking).
//

import SwiftUI
import UniformTypeIdentifiers

struct AgentConfigDetailView: View {
    @Bindable var editBuffer: ProfileEditBuffer
    var onDelete: ((UUID) -> Void)? = nil
    @Environment(BackendProfileService.self) var profileService
    @Environment(MainViewRouter.self) private var router
    @EnvironmentObject private var toastManager: ToastManager
    @Environment(\.appTheme) private var theme

    // Local state for editing advanced configurations
    @State private var localOllamaConfig: OllamaAdvancedConfig = .default()
    @State private var localGeminiConfig: GeminiAdvancedConfig = .default()
    @State private var localMlxConfig: MLXAdvancedConfig = .default()
    @State private var localAnthropicConfig: AnthropicAdvancedConfig = .default()
    @State private var localOpenAIConfig: OpenAIAdvancedConfig = .default()

    // Guard flag: prevents onChange(of: localOllamaConfig/localGeminiConfig/localMlxConfig) from writing
    // back to providerConfig during initial load.
    @State private var isLoadingAdvancedConfig = false

    // Tool Library (now navigated via router)

    // Prompt Library for the inline editor
    @StateObject private var promptLibraryVM = PromptLibraryViewModel()

    // Deletion State
    @State private var showingDeleteAlert = false

    // File Importer State
    @State private var showingKnowledgeImporter = false

    // Guide
    @State private var showingAgentGuide = false

    // Button Hover States
    @State private var isDeleteHovered = false
    @State private var isRevertHovered = false
    @State private var isSaveHovered = false

    // [PHASE 1 REFACTOR]: Enriched Default Persona
    private let defaultSystemPersona = """
    You are Devgentic, a specialized macOS System Agent and Senior DevOps Engineer.

    ## CORE BEHAVIORS
    1. **Prudence**: Always verify file existence before modification. Use `ls` or `stat` first.
    2. **Unix Philosophy**: Prefer chaining small, standard tools (grep, sed, awk) over complex, fragile scripts.
    3. **Transparency**: Explain your plan briefly before executing destructive actions.

    ## SAFETY PROTOCOLS
    1. **NON-INTERACTIVE ONLY**: You operate in a non-interactive shell. Do NOT use interactive commands like `nano`, `vim`, `top`, or `sudo` without `-n`.
    2. **DESTRUCTIVE ACTIONS**: Double-check absolute paths before executing `rm -rf` or file deletions.

    ## ERROR HANDLING
    - If a command fails, do NOT immediately retry the exact same command.
    - Analyze the error code/message.
    - Formulate a hypothesis (e.g., "Missing permissions", "Path incorrect").
    - Try a corrective action (e.g., "Check permissions", "Find correct path").
    """

    // MARK: - Convenience Accessors

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
                if case .agent(var config) = editBuffer.draft.details {
                    config.llmConfig = newConfig
                    editBuffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var capabilitiesBinding: Binding<AgentCapabilities> {
        Binding<AgentCapabilities>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.capabilities }
                return AgentCapabilities()
            },
            set: { newValue in
                if case .agent(var config) = editBuffer.draft.details {
                    config.capabilities = newValue
                    editBuffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var maxIterationsBinding: Binding<Int?> {
        Binding<Int?>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.maxIterations }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = editBuffer.draft.details {
                    config.maxIterations = newValue
                    editBuffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var executionTimeoutBinding: Binding<TimeInterval?> {
        Binding<TimeInterval?>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.executionTimeout }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = editBuffer.draft.details {
                    config.executionTimeout = newValue
                    editBuffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var retryPolicyBinding: Binding<RetryPolicy?> {
        Binding<RetryPolicy?>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.retryPolicy }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = editBuffer.draft.details {
                    config.retryPolicy = newValue
                    editBuffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var errorRecoveryBinding: Binding<ErrorRecovery?> {
        Binding<ErrorRecovery?>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.errorRecovery }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = editBuffer.draft.details {
                    config.errorRecovery = newValue
                    editBuffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding<String>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.description ?? "" }
                return ""
            },
            set: { newValue in
                let val = String(newValue.prefix(250))
                if case .agent(var config) = editBuffer.draft.details {
                    config.description = val.isEmpty ? nil : val
                    editBuffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var instructionsBinding: Binding<String> {
        Binding<String>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.instructions ?? "" }
                return ""
            },
            set: { newValue in
                if case .agent(var config) = editBuffer.draft.details {
                    config.instructions = newValue
                    editBuffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var knowledgeSourcesBinding: Binding<[KnowledgeSource]> {
        Binding<[KnowledgeSource]>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.knowledgeSources ?? [] }
                return []
            },
            set: { newValue in
                if case .agent(var config) = editBuffer.draft.details {
                    config.knowledgeSources = newValue.isEmpty ? nil : newValue
                    editBuffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var toolsBinding: Binding<[Tool]> {
        Binding<[Tool]>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.tools }
                return []
            },
            set: { newTools in
                if case .agent(var config) = editBuffer.draft.details {
                    config.tools = newTools
                    editBuffer.draft.details = .agent(config)
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
                    Image(systemName: "person.crop.square.fill.and.at.rectangle")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .foregroundColor(.accentColor)

                    VStack(alignment: .leading) {
                        TextField("Agent Name", text: profile.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .textFieldStyle(.plain)
                            .foregroundColor(theme.primaryText)

                        Text("Define your agent's personality, logic, and tools.")
                            .font(.subheadline)
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()

                    Button(action: { showingAgentGuide = true }) {
                        Image(systemName: "questionmark.circle")
                            .font(.title3)
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Agent configuration guide")
                }
                .padding(.bottom, 8)
                .sheet(isPresented: $showingAgentGuide) {
                    AgentConfigGuideView()
                }

                // 2. Agent Capabilities (composable toggles)
                SettingsCard(title: "Agent Capabilities", icon: "brain.head.profile", theme: theme) {
                    AgentCapabilitiesSection(capabilities: capabilitiesBinding)
                        .padding(16)
                }

                // 3. Execution Limits & Error Recovery
                SettingsCard(title: "Execution Limits", icon: "gauge.with.dots.needle.33percent", theme: theme) {
                    ExecutionLimitsSection(
                        maxIterations: maxIterationsBinding,
                        executionTimeout: executionTimeoutBinding
                    )
                    .padding(16)
                }

                SettingsCard(title: "Error Recovery", icon: "arrow.counterclockwise", theme: theme) {
                    ErrorRecoverySection(
                        retryPolicy: retryPolicyBinding,
                        errorRecovery: errorRecoveryBinding
                    )
                    .padding(16)
                }

                // 4. System Instructions & Identity
                SettingsCard(title: "System Instructions", icon: "text.quote", theme: theme) {
                  VStack(alignment: .leading, spacing: 16) {
                    // Instructions Editor
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Spacer()

                            Button {
                                AdvancedPromptWindowManager.shared.showEditor(
                                    text: instructionsBinding,
                                    agentName: editBuffer.draft.displayName,
                                    configuredTools: toolsBinding,
                                    theme: theme
                                )
                            } label: {
                                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .font(.caption)
                            .buttonStyle(.link)

                            Text("|").foregroundColor(theme.secondaryText).font(.caption)

                            Button("Use Default Persona") {
                                instructionsBinding.wrappedValue = defaultSystemPersona
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }

                        ZStack(alignment: .topLeading) {
                            TokenizingTextEditor(
                                text: instructionsBinding,
                                configuredTools: toolsBinding,
                                theme: theme,
                                promptLibraryVM: promptLibraryVM
                            )
                            .frame(minHeight: 120)
                            .padding(8)
                            .scrollContentBackground(.hidden)
                            .background(theme.textBackground)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.dividerColor, lineWidth: 1))

                            if instructionsBinding.wrappedValue.isEmpty {
                                Text("Define persona, reasoning strategy, and tool guidelines...")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(theme.secondaryText.opacity(0.5))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }

                        let instrCount = instructionsBinding.wrappedValue.count
                        let instrLimit = ProfileValidationLimits.maxInstructionsLength
                        Text("\(instrCount) characters · ~\(instrCount / 4) tokens")
                            .font(.caption2)
                            .foregroundColor(
                                instrCount > instrLimit ? .red :
                                instrCount > Int(Double(instrLimit) * 0.9) ? .orange :
                                theme.secondaryText
                            )
                    }

                    // Description
                     VStack(alignment: .leading, spacing: 8) {
                        Label("Internal Description", systemImage: "info.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(theme.secondaryText)

                        TextField("Brief description of this agent's purpose...", text: descriptionBinding)
                            .textFieldStyle(.roundedBorder)
                            .foregroundColor(theme.primaryText)
                    }
                  }
                  .padding(16)
                }

                // 5. Inference Engine (Provider)
                SettingsCard(title: "Inference Engine", icon: "cpu", theme: theme) {
                  VStack(alignment: .leading, spacing: 16) {
                    ProviderConfigSection(
                        providerConfig: providerConfig,
                        profileID: editBuffer.draft.id,
                        profileType: .agent,
                        onProviderChanged: { _, newProvider in
                            providerConfig.wrappedValue.cognitiveCapability =
                                ProfileCapabilityFilter.defaultCognitiveCapability(for: .agent, provider: newProvider)
                        }
                    )

                    Divider()
                        .padding(.vertical, 4)

                    // Capability Status Badge (Agent-specific)
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inference Capability")
                                .fontWeight(.medium)
                            Text("Detected architectural support for complex structured reasoning.")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }

                        Spacer(minLength: 16)

                        HStack(spacing: 6) {
                            let capability = providerConfig.wrappedValue.cognitiveCapability
                            Image(systemName: capabilityIcon(for: capability))
                            Text(capability.rawValue)
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(capabilityColor(for: providerConfig.wrappedValue.cognitiveCapability).opacity(0.1))
                        .foregroundColor(capabilityColor(for: providerConfig.wrappedValue.cognitiveCapability))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(capabilityColor(for: providerConfig.wrappedValue.cognitiveCapability).opacity(0.2), lineWidth: 1))
                    }
                  }
                  .padding(16)
                }

                // 6. Tools & Knowledge
                SettingsCard(title: "Capabilities", icon: "hammer.fill", theme: theme) {
                  VStack(alignment: .leading, spacing: 16) {

                    // Tools Header
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tools")
                                .fontWeight(.medium)
                            let count = toolsBinding.wrappedValue.filter { $0.isEnabled }.count
                            Text(count == 0 ? "No tools enabled" : "\(count) tool(s) active")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }

                        Spacer(minLength: 16)

                        Button("Manage Library...") {
                            router.navigate(to: .toolLibrary(profileID: editBuffer.draft.id))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    // Tool Chips
                    if !toolsBinding.wrappedValue.filter({ $0.isEnabled }).isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(toolsBinding.wrappedValue.filter { $0.isEnabled }) { tool in
                                    HStack(spacing: 4) {
                                        Image(systemName: "wrench.fill")
                                            .font(.caption2)
                                        Text(tool.name)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(Color.blue.opacity(0.1))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.2), lineWidth: 1))
                                }
                            }
                        }
                        .padding(.top, 4)
                    } else {
                        Text("Enable tools to give your agent agency.")
                            .font(.caption)
                            .italic()
                            .foregroundColor(theme.secondaryText)
                    }

                    Divider()

                    // File Handling Strategy
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File Handling")
                            .fontWeight(.medium)
                        Text("How attached files and knowledge sources are processed")
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                    }

                    FileContextStrategyPicker(
                        strategy: $editBuffer.draft.fileContextStrategy,
                        profileType: .agent
                    )

                    Divider()

                    // Knowledge Header
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

                    // Knowledge List
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

                // 7. Advanced Configuration
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
            Text("Are you sure you want to delete this agent? This action cannot be undone.")
        }
        .task {
            // Auto-populate default instructions if nil (first time setup)
            if case .agent(var config) = editBuffer.draft.details, config.instructions == nil {
                config.instructions = defaultSystemPersona
                editBuffer.draft.details = .agent(config)
                // Since this is a first-time auto-populate on an unsaved profile,
                // promote the change to the original so it doesn't show as dirty.
                editBuffer.load(editBuffer.draft)
            }

            isLoadingAdvancedConfig = true
            loadAdvancedConfigs()
            isLoadingAdvancedConfig = false
        }
        .onDisappear {
            // Cleanup: Close the floating window if the user leaves the panel entirely
            AdvancedPromptWindowManager.shared.closeWindow()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { oldValue, newValue in
            isLoadingAdvancedConfig = true
            loadAdvancedConfigs()
            isLoadingAdvancedConfig = false
        }
        .onChange(of: localOllamaConfig) { oldValue, newValue in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .ollama {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localOllamaConfig)
            }
        }
        .onChange(of: localGeminiConfig) { oldValue, newValue in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .google {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localGeminiConfig)
            }
        }
        .onChange(of: localMlxConfig) { oldValue, newValue in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .mlx {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localMlxConfig)
            }
        }
        .onChange(of: localAnthropicConfig) { oldValue, newValue in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .anthropic {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localAnthropicConfig)
            }
        }
        .onChange(of: localOpenAIConfig) { oldValue, newValue in
            guard !isLoadingAdvancedConfig else { return }
            if providerConfig.wrappedValue.apiProvider == .openAI {
                providerConfig.wrappedValue.advancedConfiguration = profileService.encodeConfig(from: localOpenAIConfig)
            }
        }
        .onChange(of: providerConfig.wrappedValue.modelName) { oldValue, newValue in
            if providerConfig.wrappedValue.apiProvider == .ollama {
                detectAndApplyOllamaPreset(for: newValue)
            }
        }
    }

    private func detectAndApplyOllamaPreset(for modelName: String) {
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
            localOllamaConfig = OllamaAdvancedConfig.preset(for: tier)
            // The onChange(of: localOllamaConfig) will update providerConfig.wrappedValue.advancedConfiguration
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
                .onHover { isRevertHovered = $0 }

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
        case .mlx:
            MLXSettingsView(config: $localMlxConfig)
        case .anthropic:
            AnthropicSettingsView(config: $localAnthropicConfig)
        case .openAI:
            OpenAISettingsView(config: $localOpenAIConfig)
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
        }
    }

    private func capabilityIcon(for capability: ModelCognitiveCapability) -> String {
        switch capability {
        case .none: return "text.bubble"
        case .singleAction: return "bolt.fill"
        case .parallelActions: return "bolt.shield.fill"
        }
    }

    private func capabilityColor(for capability: ModelCognitiveCapability) -> Color {
        switch capability {
        case .none: return theme.secondaryText
        case .singleAction: return .orange
        case .parallelActions: return .green
        }
    }
}
