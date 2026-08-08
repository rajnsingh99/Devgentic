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
import Flux2Core

private let logger = DGLogger(category: "ImageGenConfigDetail")

struct ImageGenConfigDetailView: View {
    @Bindable var editBuffer: ProfileEditBuffer
    var onDelete: ((UUID) -> Void)? = nil
    /// When non-nil, the dynamic-island leading button becomes a cancel (xmark)
    /// that invokes this closure (typically `dismiss()` from a modal host like
    /// `WorkflowProfileEditorView`). Also hides the trash icon.
    var onCancel: (() -> Void)? = nil
    @Environment(BackendProfileService.self) var profileService
    @Environment(ToastManager.self) private var toastManager
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    // Advanced config local state
    @State private var localAdvancedConfig: ImageGenAdvancedConfig = .default()

    // Guard flag: prevents onChange handlers from writing during initial load
    @State private var isLoadingAdvancedConfig = false

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
        Binding<ProviderConfig>(
            get: {
                if case .imageGen(let config) = editBuffer.draft.details { return config.llmConfig }
                return ProviderConfig(apiProvider: .openAI, modelName: "dall-e-3")
            },
            set: { newConfig in
                if case .imageGen(var config) = editBuffer.draft.details {
                    config.llmConfig = newConfig
                    editBuffer.draft.details = .imageGen(config)
                }
            }
        )
    }

    private var negativePromptBinding: Binding<String> {
        Binding<String>(
            get: {
                if case .imageGen(let config) = editBuffer.draft.details { return config.negativePrompt ?? "" }
                return ""
            },
            set: { newValue in
                if case .imageGen(var config) = editBuffer.draft.details {
                    config.negativePrompt = newValue.isEmpty ? nil : newValue
                    editBuffer.draft.details = .imageGen(config)
                }
            }
        )
    }

    private var aspectRatioBinding: Binding<ImageAspectRatio> {
        Binding<ImageAspectRatio>(
            get: {
                if case .imageGen(let config) = editBuffer.draft.details { return config.defaultAspectRatio ?? .square }
                return .square
            },
            set: { newValue in
                if case .imageGen(var config) = editBuffer.draft.details {
                    config.defaultAspectRatio = newValue
                    editBuffer.draft.details = .imageGen(config)
                }
            }
        )
    }

    private var advancedSettingsBinding: Binding<[String: JSONValue]?> {
        Binding<[String: JSONValue]?>(
            get: {
                if case .imageGen(let config) = editBuffer.draft.details { return config.advancedSettings }
                return nil
            },
            set: { newValue in
                if case .imageGen(var config) = editBuffer.draft.details {
                    config.advancedSettings = newValue
                    editBuffer.draft.details = .imageGen(config)
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
        VStack(spacing: 0) {
            // See AgentConfigDetailView for the rationale — `onCancel` swaps
            // the leading chevron for an xmark and routes it to the modal host.
            DynamicIslandBar(
                onBack: handleBackTap,
                leadingSymbol: onCancel != nil ? "xmark" : "chevron.left"
            ) {
                actionButtons
            }

            ScrollView {
                VStack(spacing: 32) {

                // ⚠️ Register A34. Sits at the top of the scroll view, where the user's eye already is
                // after pressing Save in the island bar above. Dismissible, and replaced on the next
                // save — never a permanent fixture, because an advisory describes a choice the user
                // already made rather than a fault they must fix.
                SaveAdvisoryBanner(advisories: saveAdvisories) {
                    withAnimation { saveAdvisories = [] }
                }

                // 1. Identity Header
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: ProfileType.imageGen.iconNameFilled)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)
                        .foregroundColor(.orange) // ImageGen specific color

                    VStack(alignment: .leading) {
                        TextField("Profile Name", text: profile.displayName)
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

                // 2. Inference Engine (Provider)
                SettingsCard(title: "Inference Engine", icon: "server.rack", theme: theme) {
                    VStack(alignment: .leading, spacing: 16) {
                        ProviderConfigSection(
                        providerConfig: providerConfig,
                        profileID: editBuffer.draft.id,
                        profileType: .imageGen,
                        customMLXContent: AnyView(
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
                    )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }

                // 3. Generation Defaults
                generationDefaultsSection

                // 4. Negative Prompt
                negativePromptSection

                // 5. Advanced Configuration
                SettingsCard(title: "Advanced Configuration", icon: "gearshape.2.fill", theme: theme) {
                    ImageGenSettingsView(
                        config: $localAdvancedConfig,
                        provider: providerConfig.wrappedValue.apiProvider
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }

                // 6. Capability Badge
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
            .padding(ViewLayout.containerPadding)
            .padding(.bottom, ViewLayout.containerPadding)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        } // end outer VStack
        .task {
            isLoadingAdvancedConfig = true
            loadAdvancedConfig()
            isLoadingAdvancedConfig = false
        }
        .onChange(of: providerConfig.wrappedValue.apiProvider) { _, _ in
            // When switching to MLX, immediately correct any invalid model name
            if providerConfig.wrappedValue.apiProvider == .mlx {
                snapToValidFlux2Model()
            }
            // Reload advanced config with provider-appropriate defaults
            isLoadingAdvancedConfig = true
            loadAdvancedConfig()
            isLoadingAdvancedConfig = false
        }
        .onChange(of: localAdvancedConfig) { _, _ in
            guard !isLoadingAdvancedConfig else { return }
            advancedSettingsBinding.wrappedValue = profileService.encodeConfig(from: localAdvancedConfig)
        }
        .unsavedChangesBackGuard(
            isDirty: editBuffer.isDirty,
            showingAlert: $showingBackAlert,
            onDiscard: { editBuffer.revert() },
            onLeave: { leaveEditor() }
        )
        // ⚠️ This modifier was MISSING. The trash button set `showingDeleteAlert = true` and
        // nothing rendered — no alert, no toast, no log, no deletion. `showingDeleteAlert` had
        // exactly two references in the whole file: its declaration and that assignment. The user
        // clicks repeatedly and concludes the app is frozen; the only working delete path was the
        // sidebar row's hover-trash, which is not discoverable from the screen they are on.
        // Mirrors BotConfigDetailView's alert so the three detail views behave identically.
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
            Text("Are you sure you want to delete this image generator? This action cannot be undone.")
        }
    }

    private func handleBackTap() {
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

                TextEditor(text: negativePromptBinding)
                    .font(theme.fontBody)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 80, maxHeight: 160)
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

    /// If the stored model name isn't a valid Flux2 inference model, reset to klein-4b.
    private func snapToValidFlux2Model() {
        let inferenceRawValues = Flux2Model.allCases
            .filter(\.isForInference)
            .map(\.rawValue)
        if !inferenceRawValues.contains(providerConfig.wrappedValue.modelName) {
            providerConfig.wrappedValue.modelName = Flux2Model.klein4B.rawValue
        }
    }

    private func loadAdvancedConfig() {
        let defaultConfig: ImageGenAdvancedConfig = providerConfig.wrappedValue.apiProvider == .mlx
            ? .mlxDefault()
            : .default()
        self.localAdvancedConfig = profileService.decodeConfig(
            from: advancedSettingsBinding.wrappedValue,
            as: ImageGenAdvancedConfig.self
        ) ?? defaultConfig
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
                    accessibilityLabel: "Revert unsaved changes",
                    keyboardShortcut: .cancelAction
                ) {
                    editBuffer.revert()
                    isLoadingAdvancedConfig = true
                    loadAdvancedConfig()
                    isLoadingAdvancedConfig = false
                }

                IslandPillButton(
                    title: "Save",
                    style: .primary,
                    accessibilityLabel: "Save profile changes",
                    keyboardShortcut: .defaultAction
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
            .onAppear {
                if !models.map(\.rawValue).contains(selectedModel) {
                    selectedModel = Flux2Model.klein4B.rawValue
                }
            }

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
