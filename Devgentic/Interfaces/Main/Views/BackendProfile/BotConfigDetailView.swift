// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

private let logger = DGLogger(category: "BotConfigDetail")

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
    /// When true, renders without DynamicIslandBar, outer ScrollView, and navigation guards
    /// for embedding directly within composite containers like ProfileNodeInspectorView.
    var isEmbedded: Bool = false
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

    /// Advisory findings from the last save, shown until dismissed or the next save (register A34).
    /// ⚠️ Cleared on every save, so it always describes the CURRENT state of the profile — a stale
    /// note about a model the user has since changed would be worse than no note.
    @State private var saveAdvisories: [ProfileValidationError] = []

    // File Importer State
    @State private var showingKnowledgeImporter = false
    /// Why the last "Add File" did nothing, shown inline. Nil when there is nothing to report.
    /// ⚠️ Register A60: the import result was previously discarded, so a failure was invisible.
    @State private var knowledgeImportError: String?

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
                switch buffer.draft.details {
                case .bot(var config):
                    config.llmConfig = newConfig
                    buffer.draft.details = .bot(config)
                case .agent(var config):
                    config.llmConfig = newConfig
                    buffer.draft.details = .agent(config)
                case .code(var config):
                    config.llmConfig = newConfig
                    buffer.draft.details = .code(config)
                case .imageGen(var config):
                    config.llmConfig = newConfig
                    buffer.draft.details = .imageGen(config)
                case .workflow:
                    break
                }
            }
        )
    }

    private var instructionsBinding: Binding<String> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<String>(
            get: {
                if case .bot(let config) = buffer.draft.details { return config.instructions ?? "" }
                return ""
            },
            set: { newValue in
                if case .bot(var config) = buffer.draft.details {
                    config.instructions = newValue
                    buffer.draft.details = .bot(config)
                }
            }
        )
    }

    private var knowledgeSourcesBinding: Binding<[KnowledgeSource]> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<[KnowledgeSource]>(
            get: {
                if case .bot(let config) = buffer.draft.details { return config.knowledgeSources ?? [] }
                return []
            },
            set: { newValue in
                if case .bot(var config) = buffer.draft.details {
                    config.knowledgeSources = newValue.isEmpty ? nil : newValue
                    buffer.draft.details = .bot(config)
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
            // initial state for new profiles; the user must type their own
            // before they can Save. Forces a deliberate choice instead of
            // silently shipping with a default the user never read.
            configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .chat)
        }
        .onDisappear {
            // Close the floating prompt editor if the user leaves the panel.
            // ⚠️ A plain close is correct HERE and only here: this is the Simple editor, whose
            // `.onChange(of: localText)` pushes every keystroke straight back to the binding, so
            // there is nothing pending to lose. The Agent view's Advanced editor writes back only
            // in `saveAndClose()`, which is why it needs `closeWindowCommittingChanges()`.
            promptWindowManager.closeWindow()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _, _ in
            configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .chat)
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
            // See AgentConfigDetailView for the rationale — `onCancel` swaps
            // the leading chevron for an xmark and routes it to the modal host.
            DynamicIslandBar(
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

        // 3. Persona & Behavior
        personaSection

        // 4. File Handling Strategy & Knowledge
        fileHandlingSection

        // 5. Advanced Configuration
        advancedConfigSection
    }

    private var identitySection: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.blue.opacity(0.22), Color.blue.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .overlay(Circle().stroke(Color.blue.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: Color.blue.opacity(0.2), radius: 8)

                Image(systemName: ProfileType.bot.iconNameFilled)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
                    .foregroundColor(.blue)
            }

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
    }

    private var inferenceEngineSection: some View {
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
    }

    private var personaSection: some View {
        SettingsCard(title: "Persona & Behavior", icon: "text.quote", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("System Instructions")
                        .font(theme.fontSubheadline)
                        .fontWeight(.medium)
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    GlassActionButton(title: "Expand", icon: "arrow.up.left.and.arrow.down.right", isAccent: false) {
                        promptWindowManager.showEditor(
                            text: instructionsBinding,
                            // A binding, so renaming the bot retitles the detached
                            // window instead of leaving it on the old name (A75).
                            botName: profile.displayName,
                            themeManager: themeManager,
                            // ⚠️ Register A75: this argument existed and NO caller ever
                            // passed it, so the editor's "% of context" readout — the
                            // thing that tells you a system prompt is eating the window —
                            // was dead code. The value is right here on the profile.
                            contextWindow: providerConfig.wrappedValue.modelMetadata?.contextWindow
                        )
                    }
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
                    configManager.load(from: providerConfig.wrappedValue, using: profileService, defaultProfile: .chat)
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
                        // primary user-data write path. It disappears in seconds, so "my bot
                        // config won't stick" arrived with no profile id, no type and no error to
                        // correlate against.
                        logger.error(
                            "[PROFILE] Save FAILED for '\(editBuffer.draft.displayName)' "
                            + "(\(editBuffer.draft.id), bot): \(error.localizedDescription). "
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

                    GlassActionButton(title: "Add File", icon: "plus") {
                        showingKnowledgeImporter = true
                    }
                    .fileImporter(
                        isPresented: $showingKnowledgeImporter,
                        allowedContentTypes: [.item],
                        allowsMultipleSelection: true
                    ) { result in
                        knowledgeImportError = KnowledgeSourceImport.apply(
                            result, to: knowledgeSourcesBinding, profileKind: "bot")
                    }
                    }

                    // The reason "Add File" appeared to do nothing (register A60). Cleared as soon as the
                    // next import succeeds or is cancelled, so it never lingers past the attempt it describes.
                    if let knowledgeImportError {
                        Label(knowledgeImportError, systemImage: "exclamationmark.triangle")
                            .font(theme.fontCaption)
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
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                            .italic()
                            .padding(.leading, 12)
                    }
                }

                // Bot file handling is fixed to .directInjection (bots have no tools,
                // and contextualRAG is deprecated) — one option, so no picker.
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
