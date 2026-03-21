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
    @Binding var chatTemplateSource: ChatTemplateSource
    @Binding var stopSequences: [String]

    let profileID: UUID

    /// If true, incompatible models will be disabled/dimmed (Agents). If false, all are available (Bots).
    var filterForTools: Bool = false

    @Environment(\.appTheme) private var theme
    @EnvironmentObject private var router: MainViewRouter

    @StateObject private var service = MLXModelService.shared
    @State private var showUnsupportedAlert = false

    var body: some View {
        HStack {
            Button("Manage Models") {
                router.navigateToModelStore(backend: .mlx, profileID: profileID, filterForTools: filterForTools)
            }
            .fixedSize()
            Spacer()
            if service.installedModels.isEmpty {
                Text("No models found.")
                    .foregroundColor(theme.secondaryText)
                    .font(.caption)
            } else {
                Picker("Model", selection: $selectedModel) {
                    ForEach(service.installedModels) { model in
                        let profile = MLXTokenizerAnalyzer.detectCognitiveProfile(for: model.localPath, modelName: model.displayName)
                        let isUnsupported = filterForTools && profile.capability == .none
                        
                        Text(isUnsupported ? "\(model.displayName) (Chat Only)" : model.displayName)
                            .tag(model.displayName)
                            .disabled(isUnsupported)
                    }
                }
                .labelsHidden() // Hide label to prevent weird alignment issues
            }
        }
        .onAppear {
            service.refreshInstalledModels()
            attemptAutoSelect()
        }
        // Listen for async updates (e.g. scan completing)
        .onChange(of: selectedModel) { newValue in
            evaluateCognitiveCapability(for: newValue)
        }
        .alert("Unsupported Model", isPresented: $showUnsupportedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You have selected a Chat-Only model. Agent profiles require models with Tool Calling capabilities. Please select a supported model.")
        }
    }
    
    private func attemptAutoSelect() {
        // Ensure we have models to select from
        guard let first = service.installedModels.first else { return }
        
        // Check if the current selection is valid (exists in the installed list)
        let isSelectionValid = service.installedModels.contains { $0.displayName == selectedModel }
        
        // If nothing is selected OR the current selection is invalid (e.g. deleted), pick the first one.
        if selectedModel.isEmpty || !isSelectionValid {
            DispatchQueue.main.async {
                if filterForTools {
                    let validModel = service.installedModels.first(where: {
                        MLXTokenizerAnalyzer.detectCognitiveProfile(for: $0.localPath, modelName: $0.displayName).capability != .none
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
        guard let model = service.installedModels.first(where: { $0.displayName == modelName }) else { return }

        let profile = MLXTokenizerAnalyzer.detectCognitiveProfile(for: model.localPath, modelName: modelName)

        DispatchQueue.main.async {
            self.cognitiveCapability = profile.capability
            self.modelDialect = profile.dialect
            self.modelMetadata = profile.metadata
            self.chatTemplateSource = profile.chatTemplateSource
            self.stopSequences = profile.stopSequences

            if filterForTools && profile.capability == .none {
                self.showUnsupportedAlert = true
            }
        }
    }
}
