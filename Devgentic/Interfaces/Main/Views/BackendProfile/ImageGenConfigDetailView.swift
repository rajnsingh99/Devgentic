// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageGenConfigDetailView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
#if MLX_IMAGE_GEN   // see MLXImageGenService.swift for why on-device image generation is compiled out
import Flux2Core
#endif

private let logger = DGLogger(category: "ImageGenConfigDetail")

/// Configuration detail view for Image Generator profiles, with model pickers and capability-driven options.
/// Dirty tracking comes from `ProfileEditBuffer`.
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

    // Why: SwiftUI runs `.onChange` on the next update pass, so a flag set and cleared in one call is already false;
    // a baseline survives the deferral because it is compared, not raced.
    /// The exact dictionary the last `loadAdvancedConfig()` produced.
    /// The `.onChange` write-back guard compares against it instead of consulting a loading flag.
    @State private var loadedAdvancedBaseline: [String: JSONValue]?

    // Deletion State
    @State private var showingDeleteAlert = false

    // Unsaved-changes guard on back navigation.
    @State private var showingBackAlert = false

    /// Advisory findings from the last save, shown until dismissed or the next save.
    /// Cleared on every save so it always describes the current state of the profile.
    @State private var saveAdvisories: [ProfileValidationError] = []


    // MARK: - Convenience Accessors

    private var profile: Binding<BackendProfileModel> {
        $editBuffer.draft
    }

    // MARK: - Computed Bindings

    private var providerConfig: Binding<ProviderConfig> {
        // Capture the buffer, not `self`: referencing `editBuffer` captures the whole View struct including its
        // window manager, closing a retain cycle when the binding is handed to a long-lived window.
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
        let buffer = editBuffer   // Capture the buffer, never `self`.
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
        let buffer = editBuffer   // Capture the buffer, never `self`.
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
        let buffer = editBuffer   // Capture the buffer, never `self`.
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
            // Compare against what `load` produced rather than a flag, so merely opening a profile never reads as dirty
            // and an undecodable stored config is not overwritten with defaults on the next save.
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

            // Outside the ScrollView, directly under the pinned island bar that holds Save, so the advisory reaches
            // the user regardless of scroll position without an auto-scroll.
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

    // Why: the floating prompt editor commits only explicitly, so an unflushed buffer reads clean and drops typed text.
    /// Handles the back button, flushing pending floating-editor text before the dirty check.
    /// The flush is in the tap action, not in `isDirty:`, which is computed during a view update.
    /// A no-op in editors that register no commit hook.
    private func handleBackTap() {
        profileService.flushPendingEditorText()
        if editBuffer.isDirty {
            showingBackAlert = true
        } else {
            leaveEditor()
        }
    }

    /// The one way out of this editor.
    /// Runs the unsaved-changes check for both hosts; only the exit differs: dismiss the sheet or pop the router.
    private func leaveEditor() {
        if let onCancel {
            onCancel()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                router.goBack()
            }
        }
    }

    // MARK: - Sections

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
    /// Resolves the Flux2 model selection through `ModelSelectionPolicy`.
    /// An empty selection is filled; a stored non-empty name this build does not recognise is kept (`.keptUnlisted`).
    /// Keeping is safe: `MLXImageGenService.resolveFlux2Model` falls back to `.dev` and logs when it cannot map a name.
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

    // Why: the baseline is assigned in the same synchronous call as `localAdvancedConfig`,
    // because the guarded `.onChange` runs one update pass later and reads whatever is there by then.
    /// Decodes the stored advanced config into local state and records the baseline.
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
                    // No `.cancelAction`: Revert discards every unsaved edit without a prompt, so binding it to Esc would give a
                    // dirty editor a silent exit. Esc closes the sheet, which the unsaved-changes guard governs.
                    accessibilityLabel: "Revert unsaved changes"
                ) {
                    editBuffer.revert()
                    // The draft the advisory described has been replaced.
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
                        // The save succeeded either way: the banner explains what may not work and does not report a failure.
                        saveAdvisories = try profileService.saveProfile(editBuffer.draft)
                        editBuffer.markSaved()
                        toastManager.show("Profile saved", style: .success)
                    } catch {
                        // A toast alone is not a durable record of a failed save on the primary write path, so log it
                        // with the profile id, type and error.
                        logger.error(
                            "[PROFILE] Save FAILED for '\(editBuffer.draft.displayName)' "
                            + "(\(editBuffer.draft.id), image generator): \(error.localizedDescription). "
                            + "CONSEQUENCE: the edit buffer stays dirty and the persisted profile is "
                            + "unchanged; the user's edits are still on screen but not on disk."
                        )
                        // Clear on failure too: an advisory describes a profile that was saved,
                        // so a stale banner would contradict the error toast.
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
            // The Flux2 snap rule lives only in the host's `snapToValidFlux2Model()`; do not duplicate it here.

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
