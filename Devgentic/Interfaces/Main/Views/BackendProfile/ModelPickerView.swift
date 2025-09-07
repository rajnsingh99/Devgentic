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

    @State private var models: [String] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        HStack {
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
            } else if models.isEmpty {
                 Text("No models found at this address.")
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
        guard !baseURL.isEmpty, let _ = URL(string: baseURL) else {
            self.errorMessage = "Invalid URL format."
            self.models = []
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                // This assumes a helper struct `OllamaConnect` exists to perform the network call.
                // let fetchedModels = try await OllamaConnect.fetchLocalOllamaModels(baseURL: baseURL)
                
                // --- Placeholder for network call ---
                try? await Task.sleep(nanoseconds: 1_000_000_000) // Simulate network delay
                let fetchedModels = ["llama3:latest", "gemma:7b", "mistral:latest"]
                // --- End Placeholder ---

                await MainActor.run {
                    self.models = fetchedModels
                    if !fetchedModels.contains(selectedModel), let firstModel = fetchedModels.first {
                        self.selectedModel = firstModel
                    }
                }
            } catch {
                await MainActor.run {
                    self.models = []
                    self.errorMessage = "Connection failed. Check Base URL."
                }
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }
}
