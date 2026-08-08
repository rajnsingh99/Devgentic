//
//  MLXModelPickerView.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//  Updated: Refactored to prioritize stability (Defaults to JSON Mode)
//

import SwiftUI

/// ⚠️ Register A44: this file had NO logger at all, so a picker that writes seven profile fields —
/// model identity, capability, dialect, metadata, modalities, template source and stop sequences —
/// left nothing behind when it did so.
private let logger = DGLogger(category: "MLXModelPicker")

struct MLXModelPickerView: View {
    @Binding var selectedModel: String
    @Binding var cognitiveCapability: ModelCognitiveCapability
    @Binding var modelDialect: ModelDialect
    @Binding var modelMetadata: ModelMetadata?
    @Binding var supportedModalities: SupportedModalities
    @Binding var chatTemplateSource: ChatTemplateSource
    @Binding var stopSequences: [String]

    let profileID: UUID

    /// If true, incompatible models will be disabled/dimmed (Agents). If false, all are available (Bots).
    var filterForTools: Bool = false

    @Environment(\.appTheme) private var theme
    @Environment(MainViewRouter.self) private var router

    private var service: MLXModelService { MLXModelService.shared }
    @State private var showUnsupportedAlert = false
    @State private var currentFitAssessment: ModelFitAssessment?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                GlassActionButton(title: "Manage Models", icon: "slider.horizontal.3") {
                    router.navigateToModelStore(backend: .mlx, profileID: profileID, filterForTools: filterForTools)
                }
                Spacer()
                if service.installedModels.isEmpty {
                    Text("No models found.")
                        .foregroundColor(theme.secondaryText)
                        .font(.caption)
                } else {
                    // ⚠️ Every installed model stays listed, including in tool-filtering
                    // mode. This used to `filter` them out, so a model whose tool support the
                    // heuristic missed — any new family, re-quantized upload or personal
                    // fine-tune — could not be selected here at all, and the store's Installed
                    // tab hid it too. The doc comment on `filterForTools` has always said
                    // "disabled/dimmed"; the code deleted them instead.
                    // `showUnsupportedAlert` is the correct describe-and-warn shape and still
                    // fires on selection.
                    let visibleModels = service.installedModels

                    if visibleModels.isEmpty {
                        Text("No models found.")
                            .foregroundColor(theme.secondaryText)
                            .font(.caption)
                    } else {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(visibleModels) { model in
                                let profile = service.cachedCognitiveProfile(for: model)
                                // Vision badge: flag models the local VLM runtime can see images with.
                                let vision = profile.modalities.contains(.visionInput) ? "  👁 Vision" : ""
                                // Tool-capability is LABELLED, not enforced. In an Agent
                                // profile a model the heuristic can't confirm stays fully
                                // selectable; the warning alert explains the risk on
                                // selection and the user decides.
                                //
                                // The note now comes from the shared policy (register G95) so all
                                // three pickers word the same verdict identically. This picker was
                                // already the compliant one — the helper was extracted FROM its
                                // behaviour, not imposed on it. MLX carries no caveat, so a `.none`
                                // here is the Tier-0 name heuristic and correctly reads as
                                // "unconfirmed" rather than a flat "no tools".
                                let toolNote = ProfileCapabilityFilter.toolCapabilityNote(
                                    capability: profile.capability,
                                    caveat: profile.toolSupportCaveat,
                                    profileType: filterForTools ? .agent : .bot
                                ).map { "  \($0)" } ?? ""
                                Text(model.displayName + vision + toolNote)
                                    .tag(model.displayName)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            // Inline fit indicator
            if let assessment = currentFitAssessment, assessment.estimatedRuntimeRAM > 0 {
                ModelFitInlineView(assessment: assessment)
            }
        }
        // `.task` not `.onAppear`: the scan is off the MainActor now, so `attemptAutoSelect`
        // ran against an empty list and silently selected nothing — and nothing re-triggered
        // it once the scan landed, leaving the picker blank.
        .task {
            await service.ensureLoaded()
            // ⚠️ Register A44. The first-run scan can take seconds; the user may well have left the
            // profile by the time it lands. `.task` cancels on disappear, so honouring cancellation
            // here is what stops a late scan writing model identity and metadata into an editor
            // that is gone — the work below used to hop out to `DispatchQueue.main.async`, which
            // leaves the cancellation scope entirely and always ran.
            guard !Task.isCancelled else {
                logger.debug(
                    "[PROFILE] MLX model scan finished after the picker went away; skipping "
                    + "auto-select. CONSEQUENCE: none — the profile is untouched."
                )
                return
            }
            attemptAutoSelect()
        }
        // Listen for async updates (e.g. scan completing)
        .onChange(of: selectedModel) { _, newValue in
            evaluateCognitiveCapability(for: newValue)
        }
        .alert("Unsupported Model", isPresented: $showUnsupportedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("We couldn't confirm tool-calling support for this model, so agent runs may fail to call tools. This check is a name-based heuristic and is often wrong for new or re-quantized models — if you know it supports tools, keep it selected.")
        }
    }

    /// ⚠️ Register A44: the body of this used to be wrapped in `DispatchQueue.main.async`. Both
    /// callers — the `.task` above (after its `await`) and `.onChange(of:)` — are already on the
    /// MainActor, so the hop bought nothing and cost the two things that matter: the work escaped
    /// the `.task`'s cancellation scope, and it ran outside structured concurrency where no
    /// `Task.isCancelled` check could reach it. Writing directly keeps both callers inside the
    /// scope that owns them.
    private func attemptAutoSelect() {
        // Ensure we have models to select from
        guard let first = service.installedModels.first else { return }

        // Check if the current selection is valid (exists in the installed list)
        let isSelectionValid = service.isInstalled(repoId: selectedModel)

        // If nothing is selected OR the current selection is invalid (e.g. deleted), pick the first one.
        if selectedModel.isEmpty || !isSelectionValid {
            let target: MLXModelItem
            if filterForTools {
                // Use cached profiles instead of calling detectCognitiveProfile inline
                let validModel = service.installedModels.first(where: {
                    service.cachedCognitiveProfile(for: $0).capability != .none
                })
                target = validModel ?? first
            } else {
                target = first
            }

            // ⚠️ Unlike the cloud and Ollama pickers (registers G95 / MP-01 / A37), replacing the
            // selection here is DEFENSIBLE: `isInstalled` is a local disk check, and an MLX model
            // that is not on disk genuinely cannot run — there is no "the daemon is still starting"
            // or "hand-typed name" case to preserve. It must not be SILENT, though, which is what
            // it was: this is a profile-altering write with no record of having happened.
            if selectedModel.isEmpty {
                logger.info(
                    "[PROFILE] Filling an empty MLX model selection with '\(target.displayName)'. "
                    + "CONSEQUENCE: the profile draft now names a model; nothing was overwritten."
                )
            } else {
                logger.notice(
                    "[PROFILE] The saved MLX model '\(self.selectedModel)' is not installed; "
                    + "selecting '\(target.displayName)' instead. CONSEQUENCE: the profile draft's "
                    + "model is REPLACED — an uninstalled MLX model cannot run — and the editor is "
                    + "left dirty, so the change is only persisted if the user saves."
                )
            }

            selectedModel = target.displayName
            evaluateCognitiveCapability(for: target.displayName)
        } else {
            // Even if valid, evaluate it on load in case the user toggled it manually before and we want to sync
            evaluateCognitiveCapability(for: selectedModel)
        }
    }

    private func evaluateCognitiveCapability(for modelName: String) {
        guard let model = service.installedModel(named: modelName) else {
            logger.notice(
                "[PROFILE] No installed MLX model matches '\(modelName)'. CONSEQUENCE: capability, "
                + "dialect, metadata, modalities, template source and stop sequences are left as "
                + "stored rather than reset to values that cannot be justified."
            )
            return
        }

        // Use cached profile — no file I/O on every evaluation
        let profile = service.cachedCognitiveProfile(for: model)

        cognitiveCapability = profile.capability
        modelDialect = profile.dialect
        modelMetadata = profile.metadata
        chatTemplateSource = profile.chatTemplateSource
        stopSequences = profile.stopSequences
        supportedModalities = profile.modalities
        currentFitAssessment = ModelFitAdvisor.assess(metadata: profile.metadata)

        logger.info(
            "[PROFILE] Applied MLX detection for '\(modelName)': capability \(profile.capability.rawValue), "
            + "dialect \(profile.dialect.rawValue), template \(String(describing: profile.chatTemplateSource)), "
            + "\(profile.stopSequences.count) stop sequence(s)."
        )

        if filterForTools && profile.capability == .none {
            showUnsupportedAlert = true
        }
    }
}
