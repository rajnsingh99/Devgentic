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
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    // Shared advanced config manager (replaces 5 @State config vars + isLoading flag)
    @State private var configManager = ProviderAdvancedConfigManager()

    // Tool Library (now navigated via router)

    // Prompt Library for the inline editor
    @State private var promptLibraryVM = PromptLibraryViewModel()

    // Deletion State
    @State private var showingDeleteAlert = false

    // File Importer State
    @State private var showingKnowledgeImporter = false

    // Guide
    @State private var showingAgentGuide = false

    // Button Hover States
    @State private var isDeleteHovered = false

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
                case .code(let config): return config.llmConfig
                case .imageGen(let config): return config.llmConfig
                case .workflow: return ProviderConfig(apiProvider: .ollama, modelName: "")
                }
            },
            set: { newConfig in
                if case .agent(var config) = editBuffer.draft.details {
                    config.llmConfig = newConfig
                    editBuffer.draft.details = .agent(config)
                } else if case .code(var config) = editBuffer.draft.details {
                    config.llmConfig = newConfig
                    editBuffer.draft.details = .code(config)
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

    private var historyStrategyBinding: Binding<HistoryStrategy> {
        Binding<HistoryStrategy>(
            get: {
                if case .agent(let config) = editBuffer.draft.details {
                    return config.historyStrategy ?? .recentHistory
                }
                return .recentHistory
            },
            set: { newValue in
                if case .agent(var config) = editBuffer.draft.details {
                    config.historyStrategy = newValue
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

    private var skillConfigBinding: Binding<SkillFolderConfig?> {
        Binding<SkillFolderConfig?>(
            get: {
                if case .agent(let config) = editBuffer.draft.details { return config.skillConfig }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = editBuffer.draft.details {
                    config.skillConfig = newValue
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
                        Image(systemName: ProfileType.agent.iconNameFilled)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading) {
                            TextField("Agent Name", text: profile.displayName)
                                .font(theme.fontTitle2)
                                .fontWeight(.bold)
                                .textFieldStyle(.plain)
                                .foregroundColor(theme.primaryText)

                            Text("Define your agent's personality, logic, and tools.")
                                .font(theme.fontSubheadline)
                                .foregroundColor(theme.secondaryText)
                        }
                        Spacer()

                        Button(action: { showingAgentGuide = true }) {
                            Image(systemName: "questionmark.circle")
                                .font(theme.fontTitle3)
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Agent configuration guide")
                        .accessibilityLabel("Agent configuration guide")
                    }
                .padding(.bottom, 8)
                .sheet(isPresented: $showingAgentGuide) {
                    AgentConfigGuideView()
                }

                // 2. Inference Engine (Provider)
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

                        // Capability Status Badge (Agent-specific)
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Inference Capability")
                                    .fontWeight(.medium)
                                Text("Detected architectural support for complex structured reasoning.")
                                    .font(theme.fontCaption)
                                    .foregroundColor(theme.secondaryText)
                            }

                            Spacer(minLength: 16)

                            HStack(spacing: 6) {
                                let capability = providerConfig.wrappedValue.cognitiveCapability
                                Image(systemName: capabilityIcon(for: capability))
                                Text(capability.rawValue)
                                    .font(theme.fontCaption)
                                    .fontWeight(.semibold)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(capabilityColor(for: providerConfig.wrappedValue.cognitiveCapability).opacity(0.1))
                            .foregroundColor(capabilityColor(for: providerConfig.wrappedValue.cognitiveCapability))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(capabilityColor(for: providerConfig.wrappedValue.cognitiveCapability).opacity(0.2), lineWidth: 1))
                        }
                    }
                }

                // 3. Agent Capabilities (composable toggles + tools)
                SettingsCard(title: "Capabilities", icon: "brain.head.profile", theme: theme) {
                    VStack(alignment: .leading, spacing: 16) {
                        AgentCapabilitiesSection(capabilities: capabilitiesBinding)

                        Divider()

                        // Tools
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center) {
                                HStack(spacing: 10) {
                                    Image(systemName: "hammer.fill")
                                        .font(theme.fontBody)
                                        .foregroundColor(theme.secondaryText)
                                        .frame(width: 24, alignment: .center)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Tools")
                                            .font(theme.fontBody.weight(.medium))
                                            .foregroundColor(theme.primaryText)
                                        let count = toolsBinding.wrappedValue.filter { $0.isEnabled }.count
                                        Text(count == 0 ? "No tools enabled" : "\(count) tool(s) active")
                                            .font(theme.fontCaption)
                                            .foregroundColor(theme.secondaryText)
                                    }
                                }

                                Spacer(minLength: 16)

                                Button("Manage Library...") {
                                    router.navigate(to: .toolLibrary(profileID: editBuffer.draft.id))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if !toolsBinding.wrappedValue.filter({ $0.isEnabled }).isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(toolsBinding.wrappedValue.filter { $0.isEnabled }) { tool in
                                            HStack(spacing: 4) {
                                                Image(systemName: "wrench.fill")
                                                    .font(theme.fontCaption2)
                                                Text(tool.name)
                                                    .font(theme.fontCaption)
                                                    .fontWeight(.medium)
                                            }
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 10)
                                            .background(theme.accentColor.opacity(0.1))
                                            .foregroundColor(theme.accentColor)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.accentColor.opacity(0.2), lineWidth: 1))
                                        }
                                    }
                                }
                                .padding(.leading, 34)
                            } else {
                                Text("Enable tools to give your agent agency.")
                                    .font(theme.fontCaption)
                                    .italic()
                                    .foregroundColor(theme.secondaryText)
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }

                // 3. System Instructions & Identity
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
                                .font(theme.fontCaption)
                                .buttonStyle(.link)

                                Text("|").foregroundColor(theme.secondaryText).font(theme.fontCaption)

                                Button("Use Default Persona") {
                                    instructionsBinding.wrappedValue = defaultSystemPersona
                                }
                                .font(theme.fontCaption)
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
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.dividerColor, lineWidth: 1))

                            if instructionsBinding.wrappedValue.isEmpty {
                                Text("Define persona, reasoning strategy, and tool guidelines...")
                                    .font(theme.fontCode)
                                    .foregroundColor(theme.secondaryText.opacity(0.5))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }

                        let instrCount = instructionsBinding.wrappedValue.count
                        let instrLimit = ProfileValidationLimits.maxInstructionsLength
                        Text("\(instrCount) characters · ~\(instrCount / 4) tokens")
                            .font(theme.fontCaption2)
                            .foregroundColor(
                                instrCount > instrLimit ? .red :
                                instrCount > Int(Double(instrLimit) * 0.9) ? .orange :
                                theme.secondaryText
                            )
                        }

                    }
                }

                // 4. Skills
                AgentSkillsSection(
                    skillConfig: skillConfigBinding,
                    tools: toolsBinding,
                    currentModelTier: currentModelTier,
                    theme: theme
                )

                // 5. Knowledge
                SettingsCard(title: "Knowledge", icon: "book.closed.fill", theme: theme) {
                    VStack(alignment: .leading, spacing: 16) {

                        // Reference Documents
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Reference Documents")
                                        .font(theme.fontBody.weight(.semibold))
                                    Text("Add external documents the agent can use as context")
                                    .font(theme.fontCaption)
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
                                            .foregroundColor(source.exists ? theme.warningColor : theme.errorColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(source.fileName)
                                                .font(theme.fontCallout)
                                                .lineLimit(1)
                                            if !source.exists {
                                                Text("File not found")
                                                    .font(theme.fontCaption2)
                                                    .foregroundColor(theme.errorColor)
                                            } else {
                                                Text(source.location)
                                                    .font(theme.fontCaption2)
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
                                        .accessibilityLabel("Remove \(source.fileName)")
                                    }
                                    .padding(10)
                                    .background(theme.secondaryBackground.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                        source.exists ? theme.dividerColor : theme.errorColor.opacity(0.3), lineWidth: 1
                                    ))
                                }
                            }
                            .padding(.leading, 12)
                        } else {
                             Text("No reference documents added.")
                                .font(theme.fontCaption)
                                .foregroundColor(theme.secondaryText)
                                .italic()
                                .padding(.leading, 12)
                        }
                    }

                    Divider()

                        // File Handling Strategy
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("File Handling")
                                    .font(theme.fontBody.weight(.semibold))
                                Text("How attached files and knowledge sources are processed")
                                    .font(theme.fontCaption)
                                    .foregroundColor(theme.secondaryText)
                            }

                            FileContextStrategyPicker(
                                strategy: $editBuffer.draft.fileContextStrategy,
                                profileType: .agent
                            )
                            .padding(.leading, 12)
                        }
                    }
                }

                // 7. Execution
                SettingsCard(title: "Execution", icon: "bolt.fill", theme: theme) {
                    VStack(alignment: .leading, spacing: 16) {

                        // Limits
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Limits")
                                .font(theme.fontBody.weight(.semibold))
                                .foregroundColor(theme.primaryText)

                            ExecutionLimitsSection(
                                maxIterations: maxIterationsBinding,
                                executionTimeout: executionTimeoutBinding
                            )
                            .padding(.leading, 12)
                        }

                        Divider()

                        // Error Recovery
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Error Recovery")
                                .font(theme.fontBody.weight(.semibold))
                                .foregroundColor(theme.primaryText)

                            ErrorRecoverySection(
                                retryPolicy: retryPolicyBinding,
                                errorRecovery: errorRecoveryBinding
                            )
                            .padding(.leading, 12)
                        }

                        Divider()

                        // Conversation Memory
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Conversation Memory")
                                .font(theme.fontBody.weight(.semibold))
                                .foregroundColor(theme.primaryText)
                                .padding(.bottom, 2)

                            VStack(spacing: 8) {
                                ForEach(HistoryStrategy.allCases) { strategy in
                                    let isSelected = historyStrategyBinding.wrappedValue == strategy

                                    Button {
                                        historyStrategyBinding.wrappedValue = strategy
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: strategy.icon)
                                                .font(theme.fontBody)
                                                .foregroundColor(isSelected ? .accentColor : theme.secondaryText)
                                                .frame(width: 22, alignment: .center)
                                                .padding(.top, 2)

                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(strategy.displayName)
                                                    .font(theme.fontSubheadline.weight(.medium))
                                                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                                                Text(strategy.strategyDescription)
                                                    .font(theme.fontCaption)
                                                    .foregroundColor(theme.tertiaryText)
                                                    .lineSpacing(2)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }

                                            Spacer(minLength: 8)

                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(isSelected ? .accentColor : theme.surfaceOverlayStrong)
                                                .font(theme.fontTitle3)
                                                .padding(.top, 2)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(isSelected ? Color.accentColor.opacity(0.3) : theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.leading, 12)
                        }
                    }
                }

                // 9. Advanced Configuration
                SettingsCard(title: "Advanced Configuration", icon: "gearshape.2.fill", theme: theme) {
                    VStack(alignment: .leading, spacing: 16) {
                        advancedSettingsView
                    }
                }

                // Profile applicability note
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(theme.fontCaption2)
                    Text("This profile's settings apply when running standalone or as a node in a workflow.")
                        .font(theme.fontCaption2)
                }
                .foregroundColor(theme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
            }
            .padding(ViewLayout.containerPadding)
            .padding(.bottom, ViewLayout.containerPadding)
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

            configManager.load(from: providerConfig.wrappedValue, using: profileService)
        }
        .onDisappear {
            // Cleanup: Close the floating window if the user leaves the panel entirely
            AdvancedPromptWindowManager.shared.closeWindow()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _, _ in
            configManager.load(from: providerConfig.wrappedValue, using: profileService)
        }
        .advancedConfigSync(configManager: configManager, providerConfig: providerConfig, profileService: profileService)
        .onChange(of: providerConfig.wrappedValue.modelName) { _, newValue in
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
            configManager.localOllamaConfig = OllamaAdvancedConfig.preset(for: tier)
            // The onChange(of: configManager.localOllamaConfig) will update providerConfig.wrappedValue.advancedConfiguration
        }
    }

    /// The model tier for the currently selected provider/model — used for skill warnings.
    private var currentModelTier: ModelTier? {
        if case .agent(let config) = editBuffer.draft.details {
            return config.llmConfig.cognitiveProfile.metadata?.tier
        }
        return nil
    }

    // MARK: - Subviews & Helpers

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if editBuffer.isDirty {
                Button {
                    editBuffer.revert()
                    configManager.load(from: providerConfig.wrappedValue, using: profileService)
                } label: {
                    Text("Revert")
                        .font(theme.fontCaption.weight(.medium))
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
                        .font(theme.fontCaption.weight(.semibold))
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
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(isDeleteHovered ? .white : theme.errorColor.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isDeleteHovered ? theme.errorColor : theme.errorColor.opacity(0.1))
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
        ProviderAdvancedSettingsView(
            configManager: configManager,
            provider: providerConfig.wrappedValue.apiProvider,
            thinkingEnabled: Binding(
                get: { providerConfig.wrappedValue.thinkingEnabled },
                set: { providerConfig.wrappedValue.thinkingEnabled = $0 }
            )
        )
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

// MARK: - Skill Manifest Row

struct SkillManifestRow: View {
    let manifest: SkillManifest
    let theme: any Theme
    var onToggleEnabled: (() -> Void)? = nil
    @State private var isExpanded: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Enable/disable checkbox — Button prevents gesture conflict with row tap
            Button { onToggleEnabled?() } label: {
                Image(systemName: manifest.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(manifest.isEnabled ? .accentColor : theme.secondaryText)
                    .font(theme.fontBody)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.name)
                    .font(theme.fontBody.weight(.medium))
                    .foregroundColor(manifest.isEnabled ? theme.primaryText : theme.secondaryText)
                Text(manifest.description)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(isExpanded ? nil : 2)
                if let compat = manifest.compatibility {
                    Text(compat)
                        .font(theme.fontCaption2)
                        .foregroundColor(.orange)
                }
            }
            .opacity(manifest.isEnabled ? 1.0 : 0.6)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            Spacer()
            if manifest.resourceCount > 0 {
                Label("\(manifest.resourceCount)", systemImage: "doc.on.doc")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
            }
            Text("~\(manifest.discoveryTokenCost) tok")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Skill Action Button (with hover)

struct SkillActionButton: View {
    let label: String
    let icon: String
    var isDestructive: Bool = false
    let theme: any Theme
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var isHighlighted: Bool { isHovered || isFocused }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(theme.fontCaption2)
                Text(label)
                    .font(theme.fontCaption2.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(isHighlighted
                ? (isDestructive ? .white : .accentColor)
                : (isDestructive ? theme.errorColor : theme.secondaryText)
            )
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHighlighted
                        ? (isDestructive ? theme.errorColor : Color.accentColor.opacity(0.1))
                        : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHighlighted)
        .accessibilityLabel(label)
    }
}
