//
//  LocalModelDiscoveryGridView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI
import os

// Logger
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LocalModelDiscoveryGridView")

// MARK: - Local Model Discovery Grid View
struct LocalModelDiscoveryGridView: View {
    // Access the shared OllamaService
    @ObservedObject var ollamaService: OllamaService
    // Access the MainApplicationViewModel for general app state like selectedBackend
    @ObservedObject var mainViewModel: MainApplicationViewModel

    // Define a structure for discoverable models (can be expanded later)
    // This can remain here or be moved to a shared Models file if used elsewhere.
    struct DiscoverableModel: Identifiable, Hashable {
        let id = UUID()
        let name: String // e.g., "llama3:8b"
        let description: String
        let sizeEstimate: String // e.g., "5 GB"
    }

    // Placeholder list of models available for download
    // TODO: Replace this with dynamic fetching from Ollama or a manifest
    let discoverableModels: [DiscoverableModel] = [
        DiscoverableModel(name: "llama3:8b", description: "Meta's latest generation 8B parameter model.", sizeEstimate: "4.7 GB"),
        DiscoverableModel(name: "mistral:7b", description: "Popular 7B model known for efficiency and performance.", sizeEstimate: "4.1 GB"),
        DiscoverableModel(name: "phi3:mini", description: "Microsoft's powerful 3.8B parameter small language model.", sizeEstimate: "2.3 GB"),
        DiscoverableModel(name: "gemma:7b", description: "Google's family of lightweight, state-of-the-art open models.", sizeEstimate: "5.0 GB"),
        DiscoverableModel(name: "codellama:7b", description: "Code synthesis model based on Llama 2.", sizeEstimate: "4.1 GB"),
        DiscoverableModel(name: "llava:7b", description: "Large multimodal model connecting vision encoder and LLM.", sizeEstimate: "4.5 GB"),
        DiscoverableModel(name: "qwen:7b", description: "Alibaba Cloud's large vision language model.", sizeEstimate: "4.1 GB")
    ]

    // Grid layout definition
    let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Status/Error Area ---
            OllamaStatusView(ollamaService: ollamaService) // Pass OllamaService
                .padding(.horizontal)
                .padding(.bottom, 10)

            // Display general pull/remove errors from OllamaService
            if let pullError = ollamaService.modelPullError {
                Text("Error: \(pullError)")
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.bottom, 5)
            }
            if let removeError = ollamaService.modelRemoveError {
                Text("Removal Error: \(removeError)")
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.bottom, 5)
            }
            // --- End Status/Error Area ---

            // --- Scrollable Grid ---
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(discoverableModels) { model in
                        ModelCardView(
                            model: model,
                            ollamaService: ollamaService // Pass OllamaService
                        )
                    }
                }
                .padding() // Padding around the grid
            }
            // --- End Scrollable Grid ---
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
             // Clear any lingering status from other tabs or previous interactions
             ollamaService.clearAllModelActionStatuses()
             // Trigger a status check if Ollama is the selected backend and status is not connected
             if mainViewModel.selectedBackend == .ollama && ollamaService.serverStatus != .connected {
                  Task {
                       await ollamaService.checkServerStatusAndUpdateModels()
                  }
             }
        }
        .onDisappear {
            // Clear status messages when the view disappears to avoid showing stale info
            // if the user navigates away and comes back.
            ollamaService.clearAllModelActionStatuses()
        }
    }
}

// MARK: - Ollama Status View Helper
struct OllamaStatusView: View {
    @ObservedObject var ollamaService: OllamaService // Use OllamaService

    var body: some View {
        HStack {
            Image(systemName: ollamaService.serverStatus.systemImageName)
                .foregroundColor(ollamaService.serverStatus.color)
            Text("Ollama Status: \(ollamaService.serverStatus.description)")
                .font(.callout)

            Spacer()

            if ollamaService.serverStatus == .disconnected || ollamaService.serverStatus == .error {
                Button {
                    Task {
                        // Call action on OllamaService
                        await ollamaService.checkServerStatusAndUpdateModels()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Retry Connection")
                .disabled(ollamaService.serverStatus == .checking)
            } else if ollamaService.serverStatus == .checking {
                 ProgressView().controlSize(.small)
            }
        }
    }
}


// MARK: - Model Card View
struct ModelCardView: View {
    let model: LocalModelDiscoveryGridView.DiscoverableModel
    @ObservedObject var ollamaService: OllamaService // Use OllamaService

    private var isPullingThisModel: Bool {
        ollamaService.isPullingModel && ollamaService.modelToPull == model.name
    }

    private var isDownloaded: Bool {
        ollamaService.localModels.contains(model.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(model.description)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(model.sizeEstimate)
                    .font(.caption2)
                    .foregroundColor(.gray)
                Spacer()
            }
            .padding(.bottom, 5)

            // --- Action/Status Area ---
            if isPullingThisModel {
                VStack(alignment: .leading) {
                    ProgressView(value: ollamaService.pullProgress)
                        .progressViewStyle(.linear)
                    Text("\(ollamaService.pullStage.capitalized)... \(String(format: "%.0f%%", ollamaService.pullProgress * 100))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if isDownloaded {
                HStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Downloaded")
                        .font(.caption)
                }
            } else {
                HStack {
                    Spacer()
                    Button {
                        logger.info("Download button clicked for model: \(model.name)")
                        // Set the model name in OllamaService before calling pull
                        ollamaService.modelToPull = model.name
                        Task {
                            // Call action on OllamaService
                            await ollamaService.pullModel(name: model.name)
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(ollamaService.serverStatus != .connected ||
                              ollamaService.isPullingModel || // Disable if any model is pulling
                              ollamaService.isRemovingModel)   // Disable if any model is removing
                }
            }
            // --- End Action/Status Area ---
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
        .frame(minHeight: 140, alignment: .top)
    }
}

// MARK: - Preview Provider
struct LocalModelDiscoveryGridView_Previews: PreviewProvider {
    static var previews: some View {
        // Create mock OllamaService instances for different states
        let defaultOllamaService = OllamaService()
        defaultOllamaService.localModels = ["mistral:7b"]
        defaultOllamaService.serverStatus = .connected

        let pullingOllamaService = OllamaService()
        pullingOllamaService.localModels = ["mistral:7b"]
        pullingOllamaService.isPullingModel = true
        pullingOllamaService.modelToPull = "llama3:8b"
        pullingOllamaService.pullStage = "downloading manifest"
        pullingOllamaService.pullProgress = 0.15
        pullingOllamaService.serverStatus = .connected

        let disconnectedOllamaService = OllamaService()
        disconnectedOllamaService.serverStatus = .disconnected
        
        // Create a mock MainApplicationViewModel for the preview context
        // It needs an OllamaService instance.
        let mockMainViewModelDefault = MainApplicationViewModel(ollamaService: defaultOllamaService)
        let mockMainViewModelPulling = MainApplicationViewModel(ollamaService: pullingOllamaService)
        let mockMainViewModelDisconnected = MainApplicationViewModel(ollamaService: disconnectedOllamaService)


        return Group {
            LocalModelDiscoveryGridView(ollamaService: defaultOllamaService, mainViewModel: mockMainViewModelDefault)
                .previewDisplayName("Default State")

            LocalModelDiscoveryGridView(ollamaService: pullingOllamaService, mainViewModel: mockMainViewModelPulling)
                .previewDisplayName("Pulling State")

            LocalModelDiscoveryGridView(ollamaService: disconnectedOllamaService, mainViewModel: mockMainViewModelDisconnected)
                .previewDisplayName("Disconnected State")
        }
        .frame(width: 400, height: 600) // Simulate sidebar pane size
        .padding()
    }
}
