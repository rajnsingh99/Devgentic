//
//  MLXModelPickerView.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//  Updated: Refactored to prioritize stability (Defaults to JSON Mode)
//

import SwiftUI

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
                                let toolNote = (filterForTools && profile.capability == .none)
                                    ? "  ⚠︎ tools unconfirmed" : ""
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

    private func attemptAutoSelect() {
        // Ensure we have models to select from
        guard let first = service.installedModels.first else { return }

        // Check if the current selection is valid (exists in the installed list)
        let isSelectionValid = service.isInstalled(repoId: selectedModel)

        // If nothing is selected OR the current selection is invalid (e.g. deleted), pick the first one.
        if selectedModel.isEmpty || !isSelectionValid {
            DispatchQueue.main.async {
                if filterForTools {
                    // Use cached profiles instead of calling detectCognitiveProfile inline
                    let validModel = service.installedModels.first(where: {
                        service.cachedCognitiveProfile(for: $0).capability != .none
                    })
                    let target = validModel ?? first
                    self.selectedModel = target.displayName
                    self.evaluateCognitiveCapability(for: target.displayName)
                } else {
                    self.selectedModel = first.displayName
                    self.evaluateCognitiveCapability(for: first.displayName)
                }
            }
        } else {
            // Even if valid, evaluate it on load in case the user toggled it manually before and we want to sync
            evaluateCognitiveCapability(for: selectedModel)
        }
    }

    private func evaluateCognitiveCapability(for modelName: String) {
        guard let model = service.installedModel(named: modelName) else { return }

        // Use cached profile — no file I/O on every evaluation
        let profile = service.cachedCognitiveProfile(for: model)

        DispatchQueue.main.async {
            self.cognitiveCapability = profile.capability
            self.modelDialect = profile.dialect
            self.modelMetadata = profile.metadata
            self.chatTemplateSource = profile.chatTemplateSource
            self.stopSequences = profile.stopSequences
            self.supportedModalities = profile.modalities
            self.currentFitAssessment = ModelFitAdvisor.assess(metadata: profile.metadata)

            if filterForTools && profile.capability == .none {
                self.showUnsupportedAlert = true
            }
        }
    }
}
