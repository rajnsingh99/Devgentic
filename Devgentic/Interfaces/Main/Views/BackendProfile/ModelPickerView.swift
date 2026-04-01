//
//  ModelPickerView.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//

import SwiftUI

struct GeminiModelPickerView: View {
    @Binding var selectedModel: String
    let apiKey: String
    
    @State private var models: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Verifying key...").foregroundColor(.secondary)
            } else if let errorMessage = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(errorMessage).foregroundColor(.secondary).font(.caption)
            } else if models.isEmpty {
                Text("Enter a valid API key to see models.").foregroundColor(.secondary).font(.caption)
            } else {
                Picker("Available Models", selection: $selectedModel) {
                    ForEach(models, id: \.self) { modelName in
                        Text(modelName).tag(modelName)
                    }
                }
            }
        }
        .onChange(of: apiKey) { _, _ in
             // Debounce the API call slightly to avoid firing on every keystroke
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                await fetchModels()
            }
        }
    }
    
    private func fetchModels() async {
        guard !apiKey.isEmpty else {
            self.models = []
            self.errorMessage = nil
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let fetchedModels = try await GeminiService().verifyAndFetchModels(apiKey: apiKey)
            await MainActor.run {
                self.models = fetchedModels
                if !fetchedModels.contains(selectedModel), let firstModel = fetchedModels.first {
                    self.selectedModel = firstModel
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.models = []
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}


// MARK: - Anthropic Model Picker View
struct AnthropicModelPickerView: View {
    @Binding var selectedModel: String
    let apiKey: String
    
    @State private var models: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Verifying key...").foregroundColor(.secondary)
            } else if let errorMessage = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(errorMessage).foregroundColor(.secondary).font(.caption)
            } else if models.isEmpty {
                Text("Enter a valid API key to see models.").foregroundColor(.secondary).font(.caption)
            } else {
                Picker("Available Models", selection: $selectedModel) {
                    ForEach(models, id: \.self) { modelName in
                        Text(modelName).tag(modelName)
                    }
                }
            }
        }
        .onAppear {
            if !apiKey.isEmpty && models.isEmpty {
                Task {
                    await fetchModels()
                }
            }
        }
        .onChange(of: apiKey) { _, _ in
             // Debounce the API call slightly to avoid firing on every keystroke
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                await fetchModels()
            }
        }
    }
    
    private func fetchModels() async {
        guard !apiKey.isEmpty else {
            self.models = []
            self.errorMessage = nil
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let fetchedModels = try await AnthropicService().verifyAndFetchModels(apiKey: apiKey)
            await MainActor.run {
                self.models = fetchedModels
                if !fetchedModels.contains(selectedModel), let firstModel = fetchedModels.first {
                    self.selectedModel = firstModel
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.models = []
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

// MARK: - OpenAI Model Picker View
struct OpenAIModelPickerView: View {
    @Binding var selectedModel: String
    let apiKey: String
    
    @State private var models: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        HStack {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Verifying key...").foregroundColor(.secondary)
            } else if let errorMessage = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                Text(errorMessage).foregroundColor(.secondary).font(.caption)
            } else if models.isEmpty {
                Text("Enter a valid API key to see models.").foregroundColor(.secondary).font(.caption)
            } else {
                Picker("Available Models", selection: $selectedModel) {
                    ForEach(models, id: \.self) { modelName in
                        Text(modelName).tag(modelName)
                    }
                }
            }
        }
        .onAppear {
            if !apiKey.isEmpty && models.isEmpty {
                Task {
                    await fetchModels()
                }
            }
        }
        .onChange(of: apiKey) { _, _ in
             // Debounce the API call slightly to avoid firing on every keystroke
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                await fetchModels()
            }
        }
    }
    
    private func fetchModels() async {
        guard !apiKey.isEmpty else {
            self.models = []
            self.errorMessage = nil
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let fetchedModels = try await OpenAIService().verifyAndFetchModels(apiKey: apiKey)
            await MainActor.run {
                self.models = fetchedModels
                if !fetchedModels.contains(selectedModel), let firstModel = fetchedModels.first {
                    self.selectedModel = firstModel
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.models = []
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}


// MARK: - Ollama Model Picker View
struct OllamaModelPickerView: View {
    @Binding var selectedModel: String
    @Binding var cognitiveCapability: ModelCognitiveCapability
    @Binding var modelDialect: ModelDialect
    @Binding var modelMetadata: ModelMetadata?

    let baseURL: String
    let profileID: UUID

    /// If true, incompatible models will be disabled/dimmed (Agents). If false, all are available (Bots).
    var filterForTools: Bool = false

    @EnvironmentObject private var router: MainViewRouter
    @State private var models: [String] = []
    @State private var loadedLocalModels: [LocalModel] = [] // Cache to look up capabilities
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    // Alert state for unsupported model selection
    @State private var showUnsupportedAlert: Bool = false
    @State private var currentFitAssessment: ModelFitAssessment?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Button("Manage Models") {
                    router.navigateToModelStore(backend: .ollama, profileID: profileID)
                }
                .fixedSize()

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading models...")
                        .foregroundColor(.secondary)
                } else if let errorMessage = errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else if loadedLocalModels.isEmpty {
                    Text("No models found.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    let visibleModels = filterForTools
                        ? loadedLocalModels.filter { $0.cognitiveCapability != .none }
                        : loadedLocalModels

                    if visibleModels.isEmpty && filterForTools {
                        Text("No tool-capable models found.")
                            .foregroundColor(.orange)
                            .font(.caption)
                    } else {
                        Picker("Available Models", selection: $selectedModel) {
                            ForEach(visibleModels, id: \.name) { model in
                                Text(model.name)
                                    .tag(model.name)
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
        .onAppear(perform: fetchModels)
        .onChange(of: baseURL) { _, _ in
            fetchModels()
        }
        .onChange(of: selectedModel) { _, newValue in
            handleSelectionChange(newValue: newValue)
        }
        .alert("Unsupported Model", isPresented: $showUnsupportedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You have selected a Chat-Only model. Agent profiles require models with Tool Calling capabilities. Please select a supported model.")
        }
    }

    private func fetchModels() {
        guard !baseURL.isEmpty, let _ = URL(string: baseURL) else {
            self.errorMessage = "Invalid Base URL."
            self.models = []
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let rawNames = try await OllamaConnect.fetchLocalOllamaModels(baseURL: baseURL)
                
                // Fetch rich details to evaluate capabilities
                var fetchedDetails: [LocalModel] = []
                await withTaskGroup(of: LocalModel?.self) { group in
                    for name in rawNames {
                        group.addTask {
                            do {
                                let response = try await OllamaConnect.fetchModelDetails(name: name, baseURL: baseURL)
                                return LocalModel(name: name, response: response)
                            } catch {
                                return nil
                            }
                        }
                    }
                    for await model in group {
                        if let m = model {
                            fetchedDetails.append(m)
                        }
                    }
                }
                
                // Sort models: If in Agent mode, put valid models first, chat-only at the bottom.
                // Then sort alphabetically within those respective groups.
                let sortedModels = fetchedDetails.sorted { m1, m2 in
                    if filterForTools {
                        let m1Supported = m1.cognitiveCapability != .none
                        let m2Supported = m2.cognitiveCapability != .none
                        
                        if m1Supported != m2Supported {
                            return m1Supported // Supported models bubble up to the top
                        }
                    }
                    // Fallback to alphabetical sorting
                    return m1.name < m2.name
                }
                let fetchedNames = sortedModels.map { $0.name }

                await MainActor.run {
                    self.loadedLocalModels = sortedModels
                    self.models = fetchedNames
                    
                    // Smart Selection Logic
                    if !sortedModels.isEmpty {
                        
                        // If the current selection is completely invalid (empty or missing), fallback to a sensible default
                        if !fetchedNames.contains(selectedModel) || selectedModel.isEmpty {
                            if filterForTools {
                                // Find the first model that actually supports Agent tools
                                self.selectedModel = sortedModels.first(where: { $0.cognitiveCapability != .none })?.name ?? fetchedNames.first!
                            } else {
                                self.selectedModel = fetchedNames.first!
                            }
                        }
                    } else if self.errorMessage == nil {
                        if filterForTools {
                            self.errorMessage = "No models available."
                        }
                    }
                    
                    // Bind the payload capability flag for the newly resolved selection
                    updateCapabilityLevel(for: self.selectedModel)
                    
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Connection failed. Is Ollama running?"
                    self.models = []
                    self.isLoading = false
                }
            }
        }
    }
    
    /// Updates capability bindings when user changes selection.
    private func handleSelectionChange(newValue: String) {
        guard !loadedLocalModels.isEmpty else { return }
        updateCapabilityLevel(for: newValue)
    }
    
    private func updateCapabilityLevel(for modelName: String) {
        if let matchedModel = loadedLocalModels.first(where: { $0.name == modelName }) {
            self.cognitiveCapability = matchedModel.cognitiveCapability
            self.modelDialect = matchedModel.modelDialect
            self.modelMetadata = matchedModel.cognitiveProfile.metadata
            self.currentFitAssessment = ModelFitAdvisor.assess(metadata: matchedModel.cognitiveProfile.metadata)
        }
    }
}
