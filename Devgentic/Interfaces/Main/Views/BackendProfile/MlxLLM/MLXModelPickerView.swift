// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    /// ⚠️ register B13 — this picker is now the FIFTH caller of `ModelSelectionPolicy`, and the
    /// A44-era exception it used to carry is gone.
    ///
    /// That exception rested on "`isInstalled` is a local disk check, so an absent model genuinely
    /// cannot run — there is no 'daemon still starting' case to preserve." The premise is false,
    /// and the repo's own log lines say so two files away. `installedModels` can be non-empty while
    /// the model the user saved is missing from it for reasons that are entirely transient:
    ///
    ///   • `MLXModelsLocation` falls back to the DEFAULT directory when the bookmarked custom one
    ///     is "on an unmounted volume" or unreadable under TCC — and `setModelsDirectory` does not
    ///     move models, so the default tree stays populated and the scan returns a full list from
    ///     the wrong place.
    ///   • `scanDisk` deliberately HIDES a model with incomplete shards (mid-re-download, or an
    ///     interrupted update) and hides duplicate ids, while its siblings stay listed.
    ///
    /// The old guard caught only the all-empty case, which none of those trip. The consequence was
    /// identical to A37's: the binding is `$providerConfig.modelName`, i.e. the edit-buffer draft,
    /// so the rewrite persists on the next save — including A29's quit-time Save prompt. Plugging
    /// the external drive back in does not undo it.
    private func attemptAutoSelect() {
        guard let first = service.installedModels.first else { return }

        let fillCandidate: MLXModelItem = {
            guard filterForTools else { return first }
            // Cached profiles rather than an inline `detectCognitiveProfile` call.
            return service.installedModels.first {
                service.cachedCognitiveProfile(for: $0).capability != .none
            } ?? first
        }()

        switch ModelSelectionPolicy.resolve(
            saved: selectedModel,
            available: service.installedModels.map(\.displayName),
            fillCandidate: fillCandidate.displayName
        ) {
        case .fill(let candidate):
            logger.info(
                "[PROFILE] Filling an empty MLX model selection with '\(candidate)'. "
                + "CONSEQUENCE: the profile draft now names a model; nothing was overwritten."
            )
            selectedModel = candidate
            evaluateCognitiveCapability(for: candidate)

        case .keptUnlisted(let saved):
            // ⚠️ KEPT, not replaced. A model missing from the scan may be on an unmounted volume,
            // mid-re-download, or hidden by a models-directory fallback — all recoverable, none
            // distinguishable from a genuine uninstall at this layer. The picker shows it as
            // selected and the user can change it; nothing is silently rewritten under them.
            logger.notice(
                "[PROFILE] The saved MLX model '\(saved)' is not in the installed list. "
                + "CONSEQUENCE: it is KEPT as the profile's model and NOT replaced — the scan can "
                + "miss a model that is merely on an unmounted volume, mid-download, or in a "
                + "models directory that failed to resolve. Re-select manually if it is really gone."
            )
            evaluateCognitiveCapability(for: saved)

        case .keep:
            // Re-evaluate on load so a manual toggle stays in sync with the model's real capability.
            evaluateCognitiveCapability(for: selectedModel)

        case .nothingAvailable:
            break
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
