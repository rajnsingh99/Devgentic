// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageGenConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  Configuration detail view for Image Generator profiles.
//  Updated to adopt Modern Dashboard UI, Model Pickers, and dynamic capabilities.
//  Refactored on 27/03/26 to use ProfileEditBuffer (single source of truth for dirty tracking).
//

import SwiftUI
#if MLX_IMAGE_GEN   // see MLXImageGenService.swift for why on-device image generation is compiled out
import Flux2Core
#endif

private let logger = DGLogger(category: "ImageGenConfigDetail")

struct ImageGenConfigDetailView: View {
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
    @Environment(\.appTheme) private var theme

    // Advanced config local state
    @State private var localAdvancedConfig: ImageGenAdvancedConfig = .default()

    /// The exact dictionary the last `loadAdvancedConfig()` produced.
    ///
    /// ⚠️ register B45 — this replaces an `isLoadingAdvancedConfig` boolean that could NEVER fire.
    /// `load` set it true, assigned `localAdvancedConfig` and set it false, all synchronously in
    /// one MainActor turn; SwiftUI runs `.onChange` on the *next* update pass, by which point the
    /// flag was already false. So the write-back it existed to suppress happened on every open.
    ///
    /// This is register A9's defect verbatim, and A9's fix — a value baseline — never reached this
    /// file because this editor hand-rolls the lifecycle instead of using
    /// `ProviderAdvancedConfigManager`. A baseline survives the deferral because it is COMPARED,
    /// not raced: `load` sets it in the same synchronous call, so whenever `.onChange` finally runs
    /// it already holds the right value.
    @State private var loadedAdvancedBaseline: [String: JSONValue]?

    // Deletion State
    @State private var showingDeleteAlert = false

    // Unsaved-changes guard on back navigation.
    @State private var showingBackAlert = false

    /// Advisory findings from the last save, shown until dismissed or the next save (register A34).
    /// ⚠️ Cleared on every save, so it always describes the CURRENT state of the profile — a stale
    /// note about a model the user has since changed would be worse than no note.
    @State private var saveAdvisories: [ProfileValidationError] = []


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
                if case .imageGen(let config) = buffer.draft.details { return config.llmConfig }
                // Default routed through ProfileCapabilityFilter so the fallback doesn't
                // name `.openAI` while the "Show Remote Models" toggle hides it.
                return ProviderConfig(apiProvider: ProfileCapabilityFilter.defaultImageGenProvider, modelName: "dall-e-3")
            },
            set: { newConfig in
                if case .imageGen(var config) = buffer.draft.details {
                    config.llmConfig = newConfig
                    buffer.draft.details = .imageGen(config)
                }
            }
        )
    }

    private var negativePromptBinding: Binding<String> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<String>(
            get: {
                if case .imageGen(let config) = buffer.draft.details { return config.negativePrompt ?? "" }
                return ""
            },
            set: { newValue in
                if case .imageGen(var config) = buffer.draft.details {
                    config.negativePrompt = newValue.isEmpty ? nil : newValue
                    buffer.draft.details = .imageGen(config)
                }
            }
        )
    }

    private var aspectRatioBinding: Binding<ImageAspectRatio> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<ImageAspectRatio>(
            get: {
                if case .imageGen(let config) = buffer.draft.details { return config.defaultAspectRatio ?? .square }
                return .square
            },
            set: { newValue in
                if case .imageGen(var config) = buffer.draft.details {
                    config.defaultAspectRatio = newValue
                    buffer.draft.details = .imageGen(config)
                }
            }
        )
    }

    private var advancedSettingsBinding: Binding<[String: JSONValue]?> {
        let buffer = editBuffer   // ⚠️ register B27 — capture the buffer, never `self`.
        return Binding<[String: JSONValue]?>(
            get: {
                if case .imageGen(let config) = buffer.draft.details { return config.advancedSettings }
                return nil
            },
            set: { newValue in
                if case .imageGen(var config) = buffer.draft.details {
                    config.advancedSettings = newValue
                    buffer.draft.details = .imageGen(config)
                }
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
        Group {
            if isEmbedded {
                embeddedContent
            } else {
                standaloneContent
            }
        }
        .task {
            loadAdvancedConfig()
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _, _ in
            // When switching to MLX, immediately correct any invalid model name
            #if MLX_IMAGE_GEN
            if providerConfig.wrappedValue.apiProvider == .mlx {
                snapToValidFlux2Model()
            }
            #endif
            // Reload advanced config with provider-appropriate defaults
            loadAdvancedConfig()
        }
        .onChange(of: localAdvancedConfig) { _, newValue in
            // ⚠️ register B45 — compare against what `load` produced, do not consult a flag.
            // Two consequences this restores, both of them A9's: an MLX profile with no stored
            // config used to load `.mlxDefault()` over a `.default()` seed and go DIRTY ON MERE
            // OPEN (phantom Save/Revert pill), and a profile whose blob failed to decode used to
            // have app defaults written into the draft — so the next save overwrote a
            // configuration that was unreadable but still present.
            let encoded = profileService.encodeConfig(from: newValue)
            guard encoded != loadedAdvancedBaseline else { return }
            advancedSettingsBinding.wrappedValue = encoded
        }
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
                title: editBuffer.draft.displayName,
                icon: "photo",
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
            .padding(.horizontal, ViewLayout.containerPadding)
            .padding(.top, 8)
            .frame(maxWidth: ViewLayout.maxContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)

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
        .unsavedChangesBackGuard(
            isDirty: editBuffer.isDirty,
            showingAlert: $showingBackAlert,
            onDiscard: { editBuffer.revert() },
            onLeave: { leaveEditor() }
        )
        .alert("Delete '\(editBuffer.draft.displayName)'?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                do {
                    try profileService.deleteProfile(withId: editBuffer.draft.id)
                    router.returnToChat()
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ProfileReferenceIndex.deletionMessage(
                for: editBuffer.draft, in: profileService.profiles))
        }
    }

    @ViewBuilder
    private var formSections: some View {
        // 1. Identity Header
        if !isEmbedded {
            identitySection
        }

        // 2. Inference Engine (Provider)
        inferenceEngineSection

        // 3. Generation Defaults
        generationDefaultsSection

        // 4. Negative Prompt
        negativePromptSection

        // 5. Advanced Configuration
        advancedConfigSection

        // 6. Capability Badge
        modelCapabilitiesSection
    }

    private var identitySection: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: ProfileType.imageGen.iconNameFilled)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
                .foregroundColor(.orange) // ImageGen specific color

            VStack(alignment: .leading) {
                TextField("", text: profile.displayName, prompt: Text("Profile Name").foregroundColor(theme.placeholderText))
                    .font(theme.fontTitle2)
                    .fontWeight(.bold)
                    .textFieldStyle(.plain)
                    .foregroundColor(theme.primaryText)

                Text("AI-powered image generation")
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
                    profileType: .imageGen,
                    customMLXContent: mlxModelContent
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    /// The MLX arm of the provider section. In a build without on-device image generation it
    /// explains why the profile can't run instead of offering the text-model picker, which
    /// would let the user pick an LLM that cannot draw.
    private var mlxModelContent: AnyView {
        #if MLX_IMAGE_GEN
        AnyView(
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model Selection")
                            .font(theme.fontBody.weight(.medium))
                        Text("Flux2 models run fully on-device via Apple Silicon.")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer(minLength: 16)
                    Flux2ModelPickerView(selectedModel: providerConfig.modelName)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
            .onAppear { snapToValidFlux2Model() }
        )
        #else
        AnyView(
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(theme.warningColor)
                    .font(theme.fontCaption)
                    .accessibilityHidden(true)
                Text(MLXImageGenAvailability.unavailableMessage)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(8)
            .background(theme.warningColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        )
        #endif
    }

    private var advancedConfigSection: some View {
        SettingsCard(title: "Advanced Configuration", icon: "gearshape.2.fill", theme: theme) {
            ImageGenSettingsView(
                config: $localAdvancedConfig,
                provider: providerConfig.wrappedValue.apiProvider
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var modelCapabilitiesSection: some View {
        SettingsCard(title: "Model Capabilities", icon: "checkmark.shield", theme: theme) {
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
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }
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

    // MARK: - Extracted Sections

    @ViewBuilder
    private var generationDefaultsSection: some View {
        SettingsCard(title: "Generation Defaults", icon: "slider.horizontal.3", theme: theme) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aspect Ratio")
                            .font(theme.fontBody.weight(.medium))
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
                    RoundedRectangle(cornerRadius: theme.cornerRadiusSmall)
                        .stroke(theme.secondaryText.opacity(0.5), lineWidth: 1)
                        .frame(width: CGFloat(dims.width), height: CGFloat(dims.height))
                        .overlay(
                            Text("\(aspectRatioBinding.wrappedValue.dimensions().width)x\(aspectRatioBinding.wrappedValue.dimensions().height)")
                                .font(.system(size: 9)) // Fixed size: intentional (badge/chip text)
                                .foregroundColor(theme.secondaryText)
                        )
                    Spacer()
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private var negativePromptSection: some View {
        SettingsCard(title: "Negative Prompt", icon: "xmark.circle", theme: theme) {
            VStack(alignment: .leading, spacing: 8) {
                if providerConfig.wrappedValue.apiProvider == .mlx {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundColor(theme.warningColor)
                            .font(theme.fontCaption)
                            .accessibilityHidden(true)
                        Text("Flux2 models don't have a native negative prompt parameter. This text is appended to your prompt as \"Avoid: \u{2026}\" for soft guidance.")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                    }
                    .padding(8)
                    .background(theme.warningColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text("Describe what to avoid in generated images (e.g., blurry, bad anatomy).")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }

                ZStack(alignment: .topLeading) {
                    if negativePromptBinding.wrappedValue.isEmpty {
                        Text("e.g. Blurry, low quality, distorted, extra limbs, bad anatomy...")
                            .font(theme.fontFootnote)
                            .foregroundStyle(theme.placeholderText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: negativePromptBinding)
                        .font(theme.fontFootnote)
                        .foregroundStyle(theme.primaryText)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 80, maxHeight: 160)
                }
                .background(theme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                        .stroke(theme.dividerColor, lineWidth: 1)
                )

                let npCount = negativePromptBinding.wrappedValue.count
                if npCount > 0 {
                    Text("\(npCount) characters")
                        .font(theme.fontCaption2)
                        .foregroundColor(npCount > 5_000 ? theme.warningColor : theme.secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    #if MLX_IMAGE_GEN
    /// Resolves the Flux2 model selection through `ModelSelectionPolicy` — register B34.
    ///
    /// ⚠️ This was `if !inferenceRawValues.contains(modelName) { modelName = klein4B }`, duplicated
    /// verbatim inside `Flux2ModelPickerView.onAppear`, and neither copy logged. It made this the
    /// SIXTH picker to implement the model-selection rule inline (`MLXModelPickerView` already
    /// calls itself the fifth), which is precisely the drift `ModelSelectionPolicy` was extracted
    /// to stop. The picker's copy is gone; this is the only site.
    ///
    /// ⚠️ **Re-derived, because the register row's failure scenario was wrong.** B34 reads as if
    /// switching provider away and back loses a saved `dall-e-3`. It cannot: `switchProvider(to:)`
    /// clears `modelName` to `""` by design, so the common path here is a *compliant fill of an
    /// empty selection*, not an overwrite. The genuine defect is narrower — a stored, NON-empty
    /// name this build does not recognise was silently replaced. That is reachable by running an
    /// older build against a store a newer one wrote (a `Flux2Model` case this binary lacks), or by
    /// a stored variant whose `isForInference` is false.
    ///
    /// ⚠️ **`.keptUnlisted` KEEPS, with no exception.** `MLXModelPickerView` used to carry the
    /// module's one exception, and register B13 deleted it after proving its premise false; making
    /// Flux2 the new exception would re-introduce what B13 just removed. Keeping is also safe here,
    /// which is the part worth knowing: `MLXImageGenService.resolveFlux2Model` already falls back
    /// to `.dev` and logs when it cannot map a name, so an unrecognised value still generates — it
    /// does not strand the profile. Destroying the user's stored choice to avoid a warning the
    /// runtime already handles is the worse trade.
    private func snapToValidFlux2Model() {
        let inferenceRawValues = Flux2Model.allCases
            .filter(\.isForInference)
            .map(\.rawValue)

        switch ModelSelectionPolicy.resolve(
            saved: providerConfig.wrappedValue.modelName,
            available: inferenceRawValues,
            fillCandidate: Flux2Model.klein4B.rawValue
        ) {
        case .fill(let candidate):
            logger.info(
                "[PROFILE] Filling an empty Flux2 model selection with '\(candidate)'. "
                + "CONSEQUENCE: the profile draft now names a model; nothing was overwritten."
            )
            providerConfig.wrappedValue.modelName = candidate

        case .keptUnlisted(let saved):
            logger.notice(
                "[PROFILE] The stored Flux2 model '\(saved)' is not an inference variant this "
                + "build knows. CONSEQUENCE: it is KEPT, not replaced — a newer build may have "
                + "written it. Generation falls back to the default pipeline and logs that "
                + "separately; re-select from the picker to change it."
            )

        case .keep, .nothingAvailable:
            break
        }
    }
    #endif

    /// Decodes the stored advanced config into local state and records the baseline.
    ///
    /// ⚠️ register B45 — the baseline assignment is not bookkeeping, it is the fix. It must stay in
    /// the same synchronous call as the `localAdvancedConfig` write, because the `.onChange` this
    /// guards runs one update pass later and reads whatever is here by then.
    private func loadAdvancedConfig() {
        let defaultConfig: ImageGenAdvancedConfig = providerConfig.wrappedValue.apiProvider == .mlx
            ? .mlxDefault()
            : .default()
        let loaded = profileService.decodeConfig(
            from: advancedSettingsBinding.wrappedValue,
            as: ImageGenAdvancedConfig.self
        ) ?? defaultConfig
        self.localAdvancedConfig = loaded
        self.loadedAdvancedBaseline = profileService.encodeConfig(from: loaded)
    }

    private func capabilityBadge(label: String, supported: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(supported ? theme.successColor : theme.errorColor.opacity(0.6))
                .font(theme.fontBody)
            Text(label)
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(supported ? theme.successColor.opacity(0.1) : theme.errorColor.opacity(0.05))
        )
    }

    // MARK: - Action Bar

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
                    loadAdvancedConfig()
                }

                IslandPillButton(
                    title: "Save",
                    style: .primary,
                    help: "Save profile changes (⌘S)",
                    accessibilityLabel: "Save profile changes",
                    keyboardShortcut: KeyboardShortcut("s", modifiers: .command)
                ) {
                    do {
                        // ⚠️ Register A34: advisories are RETURNED now, not just logged. The
                        // save succeeded either way — the banner explains what may not work, it
                        // does not report a failure.
                        saveAdvisories = try profileService.saveProfile(editBuffer.draft)
                        editBuffer.markSaved()
                        toastManager.show("Profile saved", style: .success)
                    } catch {
                        // ⚠️ A toast and NOTHING else was the whole record of a failed save on the
                        // primary user-data write path. It disappears in seconds, so "my image generator
                        // config won't stick" arrived with no profile id, no type and no error to
                        // correlate against.
                        logger.error(
                            "[PROFILE] Save FAILED for '\(editBuffer.draft.displayName)' "
                            + "(\(editBuffer.draft.id), image generator): \(error.localizedDescription). "
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
}

// MARK: - Flux2 Model Picker

#if MLX_IMAGE_GEN

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
            // ⚠️ register B34 — the second copy of the snap rule lived here and is DELETED, not
            // rewritten. `snapToValidFlux2Model()` in the host owns it, runs on the same appear,
            // and now logs. Two copies of a rule is how this defect reached six pickers.

            // VRAM / memory info for the currently selected model
            if let model = selectedFlux2Model {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(theme.fontCaption2)
                    Text("~\(model.estimatedVRAM) GB unified memory required")
                        .font(theme.fontCaption2)
                }
                .foregroundColor(model.estimatedVRAM >= 40 ? theme.warningColor : theme.secondaryText)
            }
        }
    }
}
#endif // MLX_IMAGE_GEN
