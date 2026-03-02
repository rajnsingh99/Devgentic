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
//

import SwiftUI

struct AgentConfigDetailView: View {
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
    
    // UI State for API Key Visibility and Endpoint Editing
    @State private var isApiKeyVisible: Bool = false
    @State private var isEditingBaseURL: Bool = false
    
    // Tool Library Sheet
    @State private var showingToolLibrary = false
    
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
                if case .agent(_, let arch, let tools, let desc, let instr, let sources) = profile.details {
                    profile.details = .agent(
                        llmConfig: newConfig,
                        architecture: arch,
                        tools: tools,
                        description: desc,
                        instructions: instr,
                        knowledgeSources: sources
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
    
    private var architectureBinding: Binding<AgentArchitecture> {
        Binding<AgentArchitecture>(
            get: {
                if case .agent(_, let architecture, _, _, _, _) = profile.details { return architecture }
                return .reAct
            },
            set: { newValue in
                if case .agent(let config, _, let tools, let desc, let instr, let sources) = profile.details {
                    profile.details = .agent(
                        llmConfig: config,
                        architecture: newValue,
                        tools: tools,
                        description: desc,
                        instructions: instr,
                        knowledgeSources: sources
                    )
                }
            }
        )
    }
    
    private var descriptionBinding: Binding<String> {
        Binding<String>(
            get: {
                if case .agent(_, _, _, let description, _, _) = profile.details { return description ?? "" }
                return ""
            },
            set: { newValue in
                let val = String(newValue.prefix(250))
                if case .agent(let c, let a, let t, _, let i, let k) = profile.details {
                    profile.details = .agent(
                        llmConfig: c, architecture: a, tools: t,
                        description: val.isEmpty ? nil : val, instructions: i, knowledgeSources: k
                    )
                }
            }
        )
    }

    private var instructionsBinding: Binding<String> {
        Binding<String>(
            get: {
                if case .agent(_, _, _, _, let instructions, _) = profile.details { return instructions ?? "" }
                return ""
            },
            set: { newValue in
                let val = String(newValue.prefix(5000))
                if case .agent(let c, let a, let t, let d, _, let k) = profile.details {
                    profile.details = .agent(
                        llmConfig: c, architecture: a, tools: t,
                        description: d, instructions: val.isEmpty ? nil : val, knowledgeSources: k
                    )
                }
            }
        )
    }

    private var knowledgeSourcesBinding: Binding<[KnowledgeSource]> {
        Binding<[KnowledgeSource]>(
            get: {
                if case .agent(_, _, _, _, _, let sources) = profile.details { return sources ?? [] }
                return []
            },
            set: { newValue in
                 if case .agent(let c, let a, let t, let d, let i, _) = profile.details {
                    profile.details = .agent(
                        llmConfig: c, architecture: a, tools: t,
                        description: d, instructions: i, knowledgeSources: newValue.isEmpty ? nil : newValue
                    )
                }
            }
        )
    }
    
    private var toolsBinding: Binding<[Tool]> {
        Binding<[Tool]>(
            get: {
                if case .agent(_, _, let tools, _, _, _) = profile.details { return tools }
                return []
            },
            set: { newTools in
                if case .agent(let c, let a, _, let d, let i, let k) = profile.details {
                    profile.details = .agent(
                        llmConfig: c, architecture: a, tools: newTools,
                        description: d, instructions: i, knowledgeSources: k
                    )
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
                    Image(systemName: "person.crop.square.fill.and.at.rectangle")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .foregroundColor(.accentColor)
                        
                    VStack(alignment: .leading) {
                        TextField("Agent Name", text: $profile.displayName)
                            .font(.title2)
                            .fontWeight(.bold)
                            .textFieldStyle(.plain)
                        
                        Text("Define your agent's personality, logic, and tools.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.1), lineWidth: 1))
                
                // 2. Cognitive Architecture (The Brain)
                ModernSection(title: "Cognitive Architecture", icon: "brain.head.profile") {
                    
                    // Strategy Picker
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reasoning Strategy")
                                .fontWeight(.medium)
                            Text(architectureBinding.wrappedValue.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer(minLength: 16)
                        
                        Picker("", selection: architectureBinding) {
                            ForEach(AgentArchitecture.allCases) { arch in
                                Text(arch.rawValue).tag(arch)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    
                    Divider()
                    
                    // Instructions Editor
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("System Instructions", systemImage: "text.quote")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button {
                                AdvancedPromptWindowManager.shared.showEditor(
                                    text: instructionsBinding,
                                    agentName: profile.displayName,
                                    configuredTools: toolsBinding
                                )
                            } label: {
                                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                            
                            Text("|").foregroundColor(.secondary.opacity(0.3)).font(.caption)
                            
                            Button("Use Default Persona") {
                                instructionsBinding.wrappedValue = defaultSystemPersona
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }
                        
                        TokenizingTextEditor(
                            text: instructionsBinding,
                            configuredTools: toolsBinding
                        )
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    }
                    
                    // Description
                     VStack(alignment: .leading, spacing: 8) {
                        Label("Internal Description", systemImage: "info.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        TextField("Brief description of this agent's purpose...", text: descriptionBinding)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                // 3. Inference Engine (Provider)
                ModernSection(title: "Inference Engine", icon: "cpu") {
                    
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LLM Provider")
                                .fontWeight(.medium)
                            Text("The underlying model powering this agent.")
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                                .frame(maxWidth: 350, alignment: .trailing)
                            }
                        default:
                            remoteFields
                        }
                        
                        // ONLY show Native Tools override toggle for Local providers
                        let isLocalProvider = providerConfig.wrappedValue.apiProvider == .mlx || providerConfig.wrappedValue.apiProvider == .ollama
                        
                        if isLocalProvider {
                            Divider()
                                .padding(.vertical, 4)
                            
                            // Manual Override for Native Tools Flag
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Native Tool Calling API")
                                        .fontWeight(.medium)
                                    
                                    if providerConfig.wrappedValue.apiProvider == .mlx {
                                        Text("When enabled, tools are sent via the native API payload. Defaults to OFF for MLX models to prioritize stability.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Text("When enabled, tools are sent via the native API payload. When disabled, falls back to JSON prompt injection. (Auto-detected on model change)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                
                                Spacer(minLength: 16)
                                
                                Toggle("", isOn: Binding(
                                    get: { providerConfig.wrappedValue.supportsNativeTools },
                                    set: { newValue in
                                        withAnimation(.snappy) {
                                            providerConfig.wrappedValue.supportsNativeTools = newValue
                                        }
                                    }
                                ))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            }
                            
                            // WARNING BANNER (Only shows when MLX and Native Tools are both selected)
                            if providerConfig.wrappedValue.apiProvider == .mlx && providerConfig.wrappedValue.supportsNativeTools {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.yellow)
                                        .font(.title2)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Experimental Feature")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Text("Many community MLX models have broken chat templates that cause the Native Parser to crash or ignore tools. If the agent fails or hallucinates, disable this to rely on the robust Legacy JSON mode.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(12)
                                .background(Color.yellow.opacity(0.1))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.2), lineWidth: 1))
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
                
                // 4. Capabilities (Tools & Knowledge)
                ModernSection(title: "Capabilities", icon: "hammer.fill") {
                    
                    // Tools Header
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tools")
                                .fontWeight(.medium)
                            let count = toolsBinding.wrappedValue.filter { $0.isEnabled }.count
                            Text(count == 0 ? "No tools enabled" : "\(count) tool(s) active")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer(minLength: 16)
                        
                        Button("Manage Library...") {
                            showingToolLibrary = true
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
                            .foregroundColor(.secondary)
                    }
                    
                    Divider()
                    
                    // Knowledge Header
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Knowledge Base")
                                .fontWeight(.medium)
                            Text("RAG sources for context awareness")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer(minLength: 16)
                        
                        Menu {
                            Button("Add File") { /* Not implemented */ }
                            Button("Add URL") { /* Not implemented */ }
                        } label: {
                            Label("Add Source", systemImage: "plus")
                        }
                        .fixedSize()
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                    }
                    
                    // Knowledge List
                    if !knowledgeSourcesBinding.wrappedValue.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(knowledgeSourcesBinding.wrappedValue) { source in
                                HStack {
                                    Image(systemName: source.type == .file ? "doc.text.fill" : "link")
                                        .foregroundColor(source.type == .file ? .orange : .blue)
                                    Text(source.location)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        knowledgeSourcesBinding.wrappedValue.removeAll { $0.id == source.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(10)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.1), lineWidth: 1))
                            }
                        }
                    } else {
                         Text("No documents or URLs added.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
                
                // 5. Advanced Configuration
                ModernSection(title: "Advanced Configuration", icon: "gearshape.2.fill") {
                   advancedSettingsView
                }
            }
            .padding()
            .padding(.bottom, 80) // Space for action bar
        }
        .background(Color(nsColor: .windowBackgroundColor)) // Main background
        .sheet(isPresented: $showingToolLibrary) {
            ToolLibraryView(
                configuredTools: toolsBinding,
                instructions: instructionsBinding.wrappedValue
            )
        }
        .safeAreaInset(edge: .bottom) {
            actionButtons
                .padding()
                .background(.regularMaterial)
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.secondary.opacity(0.1)), alignment: .top)
        }
        .onAppear {
            // Auto-populate default instructions if nil (first time setup)
            if case .agent(let c, let a, let t, let d, let i, let k) = profile.details, i == nil {
                profile.details = .agent(
                    llmConfig: c, architecture: a, tools: t,
                    description: d, instructions: defaultSystemPersona, knowledgeSources: k
                )
            }
            
            initialProfileState = profile
            loadAdvancedConfigs()
        }
        .onDisappear {
            // Cleanup: Close the floating window if the user leaves the panel entirely
            AdvancedPromptWindowManager.shared.closeWindow()
        }
        .onChange(of: profile.id) {
            // Cleanup: Close the floating window if the user switches to a different agent
            AdvancedPromptWindowManager.shared.closeWindow()
            
            initialProfileState = profile
            loadAdvancedConfigs()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) {
            // Reset edit state when switching providers
            isEditingBaseURL = false
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
                Label("Delete Agent", systemImage: "trash")
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
                    .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary)
                            .help("Reset to Default")
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                } else {
                    Text(defaultBaseURL(for: provider))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    
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
                OllamaModelPickerView(
                    selectedModel: providerConfig.modelName,
                    supportsNativeTools: providerConfig.supportsNativeTools,
                    baseURL: providerConfig.wrappedValue.baseURL ?? defaultBaseURL(for: .ollama),
                    filterForTools: true
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
                        .foregroundColor(.secondary)
                } else {
                    if providerConfig.wrappedValue.apiProvider == .google {
                        GeminiModelPickerView(
                            selectedModel: providerConfig.modelName,
                            apiKey: currentApiKey
                        )
                        .labelsHidden()
                        .frame(maxWidth: 350, alignment: .trailing)
                        
                    } else if providerConfig.wrappedValue.apiProvider == .anthropic {
                        AnthropicModelPickerView(
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
