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
    /// When non-nil, the dynamic-island leading button becomes a cancel (xmark)
    /// that invokes this closure (typically `dismiss()` from a modal host like
    /// `WorkflowProfileEditorView`). Also hides the trash icon.
    var onCancel: (() -> Void)? = nil
    @Environment(BackendProfileService.self) var profileService
    @Environment(ToastManager.self) private var toastManager
    @Environment(MainViewRouter.self) private var router
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    // Shared advanced config manager (replaces 5 @State config vars + isLoading flag)
    @State private var configManager = ProviderAdvancedConfigManager()

    // Owns this view's floating prompt editor — per-instance, not a singleton.
    @State private var promptWindowManager = SimplePromptWindowManager()

    // Deletion State
    @State private var showingDeleteAlert = false

    // Unsaved-changes guard on back navigation.
    @State private var showingBackAlert = false

    // File Importer State
    @State private var showingKnowledgeImporter = false

    /// Inline validation error for the System Instructions field. Set when the
    /// user attempts to Save while the field is empty/whitespace; cleared the
    /// moment the user starts editing again. Drives the red-border + inline
    /// error caption next to the editor.
    @State private var instructionsError: String? = nil


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
                case .code(let config): return config.llmConfig
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
                case .code(var config):
                    config.llmConfig = newConfig
                    editBuffer.draft.details = .code(config)
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
            // See AgentConfigDetailView for the rationale — `onCancel` swaps
            // the leading chevron for an xmark and routes it to the modal host.
            DynamicIslandBar(
                onBack: onCancel ?? handleBackTap,
                leadingSymbol: onCancel != nil ? "xmark" : "chevron.left"
            ) {
                actionButtons
            }

            ScrollView {
                VStack(spacing: 32) {

                    // 1. Identity Header
                    HStack(alignment: .center, spacing: 16) {
                        Image(systemName: ProfileType.bot.iconNameFilled)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                            .foregroundColor(.blue) // Bot specific color

                        VStack(alignment: .leading) {
                            TextField("Bot Name", text: profile.displayName)
                                .font(theme.fontTitle2)
                                .fontWeight(.bold)
                                .textFieldStyle(.plain)
                                .foregroundColor(theme.primaryText)

                            Text("A straightforward LLM interface without agentic capabilities.")
                                .font(theme.fontSubheadline)
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }

                // 3. Persona & Behavior
                SettingsCard(title: "Persona & Behavior", icon: "text.quote", theme: theme) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("System Instructions")
                                .font(theme.fontSubheadline)
                                .fontWeight(.medium)
                                .foregroundColor(theme.secondaryText)

                            Spacer()

                            Button {
                                promptWindowManager.showEditor(
                                    text: instructionsBinding,
                                    botName: editBuffer.draft.displayName,
                                    themeManager: themeManager
                                )
                            } label: {
                                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .font(theme.fontCaption)
                            .buttonStyle(.link)
                        }

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: instructionsBinding)
                                .font(theme.fontCode)
                                .disableAutocorrection(true)
                                .frame(minHeight: 120)
                                .padding(8)
                                .scrollContentBackground(.hidden)
                                .background(theme.textBackground)
                                .foregroundColor(theme.primaryText)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(instructionsError != nil ? theme.errorColor : theme.dividerColor,
                                                lineWidth: instructionsError != nil ? 1.5 : 1)
                                )
                                .onChange(of: instructionsBinding.wrappedValue) { _, _ in
                                    // Clear the validation error as soon as the user starts editing.
                                    instructionsError = nil
                                }

                            if instructionsBinding.wrappedValue.isEmpty {
                                Text("Enter system instructions for your bot here...")
                                    .font(theme.fontCode)
                                    .foregroundColor(theme.secondaryText.opacity(0.5))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }

                        let charCount = instructionsBinding.wrappedValue.count
                        let charLimit = ProfileValidationLimits.maxInstructionsLength
                        Text("\(charCount) characters · ~\(charCount / 4) tokens")
                            .font(theme.fontCaption2)
                            .foregroundColor(
                                charCount > charLimit ? theme.errorColor :
                                charCount > Int(Double(charLimit) * 0.9) ? theme.warningColor :
                                theme.secondaryText
                            )

                        // Inline validation error — same visual pattern as
                        // CreateScheduledTaskView's `inlineError(_:)` helper.
                        if let message = instructionsError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .accessibilityHidden(true)
                                Text(message)
                                    .font(theme.fontCaption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundColor(theme.errorColor)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }

                // 4. File Handling Strategy & Knowledge
                fileHandlingSection

                // 5. Advanced Configuration
                SettingsCard(title: "Advanced Configuration", icon: "gearshape.2.fill", theme: theme) {
                    VStack(alignment: .leading, spacing: 16) {
                        advancedSettingsView
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
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
            Text("Are you sure you want to delete this bot? This action cannot be undone.")
        }
        .task {
            // Instructions are no longer auto-populated. Empty field is the
            // initial state for new profiles; the user must type their own
            // before they can Save. Forces a deliberate choice instead of
            // silently shipping with a default the user never read.
            configManager.load(from: providerConfig.wrappedValue, using: profileService)
        }
        .onDisappear {
            // Close the floating prompt editor if the user leaves the panel.
            promptWindowManager.closeWindow()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _, _ in
            configManager.load(from: providerConfig.wrappedValue, using: profileService)
        }
        .advancedConfigSync(configManager: configManager, providerConfig: providerConfig, profileService: profileService)
        // NOTE: Auto-applying an Ollama preset on every modelName change was
        // removed — it silently wiped any user customization the moment the
        // model selector changed. Users now explicitly opt in via the "Apply
        // Optimal" menu inside Advanced Configuration.
        .unsavedChangesBackGuard(
            isDirty: editBuffer.isDirty,
            showingAlert: $showingBackAlert,
            onDiscard: { editBuffer.revert() }
        )
    }

    private func handleBackTap() {
        if editBuffer.isDirty {
            showingBackAlert = true
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                router.goBack()
            }
        }
    }

    // MARK: - Subviews & Helpers

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if editBuffer.isDirty {
                IslandPillButton(
                    title: "Revert",
                    style: .secondary,
                    accessibilityLabel: "Revert unsaved changes",
                    keyboardShortcut: .cancelAction
                ) {
                    editBuffer.revert()
                    configManager.load(from: providerConfig.wrappedValue, using: profileService)
                }

                IslandPillButton(
                    title: "Save",
                    style: .primary,
                    accessibilityLabel: "Save profile changes",
                    keyboardShortcut: .defaultAction
                ) {
                    // Pre-flight: a bot with empty instructions has no persona
                    // and no behavioural guardrails. We don't auto-fill a default
                    // anymore — the user must make a deliberate choice — so block
                    // the save and surface the inline error.
                    let trimmed = instructionsBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        instructionsError = String(localized: "System instructions are required.")
                        return
                    }
                    instructionsError = nil

                    do {
                        try profileService.saveProfile(editBuffer.draft)
                        editBuffer.markSaved()
                        toastManager.show("Profile saved", style: .success)
                    } catch {
                        toastManager.show(error.localizedDescription, style: .error)
                    }
                }
            }

            // Hidden in modal-cancel mode — see AgentConfigDetailView.
            if onCancel == nil {
                IslandIconButton(
                    symbol: "trash",
                    style: .destructive,
                    help: "Delete profile",
                    accessibilityLabel: "Delete this profile"
                ) {
                    showingDeleteAlert = true
                }
            }
        }
    }


    @ViewBuilder
    private var fileHandlingSection: some View {
        SettingsCard(title: "Knowledge", icon: "book.closed.fill", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                // Reference Documents
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reference Documents")
                                .font(theme.fontBody.weight(.semibold))
                            Text("Add external documents the bot can use as context")
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
                                    .foregroundColor(source.exists ? .orange : theme.errorColor)
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
                        profileType: .bot
                    )
                    .padding(.leading, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
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
            ),
            modelMetadata: providerConfig.wrappedValue.modelMetadata,
            modelName: providerConfig.wrappedValue.modelName,
            defaultProfile: .chat
        )
    }
}
