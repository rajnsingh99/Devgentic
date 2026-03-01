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
        .onChange(of: apiKey) {
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
        .onChange(of: apiKey) {
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
        .onChange(of: apiKey) {
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
    @Binding var supportsNativeTools: Bool
    
    let baseURL: String
    
    /// If true, only models that support Tool Calling (Agents) will be displayed.
    var filterForTools: Bool = false

    @State private var models: [String] = []
    @State private var loadedLocalModels: [LocalModel] = [] // Cache to look up capabilities
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        HStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text(filterForTools ? "Finding agent-ready models..." : "Loading models...")
                    .foregroundColor(.secondary)
            } else if let errorMessage = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(errorMessage)
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else if models.isEmpty {
                 Text(filterForTools ? "No agent-capable models found." : "No models found.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                Picker("Available Models", selection: $selectedModel) {
                    ForEach(models, id: \.self) { modelName in
                        Text(modelName).tag(modelName)
                    }
                }
            }

            Spacer()

            Button(action: fetchModels) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh models")
            .disabled(isLoading)
        }
        .onAppear(perform: fetchModels)
        .onChange(of: baseURL) {
            fetchModels()
        }
        .onChange(of: selectedModel) {
            updateCapabilityFlag(for: selectedModel)
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
                
                let sortedModels = fetchedDetails.sorted { $0.name < $1.name }
                let validModels = filterForTools ? sortedModels.filter { $0.supportsNativeTools } : sortedModels
                let fetchedNames = validModels.map { $0.name }

                await MainActor.run {
                    self.loadedLocalModels = sortedModels
                    self.models = fetchedNames
                    
                    // Smart Selection Logic
                    if !fetchedNames.isEmpty {
                        if !fetchedNames.contains(selectedModel) || selectedModel.isEmpty {
                            self.selectedModel = fetchedNames.first!
                        }
                    } else if self.errorMessage == nil {
                        if filterForTools {
                            self.errorMessage = "No models support Tools. Try Llama 3.1 or Qwen 2.5."
                        }
                    }
                    
                    // Bind the payload capability flag for the newly resolved selection
                    updateCapabilityFlag(for: self.selectedModel)
                    
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
    
    private func updateCapabilityFlag(for modelName: String) {
        if let matchedModel = loadedLocalModels.first(where: { $0.name == modelName }) {
            self.supportsNativeTools = matchedModel.supportsNativeTools
        }
    }
}
