// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

private let logger = DGLogger(category: "AgentConfigDetail")

// MARK: - Localized Titles

extension ModelCognitiveCapability {
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` stays for persistence and logging only.
    /// Declared here (not next to the enum in `BackendProfile.swift`) so the model layer keeps
    /// its `Foundation`-only imports.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .none:            return "None"
        case .singleAction:    return "Single Action"
        case .parallelActions: return "Parallel Actions"
        }
    }
}

struct AgentConfigDetailView: View {
    @Bindable var editBuffer: ProfileEditBuffer
    var onDelete: ((UUID) -> Void)? = nil
    /// When non-nil, the dynamic-island leading button becomes a cancel (xmark)
    /// that invokes this closure — typically `dismiss()` from a modal host
    /// (`WorkflowProfileEditorView`). Also hides the trash icon since modal
    /// editors don't allow profile deletion; that's reserved for the standalone
    /// profile management screen.
    var onCancel: (() -> Void)? = nil
    /// When true, renders without DynamicIslandBar, outer ScrollView, and navigation guards
    /// for embedding directly within composite containers like ProfileNodeInspectorView.
    var isEmbedded: Bool = false
    @Environment(BackendProfileService.self) var profileService
    @Environment(MainViewRouter.self) private var router
    @Environment(ToastManager.self) private var toastManager
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    // Shared advanced config manager (replaces 5 @State config vars + isLoading flag)
    @State private var configManager = ProviderAdvancedConfigManager()

    // Owns this view's floating prompt editor — per-instance, not a singleton,
    // so opening the editor here doesn't trample any other view's editor.
    @State private var promptWindowManager = AdvancedPromptWindowManager()

    // Tool Library (now navigated via router)

    // Prompt Library for the inline editor
    @State private var promptLibraryVM = PromptEditViewModel()

    // Deletion State
    @State private var showingDeleteAlert = false

    // Unsaved-changes guard on back navigation.
    @State private var showingBackAlert = false

    /// Advisory findings from the last save, shown until dismissed or the next save (register A34).
    /// ⚠️ Cleared on every save, so it always describes the CURRENT state of the profile — a stale
    /// note about a model the user has since changed would be worse than no note.
    @State private var saveAdvisories: [ProfileValidationError] = []

    // File Importer State
    @State private var showingKnowledgeImporter = false
    /// Why the last "Add File" did nothing, shown inline. Nil when there is nothing to report.
    /// ⚠️ Register A60: the import result was previously discarded, so a failure was invisible.
    @State private var knowledgeImportError: String?

    // Guide
    @State private var showingAgentGuide = false

    /// Inline validation error for the System Instructions field. Set when the
    /// user attempts to Save while the field is empty/whitespace; cleared the
    /// moment the user starts editing again. Drives the red-border + inline
    /// error caption next to the editor.
    @State private var instructionsError: String? = nil


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
        // ⚠️ register B27 — capture the BUFFER, not `self`. Referencing `editBuffer` directly
        // inside these closures captures the whole View struct, and the copy carries this
        // view's `@State` window manager — so a binding handed to a long-lived NSWindow (or
        // to a manager callback) closed a retain cycle straight back to the manager. A72
        // fixed the callbacks and missed this, the other end of the same loop.
        let buffer = editBuffer
        return Binding<ProviderConfig>(
            get: {
                switch buffer.draft.details {
                case .bot(let config): return config.llmConfig
                case .agent(let config): return config.llmConfig
                case .code(let config): return config.llmConfig
                case .imageGen(let config): return config.llmConfig
                case .workflow: return ProviderConfig(apiProvider: .ollama, modelName: "")
                }
            },
            set: { newConfig in
                if case .agent(var config) = buffer.draft.details {
                    config.llmConfig = newConfig
                    buffer.draft.details = .agent(config)
                } else if case .code(var config) = buffer.draft.details {
                    config.llmConfig = newConfig
                    buffer.draft.details = .code(config)
                }
            }
        )
    }

    private var capabilitiesBinding: Binding<AgentCapabilities> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<AgentCapabilities>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.capabilities }
                return AgentCapabilities()
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.capabilities = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    /// The profile's legacy single retry knob — what `Auto` in Error Recovery / Loop Safety
    /// actually resolves to (register A70). Read-only: there is no UI for it, but its value is what
    /// those "Auto (N)" labels must state.
    private var legacyRetryPolicy: RetryPolicy? {
        if case .agent(let config) = editBuffer.draft.details { return config.retryPolicy }
        return nil
    }

    private var maxIterationsBinding: Binding<Int?> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<Int?>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.maxIterations }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.maxIterations = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var executionTimeoutBinding: Binding<TimeInterval?> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<TimeInterval?>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.executionTimeout }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.executionTimeout = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var resilienceOverridesBinding: Binding<ResilienceOverrides?> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<ResilienceOverrides?>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.resilienceOverrides }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.resilienceOverrides = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var errorRecoveryBinding: Binding<ErrorRecovery?> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<ErrorRecovery?>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.errorRecovery }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.errorRecovery = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var historyStrategyBinding: Binding<HistoryStrategy> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<HistoryStrategy>(
            get: {
                if case .agent(let config) = buffer.draft.details {
                    return config.historyStrategy ?? .recentHistory
                }
                return .recentHistory
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.historyStrategy = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var instructionsBinding: Binding<String> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<String>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.instructions ?? "" }
                return ""
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.instructions = newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var knowledgeSourcesBinding: Binding<[KnowledgeSource]> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<[KnowledgeSource]>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.knowledgeSources ?? [] }
                return []
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.knowledgeSources = newValue.isEmpty ? nil : newValue
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var toolsBinding: Binding<[Tool]> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<[Tool]>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.tools }
                return []
            },
            set: { newTools in
                if case .agent(var config) = buffer.draft.details {
                    config.tools = newTools
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    private var skillConfigBinding: Binding<SkillFolderConfig?> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<SkillFolderConfig?>(
            get: {
                if case .agent(let config) = buffer.draft.details { return config.skillConfig }
                return nil
            },
            set: { newValue in
                if case .agent(var config) = buffer.draft.details {
                    config.skillConfig = newValue
                    // ⚠️ DELIBERATELY DOES NOT TOUCH `skillSelections` (changed 2026-09-14).
                    //
                    // This editor used to keep the two in lockstep, because during the v8 dual-read
                    // window it was a WRITER of links and `SkillResolution` preferred selections.
                    // Under V6 it is not a writer any more: a profile links skills in the Skills
                    // library, and this card no longer imports folders. A selection now addresses
                    // an opaque `skill_…` that this editor has no way to produce, so anything it
                    // wrote here would be an address it invented.
                    //
                    // ⚠️ Do NOT reinstate a derive-from-skillConfig step. That is what once deleted
                    // every library-made link the moment a user touched this card — silent,
                    // persisted on the next Save, and invisible until an agent stopped seeing a
                    // skill. The legacy blob is read-only history now; leave it alone.
                    buffer.draft.details = .agent(config)
                }
            }
        )
    }

    // MARK: - Body
    var body: some View {
        Group {
            if isEmbedded {
                embeddedContent
            } else {
                standaloneContent
            }
        }
        .task {
            // Instructions are no longer auto-populated. Empty field is the
            // initial state for new profiles; the user must either type their
            // own or click "Use Default Persona". This forces a deliberate
            // choice so small/Q4 models don't run with zero guidance just
            // because the user accepted the default without reading it.
            configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .agent)

            // ⌘Q has no teardown to commit the floating editor on, so hand the service a way to
            // reach it (register B3). `[weak promptWindowManager]` captures the manager object,
            // never the view struct — capturing `self` here would route a closure the service
            // owns back into this view's `@State`, which is the retain shape register A72 is
            // about. `commitChanges` is nil while no window is open, so the hook is a safe no-op.
            profileService.commitPendingPromptEdits = { [weak promptWindowManager] in
                promptWindowManager?.commitChanges?()
            }
        }
        .onDisappear {
            // Cleanup: Close the floating window if the user leaves the panel entirely
            // Committing close: navigating away must not destroy unsaved editor text.
            promptWindowManager.closeWindowCommittingChanges()
            profileService.commitPendingPromptEdits = nil
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _, _ in
            configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .agent)
        }
        .advancedConfigSync(configManager: configManager, providerConfig: providerConfig, profileService: profileService)
    }

    private var embeddedContent: some View {
        VStack(spacing: 20) {
            formSections
        }
    }

    private var standaloneContent: some View {
        VStack(spacing: 0) {
            // When `onCancel` is set (workflow modal context), the leading
            // button becomes an xmark that dismisses the sheet — clearer than
            // a back-chevron, which implies router navigation that doesn't
            // exist here. Default path keeps the chevron + handleBackTap so
            // the standalone profile screen behaves identically to before.
            DynamicIslandBar(
                title: editBuffer.draft.displayName,
                icon: "cpu",
                onBack: handleBackTap,
                leadingSymbol: onCancel != nil ? "xmark" : "chevron.left"
            ) {
                actionButtons
            }

            // ⚠️ register B17 — OUTSIDE the ScrollView, directly under the pinned island bar
            // that holds Save. It used to be the first child of the scrolling form, with a comment
            // claiming it sat "where the user's eye already is after pressing Save" — untrue for
            // anyone saving from the Advanced section of an 800-line page, who got a green success
            // toast and an advisory several screens above them. Pinning it beside the control that
            // produced it makes the channel reach the user regardless of scroll position, without
            // a ScrollViewReader or an auto-scroll that would yank the page under them.
            SaveAdvisoryBanner(advisories: saveAdvisories) {
                withAnimation { saveAdvisories = [] }
            }
            .padding(.horizontal, 24)

            ScrollView {
                VStack(spacing: 32) {
                    formSections
                }
                .padding(ViewLayout.containerPadding)
                .padding(.bottom, ViewLayout.containerPadding)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
        .alert("Delete '\(editBuffer.draft.displayName)'?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                do {
                    try profileService.deleteProfile(withId: editBuffer.draft.id)
                    // ⚠️ Without this the container re-evaluates, finds no edit buffer, and renders
                    // "Profile Not Found — this profile may have been deleted": a deliberate,
                    // confirmed action reported back to the user as an error.
                    router.returnToChat()
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // ⚠️ register B10 — was "This action cannot be undone", which is true and useless:
            // it names no consequence beyond the profile itself. A30 added the real warning and
            // wired it only to the sidebar's hover-trash — the path A26's own note calls the least
            // discoverable. Shared with all four delete entry points, never re-implemented.
            Text(ProfileReferenceIndex.deletionMessage(
                for: editBuffer.draft, in: profileService.profiles))
        }
        // NOTE: Auto-applying an Ollama preset on every modelName change was
        // removed — it silently wiped any user customization the moment the
        // model selector changed. Users now explicitly opt in via the "Apply
        // Optimal" menu inside Advanced Configuration.
        .unsavedChangesBackGuard(
            isDirty: editBuffer.isDirty,
            showingAlert: $showingBackAlert,
            onDiscard: { editBuffer.revert() },
            onLeave: { leaveEditor() }
        )
    }

    @ViewBuilder
    private var formSections: some View {
        // 1. Identity Header
        if !isEmbedded {
            identitySection
        }

        // 2. Inference Engine (Provider)
        inferenceEngineSection

        // 3. Agent Capabilities (composable toggles + tools)
        capabilitiesSection

        // 4. System Instructions & Identity
        instructionsSection

        // 5. Skills
        skillsSection

        // 6. Knowledge
        knowledgeSection

        // 7. Execution
        executionSection

        // 8. Advanced Configuration
        advancedConfigSection

        // Profile applicability note
        if !isEmbedded {
            applicabilityNote
        }
    }

    private var identitySection: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [theme.accentColor.opacity(0.22), theme.accentColor.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .overlay(Circle().stroke(theme.accentColor.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: theme.accentColor.opacity(0.2), radius: 8)

                AgentRobotIcon(size: 28, color: theme.accentColor, isFilled: true)
            }

            VStack(alignment: .leading) {
                TextField("", text: profile.displayName, prompt: Text("Agent Name").foregroundColor(theme.placeholderText))
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
    }

    private var inferenceEngineSection: some View {
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
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Detected architectural support for complex structured reasoning.")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }

                    Spacer(minLength: 16)

                    HStack(spacing: 6) {
                        let capability = providerConfig.wrappedValue.cognitiveCapability
                        Image(systemName: capabilityIcon(for: capability))
                        Text(capability.localizedTitle)
                            .font(theme.fontCaption2.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(capabilityColor(for: providerConfig.wrappedValue.cognitiveCapability).opacity(0.1))
                    .foregroundColor(capabilityColor(for: providerConfig.wrappedValue.cognitiveCapability))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(capabilityColor(for: providerConfig.wrappedValue.cognitiveCapability).opacity(0.2), lineWidth: 1))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var capabilitiesSection: some View {
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
                                    .font(theme.fontFootnote.weight(.semibold))
                                    .foregroundColor(theme.primaryText)
                                let count = toolsBinding.wrappedValue.filter { $0.isEnabled }.count
                                Text(count == 0 ? "No tools enabled" : "\(count) tool(s) active")
                                    .font(theme.fontCaption2)
                                    .foregroundColor(theme.secondaryText)
                            }
                        }

                        Spacer(minLength: 16)

                        GlassActionButton(title: "Manage Library", icon: "arrow.up.forward.app") {
                            router.navigate(to: .toolLibrary(profileID: editBuffer.draft.id))
                        }
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
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var instructionsSection: some View {
        SettingsCard(title: "System Instructions", icon: "text.quote", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                // Instructions Editor
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Spacer()

                        GlassActionButton(title: "Expand", icon: "arrow.up.left.and.arrow.down.right", isAccent: false) {
                            promptWindowManager.showEditor(
                                text: instructionsBinding,
                                agentName: $editBuffer.draft.displayName,
                                configuredTools: toolsBinding,
                                themeManager: themeManager
                            )
                        }

                        GlassActionButton(title: "Default Persona", icon: "sparkles", isAccent: true) {
                            instructionsBinding.wrappedValue = defaultSystemPersona
                        }
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
                            Text("Define persona, reasoning strategy, and tool guidelines...")
                                .font(theme.fontCode)
                                .foregroundColor(theme.placeholderText)
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    /// ⚠️ NO IMPORT HERE (V6). This card used to be the whole skills editor — add a folder,
    /// rescan it, toggle each skill, remove them all — writing into the profile's own
    /// `skillConfig` blob. That is gone: skills live in a global library, a profile stores a
    /// REFERENCE, and linking happens where the library is. Five profiles using one skill was five
    /// copies that could disagree about what its description said.
    ///
    /// What is left is the honest summary plus the way through.
    private var skillsSection: some View {
        SettingsCard(title: "Skills", icon: "puzzlepiece", theme: theme) {
            VStack(alignment: .leading, spacing: 14) {
                // Header row
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Agent Skills")
                                .font(theme.fontFootnote.weight(.semibold))
                                .foregroundColor(theme.primaryText)

                            if !linkedSelections.isEmpty {
                                let enabledCount = linkedSelections.filter { $0.isEnabled && !$0.isAwaitingRelink }.count
                                Text("\(enabledCount) active")
                                    .font(theme.fontCodeCaption.weight(.medium))
                                    .foregroundStyle(theme.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.accentColor.opacity(0.12), in: Capsule())
                            }
                        }

                        Text(linkedSkillsSummary)
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 16)

                    GlassActionButton(title: "Manage Skills", icon: "arrow.up.forward.app", isAccent: false) {
                        router.navigate(to: .skillLibrary(profileID: editBuffer.draft.id))
                    }
                }

                // ⚠️ Named separately from "not found". A selection awaiting re-link points at a
                // skill that probably still exists and the import sweep repairs it; telling the user
                // to remove it would destroy a link that is about to fix itself.
                if awaitingRelinkCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.orange)
                        Text("\(awaitingRelinkCount) skill\(awaitingRelinkCount == 1 ? "" : "s") carried over from before the skill library and will be re-linked automatically. Nothing to do.")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }

                if linkedSelections.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "puzzlepiece")
                            .font(theme.fontBody)
                            .foregroundColor(theme.secondaryText.opacity(0.6))
                            .frame(width: 28, height: 28)
                            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("No skills linked yet")
                                .font(theme.fontCaption.weight(.medium))
                                .foregroundColor(theme.primaryText)
                            Text("Link skills from the library to teach this agent reusable workflows and capabilities.")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                        }

                        Spacer()
                    }
                    .padding(12)
                    .background(theme.secondaryBackground.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.dividerColor.opacity(0.2), lineWidth: 1)
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(linkedSelections) { selection in
                            SkillSelectionRow(
                                selection: selection,
                                theme: theme,
                                onOpenDetail: {
                                    if let skillID = selection.skillID {
                                        router.navigate(to: .skillDetail(skillID: skillID))
                                    } else {
                                        router.navigate(to: .skillLibrary(profileID: editBuffer.draft.id))
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var linkedSelections: [SkillSelection] {
        guard case .agent(let config) = editBuffer.draft.details else { return [] }
        return config.skillSelections ?? []
    }

    private var awaitingRelinkCount: Int { linkedSelections.filter(\.isAwaitingRelink).count }

    private var linkedSkillsSummary: String {
        let enabled = linkedSelections.filter { $0.isEnabled && !$0.isAwaitingRelink }.count
        guard !linkedSelections.isEmpty else {
            return "No skills linked. Skills are sets of instructions this agent loads on demand when a task matches one of them."
        }
        let pinned = linkedSelections.filter { $0.pinnedVersionID != nil }.count
        var summary = "\(enabled) skill\(enabled == 1 ? "" : "s") enabled of \(linkedSelections.count) linked."
        if pinned > 0 {
            summary += " \(pinned) pinned to a specific version, so an update to those skills will not reach this agent."
        }
        return summary
    }

    private var knowledgeSection: some View {
        SettingsCard(title: "Knowledge", icon: "book.closed.fill", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {

                // Reference Documents
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reference Documents")
                                .font(theme.fontSubheadline.weight(.semibold))
                            Text("Add external documents the agent can use as context")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                                .lineSpacing(2.5)
                        }

                        Spacer(minLength: 16)

                        GlassActionButton(title: "Add File", icon: "plus") {
                            showingKnowledgeImporter = true
                        }
                        .fileImporter(
                            isPresented: $showingKnowledgeImporter,
                            allowedContentTypes: [.item],
                            allowsMultipleSelection: true
                        ) { result in
                            knowledgeImportError = KnowledgeSourceImport.apply(
                                result, to: knowledgeSourcesBinding, profileKind: "agent")
                        }
                    }

                    // The reason "Add File" appeared to do nothing (register A60). Cleared as soon as the
                    // next import succeeds or is cancelled, so it never lingers past the attempt it describes.
                    if let knowledgeImportError {
                        Label(knowledgeImportError, systemImage: "exclamationmark.triangle")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.warningColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.warningColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }

                    if !knowledgeSourcesBinding.wrappedValue.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(knowledgeSourcesBinding.wrappedValue) { source in
                                KnowledgeSourceRow(source: source, theme: theme) {
                                    knowledgeSourcesBinding.wrappedValue.removeAll { $0.id == source.id }
                                }
                            }
                        }
                        .padding(.leading, 12)
                    } else {
                        Text("No reference documents added.")
                            .font(theme.fontCaption2)
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
                            .font(theme.fontSubheadline.weight(.semibold))
                        Text("How attached files and knowledge sources are delivered to the model")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(2.5)
                    }

                    FileContextStrategyPicker(
                        strategy: $editBuffer.draft.fileContextStrategy,
                        profileType: .agent
                    )
                    .padding(.leading, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var executionSection: some View {
        SettingsCard(title: "Execution", icon: "bolt.fill", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {

                // Limits
                VStack(alignment: .leading, spacing: 12) {
                    Text("Limits")
                        .font(theme.fontSubheadline.weight(.semibold))
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
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    ErrorRecoverySection(
                        resilienceOverrides: resilienceOverridesBinding,
                        errorRecovery: errorRecoveryBinding,
                        legacyRetryPolicy: legacyRetryPolicy
                    )
                    .padding(.leading, 12)
                }

                Divider()

                // Loop Safety — circuit-breaker caps (repetition / clarification /
                // idle / denial). Sibling group to Error Recovery; applies in chat
                // and when a workflow node executes this agent.
                VStack(alignment: .leading, spacing: 12) {
                    Text("Loop Safety")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    LoopSafetySection(
                        resilienceOverrides: resilienceOverridesBinding,
                        legacyRetryPolicy: legacyRetryPolicy
                    )
                    .padding(.leading, 12)
                }

                Divider()

                // Conversation Memory
                VStack(alignment: .leading, spacing: 10) {
                    Text("Conversation Memory")
                        .font(theme.fontSubheadline.weight(.semibold))
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
                                        Text(strategy.localizedTitle)
                                            .font(theme.fontFootnote.weight(.semibold))
                                            .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                                        Text(strategy.localizedDescription)
                                            .font(theme.fontCaption2)
                                            .foregroundColor(theme.tertiaryText)
                                            .lineSpacing(2.5)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var advancedConfigSection: some View {
        SettingsCard(title: "Advanced Configuration", icon: "gearshape.2.fill", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                advancedSettingsView
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var applicabilityNote: some View {
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

    /// ⚠️ register B46 — FLUSH FIRST. `BackendProfileService.flushPendingEditorText`'s own doc
    /// comment says "call this BEFORE reading `hasUnsavedEditorChanges` at an exit point", and
    /// until now it had exactly one caller: `applicationShouldTerminate` (register B3). The
    /// floating Advanced prompt editor holds typing in `@State` and writes back only on an explicit
    /// commit, so a back tap read a CLEAN buffer and left with no prompt — the multi-thousand
    /// character loss A27/A29/B3 exist to prevent, at the exit B3 did not cover.
    ///
    /// ⚠️ Placed in the tap ACTION, not in the `isDirty:` the guard modifier reads: that value is
    /// computed during a view update, and committing there would mutate state mid-pass.
    ///
    /// A no-op in editors that register no commit hook (`SimplePromptWindowManager` syncs on every
    /// keystroke, so it has nothing pending). It is here in all three anyway — the whole class of
    /// B44/B46 defects is a fix that landed on the one site that had the bug.
    private func handleBackTap() {
        profileService.flushPendingEditorText()
        if editBuffer.isDirty {
            showingBackAlert = true
        } else {
            leaveEditor()
        }
    }

    /// The ONE way out of this editor.
    ///
    /// ⚠️ Register A28. The leading button used to be wired `onBack: onCancel ?? handleBackTap`,
    /// so in the workflow sheet the xmark called `dismiss()` directly and never consulted
    /// `editBuffer.isDirty` — the identical view, routed, prompted correctly. The dirty check now
    /// happens for both hosts and only the EXIT differs: dismiss the sheet, or pop the router.
    private func leaveEditor() {
        if let onCancel {
            onCancel()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                router.goBack()
            }
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
                IslandPillButton(
                    title: "Revert",
                    style: .secondary,
                    // ⚠️ register B12 — NO `.cancelAction`. Revert is destructive and discards
                    // every unsaved edit without a prompt, so binding it to Esc gave a dirty editor
                    // a silent one-keypress exit: Esc reverted, `isDirty` went false, and the
                    // second Esc then passed `interactiveDismissDisabled(isDirty)` and closed the
                    // sheet. A28's comment claimed "exactly one way out of a dirty editor, and it
                    // is the one that prompts" — this was the second, and it prompted for nothing.
                    // Esc now means close, which the unsaved-changes guard already governs.
                    accessibilityLabel: "Revert unsaved changes"
                ) {
                    editBuffer.revert()
                    // ⚠️ register B17 — the draft the advisory was about no longer exists.
                    saveAdvisories = []
                    configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .agent)
                }

                IslandPillButton(
                    title: "Save",
                    style: .primary,
                    help: "Save profile changes (⌘S)",
                    accessibilityLabel: "Save profile changes",
                    keyboardShortcut: KeyboardShortcut("s", modifiers: .command)
                ) {
                    // Pre-flight: empty system instructions on a small/Q4 model
                    // routinely produces looping or wandering behaviour. We don't
                    // auto-fill a default anymore — the user must make a deliberate
                    // choice — so block the save and surface the inline error.
                    // ⚠️ Register A35: the rule and its wording now come from `ProfileValidator`,
                    // the single definition. Each editor used to carry its own copy of both, and
                    // every non-editor save path had neither.
                    if ProfileValidator.instructionsAreMissing(instructionsBinding.wrappedValue) {
                        instructionsError = ProfileValidator.missingInstructionsMessage
                        // ⚠️ register B17 — the save is being refused here, so any banner from an
                        // earlier successful save is now describing a profile state this attempt
                        // did not produce.
                        saveAdvisories = []
                        return
                    }
                    instructionsError = nil

                    do {
                        // ⚠️ Register A34: advisories are RETURNED now, not just logged. The
                        // save succeeded either way — the banner explains what may not work, it
                        // does not report a failure.
                        saveAdvisories = try profileService.saveProfile(editBuffer.draft)
                        editBuffer.markSaved()
                        toastManager.show("Profile saved", style: .success)
                    } catch {
                        // ⚠️ A toast and NOTHING else was the whole record of a failed save on the
                        // primary user-data write path. It disappears in seconds, so "my agent
                        // config won't stick" arrived with no profile id, no type and no error to
                        // correlate against.
                        logger.error(
                            "[PROFILE] Save FAILED for '\(editBuffer.draft.displayName)' "
                            + "(\(editBuffer.draft.id), agent): \(error.localizedDescription). "
                            + "CONSEQUENCE: the edit buffer stays dirty and the persisted profile is "
                            + "unchanged; the user's edits are still on screen but not on disk."
                        )
                        // ⚠️ register B17 — clear on FAILURE too. `saveAdvisories` was assigned
                        // only in the `do` branch and never reset, so a banner from an earlier
                        // successful save stayed on screen reading "Saved — one thing worth
                        // knowing" while an error toast reported that this write did not happen.
                        // An advisory describes the state of a profile that WAS saved; after a
                        // failure it describes nothing that exists.
                        saveAdvisories = []
                        toastManager.show(error.localizedDescription, style: .error)
                    }
                }
            }

            // Trash is hidden in modal-cancel mode: workflow editing doesn't
            // permit profile deletion (it would orphan every node referencing
            // this profile across every workflow). Profile lifecycle stays
            // owned by the standalone profile screen.
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
            defaultProfile: .agent
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

// MARK: - SkillSelectionRow

private struct SkillSelectionRow: View {
    let selection: SkillSelection
    let theme: any Theme
    let onOpenDetail: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpenDetail) {
            HStack(spacing: 12) {
                // 32x32 rounded icon badge
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((selection.isEnabled ? theme.accentColor : theme.secondaryText).opacity(selection.isEnabled ? 0.15 : 0.08))
                    Image(systemName: "puzzlepiece")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection.isEnabled ? theme.accentColor : theme.secondaryText)
                }
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder((selection.isEnabled ? theme.accentColor : theme.dividerColor).opacity(selection.isEnabled ? 0.35 : 0.2), lineWidth: 0.5)
                )

                // Skill info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(selection.name)
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundStyle(selection.isEnabled ? theme.primaryText : theme.secondaryText)
                            .lineLimit(1)

                        if selection.pinnedVersionID != nil {
                            HStack(spacing: 3) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8))
                                Text("Pinned")
                                    .font(theme.fontCodeCaption)
                            }
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.secondaryBackground, in: Capsule())
                            .overlay(Capsule().stroke(theme.dividerColor.opacity(0.4), lineWidth: 0.5))
                        }
                    }

                    if selection.isAwaitingRelink {
                        Text("Awaiting re-link from migration")
                            .font(theme.fontCaption2)
                            .foregroundStyle(Color.orange)
                    } else if let versionID = selection.pinnedVersionID {
                        Text("Pinned to version \(versionID)")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Text("Follows latest version")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Spacer(minLength: 8)

                // Trailing indicators & arrow
                HStack(spacing: 8) {
                    if !selection.isEnabled {
                        Text("Disabled")
                            .font(theme.fontCodeCaption.weight(.medium))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(theme.secondaryText.opacity(0.12), in: Capsule())
                            .overlay(
                                Capsule().stroke(theme.dividerColor.opacity(0.25), lineWidth: 0.5)
                            )
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isHovered ? theme.accentColor : theme.secondaryText.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.secondaryBackground.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? theme.accentColor.opacity(0.4) : theme.dividerColor.opacity(0.35),
                        lineWidth: isHovered ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel("\(selection.name)\(selection.isEnabled ? "" : ", Disabled")\(selection.pinnedVersionID != nil ? ", Pinned" : "")")
        .accessibilityHint(selection.skillID != nil ? "Open skill details" : "Open skill library")
        .help(selection.skillID != nil ? "View details for '\(selection.name)'" : "Manage skills in library")
    }
}

