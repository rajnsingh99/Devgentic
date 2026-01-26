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


// MARK: - Ollama Model Picker View
struct OllamaModelPickerView: View {
    @Binding var selectedModel: String
    let baseURL: String
    
    /// If true, only models that support Tool Calling (Agents) will be displayed.
    var filterForTools: Bool = false

    @State private var models: [String] = []
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
    }

    private func fetchModels() {
        guard !baseURL.isEmpty, let url = URL(string: baseURL) else {
            self.errorMessage = "Invalid Base URL."
            self.models = []
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            // Determine which fetch strategy to use
            let fetchedModels: [String]
            
            if filterForTools {
                // Use the Capability Service to filter
                fetchedModels = await OllamaCapabilityService.shared.getAgentReadyModels(baseURL: url)
            } else {
                // Use the standard connector for raw list
                do {
                    fetchedModels = try await OllamaConnect.fetchLocalOllamaModels(baseURL: baseURL)
                } catch {
                    fetchedModels = []
                    await MainActor.run {
                         self.errorMessage = "Connection failed. Is Ollama running?"
                    }
                }
            }

            await MainActor.run {
                // Update UI State
                self.models = fetchedModels
                
                // Smart Selection Logic
                if !fetchedModels.isEmpty {
                    // If current selection is invalid, pick the first one
                    if !fetchedModels.contains(selectedModel) {
                        self.selectedModel = fetchedModels.first!
                    } else if selectedModel.isEmpty {
                        self.selectedModel = fetchedModels.first!
                    }
                } else if self.errorMessage == nil {
                    // Only show specific error if connection didn't fail earlier
                    if filterForTools {
                        self.errorMessage = "No models support Tools. Try Llama 3.1 or Qwen 2.5."
                    }
                }
                
                self.isLoading = false
            }
        }
    }
}
