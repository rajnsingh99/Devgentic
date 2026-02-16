//
//  AgentConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//  Updated on 28/01/26 to support Agent Architecture selection.
//  Updated on 04/02/26 for Modern Dashboard UI.
//  Updated on 16/02/26 to add API Key visibility toggle.
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
    
    // UI State for API Key Visibility
    @State private var isApiKeyVisible: Bool = false
    
    // Tool Library Sheet
    @State private var showingToolLibrary = false
    
    private let defaultSystemPersona = """
    You are a Senior macOS DevOps Engineer.
    
    ## CORE BEHAVIORS
    1. **Prudence**: Always verify file existence before modification. Use `ls` or `stat` first.
    2. **Unix Philosophy**: Prefer chaining small, standard tools (grep, sed, awk) over complex, fragile scripts.
    3. **Transparency**: Explain your plan briefly before executing destructive actions.
    
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
                case .bot(let llmConfig): return llmConfig
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
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Reasoning Strategy")
                                .fontWeight(.medium)
                            Text(architectureBinding.wrappedValue.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Picker("", selection: architectureBinding) {
                            ForEach(AgentArchitecture.allCases) { arch in
                                Text(arch.rawValue).tag(arch)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
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
                            
                            Button("Use Default Persona") {
                                instructionsBinding.wrappedValue = defaultSystemPersona
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }
                        
                        TextEditor(text: instructionsBinding)
                            .font(.body.monospaced())
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
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
                    HStack {
                        VStack(alignment: .leading) {
                            Text("LLM Provider")
                                .fontWeight(.medium)
                            Text("The underlying model powering this agent.")
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
                
                // 4. Capabilities (Tools & Knowledge)
                ModernSection(title: "Capabilities", icon: "hammer.fill") {
                    // Tools Header
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Tools")
                                .fontWeight(.medium)
                            let count = toolsBinding.wrappedValue.filter { $0.isEnabled }.count
                            Text(count == 0 ? "No tools enabled" : "\(count) tool(s) active")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
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
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Knowledge Base")
                                .fontWeight(.medium)
                            Text("RAG sources for context awareness")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Add File") { /* Not implemented */ }
                            Button("Add URL") { /* Not implemented */ }
                        } label: {
                            Label("Add Source", systemImage: "plus")
                        }
                        .fixedSize()
                        .menuStyle(.borderedButton)
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
            ToolLibraryView(configuredTools: toolsBinding)
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
        Picker("Provider", selection: providerConfig.apiProvider) {
            ForEach(ApiProvider.allCases) { provider in
                Text(provider.rawValue).tag(provider)
            }
        }
    }
    
    @ViewBuilder
    private var ollamaFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Base URL", text: providerConfig.baseURL.toNonOptional(defaultValue: "http://localhost:11434"))
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            OllamaModelPickerView(
                selectedModel: providerConfig.modelName,
                baseURL: providerConfig.wrappedValue.baseURL ?? "",
                filterForTools: true
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
                GeminiModelPickerView(
                    selectedModel: providerConfig.modelName,
                    apiKey: providerConfig.wrappedValue.apiKey ?? ""
                )
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
