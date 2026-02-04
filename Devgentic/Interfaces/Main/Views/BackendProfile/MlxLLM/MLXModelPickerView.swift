//
//  MLXModelPickerView.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import SwiftUI

struct MLXModelPickerView: View {
    @Binding var selectedModel: String
    @StateObject private var service = MLXModelService.shared
    @State private var showingStore = false
    
    var body: some View {
        HStack {
            Button("Manage Models") {
                showingStore = true
            }
            .fixedSize()
            Spacer()
            if service.installedModels.isEmpty {
                Text("No models found.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                Picker("Model", selection: $selectedModel) {
                    ForEach(service.installedModels) { model in
                        Text(model.displayName).tag(model.displayName)
                    }
                }
                .labelsHidden() // Hide label to prevent weird alignment issues
            }
            
             // Forces the button to the far right edge
            
             // Prevents the button from being compressed
        }
        .onAppear {
            service.refreshInstalledModels()
            attemptAutoSelect()
        }
        // Listen for async updates (e.g. scan completing)
        .onChange(of: service.installedModels) { _ in
            attemptAutoSelect()
        }
        .sheet(isPresented: $showingStore) {
            MLXModelStoreView()
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
                self.selectedModel = first.displayName
            }
        }
    }
}
